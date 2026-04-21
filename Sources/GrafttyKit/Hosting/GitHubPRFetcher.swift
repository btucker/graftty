import Foundation

public struct GitHubPRFetcher: PRFetcher {
    private let executor: CLIExecutor
    private let now: @Sendable () -> Date

    public init(executor: CLIExecutor = CLIRunner(), now: @Sendable @escaping () -> Date = { Date() }) {
        self.executor = executor
        self.now = now
    }

    public func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
        if let open = try await fetchOne(origin: origin, branch: branch, state: "open") {
            // PR-5.4: `gh pr checks` is a SEPARATE call from `gh pr list`.
            // If list succeeded but checks fails (auth hiccup, rate
            // limit, gh version mismatch on the subcommand), we still
            // know the PR exists — surface its identity with neutral
            // checks rather than throwing and making the caller
            // (PRStatusStore) drop the cached PRInfo entirely, which
            // would hide the `#<number>` sidebar badge (PR-3.2) + the
            // breadcrumb PR button until the next successful poll.
            let checks = (try? await fetchChecks(origin: origin, number: open.number)) ?? .none
            return PRInfo(
                number: open.number,
                // PR-5.5: strip BIDI-override scalars from the
                // author-controlled title so a poisoned title can't
                // visually deceive via RTL-reversal in the breadcrumb.
                title: BidiOverrides.stripping(open.title),
                url: open.url,
                state: .open,
                checks: checks,
                fetchedAt: now()
            )
        }
        if let merged = try await fetchOne(origin: origin, branch: branch, state: "merged") {
            return PRInfo(
                number: merged.number,
                title: BidiOverrides.stripping(merged.title),
                url: merged.url,
                state: .merged,
                checks: .none,
                fetchedAt: now()
            )
        }
        return nil
    }

    // MARK: - Internals

    private struct RawPR: Decodable {
        struct HeadOwner: Decodable { let login: String }
        let number: Int
        let title: String
        let url: URL
        let state: String
        let headRefName: String
        let headRepositoryOwner: HeadOwner?
    }

    private struct RawCheck: Decodable {
        let name: String
        let state: String
        /// `gh pr checks --json bucket` value: "pass", "fail", "pending",
        /// "skipping", or "cancel". Decodes as nil when gh emits an empty
        /// string (neutral / never-classified checks).
        let bucket: String?
    }

    private func fetchOne(origin: HostingOrigin, branch: String, state: String) async throws -> RawPR? {
        // `gh pr list --head` does NOT support the `<owner>:<branch>`
        // syntax — its help text literally says so and it silently returns
        // `[]` for any value containing a colon. So send the bare branch,
        // ask gh for `headRepositoryOwner`, and enforce the "same repo as
        // base" invariant (PR-1.1) by filtering on the owner login here.
        // `--limit 5` rather than 1 so a fork PR returned first (possible
        // when both a fork and the origin have an open PR on the same
        // branch name) doesn't crowd our own PR out of the window.
        let fields = state == "merged"
            ? "number,title,url,state,headRefName,headRepositoryOwner,mergedAt"
            : "number,title,url,state,headRefName,headRepositoryOwner"
        let args = [
            "pr", "list",
            "--repo", origin.slug,
            "--head", branch,
            "--state", state,
            "--limit", "5",
            "--json", fields,
        ]
        let output = try await executor.run(command: "gh", args: args, at: NSTemporaryDirectory())
        let data = Data(output.stdout.utf8)
        let prs = try JSONDecoder().decode([RawPR].self, from: data)
        let ownerLower = origin.owner.lowercased()
        return prs.first { ($0.headRepositoryOwner?.login ?? "").lowercased() == ownerLower }
    }

    private func fetchChecks(origin: HostingOrigin, number: Int) async throws -> PRInfo.Checks {
        let args = [
            "pr", "checks", String(number),
            "--repo", origin.slug,
            "--json", "name,state,bucket"
        ]
        let output = try await executor.run(command: "gh", args: args, at: NSTemporaryDirectory())
        let data = Data(output.stdout.utf8)
        let checks = try JSONDecoder().decode([RawCheck].self, from: data)
        return Self.rollup(checks.map { ($0.state, $0.bucket) })
    }

    /// Rolls up per-check `(state, bucket)` pairs (as emitted by
    /// `gh pr checks --json state,bucket`) into a single verdict. Values:
    /// `bucket` ∈ {"pass","fail","pending","skipping","cancel", nil};
    /// `state` ∈ {"COMPLETED","IN_PROGRESS","QUEUED","PENDING", ...}.
    ///
    /// Priority: any fail → .failure. Any pending bucket or in-flight
    /// state → .pending. All-pass → .success. Anything else (skipping,
    /// cancel, null bucket) → .none so the user sees neutral rather than
    /// false-success.
    static func rollup(_ checks: [(state: String, bucket: String?)]) -> PRInfo.Checks {
        if checks.isEmpty { return .none }
        if checks.contains(where: { ($0.bucket ?? "").lowercased() == "fail" }) {
            return .failure
        }
        if checks.contains(where: {
            if ($0.bucket ?? "").lowercased() == "pending" { return true }
            let s = $0.state.uppercased()
            return s == "IN_PROGRESS" || s == "QUEUED" || s == "PENDING"
        }) {
            return .pending
        }
        if checks.allSatisfy({ ($0.bucket ?? "").lowercased() == "pass" }) {
            return .success
        }
        return .none
    }
}
