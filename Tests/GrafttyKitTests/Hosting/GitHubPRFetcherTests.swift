import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitHubPRFetcher")
struct GitHubPRFetcherTests {
    let origin = HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "graftty")

    /// Single per-repo `gh pr list` invocation that returns every
    /// open and recently-merged PR for the repo, with
    /// `statusCheckRollup` and `mergeable` baked in. One CLI call
    /// regardless of how many worktrees the user has on this repo.
    static let listArgs: [String] = [
        "pr", "list",
        "--repo", "btucker/graftty",
        "--state", "all",
        "--limit", "100",
        "--json", "number,title,url,state,headRefName,headRepositoryOwner,statusCheckRollup,mergeable",
    ]

    func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "json")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    @Test func returnsOpenPRWithPassingChecks() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: Self.listArgs,
            output: CLIOutput(stdout: loadFixture("gh-pr-open-passing"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date(timeIntervalSince1970: 100) })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [])

        let pr = snapshot.prsByBranch["feature/git-improvements"]
        #expect(pr?.number == 412)
        #expect(pr?.state == .open)
        #expect(pr?.checks == .success)
        #expect(pr?.mergeable == .mergeable)
        #expect(pr?.title == "Add PR/MR status button to breadcrumb")
        #expect(pr?.url.absoluteString == "https://github.com/btucker/graftty/pull/412")
    }

    @Test func returnsMergedPRWhenNoOpen() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: Self.listArgs,
            output: CLIOutput(stdout: loadFixture("gh-pr-merged"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [])

        let pr = snapshot.prsByBranch["feature/github-integration"]
        #expect(pr?.number == 398)
        #expect(pr?.state == .merged)
        #expect(pr?.checks == PRInfo.Checks.none)
    }

    @Test("""
    @spec PR-1.1: When the application resolves the PR for a worktree's branch on a GitHub origin, it shall scope the lookup to PRs whose head ref lives in the same repository as the base so that PRs from forks which happen to share the branch name are not associated with the worktree. Per-repo batched fetching applies the filter post-hoc by comparing each PR's `headRepositoryOwner.login` (case-insensitive) against the origin's owner and dropping PRs from other repositories before they reach the per-worktree distribution.
    """)
    func filtersOutForkPRsViaHeadRepositoryOwner() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: Self.listArgs,
            output: CLIOutput(stdout: loadFixture("gh-pr-fork-open"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [])

        #expect(snapshot.prsByBranch.isEmpty, "fork PRs must be filtered out")
    }

    @Test func matchesOwnerCaseInsensitively() async throws {
        let mixedCaseOrigin = HostingOrigin(
            provider: .github, host: "github.com", owner: "BTucker", repo: "graftty"
        )
        let mixedCaseListArgs = [
            "pr", "list",
            "--repo", "BTucker/graftty",
            "--state", "all",
            "--limit", "100",
            "--json", "number,title,url,state,headRefName,headRepositoryOwner,statusCheckRollup,mergeable",
        ]
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: mixedCaseListArgs,
            output: CLIOutput(stdout: loadFixture("gh-pr-open-passing"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: mixedCaseOrigin, branchesOfInterest: [])
        #expect(snapshot.prsByBranch["feature/git-improvements"]?.number == 412)
    }

    @Test func returnsEmptySnapshotWhenNoOpenOrMerged() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: Self.listArgs,
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [])
        #expect(snapshot.prsByBranch.isEmpty)
    }

    @Test("""
    @spec PR-5.5: When the application stores a PR/MR title into a `PRInfo` for display (breadcrumb `PRButton`, accessibility label, tooltip), it shall first strip every Unicode bidirectional-override scalar (the embedding, override, and isolate families — the same ranges as `ATTN-1.14`). PR titles are author-controlled, including authors who submit from malicious forks; a poisoned title like `"Fix \\u{202E}redli\\u{202C} helper"` would otherwise render RTL-reversed in the breadcrumb as `"Fix ildeeper helper"`-style text — the same Trojan Source visual deception (CVE-2021-42574) `ATTN-1.14` and `LAYOUT-2.18` block on self-owned surfaces. Unlike those surfaces, the PR-title path STRIPS rather than REJECTS: a poisoned title shouldn't hide the PR entirely from the user (they still need to see "a PR exists"); stripping yields a legible-ish version and the user can click through to the hosting provider for the raw text. Applies to both `GitHubPRFetcher` and `GitLabPRFetcher`.
    """)
    func stripsBidiOverrideScalarsFromTitle() async throws {
        let rawJSON = #"""
        [{"number":1,"title":"Fix \#u{202E}redli\#u{202C} helper","url":"https://github.com/btucker/graftty/pull/1","state":"OPEN","headRefName":"feature/git-improvements","headRepositoryOwner":{"login":"btucker"},"statusCheckRollup":[],"mergeable":"MERGEABLE"}]
        """#
        let fake = FakeCLIExecutor()
        fake.stub(command: "gh", args: Self.listArgs,
                  output: CLIOutput(stdout: rawJSON, stderr: "", exitCode: 0))

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [])
        let pr = snapshot.prsByBranch["feature/git-improvements"]

        #expect(pr?.number == 1)
        #expect(pr?.title == "Fix redli helper")
    }

    @Test("""
    @spec PR-8.14: When the application resolves PR status for a repo's worktrees, it shall issue a single `gh pr list --json statusCheckRollup,mergeable,...` call per repo and distribute the resulting snapshot to every worktree whose branch matches a head ref. The previous per-branch fetcher fired two `gh` subprocesses (`pr list` + `pr checks`) per worktree per polling tick; the per-repo batch keeps total CLI invocations linear in the number of repos rather than the number of worktrees.
    """)
    func issuesOneCallPerRepoCoveringAllBranches() async throws {
        let fake = FakeCLIExecutor()
        let multiPR = """
        [
          {"number":1,"title":"A","url":"https://github.com/btucker/graftty/pull/1","state":"OPEN","headRefName":"branchA","headRepositoryOwner":{"login":"btucker"},"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"mergeable":"MERGEABLE"},
          {"number":2,"title":"B","url":"https://github.com/btucker/graftty/pull/2","state":"OPEN","headRefName":"branchB","headRepositoryOwner":{"login":"btucker"},"statusCheckRollup":[{"status":"IN_PROGRESS"}],"mergeable":"CONFLICTING"},
          {"number":3,"title":"C","url":"https://github.com/btucker/graftty/pull/3","state":"MERGED","headRefName":"branchC","headRepositoryOwner":{"login":"btucker"},"statusCheckRollup":[],"mergeable":"UNKNOWN"}
        ]
        """
        fake.stub(command: "gh", args: Self.listArgs,
                  output: CLIOutput(stdout: multiPR, stderr: "", exitCode: 0))

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        // Caller asks about three branches; only one CLI call is fired.
        let snapshot = try await fetcher.fetch(
            origin: origin,
            branchesOfInterest: ["branchA", "branchB", "branchC"]
        )

        #expect(fake.invocations.count == 1, "expected exactly one `gh` subprocess for the whole repo")
        #expect(snapshot.prsByBranch["branchA"]?.checks == .success)
        #expect(snapshot.prsByBranch["branchB"]?.checks == .pending)
        #expect(snapshot.prsByBranch["branchB"]?.mergeable == .conflicting)
        #expect(snapshot.prsByBranch["branchC"]?.state == .merged)
    }

    @Test func openPRWinsOverMergedForSameBranch() async throws {
        // Same branch, two PR rows: one open, one merged. The open
        // one wins (the merged one is presumably an old, closed
        // attempt at the same feature).
        let fake = FakeCLIExecutor()
        let stdout = """
        [
          {"number":99,"title":"old","url":"https://github.com/btucker/graftty/pull/99","state":"MERGED","headRefName":"feat","headRepositoryOwner":{"login":"btucker"},"statusCheckRollup":[],"mergeable":"UNKNOWN"},
          {"number":100,"title":"new","url":"https://github.com/btucker/graftty/pull/100","state":"OPEN","headRefName":"feat","headRepositoryOwner":{"login":"btucker"},"statusCheckRollup":[],"mergeable":"MERGEABLE"}
        ]
        """
        fake.stub(command: "gh", args: Self.listArgs,
                  output: CLIOutput(stdout: stdout, stderr: "", exitCode: 0))

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [])
        #expect(snapshot.prsByBranch["feat"]?.number == 100)
        #expect(snapshot.prsByBranch["feat"]?.state == .open)
    }
}

@Suite("GitHubPRFetcher.rollup")
struct GitHubPRFetcherRollupTests {

    private static func check(status: String? = nil, conclusion: String? = nil, state: String? = nil)
        -> GitHubPRFetcher.RawPR.RawCheck
    {
        let raw = encode(status: status, conclusion: conclusion, state: state)
        return try! JSONDecoder().decode(GitHubPRFetcher.RawPR.RawCheck.self, from: Data(raw.utf8))
    }

    private static func encode(status: String?, conclusion: String?, state: String?) -> String {
        var parts: [String] = []
        if let status { parts.append("\"status\":\"\(status)\"") }
        if let conclusion { parts.append("\"conclusion\":\"\(conclusion)\"") }
        if let state { parts.append("\"state\":\"\(state)\"") }
        return "{\(parts.joined(separator: ","))}"
    }

    @Test func emptyIsNone() {
        #expect(GitHubPRFetcher.rollup([]) == PRInfo.Checks.none)
    }

    @Test func anyFailureWins() {
        #expect(GitHubPRFetcher.rollup([
            Self.check(status: "COMPLETED", conclusion: "SUCCESS"),
            Self.check(status: "COMPLETED", conclusion: "FAILURE"),
        ]) == .failure)
    }

    @Test func inProgressBeatsSuccess() {
        #expect(GitHubPRFetcher.rollup([
            Self.check(status: "COMPLETED", conclusion: "SUCCESS"),
            Self.check(status: "IN_PROGRESS"),
        ]) == .pending)
    }

    @Test func statusContextPendingIsPending() {
        #expect(GitHubPRFetcher.rollup([Self.check(state: "PENDING")]) == .pending)
    }

    @Test func queuedStatusIsPending() {
        #expect(GitHubPRFetcher.rollup([Self.check(status: "QUEUED")]) == .pending)
    }

    @Test func allPassIsSuccess() {
        #expect(GitHubPRFetcher.rollup([
            Self.check(status: "COMPLETED", conclusion: "SUCCESS"),
            Self.check(state: "SUCCESS"),
        ]) == .success)
    }

    @Test func skippingDoesNotCountAsSuccess() {
        // One skipped check alongside a passing one: don't promote
        // to "success" — user probably wants visibility that not
        // everything ran.
        #expect(GitHubPRFetcher.rollup([
            Self.check(status: "COMPLETED", conclusion: "SUCCESS"),
            Self.check(status: "COMPLETED", conclusion: "SKIPPED"),
        ]) == PRInfo.Checks.none)
    }

    @Test func actionRequiredCountsAsFailure() {
        #expect(GitHubPRFetcher.rollup([
            Self.check(status: "COMPLETED", conclusion: "ACTION_REQUIRED"),
        ]) == .failure)
    }
}

@Suite("GitHubPRFetcher.mapMergeable")
struct GitHubPRFetcherMergeableTests {
    @Test func mergeable() { #expect(GitHubPRFetcher.mapMergeable("MERGEABLE") == .mergeable) }
    @Test func conflicting() { #expect(GitHubPRFetcher.mapMergeable("CONFLICTING") == .conflicting) }
    @Test func unknownPassesThrough() { #expect(GitHubPRFetcher.mapMergeable("UNKNOWN") == .unknown) }
    @Test func nilIsUnknown() { #expect(GitHubPRFetcher.mapMergeable(nil) == .unknown) }
    @Test func caseInsensitive() { #expect(GitHubPRFetcher.mapMergeable("mergeable") == .mergeable) }
}
