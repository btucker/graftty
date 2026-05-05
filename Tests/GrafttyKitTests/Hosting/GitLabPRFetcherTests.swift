import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitLabPRFetcher")
struct GitLabPRFetcherTests {
    let origin = HostingOrigin(provider: .gitlab, host: "gitlab.com", owner: "foo", repo: "bar")
    let branch = "feature/blindspots"

    /// Single per-repo `glab mr list --all` invocation that returns
    /// every MR in any state. Pipeline status is fetched per
    /// branch-of-interest via `glab mr view` because `glab mr
    /// list` doesn't include `head_pipeline`.
    var listAllArgs: [String] {
        ["mr", "list", "--repo", "foo/bar", "--all", "--per-page", "100", "-F", "json"]
    }

    func viewArgs(_ iid: Int) -> [String] {
        ["mr", "view", String(iid), "--repo", "foo/bar", "-F", "json"]
    }

    func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "json")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    @Test func returnsOpenMRWithSuccessChecks() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: listAllArgs,
            output: CLIOutput(stdout: loadFixture("glab-mr-opened"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: viewArgs(512),
            output: CLIOutput(stdout: loadFixture("glab-mr-view-pipeline-success"), stderr: "", exitCode: 0)
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [branch])
        let mr = snapshot.prsByBranch[branch]
        #expect(mr?.number == 512)
        #expect(mr?.state == .open)
        #expect(mr?.checks == .success)
        #expect(mr?.mergeable == .mergeable)
    }

    @Test func filtersForkMRInFavorOfOriginMR() async throws {
        // `glab mr list` surfaces same-source-branch MRs from forks
        // (their `source_project_id` differs from the target's).
        // Same rationale as the GitHub side: keep only same-repo MRs.
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: listAllArgs,
            output: CLIOutput(stdout: loadFixture("glab-mr-fork-open"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: viewArgs(512),
            output: CLIOutput(stdout: loadFixture("glab-mr-view-pipeline-success"), stderr: "", exitCode: 0)
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [branch])
        let mr = snapshot.prsByBranch[branch]
        #expect(mr?.number == 512)
        #expect(mr?.state == .open)
        #expect(mr?.checks == .success)
    }

    @Test func returnsMergedWhenNoOpen() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: listAllArgs,
            output: CLIOutput(stdout: loadFixture("glab-mr-merged"), stderr: "", exitCode: 0)
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [])
        let mr = snapshot.prsByBranch["feature/gh-integration"]
        #expect(mr?.number == 498)
        #expect(mr?.state == .merged)
        #expect(mr?.checks == PRInfo.Checks.none)
    }

    @Test func pipelineViewFailureFallsBackToNoneChecks() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: listAllArgs,
            output: CLIOutput(stdout: loadFixture("glab-mr-opened"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: viewArgs(512),
            error: .nonZeroExit(command: "glab", exitCode: 1, stderr: "network hiccup")
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [branch])
        let mr = snapshot.prsByBranch[branch]
        #expect(mr?.number == 512)
        #expect(mr?.state == .open)
        #expect(mr?.checks == PRInfo.Checks.none)
    }

    @Test("""
    @spec PR-8.15: When the application resolves PR/MR status for a GitLab repo's worktrees, it shall issue a single `glab mr list --all` call per repo for the listing and fan out per-MR `glab mr view` calls in parallel only for branches the caller cares about. A repo with 100 MRs and 5 worktrees must produce 1 list call + 5 view calls per tick, not 100 view calls.
    """)
    func pipelineFetchedOnlyForBranchesOfInterest() async throws {
        // Two same-repo MRs in the listing. Only `branchA` is asked for.
        let fake = FakeCLIExecutor()
        let multiMR = """
        [
          {"iid":11,"title":"A","web_url":"https://gitlab.com/foo/bar/-/merge_requests/11","state":"opened","source_branch":"branchA","source_project_id":1,"target_project_id":1,"has_conflicts":false},
          {"iid":22,"title":"B","web_url":"https://gitlab.com/foo/bar/-/merge_requests/22","state":"opened","source_branch":"branchB","source_project_id":1,"target_project_id":1,"has_conflicts":true}
        ]
        """
        fake.stub(command: "glab", args: listAllArgs,
                  output: CLIOutput(stdout: multiMR, stderr: "", exitCode: 0))
        fake.stub(command: "glab", args: viewArgs(11),
                  output: CLIOutput(stdout: loadFixture("glab-mr-view-pipeline-success"), stderr: "", exitCode: 0))

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: ["branchA"])

        // List + 1 view (only branchA), not 1 + 2.
        #expect(fake.invocations.count == 2)
        #expect(snapshot.prsByBranch["branchA"]?.checks == .success)
        // branchB still in the snapshot (with .none checks) and conflict surfaces.
        #expect(snapshot.prsByBranch["branchB"]?.checks == PRInfo.Checks.none)
        #expect(snapshot.prsByBranch["branchB"]?.mergeable == .conflicting)
    }
}

@Suite("GitLabPRFetcher.mapStatus")
struct GitLabPRFetcherMapStatusTests {
    @Test func successMaps() { #expect(GitLabPRFetcher.mapStatus("success") == .success) }
    @Test func failedMaps() { #expect(GitLabPRFetcher.mapStatus("failed") == .failure) }
    @Test func canceledMaps() { #expect(GitLabPRFetcher.mapStatus("canceled") == .failure) }
    @Test func runningMaps() { #expect(GitLabPRFetcher.mapStatus("running") == .pending) }
    @Test func pendingMaps() { #expect(GitLabPRFetcher.mapStatus("pending") == .pending) }
    @Test func preparingMaps() { #expect(GitLabPRFetcher.mapStatus("preparing") == .pending) }
    @Test func scheduledMaps() { #expect(GitLabPRFetcher.mapStatus("scheduled") == .pending) }
    @Test func unknownIsNone() { #expect(GitLabPRFetcher.mapStatus("something-new") == PRInfo.Checks.none) }
    @Test func caseInsensitive() { #expect(GitLabPRFetcher.mapStatus("SUCCESS") == .success) }
}
