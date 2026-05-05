import Foundation
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@Suite("WorktreeMonitorBridge origin-ref refresh", .serialized)
struct WorktreeMonitorBridgeTests {

    @MainActor
    @Test func originRefChangeRetriesAfterCreateRace() async throws {
        let remoteBranchLister = RecordingRemoteBranchLister(results: [
            "/repo": .success(["feature"])
        ])
        let remoteBranchStore = RemoteBranchStore(list: { repoPath in
            try await remoteBranchLister.list(repoPath: repoPath)
        })
        let fetcher = SequencedPRFetcher(results: [
            nil,
            PRInfo(
                number: 42,
                title: "Feature",
                url: URL(string: "https://github.com/acme/repo/pull/42")!,
                state: .open,
                checks: .none,
                fetchedAt: Date()
            )
        ])
        let origin = HostingOrigin(
            provider: .github,
            host: "github.com",
            owner: "acme",
            repo: "repo"
        )
        let prStore = PRStatusStore(
            executor: NoopCLIExecutor(),
            fetcherFor: { _ in fetcher },
            detectHost: { _ in origin },
            remoteBranchStore: remoteBranchStore
        )
        let stateBox = AppStateBox(AppState(
            repos: [
                RepoEntry(
                    path: "/repo",
                    displayName: "repo",
                    worktrees: [WorktreeEntry(path: "/repo/wt", branch: "feature")]
                )
            ],
            selectedWorktreePath: nil
        ))
        // Mirror app launch: prStore needs `getRepos` set before it
        // can apply fetched snapshots to worktrees. The bridge does
        // not start the store; the app does.
        prStore.start(
            ticker: PollingTicker(interval: .seconds(60)),
            getRepos: { stateBox.state.repos }
        )
        defer { prStore.stop() }
        let followUps = RecordedFollowUps()
        let bridge = WorktreeMonitorBridge(
            appState: Binding(
                get: { stateBox.state },
                set: { stateBox.state = $0 }
            ),
            statsStore: WorktreeStatsStore(compute: { _, _, _, _ in
                WorktreeStatsStore.ComputeResult(defaultBranch: "main", stats: nil)
            }, fetch: { _ in }),
            prStatusStore: prStore,
            remoteBranchStore: remoteBranchStore,
            originRefPRFollowUpScheduler: { _, work in
                Task { await followUps.append(work) }
            }
        )

        #expect(!remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature"))

        bridge.worktreeMonitorDidDetectOriginRefChange(
            WorktreeMonitor(),
            repoPath: "/repo"
        )

        // Phase 1: immediate path. List runs once, hasRemote flips,
        // the immediate refresh fetches nil → worktree marked absent,
        // and both follow-ups get recorded by the injected scheduler.
        try await waitUntil(timeout: 5.0) {
            await remoteBranchLister.invocations(for: "/repo") == 1
        }
        try await waitUntil(timeout: 5.0) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature")
        }
        try await waitUntil(timeout: 5.0) {
            prStore.absent.contains("/repo/wt")
        }
        try await waitUntil(timeout: 5.0) {
            await followUps.count == 2
        }
        #expect(await fetcher.invocations == 1)

        // Phase 2: drive the follow-ups deterministically. With
        // wall-clock removed from the test, only per-step MainActor
        // latency bounds each `waitUntil` — never a cumulative
        // sleep+hop budget that CI parallelism can blow past.
        await followUps.fireNext()
        try await waitUntil(timeout: 5.0) {
            prStore.infos["/repo/wt"]?.number == 42
        }
        #expect(await fetcher.invocations == 2)
        #expect(!prStore.absent.contains("/repo/wt"))

        await followUps.fireNext()
        try await waitUntil(timeout: 5.0) {
            await fetcher.invocations == 3
        }
        #expect(prStore.infos["/repo/wt"]?.number == 42)
        #expect(!prStore.absent.contains("/repo/wt"))
        #expect(stateBox.state.selectedWorktreePath == nil)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @MainActor @escaping () async -> Bool
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

@MainActor
private final class AppStateBox {
    var state: AppState

    init(_ state: AppState) {
        self.state = state
    }
}

private actor RecordedFollowUps {
    private var pending: [@Sendable () async -> Void] = []

    var count: Int { pending.count }

    func append(_ work: @escaping @Sendable () async -> Void) {
        pending.append(work)
    }

    func fireNext() async {
        guard !pending.isEmpty else { return }
        let work = pending.removeFirst()
        await work()
    }
}

private actor SequencedPRFetcher: PRFetcher {
    private var results: [PRInfo?]
    private(set) var invocations = 0

    init(results: [PRInfo?]) {
        self.results = results
    }

    func fetch(
        origin: HostingOrigin,
        branchesOfInterest: Set<String>
    ) async throws -> RepoPRSnapshot {
        invocations += 1
        let next: PRInfo?
        if results.count > 1 {
            next = results.removeFirst()
        } else {
            next = results.first ?? nil
        }
        guard let pr = next else {
            return RepoPRSnapshot(prsByBranch: [:])
        }
        let branch = branchesOfInterest.first ?? "feature"
        return RepoPRSnapshot(prsByBranch: [branch: pr])
    }
}

private actor RecordingRemoteBranchLister {
    private var results: [String: Result<Set<String>, Error>]
    private var counts: [String: Int] = [:]

    init(results: [String: Result<Set<String>, Error>]) {
        self.results = results
    }

    func list(repoPath: String) async throws -> Set<String> {
        counts[repoPath, default: 0] += 1
        return try results[repoPath]?.get() ?? []
    }

    func invocations(for repoPath: String) -> Int {
        counts[repoPath, default: 0]
    }
}

private struct NoopCLIExecutor: CLIExecutor {
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        CLIOutput(stdout: "", stderr: "", exitCode: 0)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        CLIOutput(stdout: "", stderr: "", exitCode: 0)
    }
}
