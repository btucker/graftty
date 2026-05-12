import Testing
import GrafttyProtocol
import Foundation
@testable import GrafttyKit

/// PR/MR association keys off the **tracked remote branch**, not the
/// local branch name. GitHub's `gh pr list` keys results by
/// `headRefName` and GitLab's `glab mr list` by `source_branch` —
/// both the remote-side ref. When a worktree's local branch tracks
/// a differently-named upstream (e.g. local `pr-cleanup` →
/// `origin/feature/foo`, or any branch renamed locally only), a
/// literal `prsByBranch[localBranch]` lookup misses and the
/// worktree's PR badge silently disappears. Resolution must use the
/// branch git would push to, i.e. `@{upstream}`.
@Suite("PRStatusStore — upstream-branch lookup", .serialized)
struct PRStatusStoreUpstreamTrackingTests {

    private static let listArgs = [
        "pr", "list", "--repo", "foo/bar",
        "--state", "all", "--limit", "100",
        "--json", "number,title,url,state,headRefName,headRepositoryOwner,statusCheckRollup,mergeable",
    ]
    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "foo", repo: "bar"
    )

    @MainActor
    @Test("""
@spec PR-8.23: When a worktree's local branch name differs from the remote branch it tracks (via `branch.<name>.merge` / `git push -u`), the application shall associate the worktree with the PR/MR whose head ref equals the tracked remote branch name, not the local branch name. PR fetchers key snapshots by the remote-side head ref (`headRefName` for GitHub, `source_branch` for GitLab), so the previous `prsByBranch[localBranch]` lookup silently dropped the badge whenever the worktree's branch was renamed locally only or its upstream was bound to a differently-named ref.
""")
    func associatesWorktreeWithUpstreamBranchPR() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: Self.listArgs,
            output: CLIOutput(
                stdout: """
                [
                  {"number":77,"title":"Pull","url":"https://github.com/foo/bar/pull/77","state":"OPEN","headRefName":"feature/foo","headRepositoryOwner":{"login":"foo"},"statusCheckRollup":[],"mergeable":"MERGEABLE"}
                ]
                """,
                stderr: "", exitCode: 0
            )
        )

        let remoteBranchStore = RemoteBranchStore(list: { _ in
            RemoteBranchSnapshot(
                branches: ["feature/foo"],
                upstreams: ["local-rename": "feature/foo"]
            )
        })
        remoteBranchStore.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "local-rename")
        }

        let store = PRStatusStore(
            executor: fake,
            detectHost: { _ in Self.origin },
            remoteBranchStore: remoteBranchStore
        )
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/wt", branch: "local-rename", state: .running)]
        )
        store.start(ticker: ManualTicker(), getRepos: { [repo] })
        defer { store.stop() }

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "local-rename")

        try await waitUntil(timeout: 1.0) {
            store.infos["/wt"]?.number == 77
        }

        #expect(store.infos["/wt"]?.number == 77,
                "PR should be associated via tracked upstream `feature/foo`, not local `local-rename`")
        #expect(!store.absent.contains("/wt"))
    }

    @MainActor
    @Test("GitLab fetcher receives the tracked upstream branch in `branchesOfInterest` so the per-MR pipeline fan-out fetches the right MR. Without this, pipeline status for a renamed-locally branch's MR never resolves. Implementation detail of `PR-8.23`.")
    func gitLabFetcherReceivesUpstreamBranchInInterestSet() async throws {
        let observed = ObservedInterest()
        let fetcher = RecordingFetcher(observer: observed, prsByBranch: [:])
        let remoteBranchStore = RemoteBranchStore(list: { _ in
            RemoteBranchSnapshot(
                branches: ["upstream-name"],
                upstreams: ["local-name": "upstream-name"]
            )
        })
        remoteBranchStore.refresh(repoPath: "/repo")
        try await waitUntil(timeout: 1.0) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "local-name")
        }

        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in HostingOrigin(provider: .gitlab, host: "gitlab.com", owner: "foo", repo: "bar") },
            remoteBranchStore: remoteBranchStore
        )
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/wt", branch: "local-name", state: .running)]
        )
        store.start(ticker: ManualTicker(), getRepos: { [repo] })
        defer { store.stop() }

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "local-name")
        try await waitUntil(timeout: 1.0) {
            await observed.captured() == ["upstream-name"]
        }

        #expect(await observed.captured() == ["upstream-name"])
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let succeeded = await condition()
        #expect(succeeded, "waitUntil timed out")
    }
}

private actor ObservedInterest {
    private var seen: Set<String> = []
    func record(_ branches: Set<String>) { seen = branches }
    func captured() -> Set<String> { seen }
}

private actor RecordingFetcher: PRFetcher {
    private let observer: ObservedInterest
    private let prsByBranch: [String: PRInfo]

    init(observer: ObservedInterest, prsByBranch: [String: PRInfo]) {
        self.observer = observer
        self.prsByBranch = prsByBranch
    }

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        await observer.record(branchesOfInterest)
        return RepoPRSnapshot(prsByBranch: prsByBranch)
    }
}
