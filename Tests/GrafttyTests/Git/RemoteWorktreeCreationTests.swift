import Foundation
import AppKit
import GrafttyKit
import SwiftUI
import Testing
@testable import Graftty

@MainActor
@Suite
struct RemoteWorktreeCreationTests {
    @Test("@spec AGENT-5.24: If a worktree becomes stale while its terminal startup is pending, then the application shall preserve the stale state and report failed creation instead of promoting it to running.", arguments: [true, false])
    func deletionDuringStartupPreservesStaleState(startupAccepted: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo").path
        try git(["init", "-b", "main", repo])
        try git(["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Initial"])
        try git(["-C", repo, "branch", "feature"])
        let path = repo + "/.worktrees/feature"
        var state = AppState(repos: [RepoEntry(path: repo, displayName: "repo", worktrees: [
            WorktreeEntry(path: repo, branch: "main")
        ])])
        let binding = Binding(get: { state }, set: { state = $0 })
        _ = NSApplication.shared
        let manager = TerminalManager(socketPath: root.appendingPathComponent("control.sock").path)
        manager.initialize()
        let executable = root.appendingPathComponent("zmx")
        let completion = startupAccepted ? ": > \"$GRAFTTY_STARTUP_RECEIPT\"\n/bin/sleep 1" : "exit 1"
        try "#!/bin/sh\nif [ \"$1\" = list ]; then exit 0; fi\n/bin/sleep 0.2\n\(completion)\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        manager.zmxLauncher = ZmxLauncher(executable: executable, zmxDir: root)
        let monitor = WorktreeMonitor()
        let stats = WorktreeStatsStore(compute: { _, _, _, _ in .init(defaultBranch: nil, stats: nil) }, fetch: { _ in })
        defer {
            manager.destroySurfaces(terminalIDs: state.worktree(forPath: path)?.splitTree.allLeaves ?? [])
            monitor.stopWatchingWorktree(path)
            stats.clear(worktreePath: path)
        }
        let deletion = Task { @MainActor in
            let deadline = ContinuousClock.now + .seconds(3)
            while state.worktree(forPath: path)?.splitTree.root == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            if let (repoIndex, worktreeIndex) = state.indices(forWorktreePath: path) {
                // Match the deletion watcher's mutation while startup awaits.
                state.repos[repoIndex].worktrees[worktreeIndex].markStale()
            }
        }
        defer { deletion.cancel() }
        _ = AddWorktreeFlow.beginCreate(repoPath: repo, worktreeName: "feature",
            branch: .useExisting(name: "feature", source: .local), appState: binding)
        let result = await AddWorktreeFlow.finishCreate(repoPath: repo, worktreePath: path,
            branch: .useExisting(name: "feature", source: .local), appState: binding,
            worktreeMonitor: monitor, statsStore: stats, terminalManager: manager,
            teamEventDispatcher: TeamEventDispatcher(inbox: TeamInbox(rootDirectory: root.appendingPathComponent("inbox")),
                preferencesProvider: { TeamEventRoutingPreferences() }, templateProvider: { "" }),
            initialCommand: "true", terminalStartTiming: .immediately)
        try await deletion.value
        #expect(state.worktree(forPath: path)?.state == .stale)
        if case .success = result { Issue.record("Startup promoted a stale worktree") }
    }

    @Test("@spec GIT-5.23: When a paired client creates a worktree, the application shall register its first pane for terminal attachment and listening-port discovery without requiring a Mac terminal renderer or changing the Mac's selected worktree.")
    func creationSucceedsWithoutMacRenderer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-remote-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo").path
        try git(["init", "-b", "main", repo])
        try git(["-C", repo, "config", "core.hooksPath", "/dev/null"])
        try git(["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Initial"])
        try git(["-C", repo, "branch", "feature"])
        var state = AppState(repos: [RepoEntry(path: repo, displayName: "repo", worktrees: [
            WorktreeEntry(path: repo, branch: "main")
        ])])
        state.selectedWorktreePath = repo
        let binding = Binding(get: { state }, set: { state = $0 })
        let manager = TerminalManager(socketPath: root.appendingPathComponent("control.sock").path)
        let scanner = PortScanner(
            runner: RemoteCreationLsofRunner(),
            walker: RemoteCreationProcessTreeWalker()
        )
        await scanner.setPIDResolver { _ in 1234 }
        manager.portScanner = scanner
        let monitor = WorktreeMonitor()
        let stats = WorktreeStatsStore(
            compute: { _, _, _, _ in .init(defaultBranch: nil, stats: nil) },
            fetch: { _ in }
        )
        let result = await AddWorktreeFlow.add(
            repoPath: repo,
            worktreeName: "feature",
            branch: .useExisting(name: "feature", source: .local),
            appState: binding,
            worktreeMonitor: monitor,
            statsStore: stats,
            terminalManager: manager,
            teamEventDispatcher: TeamEventDispatcher(
                inbox: TeamInbox(rootDirectory: root.appendingPathComponent("inbox")),
                preferencesProvider: { TeamEventRoutingPreferences() },
                templateProvider: { "" }
            ),
            entryPoint: .pairedClient
        )
        let path = repo + "/.worktrees/feature"
        monitor.stopWatchingWorktree(path)
        stats.clear(worktreePath: path)
        #expect(FileManager.default.fileExists(atPath: path))
        guard case .success(let created) = result else {
            Issue.record("Git succeeded, but remote creation failed: \(result)")
            return
        }
        let worktree = try #require(state.worktree(forPath: path))
        let pane = try #require(worktree.splitTree.allLeaves.first)
        #expect(worktree.state == .running)
        #expect(created.worktreePath == path)
        #expect(created.sessionName == worktree.paneSessions[pane].map(ZmxLauncher.sessionName(for:)))
        #expect(manager.worktreePath(forSessionName: created.sessionName) == path)
        #expect(manager.handle(for: pane) == nil)
        #expect(manager.surfaceBudget.lru.isEmpty)
        #expect(state.selectedWorktreePath == repo)

        // Registration crosses to the scanner actor. Drive its ordinary
        // polling path until that registration reaches the next scan.
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            await scanner.tick()
            if !(await scanner.bindings(for: pane)).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await scanner.bindings(for: pane).map(\.port) == [3000])
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}

private struct RemoteCreationLsofRunner: LsofRunner {
    func run(pids: String) async -> String? {
        """
        COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
        node 1234 test 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)
        """
    }
}

private struct RemoteCreationProcessTreeWalker: ProcessTreeWalking {
    func descendants(of root: pid_t) -> [pid_t] { [root] }
}
