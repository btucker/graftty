import Foundation

/// Per-repo `glab mr list` fetcher. The listing call returns every
/// MR for the repo plus `has_conflicts`. Pipeline status isn't in
/// the list payload, so we fan out per-MR `glab mr view` requests
/// in parallel for the branches the caller cares about.
///
/// @spec PR-8.15
public struct GitLabPRFetcher: PRFetcher {
    private let executor: CLIExecutor
    private let now: @Sendable () -> Date

    /// Maximum number of `glab mr view` subprocesses in flight at
    /// once. Bounded so a repo with many open MRs (or a slow
    /// `glab`) can't saturate file descriptors / process slots.
    static let pipelineConcurrency = 6

    public init(
        executor: CLIExecutor = CLIRunner(),
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.executor = executor
        self.now = now
    }

    public func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        let raw = try await listMRs(origin: origin)
        let fetched = now()

        // PR-5.3: same-repo (non-fork) filter via project-id equality;
        // pick one MR per branch (open wins over merged).
        var primaryByBranch: [String: RawMR] = [:]
        for mr in raw {
            guard let src = mr.source_project_id, let tgt = mr.target_project_id, src == tgt else { continue }
            guard Self.mapState(mr.state) != nil else { continue }
            if let existing = primaryByBranch[mr.source_branch] {
                if existing.state.lowercased() != "opened" && mr.state.lowercased() == "opened" {
                    primaryByBranch[mr.source_branch] = mr
                }
            } else {
                primaryByBranch[mr.source_branch] = mr
            }
        }

        // Pipeline status is only in the per-MR view payload. Fetch
        // in parallel, capped at `pipelineConcurrency` so a repo
        // with many open MRs (or a slow `glab`) can't spawn dozens
        // of subprocesses at once. Restricted to branches the
        // caller cares about so a 100-MR repo with 5 worktrees
        // fires 5 view calls, not 100.
        let needsPipeline = primaryByBranch
            .filter { branchesOfInterest.contains($0.key) && $0.value.state.lowercased() == "opened" }
            .map(\.value)
        let pipelineByIID = await withTaskGroup(of: (Int, PRInfo.Checks).self) { group in
            var iter = needsPipeline.makeIterator()
            var out: [Int: PRInfo.Checks] = [:]
            for _ in 0..<min(Self.pipelineConcurrency, needsPipeline.count) {
                guard let mr = iter.next() else { break }
                group.addTask { [executor] in
                    let checks = (try? await Self.fetchPipelineStatus(executor: executor, origin: origin, iid: mr.iid)) ?? .none
                    return (mr.iid, checks)
                }
            }
            while let (iid, checks) = await group.next() {
                out[iid] = checks
                if let mr = iter.next() {
                    group.addTask { [executor] in
                        let checks = (try? await Self.fetchPipelineStatus(executor: executor, origin: origin, iid: mr.iid)) ?? .none
                        return (mr.iid, checks)
                    }
                }
            }
            return out
        }

        var byBranch: [String: PRInfo] = [:]
        for (branch, mr) in primaryByBranch {
            let state = Self.mapState(mr.state)!
            let checks: PRInfo.Checks = state == .merged ? .none : (pipelineByIID[mr.iid] ?? .none)
            let mergeable: PRInfo.Mergeable
            if state == .merged {
                mergeable = .unknown
            } else if let conflict = mr.has_conflicts {
                mergeable = conflict ? .conflicting : .mergeable
            } else {
                mergeable = .unknown
            }
            byBranch[branch] = PRInfo(
                number: mr.iid,
                // PR-5.5: strip BIDI-override scalars from the
                // author-controlled title (same rationale as the
                // GitHub side).
                title: BidiOverrides.stripping(mr.title),
                url: mr.web_url,
                state: state,
                checks: checks,
                mergeable: mergeable,
                fetchedAt: fetched
            )
        }
        return RepoPRSnapshot(prsByBranch: byBranch)
    }

    // MARK: - Internals

    struct RawMR: Decodable {
        let iid: Int
        let title: String
        let web_url: URL
        let state: String
        let source_branch: String
        let source_project_id: Int?
        let target_project_id: Int?
        let has_conflicts: Bool?
    }

    private struct RawMRDetail: Decodable {
        let head_pipeline: RawPipeline?
    }

    private struct RawPipeline: Decodable {
        let id: Int
        let status: String
    }

    private func listMRs(origin: HostingOrigin) async throws -> [RawMR] {
        let args = [
            "mr", "list",
            "--repo", origin.slug,
            "--all",
            "--per-page", "100",
            "-F", "json",
        ]
        let output = try await executor.run(command: "glab", args: args, at: NSTemporaryDirectory())
        let data = Data(output.stdout.utf8)
        return try JSONDecoder().decode([RawMR].self, from: data)
    }

    private static func fetchPipelineStatus(
        executor: CLIExecutor,
        origin: HostingOrigin,
        iid: Int
    ) async throws -> PRInfo.Checks {
        let args = [
            "mr", "view", String(iid),
            "--repo", origin.slug,
            "-F", "json",
        ]
        let output = try await executor.run(command: "glab", args: args, at: NSTemporaryDirectory())
        let data = Data(output.stdout.utf8)
        let detail = try JSONDecoder().decode(RawMRDetail.self, from: data)
        return detail.head_pipeline.map { mapStatus($0.status) } ?? .none
    }

    static func mapState(_ raw: String) -> PRInfo.State? {
        switch raw.lowercased() {
        case "opened": return .open
        case "merged": return .merged
        default: return nil
        }
    }

    static func mapStatus(_ status: String) -> PRInfo.Checks {
        switch status.lowercased() {
        case "success": return .success
        case "failed", "canceled": return .failure
        case "running", "pending", "waiting_for_resource", "preparing", "scheduled": return .pending
        default: return .none
        }
    }
}
