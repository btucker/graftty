import Testing
import GrafttyProtocol
import Foundation
@testable import GrafttyKit

@Suite("GitLabPRFetcher")
struct GitLabPRFetcherTests {
    let origin = HostingOrigin(provider: .gitlab, host: "gitlab.com", owner: "foo", repo: "bar")
    let branch = "feature/blindspots"

    /// Single per-repo `glab mr list --all` invocation that returns
    /// every MR in any state. Pipeline status is fetched per
    /// branch-of-interest via the raw single-MR REST endpoint because
    /// `glab mr list` doesn't include `head_pipeline`.
    var listAllArgs: [String] {
        [
            "mr", "list",
            "--repo", "https://gitlab.com/foo/bar",
            "--all",
            "--per-page", "100",
            "-F", "json",
        ]
    }

    func detailArgs(_ iid: Int, origin: HostingOrigin? = nil) -> [String] {
        let origin = origin ?? self.origin
        var pathSegmentAllowed = CharacterSet.alphanumerics
        pathSegmentAllowed.insert(charactersIn: "-._~")
        let projectPath = origin.slug.addingPercentEncoding(
            withAllowedCharacters: pathSegmentAllowed
        )!
        return [
            "api",
            "projects/\(projectPath)/merge_requests/\(iid)",
            "--hostname", origin.host,
        ]
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
            args: detailArgs(512),
            output: CLIOutput(stdout: loadFixture("glab-mr-detail-success"), stderr: "", exitCode: 0)
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [branch])
        let mr = snapshot.prsByBranch[branch]
        #expect(mr?.number == 512)
        #expect(mr?.state == .open)
        #expect(mr?.checks == .success)
        #expect(mr?.mergeable == .mergeable)
    }

    @Test("""
    @spec PR-8.27: While polling an open GitLab merge request, the application shall derive textual-conflict state from `has_conflicts` and `merge_status` in the raw single-MR REST response, not from the potentially stale `glab mr list` response or from `detailed_merge_status`. If `has_conflicts == true`, then the application shall report conflicting. If `has_conflicts == false` and `merge_status == can_be_merged`, then the application shall report mergeable. If the detail call fails, omits `has_conflicts`, or reports a transient recomputation state such as `checking`, `unchecked`, or `cannot_be_merged_recheck`, then the application shall report `.unknown` rather than a conclusion that can trigger a false transition. The application shall not interpret a `detailed_merge_status` such as `draft_status` as textual conflict state because it describes broader merge policy.
    """)
    func detailHasConflictsIsAuthoritativeAndDraftStatusIsIgnored() async throws {
        let fake = FakeCLIExecutor()
        let list = """
        [
          {"iid":11,"title":"Conflict hidden by stale list","web_url":"https://gitlab.com/foo/bar/-/merge_requests/11","state":"opened","source_branch":"conflicting","source_project_id":1,"target_project_id":1,"has_conflicts":false},
          {"iid":22,"title":"Clean but still draft","web_url":"https://gitlab.com/foo/bar/-/merge_requests/22","state":"opened","source_branch":"draft","source_project_id":1,"target_project_id":1,"has_conflicts":true},
          {"iid":33,"title":"Pipeline recomputing","web_url":"https://gitlab.com/foo/bar/-/merge_requests/33","state":"opened","source_branch":"checking","source_project_id":1,"target_project_id":1,"has_conflicts":false}
        ]
        """
        fake.stub(
            command: "glab",
            args: listAllArgs,
            output: CLIOutput(stdout: list, stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: detailArgs(11),
            output: CLIOutput(
                stdout: #"{"head_pipeline":null,"has_conflicts":true,"merge_status":"cannot_be_merged","detailed_merge_status":"draft_status"}"#,
                stderr: "",
                exitCode: 0
            )
        )
        fake.stub(
            command: "glab",
            args: detailArgs(22),
            output: CLIOutput(
                stdout: #"{"head_pipeline":null,"has_conflicts":false,"merge_status":"can_be_merged","detailed_merge_status":"draft_status"}"#,
                stderr: "",
                exitCode: 0
            )
        )
        fake.stub(
            command: "glab",
            args: detailArgs(33),
            output: CLIOutput(
                stdout: #"{"head_pipeline":{"id":9002,"status":"running"},"has_conflicts":false,"merge_status":"checking","detailed_merge_status":"ci_still_running"}"#,
                stderr: "",
                exitCode: 0
            )
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(
            origin: origin,
            branchesOfInterest: ["conflicting", "draft", "checking"]
        )

        #expect(snapshot.prsByBranch["conflicting"]?.mergeable == .conflicting)
        #expect(snapshot.prsByBranch["draft"]?.mergeable == .mergeable)
        #expect(snapshot.prsByBranch["checking"]?.checks == .pending)
        #expect(snapshot.prsByBranch["checking"]?.mergeable == .unknown)
    }

    @Test("""
    @spec PR-5.3: When GitLab returns merge requests for a source branch, the application shall keep only same-project merge requests whose `source_project_id` equals `target_project_id`. If either project ID is absent or the IDs differ, then the application shall exclude that merge request so a fork cannot be attributed to the local worktree.
    """)
    func filtersForkMRInFavorOfOriginMR() async throws {
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
            args: detailArgs(512),
            output: CLIOutput(stdout: loadFixture("glab-mr-detail-success"), stderr: "", exitCode: 0)
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

    @Test func returnsClosedUnmergedMR() async throws {
        let fake = FakeCLIExecutor()
        let stdout = """
        [
          {"iid":77,"title":"abandoned","web_url":"https://gitlab.com/foo/bar/-/merge_requests/77","state":"closed","source_branch":"feat","source_project_id":1,"target_project_id":1,"has_conflicts":true}
        ]
        """
        fake.stub(command: "glab", args: listAllArgs,
                  output: CLIOutput(stdout: stdout, stderr: "", exitCode: 0))

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: ["feat"])
        let mr = snapshot.prsByBranch["feat"]
        #expect(mr?.number == 77)
        #expect(mr?.state == .closed)
        // Pipeline status / conflict on a terminal MR are stale —
        // and the detail subprocess must not be spawned at all.
        #expect(mr?.checks == PRInfo.Checks.none)
        #expect(mr?.mergeable == .unknown)
        #expect(fake.invocations.count == 1, "no `glab api` detail request for a closed-unmerged MR")
    }

    @Test func detailRequestFailureFallsBackToUnknownStatus() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: listAllArgs,
            output: CLIOutput(stdout: loadFixture("glab-mr-opened"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: detailArgs(512),
            error: .nonZeroExit(command: "glab", exitCode: 1, stderr: "network hiccup")
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: [branch])
        let mr = snapshot.prsByBranch[branch]
        #expect(mr?.number == 512)
        #expect(mr?.state == .open)
        #expect(mr?.checks == PRInfo.Checks.none)
        #expect(mr?.mergeable == .unknown)
    }

    @Test("""
    @spec PR-8.15: When the application resolves PR/MR status for a GitLab repo's worktrees, it shall issue a single `glab mr list --all` call per repo for the listing and fan out raw single-MR REST calls through `glab api` in parallel only for branches the caller cares about. A repo with 100 MRs and 5 worktrees must produce 1 list call + 5 detail calls per tick, not 100 detail calls.
    """)
    func detailsFetchedOnlyForBranchesOfInterest() async throws {
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
        fake.stub(command: "glab", args: detailArgs(11),
                  output: CLIOutput(stdout: loadFixture("glab-mr-detail-success"), stderr: "", exitCode: 0))

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(origin: origin, branchesOfInterest: ["branchA"])

        // List + 1 view (only branchA), not 1 + 2.
        #expect(fake.invocations.count == 2)
        #expect(snapshot.prsByBranch["branchA"]?.checks == .success)
        // branchB still appears in the snapshot, but detail-derived fields
        // stay absent because it wasn't a branch of interest.
        #expect(snapshot.prsByBranch["branchB"]?.checks == PRInfo.Checks.none)
        #expect(snapshot.prsByBranch["branchB"]?.mergeable == .unknown)
    }

    @Test("""
    @spec PR-8.26: When multiple same-project GitLab merge requests reuse one source branch, the application shall select an opened MR over a terminal MR and otherwise select the newest candidate by highest IID, independent of `glab mr list` result order, and shall attribute pipeline status to that selected MR.
    """)
    func reusedBranchSelectsNewestEquivalentMRAndItsPipeline() async throws {
        let fake = FakeCLIExecutor()
        let reusedBranches = """
        [
          {"iid":710,"title":"old merged","web_url":"https://gitlab.com/foo/bar/-/merge_requests/710","state":"merged","source_branch":"terminal-reuse","source_project_id":1,"target_project_id":1,"has_conflicts":false},
          {"iid":821,"title":"new closed","web_url":"https://gitlab.com/foo/bar/-/merge_requests/821","state":"closed","source_branch":"terminal-reuse","source_project_id":1,"target_project_id":1,"has_conflicts":false},
          {"iid":900,"title":"old open","web_url":"https://gitlab.com/foo/bar/-/merge_requests/900","state":"opened","source_branch":"open-reuse","source_project_id":1,"target_project_id":1,"has_conflicts":true},
          {"iid":901,"title":"current open","web_url":"https://gitlab.com/foo/bar/-/merge_requests/901","state":"opened","source_branch":"open-reuse","source_project_id":1,"target_project_id":1,"has_conflicts":false}
        ]
        """
        fake.stub(
            command: "glab",
            args: listAllArgs,
            output: CLIOutput(stdout: reusedBranches, stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: detailArgs(901),
            output: CLIOutput(
                stdout: loadFixture("glab-mr-detail-success"),
                stderr: "",
                exitCode: 0
            )
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(
            origin: origin,
            branchesOfInterest: ["terminal-reuse", "open-reuse"]
        )

        #expect(snapshot.prsByBranch["terminal-reuse"]?.number == 821)
        #expect(snapshot.prsByBranch["terminal-reuse"]?.state == .closed)
        #expect(snapshot.prsByBranch["open-reuse"]?.number == 901)
        #expect(snapshot.prsByBranch["open-reuse"]?.checks == .success)
        #expect(fake.invocations.contains { $0.args == detailArgs(901) })
        #expect(!fake.invocations.contains { $0.args == detailArgs(900) })
    }

    @Test func detailRequestSelectsHostAndEncodesNestedProjectPath() async throws {
        let fake = FakeCLIExecutor()
        let selfHosted = HostingOrigin(
            provider: .gitlab,
            host: "gitlab.acme.com",
            owner: "group",
            repo: "subgroup/project"
        )
        let listArgs = [
            "mr", "list",
            "--repo", "https://gitlab.acme.com/group/subgroup/project",
            "--all",
            "--per-page", "100",
            "-F", "json",
        ]
        let list = """
        [
          {"iid":44,"title":"Nested","web_url":"https://gitlab.acme.com/group/subgroup/project/-/merge_requests/44","state":"opened","source_branch":"nested","source_project_id":1,"target_project_id":1}
        ]
        """
        fake.stub(
            command: "glab",
            args: listArgs,
            output: CLIOutput(stdout: list, stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: detailArgs(44, origin: selfHosted),
            output: CLIOutput(
                stdout: loadFixture("glab-mr-detail-success"),
                stderr: "",
                exitCode: 0
            )
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let snapshot = try await fetcher.fetch(
            origin: selfHosted,
            branchesOfInterest: ["nested"]
        )

        #expect(snapshot.prsByBranch["nested"]?.mergeable == .mergeable)
        #expect(fake.invocations.contains {
            $0.args == [
                "api",
                "projects/group%2Fsubgroup%2Fproject/merge_requests/44",
                "--hostname", "gitlab.acme.com",
            ]
        })
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
