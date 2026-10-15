import Foundation

/// Serializes opt-in tracking per repository. Failed targets remain attempted
/// until their upstream commit changes or the user re-enables tracking.
@MainActor
public final class GitAutoTracking {
    public struct Snapshot: Sendable {
        public let branch: String
        public let localCommit: String?
        public let remoteCommit: String?

        public init(branch: String, localCommit: String?, remoteCommit: String?) {
            self.branch = branch
            self.localCommit = localCommit
            self.remoteCommit = remoteCommit
        }
    }

    public enum Operation: Equatable, Sendable {
        case pull(path: String, branch: String)
        case merge(path: String, branch: String)
    }

    public typealias ReadSnapshot = @MainActor (RepoEntry) async -> Snapshot?
    /// False means the checkout was ineligible and no mutation was attempted.
    public typealias Perform = @MainActor (Operation) async throws -> Bool

    public struct Target: Codable, Equatable, Sendable {
        public let id: UUID
        public let upstreamBranch: String
        public let commit: String
    }

    private let readSnapshot: ReadSnapshot
    private let perform: Perform
    private let backgroundProcessLimiter: BackgroundProcessLimiter
    private var attempted: [String: Target] = [:]
    private var inFlight: Set<String> = []
    private var pending: Set<String> = []

    public init(
        readSnapshot: @escaping ReadSnapshot = GitAutoTracking.defaultReadSnapshot,
        perform: @escaping Perform = GitAutoTracking.defaultPerform,
        backgroundProcessLimiter: BackgroundProcessLimiter = BackgroundProcessLimiter(capacity: 4)
    ) {
        self.readSnapshot = readSnapshot
        self.perform = perform
        self.backgroundProcessLimiter = backgroundProcessLimiter
    }

    public nonisolated static func menuTitle(worktree: WorktreeEntry, repo: RepoEntry) -> String? {
        guard repo.isGitTracked, worktree.state.hasOnDiskWorktree,
              worktree.path == repo.path || worktree.isPinned else { return nil }
        return worktree.path == repo.path ? "Auto-Track Remote" : "Auto-Track Default Branch"
    }

    @discardableResult
    public nonisolated static func setEnabled(_ enabled: Bool, worktreeID: UUID, in repos: inout [RepoEntry]) -> Bool {
        for repoIndex in repos.indices {
            guard let index = repos[repoIndex].worktrees.firstIndex(where: { $0.id == worktreeID }),
                  menuTitle(worktree: repos[repoIndex].worktrees[index], repo: repos[repoIndex]) != nil else { continue }
            repos[repoIndex].worktrees[index].autoTrackEnabled = enabled
            repos[repoIndex].worktrees[index].autoTrackLastAttempt = nil
            return true
        }
        return false
    }

    public func reset(worktreePath: String) {
        attempted.removeValue(forKey: worktreePath)
    }

    public func refresh(
        repoPath: String,
        getRepo: @escaping @MainActor () -> RepoEntry?,
        recordAttempt: @escaping @MainActor (String, Target) -> Void = { _, _ in },
        onAttempt: @escaping @MainActor (String) -> Void
    ) async {
        guard inFlight.insert(repoPath).inserted else {
            pending.insert(repoPath)
            return
        }
        defer { inFlight.remove(repoPath) }
        repeat {
            pending.remove(repoPath)
            await backgroundProcessLimiter.run {
                await self.refreshOnce(getRepo: getRepo, recordAttempt: recordAttempt, onAttempt: onAttempt)
            }
        } while pending.contains(repoPath)
    }

    private func refreshOnce(
        getRepo: @MainActor () -> RepoEntry?,
        recordAttempt: @MainActor (String, Target) -> Void,
        onAttempt: @MainActor (String) -> Void
    ) async {
        guard let repo = getRepo(), repo.isGitTracked else { return }
        for worktree in repo.worktrees where !isEnabled(worktree, repo: repo) {
            attempted.removeValue(forKey: worktree.path)
        }
        guard repo.worktrees.contains(where: { isEnabled($0, repo: repo) }),
              var snapshot = await readSnapshot(repo) else { return }

        if let current = getRepo(), current.id == repo.id, current.path == repo.path,
           let home = current.worktrees.first(where: { $0.path == current.path }),
           isEnabled(home, repo: current), let commit = snapshot.remoteCommit {
            let pulled = await attempt(.pull(path: home.path, branch: snapshot.branch), worktree: home,
                                       snapshot: snapshot, commit: commit, recordAttempt: recordAttempt, onAttempt: onAttempt)
            // Pull may advance the local default branch. Read it again even on
            // failure, then fan out the actual local state to the linked agents.
            if pulled {
                guard let updated = await readSnapshot(current) else { return }
                snapshot = updated
            }
        }

        guard let commit = snapshot.localCommit else { return }
        for id in repo.worktrees.map(\.id) {
            guard let current = getRepo(), current.id == repo.id, current.path == repo.path,
                  let worktree = current.worktrees.first(where: { $0.id == id }),
                  worktree.path != current.path, isEnabled(worktree, repo: current),
                  !worktree.branch.isEmpty, worktree.branch != snapshot.branch else { continue }
            _ = await attempt(.merge(path: worktree.path, branch: snapshot.branch), worktree: worktree,
                              snapshot: snapshot, commit: commit, recordAttempt: recordAttempt, onAttempt: onAttempt)
        }
    }

    private func isEnabled(_ worktree: WorktreeEntry, repo: RepoEntry) -> Bool {
        worktree.autoTrackEnabled && Self.menuTitle(worktree: worktree, repo: repo) != nil
    }

    private func attempt(
        _ operation: Operation,
        worktree: WorktreeEntry,
        snapshot: Snapshot,
        commit: String,
        recordAttempt: @MainActor (String, Target) -> Void,
        onAttempt: @MainActor (String) -> Void
    ) async -> Bool {
        let target = Target(id: worktree.id, upstreamBranch: snapshot.branch, commit: commit)
        guard attempted[worktree.path] != target, worktree.autoTrackLastAttempt != target else { return false }
        // Mark before awaiting so failure events cannot trigger a retry loop.
        attempted[worktree.path] = target
        do {
            guard try await perform(operation) else {
                if attempted[worktree.path] == target { attempted.removeValue(forKey: worktree.path) }
                return false
            }
        } catch {
            NSLog("[Graftty] auto-tracking failed for %@: %@", worktree.path, String(describing: error))
        }
        // A toggle reset during the await belongs to the new opt-in and must
        // not be overwritten by this older operation's completion.
        if attempted[worktree.path] == target { recordAttempt(worktree.path, target) }
        onAttempt(worktree.path)
        return true
    }

    public nonisolated static let defaultReadSnapshot: ReadSnapshot = { repo in
        await readSnapshot(repo, using: nil)
    }

    static func readSnapshot(_ repo: RepoEntry, using executor: CLIExecutor?) async -> Snapshot? {
        let deadline = GitCommandDeadline(timeout: .seconds(20))
        let resolved = await GitOriginDefaultBranch.resolve(repoPath: repo.path, deadline: deadline, using: executor)
        guard let branch = resolved ?? repo.defaultBranchHint, !branch.isEmpty else { return nil }
        func commit(_ ref: String) async -> String? {
            guard let output = try? await GitRunner.run(
                args: ["rev-parse", "--verify", "\(ref)^{commit}"], at: repo.path,
                timeout: deadline.remaining(), using: executor
            ) else { return nil }
            let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let local = await commit("refs/heads/\(branch)")
        let remote = await commit("refs/remotes/origin/\(branch)")
        return Snapshot(branch: branch, localCommit: local, remoteCommit: remote)
    }

    public nonisolated static let defaultPerform: Perform = { operation in
        try await perform(operation, using: nil)
    }

    @discardableResult
    static func perform(_ operation: Operation, using executor: CLIExecutor?) async throws -> Bool {
        let path: String
        let branch: String
        let args: [String]
        switch operation {
        case .pull(let checkout, let upstream):
            path = checkout
            branch = upstream
            args = ["pull", "--no-edit", "origin", branch]
        case .merge(let checkout, let upstream):
            path = checkout
            branch = upstream
            args = ["merge", "--no-edit", "--", "refs/heads/\(branch)"]
        }
        let deadline = GitCommandDeadline(timeout: .seconds(20))
        let current = try await GitRunner.run(args: ["branch", "--show-current"], at: path,
                                              timeout: deadline.remaining(), using: executor)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Never pull a feature branch in the main checkout, or merge into a
        // detached HEAD/default branch after a checkout raced the monitor.
        switch operation {
        case .pull: guard current == branch else { return false }
        case .merge: guard !current.isEmpty, current != branch else { return false }
        }
        _ = try await GitRunner.run(args: args, at: path, timeout: deadline.remaining(), using: executor)
        return true
    }
}
