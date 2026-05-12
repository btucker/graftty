import Foundation
import Observation
import os

/// @spec PR-8.23
/// Per-repo remote-branch snapshot. `upstreams` is keyed by the
/// local branch name and resolves to the remote-side ref `git push`
/// would update — populated only for origin-tracked branches, so PR
/// lookup can ignore branches that don't map to a PR/MR head ref.
public struct RemoteBranchSnapshot: Sendable, Equatable {
    public let branches: Set<String>
    public let upstreams: [String: String]

    public init(branches: Set<String>, upstreams: [String: String] = [:]) {
        self.branches = branches
        self.upstreams = upstreams
    }
}

@MainActor
@Observable
public final class RemoteBranchStore {
    public private(set) var branchesByRepo: [String: RemoteBranchSnapshot] = [:]

    public typealias ListFunction = @Sendable (_ repoPath: String) async throws -> RemoteBranchSnapshot

    @ObservationIgnored public var onChange: (@MainActor (_ repoPath: String, _ old: Set<String>, _ new: Set<String>) -> Void)?
    @ObservationIgnored private let list: ListFunction
    @ObservationIgnored private var inFlight: [String: Int] = [:]
    @ObservationIgnored private var generation: [String: Int] = [:]
    @ObservationIgnored private var pendingRerun: [String: Int] = [:]
    @ObservationIgnored private var completions: [String: [Int: [@MainActor () -> Void]]] = [:]
    @ObservationIgnored private var ticker: PollingTickerLike?
    @ObservationIgnored private var getRepos: @MainActor () -> [RepoEntry] = { [] }
    @ObservationIgnored private let logger = Logger(subsystem: "com.btucker.graftty", category: "RemoteBranchStore")

    public init(list: @escaping ListFunction = RemoteBranchStore.defaultList) {
        self.list = list
    }

    /// True iff `branch` has an upstream tracked under origin, or a
    /// same-named remote ref already exists (pushed without tracking).
    public func hasRemote(repoPath: String, branch: String) -> Bool {
        guard Self.isEligibleLocalBranch(branch) else { return false }
        guard let info = branchesByRepo[repoPath] else { return false }
        if info.upstreams[branch] != nil { return true }
        return info.branches.contains(branch)
    }

    /// `branch.<local>.merge` resolved to its origin-side ref name,
    /// or nil if the branch has no origin upstream. Callers fall
    /// back to the local branch name for PR lookup when nil.
    public func upstreamRemoteBranch(repoPath: String, branch: String) -> String? {
        branchesByRepo[repoPath]?.upstreams[branch]
    }

    public func clear(repoPath: String) {
        branchesByRepo.removeValue(forKey: repoPath)
        inFlight.removeValue(forKey: repoPath)
        if let pendingGeneration = pendingRerun.removeValue(forKey: repoPath) {
            completions[repoPath]?[pendingGeneration] = nil
            if completions[repoPath]?.isEmpty == true {
                completions.removeValue(forKey: repoPath)
            }
        }
        generation[repoPath, default: 0] += 1
    }

    public func start(
        ticker: PollingTickerLike,
        getRepos: @escaping @MainActor () -> [RepoEntry]
    ) {
        stop()
        self.ticker = ticker
        self.getRepos = getRepos
        ticker.start { [weak self] in
            guard let self else { return }
            for repo in self.getRepos() where repo.isGitTracked {
                self.refresh(repoPath: repo.path)
            }
        }
    }

    public func stop() {
        ticker?.stop()
        ticker = nil
        getRepos = { [] }
    }

    public func pulse() {
        ticker?.pulse()
    }

    public func refresh(repoPath: String, completion: (@MainActor () -> Void)? = nil) {
        if inFlight[repoPath] != nil {
            let refreshGeneration: Int
            if let pendingGeneration = pendingRerun[repoPath] {
                refreshGeneration = pendingGeneration
            } else {
                refreshGeneration = generation[repoPath, default: 0] + 1
                pendingRerun[repoPath] = refreshGeneration
            }
            if let completion {
                completions[repoPath, default: [:]][refreshGeneration, default: []].append(completion)
            }
            return
        }

        generation[repoPath, default: 0] += 1
        let refreshGeneration = generation[repoPath, default: 0]
        beginRefresh(repoPath: repoPath, refreshGeneration: refreshGeneration, completion: completion)
    }

    private func beginRefresh(
        repoPath: String,
        refreshGeneration: Int,
        completion: (@MainActor () -> Void)? = nil
    ) {
        generation[repoPath] = refreshGeneration
        inFlight[repoPath] = refreshGeneration
        if let completion {
            completions[repoPath, default: [:]][refreshGeneration, default: []].append(completion)
        }
        let list = self.list
        Task { [weak self] in
            do {
                let snapshot = try await list(repoPath)
                self?.apply(repoPath: repoPath, snapshot: snapshot, refreshGeneration: refreshGeneration)
            } catch {
                self?.logger.info("remote branch scan failed for \(repoPath): \(String(describing: error))")
                self?.finish(repoPath: repoPath, refreshGeneration: refreshGeneration)
            }
        }
    }

    private func apply(repoPath: String, snapshot: RemoteBranchSnapshot, refreshGeneration: Int) {
        defer {
            finish(repoPath: repoPath, refreshGeneration: refreshGeneration)
        }
        guard generation[repoPath, default: 0] == refreshGeneration else { return }
        let oldSnapshot = branchesByRepo[repoPath]
        let oldBranches = oldSnapshot?.branches ?? []
        guard oldSnapshot != snapshot else { return }
        branchesByRepo[repoPath] = snapshot
        if oldBranches != snapshot.branches {
            onChange?(repoPath, oldBranches, snapshot.branches)
        }
    }

    private func finish(repoPath: String, refreshGeneration: Int) {
        let shouldStartPending = inFlight[repoPath] == refreshGeneration
        if inFlight[repoPath] == refreshGeneration {
            inFlight.removeValue(forKey: repoPath)
        }

        let callbacks = completions[repoPath]?[refreshGeneration] ?? []
        completions[repoPath]?[refreshGeneration] = nil
        if completions[repoPath]?.isEmpty == true {
            completions.removeValue(forKey: repoPath)
        }

        if shouldStartPending, let pendingGeneration = pendingRerun.removeValue(forKey: repoPath) {
            beginRefresh(repoPath: repoPath, refreshGeneration: pendingGeneration)
        }

        for callback in callbacks {
            callback()
        }
    }

    nonisolated static func isEligibleLocalBranch(_ branch: String) -> Bool {
        if branch.hasPrefix("(") && branch.hasSuffix(")") { return false }
        return !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static func parseRefs(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { raw in
            let ref = String(raw)
            guard ref.hasPrefix("origin/") else { return nil }
            let branch = String(ref.dropFirst("origin/".count))
            guard branch != "HEAD" else { return nil }
            return branch
        })
    }

    /// Parses `git for-each-ref --format=%(refname:short)\t%(upstream:short) refs/heads/`
    /// into `[local: remoteOnOrigin]`, dropping branches with no
    /// upstream or with a non-origin upstream.
    nonisolated static func parseUpstreams(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let local = String(parts[0])
            let upstream = String(parts[1])
            guard !local.isEmpty, upstream.hasPrefix("origin/") else { continue }
            let remote = String(upstream.dropFirst("origin/".count))
            guard !remote.isEmpty, remote != "HEAD" else { continue }
            result[local] = remote
        }
        return result
    }

    public nonisolated static let defaultList: ListFunction = { repoPath in
        async let remotesTask = GitRunner.run(
            args: ["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"],
            at: repoPath
        )
        async let headsTask = GitRunner.run(
            args: ["for-each-ref", "--format=%(refname:short)\t%(upstream:short)", "refs/heads/"],
            at: repoPath
        )
        let (remotes, heads) = try await (remotesTask, headsTask)
        return RemoteBranchSnapshot(
            branches: parseRefs(remotes),
            upstreams: parseUpstreams(heads)
        )
    }

    nonisolated static func parseRefsForTesting(_ output: String) -> Set<String> {
        parseRefs(output)
    }

    nonisolated static func parseUpstreamsForTesting(_ output: String) -> [String: String] {
        parseUpstreams(output)
    }
}
