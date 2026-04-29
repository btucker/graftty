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
    @ObservationIgnored private var completions: [String: [Int: [@MainActor () -> Void]]] = [:]
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
        generation[repoPath, default: 0] += 1
    }

    public func refresh(repoPath: String, completion: (@MainActor () -> Void)? = nil) {
        if let refreshGeneration = inFlight[repoPath] {
            if let completion {
                completions[repoPath, default: [:]][refreshGeneration, default: []].append(completion)
            }
            return
        }

        generation[repoPath, default: 0] += 1
        let refreshGeneration = generation[repoPath, default: 0]
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
        if inFlight[repoPath] == refreshGeneration {
            inFlight.removeValue(forKey: repoPath)
        }

        let callbacks = completions[repoPath]?[refreshGeneration] ?? []
        completions[repoPath]?[refreshGeneration] = nil
        if completions[repoPath]?.isEmpty == true {
            completions.removeValue(forKey: repoPath)
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
