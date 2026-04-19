import Testing
import Foundation
@testable import EspalierKit

@Suite("PRStatusStore integration")
struct PRStatusStoreIntegrationTests {

    @Test func fetchesAndPublishesPRInfo() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "foo/bar",
                "--head", "feature/x", "--state", "open", "--limit", "5",
                "--json", "number,title,url,state,headRefName,headRepositoryOwner"
            ],
            output: CLIOutput(
                stdout: #"[{"number":10,"title":"hello","url":"https://github.com/foo/bar/pull/10","state":"OPEN","headRefName":"feature/x","headRepositoryOwner":{"login":"foo"}}]"#,
                stderr: "",
                exitCode: 0
            )
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "10", "--repo", "foo/bar", "--json", "name,state,bucket"],
            output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0)
        )

        // Inject a host detector so the test doesn't need to touch GitRunner's
        // shared-state executor (which races with other suites in parallel).
        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "foo", repo: "bar")
        let store = await PRStatusStore(
            executor: fake,
            detectHost: { _ in origin }
        )
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature/x")

        // Poll for the async Task to complete.
        for _ in 0..<50 {
            if await store.infos["/wt"] != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let info = await store.infos["/wt"]
        #expect(info?.number == 10)
        #expect(info?.state == .open)
        #expect(info?.checks == PRInfo.Checks.none)
    }

    @Test func absentWhenNoPR() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "foo/bar",
                "--head", "feature/x", "--state", "open", "--limit", "5",
                "--json", "number,title,url,state,headRefName,headRepositoryOwner"
            ],
            output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "foo/bar",
                "--head", "feature/x", "--state", "merged", "--limit", "5",
                "--json", "number,title,url,state,headRefName,headRepositoryOwner,mergedAt"
            ],
            output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0)
        )

        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "foo", repo: "bar")
        let store = await PRStatusStore(
            executor: fake,
            detectHost: { _ in origin }
        )
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature/x")

        for _ in 0..<50 {
            if await store.absent.contains("/wt") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await store.infos["/wt"] == nil)
        #expect(await store.absent.contains("/wt"))
    }

    @Test func branchDidChangeDropsStalePRImmediatelyAndRefetchesForNewBranch() async throws {
        // Reproduces the "wrong PR after branch switch" symptom: a worktree
        // showed branch A's PR for minutes after the user checked out
        // branch B, because nothing notified PRStatusStore that the branch
        // had changed — only the polling tick (5–15 min cadence) eventually
        // corrected it.
        let fake = FakeCLIExecutor()

        // Branch A: PR #100
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "foo/bar",
                "--head", "branchA", "--state", "open", "--limit", "5",
                "--json", "number,title,url,state,headRefName,headRepositoryOwner"
            ],
            output: CLIOutput(
                stdout: #"[{"number":100,"title":"A","url":"https://github.com/foo/bar/pull/100","state":"OPEN","headRefName":"branchA","headRepositoryOwner":{"login":"foo"}}]"#,
                stderr: "", exitCode: 0
            )
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "100", "--repo", "foo/bar", "--json", "name,state,bucket"],
            output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0)
        )

        // Branch B: PR #200
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "foo/bar",
                "--head", "branchB", "--state", "open", "--limit", "5",
                "--json", "number,title,url,state,headRefName,headRepositoryOwner"
            ],
            output: CLIOutput(
                stdout: #"[{"number":200,"title":"B","url":"https://github.com/foo/bar/pull/200","state":"OPEN","headRefName":"branchB","headRepositoryOwner":{"login":"foo"}}]"#,
                stderr: "", exitCode: 0
            )
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "200", "--repo", "foo/bar", "--json", "name,state,bucket"],
            output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0)
        )

        let origin = HostingOrigin(provider: .github, host: "github.com", owner: "foo", repo: "bar")
        let store = await PRStatusStore(executor: fake, detectHost: { _ in origin })

        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "branchA")
        for _ in 0..<50 {
            if await store.infos["/wt"]?.number == 100 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await store.infos["/wt"]?.number == 100)

        // Branch changed externally (e.g. the user ran `git checkout`).
        // The bridge notifies the store.
        await store.branchDidChange(worktreePath: "/wt", repoPath: "/repo", branch: "branchB")

        // Stale info must be dropped immediately — not after the new fetch
        // lands. Otherwise the UI keeps showing branch A's PR through the
        // gh-fetch in-flight window.
        #expect(await store.infos["/wt"] == nil, "stale PR still showing after branch change")

        // Eventually the new branch's PR is fetched and published.
        for _ in 0..<50 {
            if await store.infos["/wt"]?.number == 200 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await store.infos["/wt"]?.number == 200)
    }

    @Test func unsupportedHostMarksAbsent() async throws {
        let fake = FakeCLIExecutor()

        let origin = HostingOrigin(provider: .unsupported, host: "bitbucket.org", owner: "foo", repo: "bar")
        let store = await PRStatusStore(
            executor: fake,
            detectHost: { _ in origin }
        )
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "main")

        for _ in 0..<50 {
            if await store.absent.contains("/wt") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await store.absent.contains("/wt"))
    }
}
