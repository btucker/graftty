import Testing
import GrafttyProtocol
import Foundation
@testable import GrafttyKit
import GrafttyKitTestSupport

/// PR fetchers key snapshots by the PR's remote head ref. A worktree
/// whose local branch name matches neither that ref nor a tracked
/// upstream — a checkout made at a merged PR's head after its remote
/// branch was deleted, or a branch pushed under another name without
/// `-u` — used to lose its PR badge entirely. These tests cover the
/// fallback that matches the branch's tip commit against PR heads.
@Suite("""
@spec PR-1.3: If a worktree's branch matches no PR/MR head ref by name or tracked upstream, then the application shall associate the worktree with the same-repository PR/MR whose head commit equals the branch's tip commit, preferring the PR/MR whose head ref is the branch's own name, then an open PR/MR, and otherwise the highest number. The application shall skip this fallback for the repository's default branch and for any branch whose tip is the default branch's tip, and shall not match a PR/MR whose head ref is another local branch or another local branch's tracked upstream, so a branch created from another branch's tip does not inherit that branch's PR/MR.
""", .serialized)
struct PRStatusStoreHeadCommitMatchTests {
    private static let origin = HostingOrigin(
        provider: .github, host: "github.com", owner: "foo", repo: "bar"
    )
    private static let mergedHead = "d5988db63e82c9d639e904e58d0e9ff333b2c76c"

    @MainActor
    @Test func mergedPRWithDeletedHeadRefMatchesCheckoutAtItsHeadCommit() async throws {
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                remoteBranches: [BranchRef(name: "main", lastCommitDate: .distantPast)],
                localBranches: [Self.local("main"), Self.local("pr-883-webrtc-keepalive")],
                upstreams: ["main": "main"],
                defaultBranch: "main",
                localTips: ["main": "aaaa", "pr-883-webrtc-keepalive": Self.mergedHead]
            ),
            prs: ["claude/cool-keller-sp10qn": Self.pr(883, state: .merged, head: Self.mergedHead)],
            branch: "pr-883-webrtc-keepalive"
        )
        defer { store.stop() }

        try await waitUntil { store.infos["/wt"]?.number == 883 }
        #expect(store.infos["/wt"]?.state == .merged)
        #expect(!store.absent.contains("/wt"))
    }

    @MainActor
    @Test func openPRPushedUnderAnotherNameMatchesByTipCommit() async throws {
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                remoteBranches: [Self.local("main"), Self.local("renamed-on-push")],
                localBranches: [Self.local("main"), Self.local("local-name")],
                upstreams: ["main": "main"],
                defaultBranch: "main",
                localTips: ["main": "aaaa", "local-name": "bbbb"]
            ),
            prs: ["renamed-on-push": Self.pr(12, state: .open, head: "bbbb")],
            branch: "local-name"
        )
        defer { store.stop() }

        try await waitUntil { store.infos["/wt"]?.number == 12 }
        #expect(!store.absent.contains("/wt"))
    }

    @MainActor
    @Test func branchCreatedFromAnotherLocalBranchDoesNotInheritItsPR() async throws {
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                remoteBranches: [Self.local("main"), Self.local("bar")],
                localBranches: [Self.local("main"), Self.local("bar"), Self.local("foo")],
                upstreams: ["main": "main", "bar": "bar"],
                defaultBranch: "main",
                localTips: ["main": "aaaa", "bar": "cccc", "foo": "cccc"]
            ),
            prs: ["bar": Self.pr(5, state: .open, head: "cccc")],
            branch: "foo"
        )
        defer { store.stop() }

        try await waitUntilSnapshotApplied(store)
        #expect(store.infos["/wt"] == nil)
    }

    @MainActor
    @Test func branchCreatedFromABranchTrackingAnotherNameDoesNotInheritItsPR() async throws {
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                remoteBranches: [Self.local("main"), Self.local("feature-x")],
                localBranches: [Self.local("main"), Self.local("bar"), Self.local("foo")],
                upstreams: ["main": "main", "bar": "feature-x"],
                defaultBranch: "main",
                localTips: ["main": "aaaa", "bar": "cccc", "foo": "cccc"]
            ),
            prs: ["feature-x": Self.pr(5, state: .open, head: "cccc")],
            branch: "foo"
        )
        defer { store.stop() }

        try await waitUntilSnapshotApplied(store)
        #expect(store.infos["/wt"] == nil)
    }

    @MainActor
    @Test func defaultBranchDoesNotMatchAPRByTipCommit() async throws {
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                remoteBranches: [Self.local("main")],
                localBranches: [Self.local("main")],
                upstreams: ["main": "main"],
                defaultBranch: "main",
                localTips: ["main": "dddd"]
            ),
            prs: ["fast-forwarded": Self.pr(9, state: .merged, head: "dddd")],
            branch: "main"
        )
        defer { store.stop() }

        try await waitUntil { store.absent.contains("/wt") }
        #expect(store.infos["/wt"] == nil)
    }

    @MainActor
    @Test func branchAtTheDefaultBranchTipDoesNotMatchAPRByTipCommit() async throws {
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                remoteBranches: [Self.local("main")],
                localBranches: [Self.local("main"), Self.local("new-feature")],
                upstreams: ["main": "main"],
                defaultBranch: "main",
                localTips: ["main": "dddd", "new-feature": "dddd"]
            ),
            prs: ["fast-forwarded": Self.pr(9, state: .merged, head: "dddd")],
            branch: "new-feature"
        )
        defer { store.stop() }

        try await waitUntilSnapshotApplied(store)
        #expect(store.infos["/wt"] == nil)
    }

    @MainActor
    @Test func branchPushedWithoutUpstreamKeepsItsOwnPRAfterTheHeadRefIsDeleted() async throws {
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                remoteBranches: [Self.local("main")],
                localBranches: [Self.local("main"), Self.local("foo")],
                upstreams: ["main": "main"],
                defaultBranch: "main",
                localTips: ["main": "aaaa", "foo": "eeee"]
            ),
            prs: ["foo": Self.pr(7, state: .merged, head: "eeee")],
            branch: "foo"
        )
        defer { store.stop() }

        try await waitUntil { store.infos["/wt"]?.number == 7 }
    }

    @MainActor
    @Test func refreshKeepsTipCommitMatchForBranchWithoutRemote() async throws {
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                localBranches: [Self.local("pr-883-webrtc-keepalive")],
                localTips: ["pr-883-webrtc-keepalive": Self.mergedHead]
            ),
            prs: ["claude/cool-keller-sp10qn": Self.pr(883, state: .merged, head: Self.mergedHead)],
            branch: "pr-883-webrtc-keepalive"
        )
        defer { store.stop() }
        try await waitUntil { store.infos["/wt"]?.number == 883 }

        store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "pr-883-webrtc-keepalive")

        #expect(store.infos["/wt"]?.number == 883)
    }

    @MainActor
    @Test("""
@spec PR-1.4: When a refresh is requested for a worktree whose branch has no remote but whose tip commit matches a PR/MR in the repository's last snapshot, the application shall refetch the repository's PRs/MRs instead of waiting for the next poll.
""")
    func refreshOfTipMatchedBranchWithoutRemoteRefetches() async throws {
        let fetcher = RecordingFetcher(prsByBranch: [
            "claude/cool-keller-sp10qn": Self.pr(883, state: .merged, head: Self.mergedHead),
        ])
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                localBranches: [Self.local("pr-883-webrtc-keepalive")],
                localTips: ["pr-883-webrtc-keepalive": Self.mergedHead]
            ),
            fetcher: fetcher,
            branch: "pr-883-webrtc-keepalive"
        )
        defer { store.stop() }
        try await waitUntil { store.infos["/wt"]?.number == 883 && !store.isInFlightForTesting("/repo") }
        #expect(await fetcher.invocationCount == 1)

        // A branch change clears the badge, then refreshes.
        store.branchDidChange(worktreePath: "/wt", repoPath: "/repo", branch: "pr-883-webrtc-keepalive")

        try await waitUntil { await fetcher.invocationCount == 2 }
        try await waitUntil { store.infos["/wt"]?.number == 883 }
    }

    @MainActor
    @Test func tipMatchedHeadRefJoinsBranchesOfInterestOnTheNextFetch() async throws {
        let fetcher = RecordingFetcher(prsByBranch: [
            "renamed-on-push": Self.pr(12, state: .open, head: "bbbb"),
        ])
        let ticker = ManualTicker()
        let store = try await makeStore(
            snapshot: RemoteBranchSnapshot(
                remoteBranches: [Self.local("main"), Self.local("renamed-on-push")],
                localBranches: [Self.local("main"), Self.local("local-name")],
                upstreams: ["main": "main"],
                defaultBranch: "main",
                localTips: ["main": "aaaa", "local-name": "bbbb"]
            ),
            fetcher: fetcher,
            branch: "local-name",
            ticker: ticker
        )
        defer { store.stop() }
        try await waitUntil { store.infos["/wt"]?.number == 12 && !store.isInFlightForTesting("/repo") }

        store.pulse()
        await ticker.fire()
        try await waitUntil { await fetcher.invocationCount == 2 }

        // GitLab fetches pipeline and mergeability only for these refs.
        #expect(await fetcher.branchesOfInterestHistory.last?.contains("renamed-on-push") == true)
    }

    @Test func headCommitLookupPrefersOpenThenHighestNumber() {
        let snapshot = RepoPRSnapshot(prsByBranch: [
            "a": Self.pr(30, state: .merged, head: "ffff"),
            "b": Self.pr(10, state: .open, head: "ffff"),
            "c": Self.pr(20, state: .open, head: "ffff"),
            "d": Self.pr(40, state: .open, head: "0000"),
        ])

        #expect(snapshot.headRef(forHeadCommit: "ffff", excludingHeadRefs: []) == "c")
        #expect(snapshot.headRef(forHeadCommit: "ffff", excludingHeadRefs: ["b", "c"]) == "a")
        #expect(snapshot.headRef(forHeadCommit: "1111", excludingHeadRefs: []) == nil)
    }

    // MARK: - Helpers

    @MainActor
    private func makeStore(
        snapshot: RemoteBranchSnapshot,
        prs: [String: PRInfo] = [:],
        fetcher: RecordingFetcher? = nil,
        branch: String,
        ticker: ManualTicker? = nil
    ) async throws -> PRStatusStore {
        let ticker = ticker ?? ManualTicker()
        let remoteBranchStore = RemoteBranchStore(list: { _ in snapshot })
        remoteBranchStore.refresh(repoPath: "/repo")
        try await waitUntil { remoteBranchStore.branchesByRepo["/repo"] != nil }

        let fetcher = fetcher ?? RecordingFetcher(prsByBranch: prs)
        let store = PRStatusStore(
            executor: FakeCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in Self.origin },
            remoteBranchStore: remoteBranchStore
        )
        let repo = RepoEntry(
            path: "/repo",
            displayName: "repo",
            worktrees: [WorktreeEntry(path: "/wt", branch: branch, state: .running)]
        )
        store.start(ticker: ticker, getRepos: { [repo] })
        await ticker.fire()
        return store
    }

    /// `prsByRepoBranch` is published at the end of every snapshot
    /// application, so a negative assertion after this cannot pass
    /// merely because the fetch has not landed yet.
    @MainActor
    private func waitUntilSnapshotApplied(_ store: PRStatusStore) async throws {
        try await waitUntil { store.prsByRepoBranch["/repo"] != nil }
    }

    private static func local(_ name: String) -> BranchRef {
        BranchRef(name: name, lastCommitDate: .distantPast)
    }

    private static func pr(_ number: Int, state: PRInfo.State, head: String) -> PRInfo {
        PRInfo(
            number: number,
            title: "PR \(number)",
            url: URL(string: "https://github.com/foo/bar/pull/\(number)")!,
            state: state,
            checks: .none,
            headSHA: head,
            fetchedAt: Date()
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
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

private actor RecordingFetcher: PRFetcher {
    let prsByBranch: [String: PRInfo]
    private(set) var branchesOfInterestHistory: [Set<String>] = []

    init(prsByBranch: [String: PRInfo]) {
        self.prsByBranch = prsByBranch
    }

    var invocationCount: Int { branchesOfInterestHistory.count }

    func fetch(origin: HostingOrigin, branchesOfInterest: Set<String>) async throws -> RepoPRSnapshot {
        branchesOfInterestHistory.append(branchesOfInterest)
        return RepoPRSnapshot(prsByBranch: prsByBranch)
    }
}
