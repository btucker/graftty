import Foundation
import GrafttyProtocol
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@Suite("WorktreeMonitorBridge event-driven refresh", .serialized)
struct WorktreeMonitorBridgeTests {

    @MainActor
    @Test("""
@spec DIVERGE-4.2: When a worktree's HEAD reference changes, the application shall recompute that worktree's divergence counts immediately, without waiting for the polling fallback.
""")
    func headRefChangeRefreshesStatsImmediately() async throws {
        let repoURL = try makeGitRepo()
        defer { try? FileManager.default.removeItem(at: repoURL) }
        let repoPath = CanonicalPath.canonicalize(repoURL.path)
        let compute = RecordingStatsCompute()
        let stateBox = AppStateBox(AppState(
            repos: [
                RepoEntry(
                    path: repoPath,
                    displayName: "repo",
                    worktrees: [
                        WorktreeEntry(path: repoPath, branch: "main", state: .running)
                    ]
                )
            ],
            selectedWorktreePath: nil
        ))
        let bridge = makeBridge(stateBox: stateBox, compute: compute)

        bridge.worktreeMonitorDidDetectBranchChange(
            WorktreeMonitor(),
            worktreePath: repoPath
        )

        try await waitUntil(timeout: 2.0) {
            compute.callCount(for: repoPath) == 1
        }
    }

    @MainActor
    @Test("Non-git repositories ignore ref-driven divergence refreshes")
    func nonGitRefEventsDoNotRefreshStats() async throws {
        let compute = RecordingStatsCompute()
        let stateBox = AppStateBox(AppState(
            repos: [
                RepoEntry(
                    path: "/project",
                    displayName: "project",
                    worktrees: [
                        WorktreeEntry(path: "/project", branch: "main", state: .running)
                    ],
                    isGitTracked: false
                )
            ],
            selectedWorktreePath: nil
        ))
        let bridge = makeBridge(stateBox: stateBox, compute: compute)

        bridge.worktreeMonitorDidDetectBranchChange(
            WorktreeMonitor(),
            worktreePath: "/project"
        )
        bridge.worktreeMonitorDidDetectOriginRefChange(
            WorktreeMonitor(),
            repoPath: "/project"
        )

        try await Task.sleep(for: .milliseconds(100))
        #expect(compute.calledPaths.isEmpty)
    }

    @MainActor
    @Test("""
@spec DIVERGE-4.7: When a remote-tracking-ref change event fires (GIT-2.5), the application shall immediately refresh divergence stats for every running worktree in the affected repository, without waiting for the polling fallback.
""")
    func originRefChangeRefreshesRunningWorktreesImmediately() async throws {
        let compute = RecordingStatsCompute()
        let stateBox = AppStateBox(AppState(
            repos: [
                RepoEntry(
                    path: "/repo",
                    displayName: "repo",
                    worktrees: [
                        WorktreeEntry(path: "/repo/a", branch: "a", state: .running),
                        WorktreeEntry(path: "/repo/b", branch: "b", state: .running),
                        WorktreeEntry(path: "/repo/closed", branch: "closed", state: .closed)
                    ]
                )
            ],
            selectedWorktreePath: nil
        ))
        let bridge = makeBridge(stateBox: stateBox, compute: compute)

        bridge.worktreeMonitorDidDetectOriginRefChange(
            WorktreeMonitor(),
            repoPath: "/repo"
        )

        try await waitUntil(timeout: 2.0) {
            compute.calledPaths == ["/repo/a", "/repo/b"]
        }
        #expect(compute.callCount(for: "/repo/closed") == 0)
    }

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
        try await waitUntil(timeout: 30.0) {
            await remoteBranchLister.invocations(for: "/repo") == 1
        }
        try await waitUntil(timeout: 30.0) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature")
        }
        try await waitUntil(timeout: 30.0) {
            prStore.absent.contains("/repo/wt")
        }
        try await waitUntil(timeout: 30.0) {
            await followUps.count == 2
        }
        #expect(await fetcher.invocations == 1)

        // Phase 2: drive the follow-ups deterministically. With
        // wall-clock removed from the test, only per-step MainActor
        // latency bounds each `waitUntil` — never a cumulative
        // sleep+hop budget that CI parallelism can blow past.
        await followUps.fireNext()
        try await waitUntil(timeout: 30.0) {
            prStore.infos["/repo/wt"]?.number == 42
        }
        #expect(await fetcher.invocations == 2)
        #expect(!prStore.absent.contains("/repo/wt"))

        await followUps.fireNext()
        try await waitUntil(timeout: 30.0) {
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

    @MainActor
    private func makeBridge(
        stateBox: AppStateBox,
        compute: RecordingStatsCompute
    ) -> WorktreeMonitorBridge {
        let remoteBranchStore = RemoteBranchStore(list: { _ in RemoteBranchSnapshot() })
        let prStore = PRStatusStore(
            executor: NoopCLIExecutor(),
            fetcherFor: { _ in nil },
            detectHost: { _ in nil },
            remoteBranchStore: remoteBranchStore
        )
        return WorktreeMonitorBridge(
            appState: Binding(
                get: { stateBox.state },
                set: { stateBox.state = $0 }
            ),
            statsStore: WorktreeStatsStore(compute: compute.function, fetch: { _ in }),
            prStatusStore: prStore,
            remoteBranchStore: remoteBranchStore
        )
    }

    private func makeGitRepo() throws -> URL {
        let repoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(at: repoURL)
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["init", "--initial-branch=main"]
        process.currentDirectoryURL = repoURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        succeeded = true
        return repoURL
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

    func list(repoPath: String) async throws -> RemoteBranchSnapshot {
        counts[repoPath, default: 0] += 1
        let branches = try results[repoPath]?.get() ?? []
        return RemoteBranchSnapshot(branches: branches)
    }

    func invocations(for repoPath: String) -> Int {
        counts[repoPath, default: 0]
    }
}

private final class RecordingStatsCompute: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]

    var calledPaths: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(calls.keys)
    }

    func callCount(for path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls[path, default: 0]
    }

    var function: WorktreeStatsStore.ComputeFunction {
        { [weak self] worktreePath, _, _, _ in
            self?.record(worktreePath)
            return WorktreeStatsStore.ComputeResult(
                defaultBranch: "main",
                stats: WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 0)
            )
        }
    }

    private func record(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        calls[path, default: 0] += 1
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
