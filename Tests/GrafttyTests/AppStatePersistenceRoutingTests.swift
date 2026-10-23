import AppKit
import Foundation
import SwiftUI
import Testing
import GrafttyKit
@testable import Graftty

/// Records every persisted snapshot. The persister's timer is manual, so a
/// write only appears on its own when a path calls `flushNow()`.
/// `holdWrites()` parks the next write until `releaseWrites()`.
@MainActor
private final class PersistenceProbe {
    private final class Writes: @unchecked Sendable {
        let lock = NSLock()
        var states: [AppState] = []
        var failure: (any Error)?
        var gate: DispatchSemaphore?
        var holdLimit: DispatchTimeInterval = .seconds(2)
        var parked = false

        func record(_ state: AppState) throws {
            // `self.` keeps Swift 6.3 from resolving the closure's name to
            // the local being declared.
            if let gate = lock.withLock({ self.gate }) {
                lock.withLock { parked = true }
                _ = gate.wait(timeout: .now() + lock.withLock { holdLimit })
            }
            if let failure = lock.withLock({ self.failure }) { throw failure }
            lock.withLock { states.append(state) }
        }
    }

    private let writes = Writes()
    private var armedSave: (@MainActor () -> Void)?
    private(set) lazy var persister = AppStatePersister(
        write: { [writes] in try writes.record($0) },
        // Weak: async work a router path started (e.g. the worktree-create
        // Git task) inherits this persister and can mark it after the test.
        schedule: { [weak self] _, action in
            self?.armedSave = action
            return { [weak self] in self?.armedSave = nil }
        }
    )

    var written: [AppState] { writes.lock.withLock { writes.states } }

    func failWrites(with error: (any Error)?) { writes.lock.withLock { writes.failure = error } }
    func holdWrites(upTo limit: DispatchTimeInterval = .seconds(2)) {
        writes.lock.withLock {
            writes.gate = DispatchSemaphore(value: 0)
            writes.holdLimit = limit
        }
    }

    func releaseWrites() {
        let gate = writes.lock.withLock { () -> DispatchSemaphore? in
            defer { writes.gate = nil }
            return writes.gate
        }
        gate?.signal()
    }

    /// Waits (bounded) until a write is parked on the held gate.
    func waitUntilAWriteIsParked() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !writes.lock.withLock({ writes.parked }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Fires the trailing timer, then waits for the queued write to land.
    /// Requires an armed save: the trailing `flushNow()` would otherwise
    /// write the pending state itself and hide a mark that never armed one.
    func fireArmedSave() async throws {
        let action = try #require(armedSave, "no save was armed")
        armedSave = nil
        action()
        try await persister.flushNow()
    }
}

@MainActor
private final class StateBox {
    var state: AppState
    init(_ state: AppState) { self.state = state }
    var binding: Binding<AppState> {
        Binding(get: { self.state }, set: { self.state = $0 })
    }
}

/// The production router with temp-directory stores and no window or view
/// hierarchy, the LAYOUT-5.1 "main window closed" shape.
@MainActor
private final class HeadlessRouter {
    let directory: URL
    let terminalManager = TerminalManager(socketPath: "/tmp/graftty-persistence-routing.sock")
    let teamInbox: TeamInbox
    let remoteBranchStore = RemoteBranchStore()
    /// Shared across `route` calls so a retry sees the original operation.
    let worktreeCreations = CLIWorktreeCreationStore()
    let remoteMacsModel: RemoteMacsModel

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("persistence-routing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        teamInbox = TeamInbox(rootDirectory: directory.appendingPathComponent("inbox"))
        remoteMacsModel = RemoteMacsModel(
            store: RemoteMacStore(storeURL: directory.appendingPathComponent("remotes.json"))
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Lets `pane add` create a real libghostty surface, as
    /// `GrafttyAppPaneLifecycleTests` does; `/usr/bin/false` never attaches.
    func enableSurfaces() {
        _ = NSApplication.shared
        terminalManager.initialize()
        terminalManager.zmxLauncher = ZmxLauncher(
            executable: URL(fileURLWithPath: "/usr/bin/false"),
            zmxDir: directory.appendingPathComponent("zmx")
        )
    }

    func route(_ message: NotificationMessage, _ box: StateBox) async -> ResponseMessage? {
        let dispatcher = TeamEventDispatcher(
            inbox: teamInbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )
        return await SocketRequestRouter(
            appState: box.binding,
            terminalManager: terminalManager,
            teamInbox: teamInbox,
            teamEventDispatcher: dispatcher,
            worktreeMonitor: WorktreeMonitor(),
            statsStore: WorktreeStatsStore(),
            prStatusStore: PRStatusStore(remoteBranchStore: remoteBranchStore),
            worktreeCreations: worktreeCreations,
            worktreeRemovals: CLIWorktreeRemovalStore(),
            remoteBranchStore: remoteBranchStore,
            agentRegistry: ClaudeSessionRegistry(),
            remoteMacsModel: remoteMacsModel,
            remoteTeamRouter: RemoteTeamRouter(),
            teamsEnabled: { true }
        ).handleRequest(message)
    }
}

/// `AppServices.teamsEnabled` reads `UserDefaults.standard` live; agent
/// launches are rejected without it. Restored after each test.
@MainActor
private func withAgentTeamsEnabled<T>(_ body: () async -> T) async -> T {
    let previous = UserDefaults.standard.object(forKey: SettingsKeys.agentTeamsEnabled)
    UserDefaults.standard.set(true, forKey: SettingsKeys.agentTeamsEnabled)
    defer {
        if let previous {
            UserDefaults.standard.set(previous, forKey: SettingsKeys.agentTeamsEnabled)
        } else {
            UserDefaults.standard.removeObject(forKey: SettingsKeys.agentTeamsEnabled)
        }
    }
    return await body()
}

private let repoPath = "/nonexistent-persistence-routing-repo"

private func runningWorktreeState() -> (AppState, PaneSlotID) {
    let pane = PaneSlotID()
    var worktree = WorktreeEntry(path: repoPath, branch: "main", state: .running)
    worktree.splitTree = SplitTree(root: .leaf(pane))
    worktree.paneSessions = [pane: PaneSessionID()]
    let state = AppState(
        repos: [RepoEntry(path: repoPath, displayName: "repo", worktrees: [worktree])],
        selectedWorktreePath: repoPath
    )
    return (state, pane)
}

/// Both agent-launch suites toggle the process-wide Agent Teams default
/// through `withAgentTeamsEnabled`; run concurrently, one can restore the
/// key mid-test for the other or leave `true` behind for later runs.
@Suite(.serialized)
@MainActor
struct AgentLaunchPersistenceTests {
    @Suite(
        "@spec PERSIST-2.5: When a request launches an agent whose CLI hooks read `state.json`, the application shall write every marked state change to disk before replying.",
        .serialized
    )
    @MainActor
    struct AgentLaunchStateFlushTests {

        @Test func worktreeCreateWithAnAgentFlushesTheNewWorktreeBeforeReplying() async throws {
            let probe = PersistenceProbe()
            let router = try HeadlessRouter()
            let box = StateBox(runningWorktreeState().0)

            let response = await withAgentTeamsEnabled {
                await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
                    await router.route(.createWorktree(
                        callerWorktree: repoPath, worktreeName: "agent-task", branchName: "agent-task",
                        existing: false, base: nil, command: nil,
                        agentRuntime: .codex, agentPrompt: nil, operationID: "op-flush"
                    ), box)
                }
            }

            guard case .worktreeCreate = response else {
                Issue.record("unexpected response \(String(describing: response))")
                return
            }
            // The launched agent's first `graftty team hook` resolves its worktree
            // from state.json (TeamPresenceCLI.resolveTeamAndWorktree).
            let onDisk = try #require(probe.written.last, "the reply was sent before state.json was written")
            #expect(onDisk.worktree(forPath: repoPath + "/.worktrees/agent-task") != nil)
        }

        @Test func paneAddWithAnAgentFlushesTheNewPaneBeforeReplying() async throws {
            let probe = PersistenceProbe()
            let router = try HeadlessRouter()
            let (state, existingPane) = runningWorktreeState()
            let box = StateBox(state)
            router.enableSurfaces()
            defer {
                for pane in box.state.worktree(forPath: repoPath)?.splitTree.allLeaves ?? [] {
                    router.terminalManager.evictSurface(terminalID: pane, forRetry: true)
                }
            }

            let response = await withAgentTeamsEnabled {
                await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
                    await router.route(.addPane(
                        path: repoPath, direction: .right, command: nil,
                        agentRuntime: .codex, agentPrompt: nil
                    ), box)
                }
            }

            #expect(response == .ok, "\(String(describing: response))")
            let onDisk = try #require(probe.written.last, "the reply was sent before state.json was written")
            let panes = onDisk.worktree(forPath: repoPath)?.splitTree.allLeaves ?? []
            #expect(panes.count == 2 && panes.contains(existingPane))
        }
    }

    /// AGENT-5.8 around the PERSIST-2.5 flush: a same-ID retry must get the
    /// original operation, not collide with its placeholder.
    @Suite("A same-operation retry during the agent-launch state flush returns the original operation", .serialized)
    @MainActor
    struct AgentLaunchFlushRetryTests {

        @Test func aRetryWhileTheFlushIsInFlightReturnsThePendingOperation() async throws {
            let probe = PersistenceProbe()
            let router = try HeadlessRouter()
            let box = StateBox(runningWorktreeState().0)
            let request = NotificationMessage.createWorktree(
                callerWorktree: repoPath, worktreeName: "agent-retry", branchName: "agent-retry",
                existing: false, base: nil, command: nil,
                agentRuntime: .codex, agentPrompt: nil, operationID: "op-retry"
            )

            // A synchronous flush blocks main for the held write, so keep the
            // hold short; a suspending flush lets the retry in while it is parked.
            probe.holdWrites(upTo: .milliseconds(200))
            let (original, retry) = await withAgentTeamsEnabled {
                await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
                    let original = Task { await router.route(request, box) }
                    await probe.waitUntilAWriteIsParked()  // the original is suspended in its flush
                    let retry = await router.route(request, box)
                    probe.releaseWrites()
                    return (await original.value, retry)
                }
            }

            guard case .worktreeCreate(let status) = original else {
                Issue.record("unexpected original response \(String(describing: original))")
                return
            }
            #expect(retry == .worktreeCreate(status), "the retry got \(String(describing: retry))")
        }
    }
}

@Suite("@spec PERSIST-2.7: While no window is open, when a control-socket request changes `AppState`, the application shall still save the change within the save delay.")
@MainActor
struct WindowlessStatePersistenceTests {

    @Test func aSocketMutationWithNoViewHierarchyIsSaved() async throws {
        let probe = PersistenceProbe()
        let router = try HeadlessRouter()
        let linkedPath = repoPath + "/.worktrees/pinned"
        var state = runningWorktreeState().0
        var linked = WorktreeEntry(path: linkedPath, branch: "pinned", state: .running)
        linked.isPinned = true
        state.repos[0].worktrees.append(linked)
        let box = StateBox(state)

        let response = await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            await router.route(.setWorktreePinned(worktreePath: linkedPath, isPinned: false), box)
        }
        #expect(response == .ok, "\(String(describing: response))")
        #expect(probe.written.isEmpty, "the save should be coalesced, not written inline")

        try await probe.fireArmedSave()

        #expect(probe.written.last?.worktree(forPath: linkedPath)?.isPinned == false)
    }
}

@Suite("A paired device's worktree order is applied only once it is saved")
@MainActor
struct RemoteWorktreeOrderPersistenceTests {

    @Test func aFailedSaveLeavesTheOrderUnchanged() async throws {
        struct DiskFull: Error {}
        let probe = PersistenceProbe()
        probe.failWrites(with: DiskFull())
        let box = StateBox(runningWorktreeState().0)

        let response = GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            GrafttyApp.applyRemoteWorktreeOrder(.recentActivity, repositoryID: repoPath, appState: box.binding)
        }

        guard case .error(let code, _, _, _) = response else {
            Issue.record("unexpected response \(response)")
            return
        }
        #expect(code == "persistence-failed")
        #expect(box.state.repos[0].worktreeOrderMode == .manual, "the device was told the change failed, but it was applied")
    }

    @Test func aLocalOrderChangeDuringTheDeviceSaveIsNotOverwritten() async throws {
        let probe = PersistenceProbe()
        let box = StateBox(runningWorktreeState().0)
        // A synchronous save blocks main for the held write, so the local
        // change below can only land after the device's change completes.
        probe.holdWrites(upTo: .milliseconds(200))

        let device = Task {
            GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
                GrafttyApp.applyRemoteWorktreeOrder(.recentActivity, repositoryID: repoPath, appState: box.binding)
            }
        }
        await probe.waitUntilAWriteIsParked()
        // The user picks an order in the Mac sidebar meanwhile.
        _ = SidebarHostNavigation.setWorktreeOrder(.manual, in: &box.state, repositoryID: repoPath)
        probe.releaseWrites()
        _ = await device.value

        #expect(box.state.repos[0].worktreeOrderMode == .manual, "the device's older request overwrote the user's newer order")
    }

    @Test func aSavedOrderIsAppliedAndOnDisk() async throws {
        let probe = PersistenceProbe()
        let box = StateBox(runningWorktreeState().0)

        let response = GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            GrafttyApp.applyRemoteWorktreeOrder(.recentActivity, repositoryID: repoPath, appState: box.binding)
        }

        #expect(response == .ok)
        #expect(box.state.repos[0].worktreeOrderMode == .recentActivity)
        #expect(probe.written.last?.repos[0].worktreeOrderMode == .recentActivity)
    }
}
