import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitLabPRFetcher")
struct GitLabPRFetcherTests {
    let origin = HostingOrigin(provider: .gitlab, host: "gitlab.com", owner: "foo", repo: "bar")
    let branch = "feature/blindspots"

    func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "json")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    @Test func returnsOpenMRWithSuccessChecks() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: [
                "mr", "list",
                "--repo", "foo/bar",
                "--source-branch", branch,
                "--state", "opened",
                "--per-page", "5",
                "-F", "json"
            ],
            output: CLIOutput(stdout: loadFixture("glab-mr-opened"), stderr: "", exitCode: 0)
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let mr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(mr?.number == 512)
        #expect(mr?.state == .open)
        #expect(mr?.checks == .success)
    }

    @Test func filtersForkMRInFavorOfOriginMR() async throws {
        // `glab mr list` will surface same-source-branch MRs from forks
        // (their `source_project_id` differs from the target project's).
        // Parity with PR-5.1 on the GitHub side: take the origin-owned
        // MR, not the fork's, even if `glab`'s default sort puts the
        // fork first.
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: [
                "mr", "list",
                "--repo", "foo/bar",
                "--source-branch", branch,
                "--state", "opened",
                "--per-page", "5",
                "-F", "json"
            ],
            output: CLIOutput(stdout: loadFixture("glab-mr-fork-open"), stderr: "", exitCode: 0)
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let mr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(mr?.number == 512)
        #expect(mr?.state == .open)
        #expect(mr?.checks == .success)
    }

    @Test func returnsMergedWhenNoOpen() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: [
                "mr", "list",
                "--repo", "foo/bar",
                "--source-branch", branch,
                "--state", "opened",
                "--per-page", "5",
                "-F", "json"
            ],
            output: CLIOutput(stdout: loadFixture("glab-mr-empty"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: [
                "mr", "list",
                "--repo", "foo/bar",
                "--source-branch", branch,
                "--state", "merged",
                "--per-page", "5",
                "-F", "json"
            ],
            output: CLIOutput(stdout: loadFixture("glab-mr-merged"), stderr: "", exitCode: 0)
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let mr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(mr?.number == 498)
        #expect(mr?.state == .merged)
        #expect(mr?.checks == PRInfo.Checks.none)
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
