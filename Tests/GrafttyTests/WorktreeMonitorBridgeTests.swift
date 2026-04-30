import Foundation
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

@Suite("WorktreeMonitorBridge origin-ref refresh")
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
            originRefPRFollowUpDelays: [.milliseconds(50)]
        )

        #expect(!remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature"))

        bridge.worktreeMonitorDidDetectOriginRefChange(
            WorktreeMonitor(),
            repoPath: "/repo"
        )

        try await waitUntil(timeout: 0.5) {
            await remoteBranchLister.invocations(for: "/repo") == 1
        }
        try await waitUntil(timeout: 0.5) {
            remoteBranchStore.hasRemote(repoPath: "/repo", branch: "feature")
        }
        try await waitUntil(timeout: 0.5) {
            await fetcher.invocations == 1
        }
        #expect(prStore.absent.contains("/repo/wt"))
        #expect(prStore.infos["/repo/wt"] == nil)

        try await waitUntil(timeout: 0.5) {
            prStore.infos["/repo/wt"]?.number == 42
        }
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

private actor SequencedPRFetcher: PRFetcher {
    private var results: [PRInfo?]
    private(set) var invocations = 0

    init(results: [PRInfo?]) {
        self.results = results
    }

    func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
        invocations += 1
        if results.isEmpty { return nil }
        return results.removeFirst()
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
