import SwiftUI
import Testing
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("GrafttyApp pane lifecycle")
struct GrafttyAppPaneLifecycleTests {
    @Test("""
    @spec REMOTE-13.13: When a user selects a closed remote worktree or a \
    relayed client opens one, the owning Mac shall start the worktree \
    without changing the owner's selected worktree.
    """)
    func remoteOpenStartsClosedWorktree() throws {
        let pane = PaneSlotID()
        let session = PaneSessionID()
        var worktree = WorktreeEntry(
            path: "/repo/feature",
            branch: "feature",
            state: .closed
        )
        worktree.splitTree = SplitTree(root: .leaf(pane))
        worktree.paneSessions[pane] = session
        var state = AppState(
            repos: [
                RepoEntry(
                    path: "/repo",
                    displayName: "repo",
                    worktrees: [worktree]
                ),
            ],
            selectedWorktreePath: "/repo/other"
        )
        let binding = Binding<AppState>(
            get: { state },
            set: { state = $0 }
        )
        let manager = TerminalManager(socketPath: "/tmp/graftty-open-test.sock")
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: pane,
            app: fakeApp(),
            worktreePath: worktree.path,
            socketPath: "/tmp/graftty-open-test.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _, _ in backend }
        ))
        manager.insertSurfaceForTesting(handle, for: pane)

        let result = GrafttyApp.startWorktree(
            path: worktree.path,
            appState: binding,
            terminalManager: manager,
            startSurfacesInBackground: true
        )

        let opened = state.repos[0].worktrees[0]
        #expect(result == .started)
        #expect(opened.state == .running)
        #expect(opened.splitTree.containsLeaf(pane))
        #expect(opened.paneSessions[pane] == session)
        #expect(manager.isFirstPane(pane))
        #expect(backend.startCount == 1)
        #expect(state.selectedWorktreePath == "/repo/other")
    }

    @Test("local worktree open keeps zmx start deferred until layout")
    func localOpenKeepsSurfaceStartDeferred() throws {
        let pane = PaneSlotID()
        let session = PaneSessionID()
        var worktree = WorktreeEntry(
            path: "/repo/local",
            branch: "local",
            state: .closed
        )
        worktree.splitTree = SplitTree(root: .leaf(pane))
        worktree.paneSessions[pane] = session
        var state = AppState(
            repos: [
                RepoEntry(
                    path: "/repo",
                    displayName: "repo",
                    worktrees: [worktree]
                ),
            ]
        )
        let binding = Binding<AppState>(
            get: { state },
            set: { state = $0 }
        )
        let manager = TerminalManager(socketPath: "/tmp/graftty-open-test.sock")
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: pane,
            app: fakeApp(),
            worktreePath: worktree.path,
            socketPath: "/tmp/graftty-open-test.sock",
            zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _, _ in backend }
        ))
        manager.insertSurfaceForTesting(handle, for: pane)

        #expect(GrafttyApp.startWorktree(
            path: worktree.path,
            appState: binding,
            terminalManager: manager
        ) == .started)
        #expect(backend.startCount == 0)
    }

    @Test("remote open is idempotent and refuses unavailable worktrees")
    func remoteOpenValidatesState() {
        let running = WorktreeEntry(
            path: "/repo/running",
            branch: "running",
            state: .running
        )
        let stale = WorktreeEntry(
            path: "/repo/stale",
            branch: "stale",
            state: .stale
        )
        var state = AppState(
            repos: [
                RepoEntry(
                    path: "/repo",
                    displayName: "repo",
                    worktrees: [running, stale]
                ),
            ]
        )
        let binding = Binding<AppState>(
            get: { state },
            set: { state = $0 }
        )
        let manager = TerminalManager(socketPath: "/tmp/graftty-open-test.sock")

        #expect(GrafttyApp.startWorktree(
            path: running.path,
            appState: binding,
            terminalManager: manager
        ) == .alreadyRunning)
        #expect(GrafttyApp.startWorktree(
            path: stale.path,
            appState: binding,
            terminalManager: manager
        ) == .unavailable)
        #expect(GrafttyApp.startWorktree(
            path: "/repo/missing",
            appState: binding,
            terminalManager: manager
        ) == .notFound)
    }

    @Test("""
    @spec REMOTE-13.15: While a remote worktree is selected, the application \
    shall route split, close, focus, zoom, resize, and equalize commands \
    through that worktree's host-managed pane command handler.
    """)
    func hostManagedPaneCommandRouting() {
        let remote = PaneSlotID()
        let local = PaneSlotID()
        let manager = TerminalManager(socketPath: "/tmp/graftty-command-test.sock")
        var received: [HostManagedPaneCommand] = []
        manager.registerHostManagedPaneCommandHandler(for: remote) {
            received.append($0)
        }

        let commands: [HostManagedPaneCommand] = [
            .split(.left),
            .close,
            .focus(.right),
            .focusOrder(forward: true),
            .toggleZoom,
            .resize(direction: .down, amount: 4),
            .equalize,
        ]
        for command in commands {
            #expect(manager.routeHostManagedPaneCommand(
                command,
                for: remote
            ))
        }
        #expect(received.count == commands.count)
        guard case .split(.left) = received.first else {
            Issue.record("expected the remote split command")
            return
        }
        #expect(manager.routeHostManagedPaneCommand(
            .surfaceClosed,
            for: remote
        ))
        guard case .surfaceClosed = received.last else {
            Issue.record("expected the remote surface-close event")
            return
        }
        #expect(!manager.routeHostManagedPaneCommand(.close, for: local))

        manager.unregisterHostManagedPaneCommandHandler(for: remote)
        #expect(!manager.routeHostManagedPaneCommand(.close, for: remote))
    }

    @Test func reassignPaneByPWDMovesPaneSessionToTargetWorktree() {
        let slot = PaneSlotID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!)
        let session = PaneSessionID(id: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!)
        var source = WorktreeEntry(path: "/repo/source", branch: "source", state: .running)
        source.splitTree = SplitTree(root: .leaf(slot))
        source.focusedPaneSlotID = slot
        source.paneSessions[slot] = session
        let target = WorktreeEntry(path: "/repo/target", branch: "target", state: .closed)
        var state = AppState(
            repos: [
                RepoEntry(
                    path: "/repo",
                    displayName: "repo",
                    worktrees: [source, target]
                )
            ],
            selectedWorktreePath: source.path
        )
        let binding = Binding<AppState>(
            get: { state },
            set: { state = $0 }
        )
        let manager = TerminalManager(socketPath: "/tmp/graftty-test.sock")
        manager.recordPaneSession(
            session,
            for: slot,
            worktreePath: source.path
        )

        GrafttyApp.reassignPaneByPWD(
            appState: binding,
            terminalManager: manager,
            terminalID: slot,
            newPWD: "/repo/target/subdir"
        )

        let movedSource = state.repos[0].worktrees[0]
        let movedTarget = state.repos[0].worktrees[1]
        #expect(movedSource.paneSessions[slot] == nil)
        #expect(movedTarget.paneSessions[slot] == session)
        #expect(movedTarget.splitTree.containsLeaf(slot))
        #expect(
            manager.worktreePath(
                forSessionName: ZmxLauncher.sessionName(for: session)
            ) == target.path
        )
    }

    @Test func defaultBranchStatusRequiresBehindDefaultCheckout() {
        let main = WorktreeEntry(path: "/repo", branch: "main")
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [main])
        let stats = WorktreeStats(
            ahead: 0,
            behind: 2,
            insertions: 0,
            deletions: 0,
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
        )

        let status = defaultBranchStatus(for: repo, stats: stats)

        #expect(status?.branchName == "main")
        #expect(status?.remoteRef == "origin/main")
        #expect(status?.behindCount == 2)
    }

    @Test func defaultBranchStatusIgnoresNonDefaultMainCheckout() {
        let current = WorktreeEntry(path: "/repo", branch: "release")
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [current])
        let stats = WorktreeStats(
            ahead: 0,
            behind: 2,
            insertions: 0,
            deletions: 0,
            upstreamRefs: UpstreamRefs(defaultRef: "origin/main")
        )

        #expect(defaultBranchStatus(for: repo, stats: stats) == nil)
    }
}
