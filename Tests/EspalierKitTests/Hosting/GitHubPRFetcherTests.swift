import Testing
import Foundation
@testable import EspalierKit

@Suite("GitHubPRFetcher")
struct GitHubPRFetcherTests {
    let origin = HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "espalier")
    let branch = "feature/git-improvements"

    // `gh pr list --head` does not support the `<owner>:<branch>` syntax
    // — its help text literally says so, and it silently returns `[]` for
    // any value containing a colon. So the fetcher sends the bare branch
    // name, and applies the "same-repo-as-base" invariant (PR-1.1) by
    // filtering results on `headRepositoryOwner.login` post-hoc.
    func listArgs(state: String) -> [String] {
        let jsonFields = state == "merged"
            ? "number,title,url,state,headRefName,headRepositoryOwner,mergedAt"
            : "number,title,url,state,headRefName,headRepositoryOwner"
        return [
            "pr", "list",
            "--repo", "btucker/espalier",
            "--head", branch,
            "--state", state,
            "--limit", "5",
            "--json", jsonFields,
        ]
    }

    func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "json")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    @Test func returnsOpenPRWithPassingChecks() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: listArgs(state: "open"),
            output: CLIOutput(stdout: loadFixture("gh-pr-open-passing"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "412", "--repo", "btucker/espalier", "--json", "name,state,bucket"],
            output: CLIOutput(stdout: loadFixture("gh-pr-checks-passing"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date(timeIntervalSince1970: 100) })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)

        #expect(pr?.number == 412)
        #expect(pr?.state == .open)
        #expect(pr?.checks == .success)
        #expect(pr?.title == "Add PR/MR status button to breadcrumb")
        #expect(pr?.url.absoluteString == "https://github.com/btucker/espalier/pull/412")
    }

    @Test func returnsMergedPRWhenNoOpen() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: listArgs(state: "open"),
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: listArgs(state: "merged"),
            output: CLIOutput(stdout: loadFixture("gh-pr-merged"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)

        #expect(pr?.number == 398)
        #expect(pr?.state == .merged)
        #expect(pr?.checks == PRInfo.Checks.none)
    }

    @Test func sendsBareBranchToGhHead() async throws {
        // Regression: the prior implementation passed `--head <owner>:<branch>`
        // to `gh pr list`, but gh's `--head` filter explicitly does not support
        // that syntax and silently returns an empty array — so no worktree
        // ever displayed a PR. Pin the contract: the value after `--head`
        // must be the bare branch name with no colons.
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: listArgs(state: "open"),
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: listArgs(state: "merged"),
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        _ = try await fetcher.fetch(origin: origin, branch: branch)

        let listInvocation = fake.invocations.first { $0.args.contains("list") }
        let args = listInvocation?.args ?? []
        guard let headIdx = args.firstIndex(of: "--head") else {
            Issue.record("expected --head in gh pr list args")
            return
        }
        let headValue = args[args.index(after: headIdx)]
        #expect(headValue == branch)
        #expect(!headValue.contains(":"))
    }

    @Test func filtersOutForkPRsViaHeadRepositoryOwner() async throws {
        // Another user's fork can have a PR open against this repo with
        // the same branch name; `gh pr list --head <branch>` happily
        // returns it alongside ours. The fetcher must filter to PRs whose
        // `headRepositoryOwner.login` matches the origin's owner so a
        // worktree never picks up a stranger's PR (PR-1.1).
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: listArgs(state: "open"),
            output: CLIOutput(stdout: loadFixture("gh-pr-fork-open"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: listArgs(state: "merged"),
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)

        #expect(pr == nil)
    }

    @Test func matchesOwnerCaseInsensitively() async throws {
        // GitHub logins are canonicalized on the API side but users type
        // remote URLs in whatever casing they like (`git@github.com:BTucker/...`).
        // Don't let a casing mismatch between the parsed remote and the
        // API-returned `login` drop the user's own PR.
        let fake = FakeCLIExecutor()
        let mixedCaseOrigin = HostingOrigin(
            provider: .github,
            host: "github.com",
            owner: "BTucker",
            repo: "espalier"
        )
        let openArgs = [
            "pr", "list",
            "--repo", "BTucker/espalier",
            "--head", branch,
            "--state", "open",
            "--limit", "5",
            "--json", "number,title,url,state,headRefName,headRepositoryOwner",
        ]
        fake.stub(
            command: "gh",
            args: openArgs,
            output: CLIOutput(stdout: loadFixture("gh-pr-open-passing"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "412", "--repo", "BTucker/espalier", "--json", "name,state,bucket"],
            output: CLIOutput(stdout: loadFixture("gh-pr-checks-passing"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: mixedCaseOrigin, branch: branch)

        #expect(pr?.number == 412)
    }

    @Test func returnsNilWhenNoOpenOrMerged() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: listArgs(state: "open"),
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: listArgs(state: "merged"),
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(pr == nil)
    }
}

@Suite("GitHubPRFetcher.rollup")
struct GitHubPRFetcherRollupTests {
    // `gh pr checks --json ...` exposes the per-check verdict via the
    // `bucket` field (values: "pass", "fail", "pending", "skipping",
    // "cancel"), NOT `conclusion` (which is the underlying Actions
    // attribute visible only through the GraphQL API). Earlier code asked
    // gh for `conclusion` and got a hard error — this suite now pins
    // against the real gh schema.

    @Test func emptyIsNone() {
        #expect(GitHubPRFetcher.rollup([]) == PRInfo.Checks.none)
    }

    @Test func anyFailureWins() {
        #expect(GitHubPRFetcher.rollup([
            ("COMPLETED", "pass"),
            ("COMPLETED", "fail")
        ]) == .failure)
    }

    @Test func inProgressBeatsSuccess() {
        #expect(GitHubPRFetcher.rollup([
            ("COMPLETED", "pass"),
            ("IN_PROGRESS", nil)
        ]) == .pending)
    }

    @Test func pendingBucketIsPending() {
        #expect(GitHubPRFetcher.rollup([("PENDING", "pending")]) == .pending)
    }

    @Test func queuedStateIsPending() {
        #expect(GitHubPRFetcher.rollup([("QUEUED", nil)]) == .pending)
    }

    @Test func allPassIsSuccess() {
        #expect(GitHubPRFetcher.rollup([
            ("COMPLETED", "pass"),
            ("COMPLETED", "pass")
        ]) == .success)
    }

    @Test func completedWithNullBucketIsNone() {
        // Neutral / skipped checks: COMPLETED but gh didn't classify it.
        #expect(GitHubPRFetcher.rollup([
            ("COMPLETED", "pass"),
            ("COMPLETED", nil)
        ]) == PRInfo.Checks.none)
    }

    @Test func skippingAndCancelDoNotCountAsSuccess() {
        // One skip alongside passes: don't promote to "success" — user
        // probably wants visibility that not everything ran.
        #expect(GitHubPRFetcher.rollup([
            ("COMPLETED", "pass"),
            ("COMPLETED", "skipping")
        ]) == PRInfo.Checks.none)
    }
}
