import Foundation
import Observation
#if canImport(os)
import os
#endif

public struct BranchRef: Sendable, Equatable, Hashable {
    public let name: String
    public let lastCommitDate: Date

    public init(name: String, lastCommitDate: Date) {
        self.name = name
        self.lastCommitDate = lastCommitDate
    }
}

/// @spec PR-8.23
/// Per-repo remote-branch snapshot. `upstreams` is keyed by the
/// local branch name and resolves to the remote-side ref `git push`
/// would update — populated only for origin-tracked branches, so PR
/// lookup can ignore branches that don't map to a PR/MR head ref.
public struct RemoteBranchSnapshot: Sendable, Equatable {
    public let remoteBranches: [BranchRef]
    public let localBranches: [BranchRef]
    public let upstreams: [String: String]
    /// @spec LAYOUT-2.29
    /// Repository's default branch derived from origin/HEAD's symbolic-ref in
    /// the combined local-ref scan, with a main/master/develop ref fallback.
    /// `nil` when no default branch can be identified.
    public let defaultBranch: String?

    public init(
        remoteBranches: [BranchRef] = [],
        localBranches: [BranchRef] = [],
        upstreams: [String: String] = [:],
        defaultBranch: String? = nil
    ) {
        self.remoteBranches = remoteBranches
        self.localBranches = localBranches
        self.upstreams = upstreams
        self.defaultBranch = defaultBranch
    }

    /// Back-compat: callers that previously read `branches: Set<String>`
    /// (e.g. `hasRemote`) now read the derived set.
    public var branches: Set<String> { Set(remoteBranches.map(\.name)) }
}

@MainActor
@Observable
public final class RemoteBranchStore {
    public private(set) var branchesByRepo: [String: RemoteBranchSnapshot] = [:]

    public typealias ListFunction = @Sendable (_ repoPath: String) async throws -> RemoteBranchSnapshot

    /// Called after every scan finishes, applied or discarded.
    @ObservationIgnored var onScanFinishedForTesting: (@MainActor () -> Void)?
    @ObservationIgnored public var onChange: (@MainActor (_ repoPath: String, _ old: Set<String>, _ new: Set<String>) -> Void)?
    @ObservationIgnored private let list: ListFunction
    /// Per-repo scan slots, abandonment, and the polling cursor.
    @ObservationIgnored private let scheduler: RepoPollScheduler
    /// Repos with one trailing scan queued behind a live one, and the
    /// completions waiting on that trailing scan.
    @ObservationIgnored private var pendingRerun: Set<String> = []
    @ObservationIgnored private var pendingCompletions: [String: [@MainActor () -> Void]] = [:]
    /// Completions keyed by the generation of the scan they wait on.
    @ObservationIgnored private var completions: [String: [Int: [@MainActor () -> Void]]] = [:]
    @ObservationIgnored private var ticker: PollingTickerLike?
    @ObservationIgnored private var getRepos: @MainActor () -> [RepoEntry] = { [] }
    @ObservationIgnored private let logger = Logger(subsystem: "com.btucker.graftty", category: "RemoteBranchStore")
    // ISO8601DateFormatter is thread-safe for date parsing; nonisolated(unsafe) acknowledges
    // the missing Sendable conformance while preserving the single-allocation benefit.
    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private nonisolated static let parseLogger = Logger(subsystem: "com.btucker.graftty", category: "RemoteBranchStore")

    public init(
        list: @escaping ListFunction = RemoteBranchStore.defaultList,
        backgroundProcessLimiter: BackgroundProcessLimiter = BackgroundProcessLimiter(capacity: 4)
    ) {
        self.list = list
        self.scheduler = RepoPollScheduler(limiter: backgroundProcessLimiter)
        scheduler.bind(owner: self)
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

    /// Resolves the main-checkout label's primary text for a repo:
    /// the live `origin/HEAD`-derived value (from the latest snapshot)
    /// if available, else the hint persisted at add-repo time. Returns
    /// `nil` only when neither source is known — callers (specifically
    /// `SidebarWorktreeLabel.text`) fall back to `"main"` at the boundary.
    public func resolvedDefaultBranch(forRepoAt repoPath: String, hint: String?) -> String? {
        branchesByRepo[repoPath]?.defaultBranch ?? hint
    }

    public func clear(repoPath: String) {
        branchesByRepo.removeValue(forKey: repoPath)
        pendingRerun.remove(repoPath)
        pendingCompletions.removeValue(forKey: repoPath)
        scheduler.invalidate(repoPath)
    }

    func isInFlightForTesting(_ repoPath: String) -> Bool {
        scheduler.isInFlight(repoPath)
    }

    /// Simulates a scan that started at `date` and is still running.
    func seedInFlightSinceForTesting(_ date: Date, forRepo repoPath: String) {
        scheduler.seedInFlightForTesting(repoPath, since: date)
    }

    public func start(
        ticker: PollingTickerLike,
        getRepos: @escaping @MainActor () -> [RepoEntry]
    ) {
        stop()
        self.ticker = ticker
        self.getRepos = getRepos
        ticker.start { [weak self] in
            self?.pollTick()
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

    private func pollTick() {
        let repos = getRepos().filter(\.isGitTracked)
        let batch = scheduler.nextBatch(from: repos, path: \.path)
        for repo in batch {
            refresh(repoPath: repo.path)
        }
    }

    public func refresh(repoPath: String, completion: (@MainActor () -> Void)? = nil) {
        if scheduler.isLive(repoPath) {
            // Coalesce into one trailing scan so a ref change observed
            // during the live scan is not missed. A scan past the
            // abandonment threshold no longer coalesces: the code below
            // supersedes it and starts the queued rerun now (GIT-2.12).
            pendingRerun.insert(repoPath)
            if let completion {
                pendingCompletions[repoPath, default: []].append(completion)
            }
            return
        }

        // A slot still in flight here holds an abandoned scan whose result
        // will be discarded, so its waiters join the fresh scan instead of
        // running on that discarded result (or never, if it stays hung).
        var callbacks: [@MainActor () -> Void] = []
        if scheduler.isInFlight(repoPath),
           let abandoned = completions.removeValue(forKey: repoPath) {
            callbacks = abandoned.sorted { $0.key < $1.key }.flatMap(\.value)
        }
        pendingRerun.remove(repoPath)
        callbacks += pendingCompletions.removeValue(forKey: repoPath) ?? []
        if let completion {
            callbacks.append(completion)
        }
        beginRefresh(repoPath: repoPath, callbacks: callbacks)
    }

    private func beginRefresh(
        repoPath: String,
        callbacks: [@MainActor () -> Void]
    ) {
        let refreshGeneration = scheduler.claim(repoPath)
        if !callbacks.isEmpty {
            completions[repoPath, default: [:]][refreshGeneration] = callbacks
        }
        let list = self.list
        let scheduler = self.scheduler
        Task { [weak self] in
            do {
                let snapshot = try await scheduler.run(repoPath, generation: refreshGeneration) {
                    try await list(repoPath)
                }
                if let snapshot {
                    self?.apply(
                        repoPath: repoPath,
                        snapshot: snapshot,
                        refreshGeneration: refreshGeneration
                    )
                } else {
                    self?.finish(
                        repoPath: repoPath,
                        refreshGeneration: refreshGeneration
                    )
                }
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
        guard scheduler.isCurrent(repoPath, generation: refreshGeneration) else { return }
        let oldSnapshot = branchesByRepo[repoPath]
        let oldBranches = oldSnapshot?.branches ?? []
        guard oldSnapshot != snapshot else { return }
        branchesByRepo[repoPath] = snapshot
        if oldBranches != snapshot.branches {
            onChange?(repoPath, oldBranches, snapshot.branches)
        }
    }

    private func finish(repoPath: String, refreshGeneration: Int) {
        let ownedSlot = scheduler.release(repoPath, generation: refreshGeneration)

        let callbacks = completions[repoPath]?[refreshGeneration] ?? []
        completions[repoPath]?[refreshGeneration] = nil
        if completions[repoPath]?.isEmpty == true {
            completions.removeValue(forKey: repoPath)
        }

        if ownedSlot, pendingRerun.remove(repoPath) != nil {
            beginRefresh(
                repoPath: repoPath,
                callbacks: pendingCompletions.removeValue(forKey: repoPath) ?? []
            )
        }

        for callback in callbacks {
            callback()
        }
        onScanFinishedForTesting?()
    }

    nonisolated static func isEligibleLocalBranch(_ branch: String) -> Bool {
        if branch.hasPrefix("(") && branch.hasSuffix(")") { return false }
        return !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parses the single `for-each-ref` result used by `defaultList`.
    /// Full ref names make heads and origin refs unambiguous; the upstream
    /// and symbolic-ref columns provide the remaining snapshot metadata
    /// without launching separate Git probes.
    nonisolated static func parseCombinedRefs(_ output: String) -> RemoteBranchSnapshot {
        let localPrefix = "refs/heads/"
        let remotePrefix = "refs/remotes/origin/"
        var remoteBranches: [BranchRef] = []
        var localBranches: [BranchRef] = []
        var upstreams: [String: String] = [:]
        var defaultBranch: String?

        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 4 else { continue }
            let refName = String(parts[0])
            let dateString = String(parts[1])

            if refName.hasPrefix(localPrefix) {
                let localName = String(refName.dropFirst(localPrefix.count))
                guard isEligibleLocalBranch(localName) else { continue }
                localBranches.append(BranchRef(
                    name: localName,
                    lastCommitDate: parseCommitDate(dateString, refName: localName)
                ))

                let upstreamRef = String(parts[2])
                if upstreamRef.hasPrefix(remotePrefix) {
                    let remoteName = String(upstreamRef.dropFirst(remotePrefix.count))
                    if !remoteName.isEmpty, remoteName != "HEAD" {
                        upstreams[localName] = remoteName
                    }
                }
                continue
            }

            guard refName.hasPrefix(remotePrefix) else { continue }
            let remoteName = String(refName.dropFirst(remotePrefix.count))
            if remoteName == "HEAD" {
                let symbolicRef = String(parts[3])
                if symbolicRef.hasPrefix(remotePrefix) {
                    let name = String(symbolicRef.dropFirst(remotePrefix.count))
                    if !name.isEmpty, name != "HEAD" {
                        defaultBranch = name
                    }
                }
                continue
            }
            guard !remoteName.isEmpty else { continue }
            remoteBranches.append(BranchRef(
                name: remoteName,
                lastCommitDate: parseCommitDate(dateString, refName: remoteName)
            ))
        }

        if defaultBranch == nil {
            let remoteNames = Set(remoteBranches.map(\.name))
            defaultBranch = ["main", "master", "develop"].first {
                remoteNames.contains($0)
            }
        }

        return RemoteBranchSnapshot(
            remoteBranches: remoteBranches,
            localBranches: localBranches,
            upstreams: upstreams,
            defaultBranch: defaultBranch
        )
    }

    nonisolated private static func parseCommitDate(
        _ dateString: String,
        refName: String
    ) -> Date {
        if let parsed = Self.iso8601Formatter.date(from: dateString) {
            return parsed
        }
        Self.parseLogger.info("RemoteBranchStore: failed to parse committerdate '\(dateString, privacy: .public)' for ref '\(refName, privacy: .public)'")
        return .distantPast
    }

    public nonisolated static let defaultList: ListFunction = makeDefaultList()

    nonisolated static func scanTimeout() -> Duration {
        .seconds(20)
    }

    /// Builds the recurring local-ref scan with one shared deadline and an
    /// executor seam for race-free timeout propagation tests.
    nonisolated static func makeDefaultList(
        executor: CLIExecutor? = nil,
        timeout: Duration = scanTimeout()
    ) -> ListFunction {
        { repoPath in
            let deadline = GitCommandDeadline(timeout: timeout)
            let output = try await GitRunner.run(
                args: [
                    "for-each-ref",
                    "--format=%(refname)\t%(committerdate:iso-strict)\t%(upstream)\t%(symref)",
                    "refs/heads/",
                    "refs/remotes/origin",
                ],
                at: repoPath,
                timeout: try deadline.remaining(),
                using: executor
            )
            return parseCombinedRefs(output)
        }
    }

}
