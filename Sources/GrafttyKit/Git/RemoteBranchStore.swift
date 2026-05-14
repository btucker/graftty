import Foundation
import Observation
import os

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

    public init(
        remoteBranches: [BranchRef] = [],
        localBranches: [BranchRef] = [],
        upstreams: [String: String] = [:]
    ) {
        self.remoteBranches = remoteBranches
        self.localBranches = localBranches
        self.upstreams = upstreams
    }

    /// Back-compat: callers that previously read `branches: Set<String>`
    /// (e.g. `hasRemote`) now read the derived set.
    public var branches: Set<String> { Set(remoteBranches.map(\.name)) }

    /// Back-compat initializer for existing callers that pass a `Set<String>`.
    /// `lastCommitDate` is set to `Date.distantPast` for all refs.
    public init(branches: Set<String>, upstreams: [String: String] = [:]) {
        self.remoteBranches = branches.map { BranchRef(name: $0, lastCommitDate: .distantPast) }
        self.localBranches = []
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
    // ISO8601DateFormatter is thread-safe for date parsing; nonisolated(unsafe) acknowledges
    // the missing Sendable conformance while preserving the single-allocation benefit.
    private nonisolated(unsafe) static let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private nonisolated static let parseLogger = Logger(subsystem: "com.btucker.graftty", category: "RemoteBranchStore")

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

    /// Parses `git for-each-ref` heads output into `[local: remoteOnOrigin]`,
    /// dropping branches with no upstream or with a non-origin upstream.
    /// Accepts both the 2-column format `%(refname:short)\t%(upstream:short)`
    /// and the 3-column format `%(refname:short)\t%(committerdate:iso-strict)\t%(upstream:short)`;
    /// the upstream is always the last tab-separated field.
    nonisolated static func parseUpstreams(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let local = String(parts[0])
            let upstream = String(parts[parts.count - 1])
            guard !local.isEmpty, upstream.hasPrefix("origin/") else { continue }
            let remote = String(upstream.dropFirst("origin/".count))
            guard !remote.isEmpty, remote != "HEAD" else { continue }
            result[local] = remote
        }
        return result
    }

    nonisolated static func parseLocalBranchesWithDates(_ output: String) -> [BranchRef] {
        return output.split(whereSeparator: \.isNewline).compactMap { raw in
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let name = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard isEligibleLocalBranch(name) else { return nil }
            let dateString = String(parts[1])
            let date: Date
            if let parsed = Self.iso8601Formatter.date(from: dateString) {
                date = parsed
            } else {
                Self.parseLogger.info("RemoteBranchStore: failed to parse committerdate '\(dateString, privacy: .public)' for ref '\(name, privacy: .public)'")
                date = .distantPast
            }
            return BranchRef(name: name, lastCommitDate: date)
        }
    }

    nonisolated static func parseRemoteBranchesWithDates(_ output: String) -> [BranchRef] {
        return output.split(whereSeparator: \.isNewline).compactMap { raw in
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return nil }
            let ref = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard ref.hasPrefix("origin/") else { return nil }
            let name = String(ref.dropFirst("origin/".count))
            guard name != "HEAD", !name.isEmpty else { return nil }
            let dateString = String(parts[1])
            let date: Date
            if let parsed = Self.iso8601Formatter.date(from: dateString) {
                date = parsed
            } else {
                Self.parseLogger.info("RemoteBranchStore: failed to parse committerdate '\(dateString, privacy: .public)' for ref '\(name, privacy: .public)'")
                date = .distantPast
            }
            return BranchRef(name: name, lastCommitDate: date)
        }
    }

    public nonisolated static let defaultList: ListFunction = { repoPath in
        async let remotesTask = GitRunner.run(
            args: ["for-each-ref", "--format=%(refname:short)\t%(committerdate:iso-strict)", "refs/remotes/origin"],
            at: repoPath
        )
        async let headsTask = GitRunner.run(
            args: ["for-each-ref", "--format=%(refname:short)\t%(committerdate:iso-strict)\t%(upstream:short)", "refs/heads/"],
            at: repoPath
        )
        let (remotes, heads) = try await (remotesTask, headsTask)
        return RemoteBranchSnapshot(
            remoteBranches: parseRemoteBranchesWithDates(remotes),
            localBranches: parseLocalBranchesWithDates(heads),
            upstreams: parseUpstreams(heads)
        )
    }

    nonisolated static func parseUpstreamsForTesting(_ output: String) -> [String: String] {
        parseUpstreams(output)
    }

    nonisolated static func parseLocalBranchesWithDatesForTesting(_ output: String) -> [BranchRef] {
        parseLocalBranchesWithDates(output)
    }

    nonisolated static func parseRemoteBranchesWithDatesForTesting(_ output: String) -> [BranchRef] {
        parseRemoteBranchesWithDates(output)
    }
}
