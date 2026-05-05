import Foundation

/// Per-repo `gh pr list` fetcher. One CLI call returns every open
/// and recently-merged PR for the repo with `statusCheckRollup`
/// and `mergeable`. `--state all --limit 100` covers the
/// realistic worktree window — a PR aged out beyond 100 entries is
/// invariably also gone from the user's local worktree list. The
/// same-repo (non-fork) filter applies `PR-1.1` post-hoc on
/// `headRepositoryOwner.login`.
///
/// @spec PR-8.14
public struct GitHubPRFetcher: PRFetcher {
    private let executor: CLIExecutor
    private let now: @Sendable () -> Date

    public init(
        executor: CLIExecutor = CLIRunner(),
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.executor = executor
        self.now = now
    }

    public func fetch(
        origin: HostingOrigin,
        branchesOfInterest _: Set<String> = []
    ) async throws -> RepoPRSnapshot {
        let raw = try await listPRs(origin: origin)
        let ownerLower = origin.owner.lowercased()
        let fetched = now()

        var byBranch: [String: PRInfo] = [:]
        for pr in raw {
            // PR-1.1: same-repo filter — skip fork PRs whose head
            // ref happens to collide with a local worktree branch.
            guard (pr.headRepositoryOwner?.login ?? "").lowercased() == ownerLower else { continue }
            guard let state = Self.mapState(pr.state) else { continue }

            let info = PRInfo(
                number: pr.number,
                // PR-5.5: strip BIDI-override scalars from the
                // author-controlled title so a poisoned title can't
                // visually deceive via RTL-reversal in the breadcrumb.
                title: BidiOverrides.stripping(pr.title),
                url: pr.url,
                state: state,
                checks: state == .merged ? .none : Self.rollup(pr.statusCheckRollup ?? []),
                mergeable: state == .merged ? .unknown : Self.mapMergeable(pr.mergeable),
                fetchedAt: fetched
            )

            // Prefer open over merged when both exist for a branch.
            if let existing = byBranch[pr.headRefName] {
                if existing.state == .merged && info.state == .open {
                    byBranch[pr.headRefName] = info
                }
            } else {
                byBranch[pr.headRefName] = info
            }
        }
        return RepoPRSnapshot(prsByBranch: byBranch)
    }

    // MARK: - Internals

    struct RawPR: Decodable {
        struct HeadOwner: Decodable { let login: String }
        struct RawCheck: Decodable {
            /// `gh pr list --json statusCheckRollup` returns either a
            /// "CheckRun" or a "StatusContext". CheckRuns expose
            /// `status`/`conclusion`; status contexts expose `state`.
            let status: String?
            let conclusion: String?
            let state: String?
        }

        let number: Int
        let title: String
        let url: URL
        let state: String
        let headRefName: String
        let headRepositoryOwner: HeadOwner?
        let statusCheckRollup: [RawCheck]?
        let mergeable: String?
    }

    private func listPRs(origin: HostingOrigin) async throws -> [RawPR] {
        let args = [
            "pr", "list",
            "--repo", origin.slug,
            "--state", "all",
            "--limit", "100",
            "--json", "number,title,url,state,headRefName,headRepositoryOwner,statusCheckRollup,mergeable",
        ]
        let output = try await executor.run(command: "gh", args: args, at: NSTemporaryDirectory())
        let data = Data(output.stdout.utf8)
        return try JSONDecoder().decode([RawPR].self, from: data)
    }

    static func mapState(_ raw: String) -> PRInfo.State? {
        switch raw.uppercased() {
        case "OPEN": return .open
        case "MERGED": return .merged
        // Closed-unmerged is intentionally dropped to match the prior fetcher.
        default: return nil
        }
    }

    static func mapMergeable(_ raw: String?) -> PRInfo.Mergeable {
        switch (raw ?? "").uppercased() {
        case "MERGEABLE": return .mergeable
        case "CONFLICTING": return .conflicting
        default: return .unknown
        }
    }

    /// Rolls up `statusCheckRollup` entries (each either a CheckRun
    /// or a StatusContext) into a single verdict in one pass.
    ///
    /// CheckRun fields: `status` ∈ {QUEUED, IN_PROGRESS, COMPLETED};
    /// `conclusion` ∈ {SUCCESS, FAILURE, CANCELLED, SKIPPED, NEUTRAL,
    /// TIMED_OUT, ACTION_REQUIRED, STALE, STARTUP_FAILURE} when
    /// status == COMPLETED.
    /// StatusContext fields: `state` ∈ {SUCCESS, FAILURE, ERROR,
    /// PENDING, EXPECTED}.
    ///
    /// Priority: any failure/error → `.failure`. Any in-flight or
    /// pending → `.pending`. All-pass → `.success`. Empty or
    /// skipped/cancelled-only → `.none` so the user sees neutral
    /// rather than false-success.
    static func rollup(_ checks: [RawPR.RawCheck]) -> PRInfo.Checks {
        if checks.isEmpty { return .none }
        var sawPending = false
        var allSuccess = true
        for c in checks {
            switch verdict(for: c) {
            case .failure: return .failure
            case .pending: sawPending = true; allSuccess = false
            case .success: continue
            case .neutral: allSuccess = false
            }
        }
        if sawPending { return .pending }
        return allSuccess ? .success : .none
    }

    private enum CheckVerdict { case failure, pending, success, neutral }

    private static func verdict(for c: RawPR.RawCheck) -> CheckVerdict {
        let conc = (c.conclusion ?? "").uppercased()
        let state = (c.state ?? "").uppercased()
        let status = (c.status ?? "").uppercased()
        if conc == "FAILURE" || conc == "TIMED_OUT" || conc == "STARTUP_FAILURE" || conc == "ACTION_REQUIRED" ||
           state == "FAILURE" || state == "ERROR" {
            return .failure
        }
        if status == "QUEUED" || status == "IN_PROGRESS" || status == "PENDING" ||
           state == "PENDING" || state == "EXPECTED" {
            return .pending
        }
        if conc == "SUCCESS" || state == "SUCCESS" {
            return .success
        }
        return .neutral
    }
}
