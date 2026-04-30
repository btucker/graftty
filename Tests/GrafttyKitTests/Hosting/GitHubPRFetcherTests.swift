import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitHubPRFetcher")
struct GitHubPRFetcherTests {
    let origin = HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "graftty")
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
            "--repo", "btucker/graftty",
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
            args: ["pr", "checks", "412", "--repo", "btucker/graftty", "--json", "name,state,bucket"],
            output: CLIOutput(stdout: loadFixture("gh-pr-checks-passing"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date(timeIntervalSince1970: 100) })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)

        #expect(pr?.number == 412)
        #expect(pr?.state == .open)
        #expect(pr?.checks == .success)
        #expect(pr?.title == "Add PR/MR status button to breadcrumb")
        #expect(pr?.url.absoluteString == "https://github.com/btucker/graftty/pull/412")
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

    @Test("""
    @spec PR-1.1: When the application resolves the PR for a worktree's branch on a GitHub origin, it shall scope the lookup to PRs whose head ref lives in the same repository as the base so that PRs from forks which happen to share the branch name are not associated with the worktree. Because `gh pr list --head` does not support the `<owner>:<branch>` syntax (it silently returns an empty result), the filter shall be implemented by passing the bare branch name to `gh`, requesting `headRepositoryOwner` in the JSON output, and discarding results whose `headRepositoryOwner.login` does not match the origin owner (compared case-insensitively).
    """)
    func filtersOutForkPRsViaHeadRepositoryOwner() async throws {
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
            repo: "graftty"
        )
        let openArgs = [
            "pr", "list",
            "--repo", "BTucker/graftty",
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
            args: ["pr", "checks", "412", "--repo", "BTucker/graftty", "--json", "name,state,bucket"],
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

    // PR-5.4: `gh pr list` and `gh pr checks` are separate subprocess
    // calls. A transient failure of the SECOND (auth hiccup, rate limit,
    // network blip, gh version bump that broke the checks subcommand)
    // used to propagate out and make the whole fetch fail — the caller
    // (PRStatusStore) caught the error and DROPPED the cached PRInfo
    // entirely. User-visible: the `#<number>` sidebar badge (PR-3.2) and
    // breadcrumb PR button disappeared even though the PR itself was
    // still cached-discoverable. Fix: treat the second call as best-effort;
    // fall back to `.none` checks so the PR identity still surfaces.
    @Test("""
    @spec PR-5.4: When `gh pr list` succeeds but the subsequent `gh pr checks` call for the resolved PR fails (auth hiccup, rate limit, subcommand regression, network blip), the application shall still surface the PR's identity with `.none` check status rather than propagating the checks error out of the fetch. The `#<number>` sidebar badge (`PR-3.2`) and the breadcrumb PR button shall remain visible — losing them because checks couldn't be resolved produces worse UX than displaying them with neutral check state.
    """)
    func openPRSurfacesEvenWhenChecksFetchFails() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: listArgs(state: "open"),
            output: CLIOutput(stdout: loadFixture("gh-pr-open-passing"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "412", "--repo", "btucker/graftty", "--json", "name,state,bucket"],
            error: CLIError.nonZeroExit(command: "gh", exitCode: 1, stderr: "authentication required")
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date(timeIntervalSince1970: 100) })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)

        // The PR is still resolved — what the user cares about.
        #expect(pr?.number == 412)
        #expect(pr?.state == .open)
        // Checks degrade to neutral rather than making the PR vanish.
        #expect(pr?.checks == PRInfo.Checks.none)
    }

    /// External-contributor PRs can be titled with Unicode
    /// bidirectional-override scalars (U+202A-U+202E, U+2066-U+2069),
    /// producing the "Trojan Source" render distortion (CVE-2021-42574)
    /// in the breadcrumb's `PRButton` — which renders `Text(info.title)`
    /// with no filtering of its own. ATTN-1.14 + LAYOUT-2.18 block this
    /// on self-owned surfaces (notify text, OSC 2 titles); the PR-title
    /// intake needs the same defense because the author is explicitly
    /// not trusted.
    ///
    /// Strip (not reject) the scalars — rejection would hide the PR
    /// entirely and worsen UX. Stripped title still conveys the human-
    /// readable gist of the PR; if the user wants to see the raw title
    /// they can click through to the hosting provider.
    @Test("""
    @spec PR-5.5: When the application stores a PR/MR title into a `PRInfo` for display (breadcrumb `PRButton`, accessibility label, tooltip), it shall first strip every Unicode bidirectional-override scalar (the embedding, override, and isolate families — the same ranges as `ATTN-1.14`). PR titles are author-controlled, including authors who submit from malicious forks; a poisoned title like `"Fix \\u{202E}redli\\u{202C} helper"` would otherwise render RTL-reversed in the breadcrumb as `"Fix ildeeper helper"`-style text — the same Trojan Source visual deception (CVE-2021-42574) `ATTN-1.14` and `LAYOUT-2.18` block on self-owned surfaces. Unlike those surfaces, the PR-title path STRIPS rather than REJECTS: a poisoned title shouldn't hide the PR entirely from the user (they still need to see "a PR exists"); stripping yields a legible-ish version and the user can click through to the hosting provider for the raw text. Applies to both `GitHubPRFetcher` and `GitLabPRFetcher`.
    """)
    func stripsBidiOverrideScalarsFromTitle() async throws {
        // Inline stub with a title containing U+202E RIGHT-TO-LEFT
        // OVERRIDE and U+202C POP DIRECTIONAL FORMATTING.
        let rawJSON = #"""
        [{"number":1,"title":"Fix \#u{202E}redli\#u{202C} helper","url":"https://github.com/btucker/graftty/pull/1","state":"OPEN","headRefName":"feature/git-improvements","headRepositoryOwner":{"login":"btucker"}}]
        """#
        let fake = FakeCLIExecutor()
        fake.stub(command: "gh", args: listArgs(state: "open"),
                  output: CLIOutput(stdout: rawJSON, stderr: "", exitCode: 0))
        fake.stub(command: "gh",
                  args: ["pr", "checks", "1", "--repo", "btucker/graftty",
                         "--json", "name,state,bucket"],
                  output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0))

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)

        #expect(pr?.number == 1)
        // BIDI-override scalars stripped; the legible content remains.
        #expect(pr?.title == "Fix redli helper")
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
