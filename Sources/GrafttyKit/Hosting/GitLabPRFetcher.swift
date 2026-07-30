import Foundation
import GrafttyProtocol

/// Per-repo `glab mr list` fetcher. Pipeline status isn't available
/// from the listing and its conflict status can be stale, so we fan
/// out per-MR `glab mr view` requests in parallel for the branches
/// the caller cares about.
///
/// @spec PR-8.15
public struct GitLabPRFetcher: PRFetcher {
    private let executor: CLIExecutor
    private let now: @Sendable () -> Date

    /// Maximum number of `glab mr view` subprocesses in flight at
    /// once. Bounded so a repo with many open MRs (or a slow
    /// `glab`) can't saturate file descriptors / process slots.
    static let detailConcurrency = 6

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
        // pick one MR per branch. Open wins over terminal, then highest IID
        // wins so reused branches are independent of glab's result ordering.
        var primaryByBranch: [String: RawMR] = [:]
        for mr in raw {
            guard let src = mr.source_project_id, let tgt = mr.target_project_id, src == tgt else { continue }
            guard Self.mapState(mr.state) != nil else { continue }
            if let existing = primaryByBranch[mr.source_branch] {
                if Self.prefers(mr, over: existing) {
                    primaryByBranch[mr.source_branch] = mr
                }
            } else {
                primaryByBranch[mr.source_branch] = mr
            }
        }

        // Pipeline and authoritative conflict status are only in
        // the per-MR view payload. The list endpoint can return a
        // stale `has_conflicts` value because it doesn't proactively
        // recalculate merge status. Fetch details in parallel,
        // capped at `detailConcurrency` so a repo with many open
        // MRs (or a slow `glab`) can't spawn dozens of subprocesses
        // at once. Restricted to branches the caller cares about so
        // a 100-MR repo with 5 worktrees fires 5 view calls, not 100.
        let needsDetail = primaryByBranch
            .filter { branchesOfInterest.contains($0.key) && $0.value.state.lowercased() == "opened" }
            .map(\.value)
        let detailByIID = await withTaskGroup(of: (Int, RawMRDetail?).self) { group in
            var iter = needsDetail.makeIterator()
            var out: [Int: RawMRDetail] = [:]
            for _ in 0..<min(Self.detailConcurrency, needsDetail.count) {
                guard let mr = iter.next() else { break }
                group.addTask { [executor] in
                    let detail = try? await Self.fetchMRDetail(executor: executor, origin: origin, iid: mr.iid)
                    return (mr.iid, detail)
                }
            }
            while let (iid, detail) = await group.next() {
                out[iid] = detail
                if let mr = iter.next() {
                    group.addTask { [executor] in
                        let detail = try? await Self.fetchMRDetail(executor: executor, origin: origin, iid: mr.iid)
                        return (mr.iid, detail)
                    }
                }
            }
            return out
        }

        var byBranch: [String: PRInfo] = [:]
        for (branch, mr) in primaryByBranch {
            let state = Self.mapState(mr.state)!
            let detail = detailByIID[mr.iid]
            let checks: PRInfo.Checks = state.isTerminal
                ? .none
                : detail?.head_pipeline.map { Self.mapStatus($0.status) } ?? .none
            let mergeable = state.isTerminal
                ? PRInfo.Mergeable.unknown
                : Self.mapMergeable(detail)
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
    }

    private struct RawMRDetail: Decodable {
        let head_pipeline: RawPipeline?
        let has_conflicts: Bool?
        let merge_status: String?
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
        let output = try await executor.run(
            command: "glab",
            args: args,
            at: NSTemporaryDirectory(),
            timeout: Self.fetchTimeout
        )
        let data = Data(output.stdout.utf8)
        return try JSONDecoder().decode([RawMR].self, from: data)
    }

    private static func fetchMRDetail(
        executor: CLIExecutor,
        origin: HostingOrigin,
        iid: Int
    ) async throws -> RawMRDetail {
        let args = [
            "mr", "view", String(iid),
            "--repo", origin.slug,
            "-F", "json",
        ]
        let output = try await executor.run(
            command: "glab",
            args: args,
            at: NSTemporaryDirectory(),
            timeout: GitLabPRFetcher.fetchTimeout
        )
        let data = Data(output.stdout.utf8)
        return try JSONDecoder().decode(RawMRDetail.self, from: data)
    }

    static func mapState(_ raw: String) -> PRInfo.State? {
        switch raw.lowercased() {
        case "opened": return .open
        case "merged": return .merged
        case "closed": return .closed
        default: return nil
        }
    }

    private static func mapMergeable(_ detail: RawMRDetail?) -> PRInfo.Mergeable {
        guard let hasConflicts = detail?.has_conflicts else {
            return .unknown
        }
        if hasConflicts {
            return .conflicting
        }
        // GitLab documents `has_conflicts` as false for every merge status
        // other than `cannot_be_merged`, including transient recomputation
        // states such as `checking` and `unchecked`. Only pair false with
        // `can_be_merged` to make a meaningful clean-merge conclusion.
        return detail?.merge_status?.lowercased() == "can_be_merged"
            ? .mergeable
            : .unknown
    }

    private static func prefers(_ candidate: RawMR, over existing: RawMR) -> Bool {
        let candidateIsOpen = candidate.state.lowercased() == "opened"
        let existingIsOpen = existing.state.lowercased() == "opened"
        if candidateIsOpen != existingIsOpen {
            return candidateIsOpen
        }
        return candidate.iid > existing.iid
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
