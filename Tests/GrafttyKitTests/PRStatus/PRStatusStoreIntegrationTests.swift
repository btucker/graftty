import Testing
import Foundation
@testable import GrafttyKit

@Suite("PRStatusStore integration")
struct PRStatusStoreIntegrationTests {

    private static let listArgs = [
        "pr", "list", "--repo", "foo/bar",
        "--state", "all", "--limit", "100",
        "--json", "number,title,url,state,headRefName,headRepositoryOwner,statusCheckRollup,mergeable",
    ]
    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "foo", repo: "bar"
    )

    @MainActor
    private static func makeStore(
        executor: CLIExecutor,
        provider: HostingProvider = .github,
        host: String = "github.com",
        owner: String = "foo",
        repo: String = "bar",
        worktrees: [WorktreeEntry] = [
            WorktreeEntry(path: "/wt", branch: "feature/x", state: .running)
        ]
    ) -> (PRStatusStore, ManualTicker) {
        let originLocal = HostingOrigin(provider: provider, host: host, owner: owner, repo: repo)
        let store = PRStatusStore(executor: executor, detectHost: { _ in originLocal })
        let ticker = ManualTicker()
        let repoEntry = RepoEntry(path: "/repo", displayName: "repo", worktrees: worktrees)
        store.start(ticker: ticker, getRepos: { [repoEntry] })
        return (store, ticker)
    }

    @Test func fetchesAndPublishesPRInfo() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: Self.listArgs,
            output: CLIOutput(
                stdout: #"[{"number":10,"title":"hello","url":"https://github.com/foo/bar/pull/10","state":"OPEN","headRefName":"feature/x","headRepositoryOwner":{"login":"foo"},"statusCheckRollup":[],"mergeable":"MERGEABLE"}]"#,
                stderr: "",
                exitCode: 0
            )
        )

        let (store, _) = await Self.makeStore(executor: fake)
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature/x")

        for _ in 0..<50 {
            if await store.infos["/wt"] != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let info = await store.infos["/wt"]
        #expect(info?.number == 10)
        #expect(info?.state == .open)
        #expect(info?.checks == PRInfo.Checks.none)
        #expect(info?.mergeable == .mergeable)
        await MainActor.run { store.stop() }
    }

    @Test func absentWhenNoPR() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: Self.listArgs,
            output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0)
        )

        let (store, _) = await Self.makeStore(executor: fake)
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature/x")

        for _ in 0..<50 {
            if await store.absent.contains("/wt") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await store.infos["/wt"] == nil)
        #expect(await store.absent.contains("/wt"))
        await MainActor.run { store.stop() }
    }

    @Test func branchDidChangeDropsStalePRImmediatelyAndRefetchesForNewBranch() async throws {
        // Reproduces the "wrong PR after branch switch" symptom: a
        // worktree showed branch A's PR for minutes after the user
        // checked out branch B because nothing notified
        // PRStatusStore that the branch had changed.
        let fake = FakeCLIExecutor()
        // Single per-repo response covers both branches; the
        // store distributes by current worktree branch.
        fake.stub(
            command: "gh",
            args: Self.listArgs,
            output: CLIOutput(
                stdout: """
                [
                  {"number":100,"title":"A","url":"https://github.com/foo/bar/pull/100","state":"OPEN","headRefName":"branchA","headRepositoryOwner":{"login":"foo"},"statusCheckRollup":[],"mergeable":"MERGEABLE"},
                  {"number":200,"title":"B","url":"https://github.com/foo/bar/pull/200","state":"OPEN","headRefName":"branchB","headRepositoryOwner":{"login":"foo"},"statusCheckRollup":[],"mergeable":"MERGEABLE"}
                ]
                """,
                stderr: "", exitCode: 0
            )
        )

        let (repoBox, store) = await MainActor.run {
            let repoBox = RepoEntryBox(repo: RepoEntry(
                path: "/repo",
                displayName: "repo",
                worktrees: [WorktreeEntry(path: "/wt", branch: "branchA", state: .running)]
            ))
            let store = PRStatusStore(executor: fake, detectHost: { _ in Self.origin })
            store.start(ticker: ManualTicker(), getRepos: { [repoBox.repo] })
            return (repoBox, store)
        }

        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "branchA")
        for _ in 0..<50 {
            if await store.infos["/wt"]?.number == 100 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await store.infos["/wt"]?.number == 100)

        // Branch changed externally — bridge notifies the store.
        await MainActor.run {
            repoBox.repo.worktrees[0].branch = "branchB"
        }
        // Step past in-flight cap so the second refresh dispatches.
        await MainActor.run {
            store.seedInFlightSinceForTesting(
                Date().addingTimeInterval(-3600),
                forRepo: "/repo"
            )
        }
        await store.branchDidChange(worktreePath: "/wt", repoPath: "/repo", branch: "branchB")

        // Stale info dropped immediately — not after the new fetch lands.
        #expect(await store.infos["/wt"] == nil, "stale PR still showing after branch change")

        for _ in 0..<50 {
            if await store.infos["/wt"]?.number == 200 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(await store.infos["/wt"]?.number == 200)
        await MainActor.run { store.stop() }
    }

    @Test func unsupportedHostMarksAbsent() async throws {
        let fake = FakeCLIExecutor()
        let (store, _) = await Self.makeStore(
            executor: fake,
            provider: .unsupported,
            host: "bitbucket.org",
            worktrees: [WorktreeEntry(path: "/wt", branch: "main", state: .running)]
        )
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "main")

        for _ in 0..<50 {
            if await store.absent.contains("/wt") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await store.absent.contains("/wt"))
        await MainActor.run { store.stop() }
    }
}

@MainActor
private final class RepoEntryBox {
    var repo: RepoEntry
    init(repo: RepoEntry) { self.repo = repo }
}

