import Foundation
import Observation
import os

@MainActor
@Observable
public final class RemoteBranchStore {
    public private(set) var branchesByRepo: [String: Set<String>] = [:]

    public typealias ListFunction = @Sendable (_ repoPath: String) async throws -> Set<String>

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

    public func hasRemote(repoPath: String, branch: String) -> Bool {
        guard Self.isEligibleLocalBranch(branch) else { return false }
        return branchesByRepo[repoPath]?.contains(branch) == true
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
            for repo in self.getRepos() {
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
                let branches = try await list(repoPath)
                self?.apply(repoPath: repoPath, branches: branches, refreshGeneration: refreshGeneration)
            } catch {
                self?.logger.info("remote branch scan failed for \(repoPath): \(String(describing: error))")
                self?.finish(repoPath: repoPath, refreshGeneration: refreshGeneration)
            }
        }
    }

    private func apply(repoPath: String, branches: Set<String>, refreshGeneration: Int) {
        defer {
            finish(repoPath: repoPath, refreshGeneration: refreshGeneration)
        }
        guard generation[repoPath, default: 0] == refreshGeneration else { return }
        let old = branchesByRepo[repoPath] ?? []
        guard old != branches else { return }
        branchesByRepo[repoPath] = branches
        onChange?(repoPath, old, branches)
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

    public nonisolated static let defaultList: ListFunction = { repoPath in
        let output = try await GitRunner.run(
            args: ["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"],
            at: repoPath
        )
        return parseRefs(output)
    }

    nonisolated static func parseRefsForTesting(_ output: String) -> Set<String> {
        parseRefs(output)
    }
}
