import AppKit
import Foundation
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
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
    var hasArmedSave: Bool { armedSave != nil }

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

    func router(for box: StateBox) -> SocketRequestRouter {
        let dispatcher = TeamEventDispatcher(
            inbox: teamInbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )
        return SocketRequestRouter(
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
            remoteTeamRouter: RemoteTeamRouter()
        )
    }

    func route(_ message: NotificationMessage, _ box: StateBox) async -> ResponseMessage? {
        await router(for: box).handleRequest(message)
    }

    /// Fire-and-forget messages (`.notify`, `.clear`) go through `handleMessage`.
    func send(_ message: NotificationMessage, _ box: StateBox) {
        router(for: box).handleMessage(message)
    }
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

            let response = await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
                await router.route(.createWorktree(
                    callerWorktree: repoPath, worktreeName: "agent-task", branchName: "agent-task",
                    existing: false, base: nil, command: nil,
                    agentRuntime: .codex, agentPrompt: nil, operationID: "op-flush"
                ), box)
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

            let response = await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
                await router.route(.addPane(
                    path: repoPath, direction: .right, command: nil,
                    agentRuntime: .codex, agentPrompt: nil
                ), box)
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
            let (original, retry) = await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
                let original = Task { await router.route(request, box) }
                await probe.waitUntilAWriteIsParked()  // the original is suspended in its flush
                let retry = await router.route(request, box)
                probe.releaseWrites()
                return (await original.value, retry)
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

    /// #604 headline: the shared control core calls `stateDidChange()` after
    /// every attention change, and on the Mac that hook did nothing.
    @Test func aNotifyWithNoWindowReachesStateJSONWithoutTheQuitFlush() async throws {
        let probe = PersistenceProbe()
        let router = try HeadlessRouter()
        let box = StateBox(runningWorktreeState().0)

        GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            router.send(.notify(path: repoPath, text: "Build done"), box)
        }
        try await probe.fireArmedSave()

        #expect(probe.written.last?.worktree(forPath: repoPath)?.attention?.text == "Build done")
    }

    @Test func aClearWithNoWindowIsSaved() async throws {
        let probe = PersistenceProbe()
        let router = try HeadlessRouter()
        var state = runningWorktreeState().0
        state.repos[0].worktrees[0].attention = Attention(text: "stale", timestamp: Date())
        let box = StateBox(state)

        GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            router.send(.clear(path: repoPath), box)
        }
        try await probe.fireArmedSave()

        let saved = try #require(probe.written.last?.worktree(forPath: repoPath))
        #expect(saved.attention == nil)
    }
}

@Suite("@spec PERF-1.22: While no window is open, when a control-socket request changes `AppState`, the application shall send the change to panes-state subscribers without waiting for the safety-net tick.", .timeLimit(.minutes(1)))
@MainActor
struct WindowlessChangeSignalTests {

    @Test func aWindowlessSocketMutationReachesAPanesStateSubscriber() async throws {
        let probe = PersistenceProbe()
        let router = try HeadlessRouter()
        let linkedPath = repoPath + "/.worktrees/pinned"
        var state = runningWorktreeState().0
        var linked = WorktreeEntry(path: linkedPath, branch: "pinned", state: .running)
        linked.isPinned = true
        state.repos[0].worktrees.append(linked)
        let box = StateBox(state)
        let owner = WorktreeOrigin(deviceID: .init(value: "local"), deviceLabel: "Mac", relayDepth: 0)
        let changes = AppStateChanges()
        changes.publish(onMarkDirtyOf: probe.persister)

        let (frames, frame) = AsyncStream<PanesStateMessage>.makeStream()
        var sent = frames.makeAsyncIterator()
        // No ticks: only a published change can produce a second frame. The
        // row projection carries the pin, so the unpin changes the snapshot.
        let subscription = await changes.subscribePanesState(
            settle: { _ in }, ticks: AsyncStream { _ in },
            snapshot: {
                .snapshot(box.state.repos.flatMap { repo in
                    repo.worktrees.map { WorktreePanes(entry: $0, repo: repo, inputs: WorktreeRowInputs(
                        origin: owner, projectID: repo.path, displayName: $0.branch)) }
                })
            },
            onChange: { frame.yield($0) })
        defer { subscription.cancel() }
        let initial = await sent.next()

        let response = await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            await router.route(.setWorktreePinned(worktreePath: linkedPath, isPinned: false), box)
        }
        #expect(response == .ok, "\(String(describing: response))")
        try #require(changes.currentRevision > 0, "the windowless mutation published no change")

        let next = await sent.next()
        #expect(next != nil && next != initial)
    }

    /// A removal awaits `git worktree remove` with the worktree `.deleting`.
    /// The window's `.onChange` would mark that state; with no window the
    /// flow must mark it itself, or subscribers see it only on a tick.
    @Test func aRemovalMarksItsDeletingStateBeforeAwaitingGit() async throws {
        let (root, box, path) = try await removalFixture(registered: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PersistenceProbe()
        var marked: [WorktreeState?] = []
        probe.persister.onMarkDirty = { marked.append(box.state.worktree(forPath: path)?.state) }

        _ = await remove(path, in: box, root: root, probe: probe)

        #expect(marked.contains(.deleting), "marks: \(marked)")
        #expect(marked.last == .some(nil), "the removal itself was not marked: \(marked)")
    }

    /// A failed removal restores the prior state; that restore must be the
    /// last mark, or `.deleting` is what subscribers and `state.json` keep.
    @Test func aFailedRemovalMarksTheRestoredStateLast() async throws {
        let (root, box, path) = try await removalFixture(registered: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = PersistenceProbe()
        var marked: [WorktreeState?] = []
        probe.persister.onMarkDirty = { marked.append(box.state.worktree(forPath: path)?.state) }

        let result = await remove(path, in: box, root: root, probe: probe)

        guard case .failure = result else {
            Issue.record("expected the removal to fail: \(result)")
            return
        }
        #expect(box.state.worktree(forPath: path)?.state == .running)
        if let last = marked.last { #expect(last == .running, "marks: \(marked)") }
    }

    /// A git repo with a linked worktree entry at `<root>/linked`.
    /// `registered: false` leaves the directory missing (removal prunes and
    /// succeeds); `true` creates a plain directory git refuses to remove.
    private func removalFixture(registered: Bool) async throws -> (URL, StateBox, String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-change-signal-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await GitRunner.run(args: ["init"], at: root.path)
        let path = root.appendingPathComponent("linked").path
        if registered { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        let box = StateBox(AppState(repos: [RepoEntry(path: root.path, displayName: "repo", worktrees: [
            WorktreeEntry(path: root.path, branch: "main"),
            WorktreeEntry(path: path, branch: "linked", state: .running),
        ])]))
        return (root, box, path)
    }

    private func remove(_ path: String, in box: StateBox, root: URL, probe: PersistenceProbe)
        async -> Swift.Result<DeleteWorktreeFlow.Outcome, DeleteWorktreeFlow.FlowError> {
        let manager = TerminalManager(socketPath: root.appendingPathComponent("control.sock").path)
        return await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            await DeleteWorktreeFlow.delete(
                worktreePath: path, force: false, appState: box.binding,
                terminalManager: manager, statsStore: WorktreeStatsStore(),
                prStatusStore: PRStatusStore(), teamEventDispatcher: testDispatcher(root)
            )
        }
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

/// A router or service test that forgets `$appStatePersisterOverride` marks
/// the shared persister; in a test host that must never reach the
/// developer's live `~/Library/Application Support/Graftty/state.json`.
@Suite("The shared state persister never targets the live state directory in a test host")
@MainActor
struct SharedPersisterTestHostTests {

    @Test func aTestHostWritesSomewhereOtherThanApplicationSupport() {
        #expect(GrafttyApp.sharedAppStatePersisterDirectory != AppState.defaultDirectory)
    }
}

private func twoPaneState(ratio: Double = 0.3) -> (AppState, PaneSlotID, PaneSlotID) {
    let left = PaneSlotID()
    let right = PaneSlotID()
    var worktree = WorktreeEntry(path: repoPath, branch: "main", state: .running)
    worktree.splitTree = SplitTree(root: .split(.init(
        direction: .horizontal, ratio: ratio, left: .leaf(left), right: .leaf(right)
    )))
    worktree.paneSessions = [left: PaneSessionID(), right: PaneSessionID()]
    let state = AppState(
        repos: [RepoEntry(path: repoPath, displayName: "repo", worktrees: [worktree])],
        selectedWorktreePath: repoPath
    )
    return (state, left, right)
}

@Suite("@spec PERSIST-2.9: When a pane command changes `AppState` (start, split, close, resize, equalize, zoom, navigate, reassign or pane attention), the application shall save the change within the save delay even while no window is open.")
@MainActor
struct WindowlessPaneCommandSaveTests {

    @Test func equalizingSplitsIsSaved() async throws {
        let probe = PersistenceProbe()
        let (state, left, _) = twoPaneState(ratio: 0.3)
        let box = StateBox(state)

        GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            PaneCommands.equalizeSplits(appState: box.binding, around: left)
        }
        try await probe.fireArmedSave()

        #expect(probe.written.last?.worktree(forPath: repoPath)?.splitTree == box.state.worktree(forPath: repoPath)?.splitTree)
        #expect(probe.written.last?.worktree(forPath: repoPath)?.splitTree != twoPaneState(ratio: 0.3).0.worktree(forPath: repoPath)?.splitTree)
    }

    @Test func zoomingIsSaved() async throws {
        let probe = PersistenceProbe()
        let (state, left, _) = twoPaneState()
        let box = StateBox(state)

        GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            PaneCommands.toggleZoom(appState: box.binding, on: left)
        }
        try await probe.fireArmedSave()

        #expect(probe.written.last?.worktree(forPath: repoPath)?.splitTree.zoomed == left)
    }

    /// `terminalManager.onCommandFinished` fires from shell integration on
    /// any live surface, including background-started panes.
    @Test func paneAttentionFromAFinishedCommandIsSaved() async throws {
        let probe = PersistenceProbe()
        let (state, left, _) = twoPaneState()
        let box = StateBox(state)

        GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            PaneCommands.setAttentionForTerminal(
                appState: box.binding, terminalID: left, text: "Command finished",
                clearAfter: 10, source: .commandFinished
            )
        }
        try await probe.fireArmedSave()

        #expect(probe.written.last?.worktree(forPath: repoPath)?.paneAttention[left]?.text == "Command finished")
    }

    @Test func aSocketPaneCloseIsSaved() async throws {
        let probe = PersistenceProbe()
        let router = try HeadlessRouter()
        let (state, _, right) = twoPaneState()
        let box = StateBox(state)

        let response = await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            await router.route(.closePane(path: repoPath, index: 2), box)
        }
        #expect(response == .ok, "\(String(describing: response))")
        try await probe.fireArmedSave()

        let saved = try #require(probe.written.last?.worktree(forPath: repoPath))
        #expect(!saved.splitTree.containsLeaf(right))
    }

    @Test func aCommandThatChangesNothingSchedulesNoSave() {
        let probe = PersistenceProbe()
        let pane = PaneSlotID()
        let box = StateBox(twoPaneState().0)

        GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            PaneCommands.equalizeSplits(appState: box.binding, around: pane)  // not in any tree
        }

        #expect(!probe.hasArmedSave)
    }
}

private func runGit(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
}

@MainActor
private func testDispatcher(_ root: URL) -> TeamEventDispatcher {
    TeamEventDispatcher(
        inbox: TeamInbox(rootDirectory: root.appendingPathComponent("inbox")),
        preferencesProvider: { TeamEventRoutingPreferences() },
        templateProvider: { "" }
    )
}

@Suite("@spec PERSIST-2.10: When a worktree is created or removed through the control socket, a paired device or the web server, the application shall save the result within the save delay even while no window is open.")
@MainActor
struct WindowlessWorktreeLifecycleSaveTests {

    @Test func aSocketCreateWithoutAnAgentSavesItsPlaceholder() async throws {
        let probe = PersistenceProbe()
        let router = try HeadlessRouter()
        let box = StateBox(runningWorktreeState().0)

        let response = await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            await router.route(.createWorktree(
                callerWorktree: repoPath, worktreeName: "plain", branchName: "plain",
                existing: false, base: nil, command: nil,
                agentRuntime: nil, agentPrompt: nil, operationID: "op-plain"
            ), box)
        }
        guard case .worktreeCreate = response else {
            Issue.record("unexpected response \(String(describing: response))")
            return
        }
        try await probe.fireArmedSave()

        #expect(probe.written.last?.worktree(forPath: repoPath + "/.worktrees/plain") != nil)
    }

    /// The finish step's success branch (git done, terminal started) is the
    /// state a restart must restore; it was saved by no path.
    @Test func aCompletedCreateIsSaved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-windowless-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo").path
        try runGit(["init", "-b", "main", repo])
        try runGit(["-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "-c", "core.hooksPath=/dev/null", "commit", "--allow-empty", "-m", "Initial"])
        try runGit(["-C", repo, "branch", "feature"])
        let box = StateBox(AppState(repos: [RepoEntry(path: repo, displayName: "repo", worktrees: [
            WorktreeEntry(path: repo, branch: "main")
        ])]))
        let probe = PersistenceProbe()
        let manager = TerminalManager(socketPath: root.appendingPathComponent("control.sock").path)
        let monitor = WorktreeMonitor()
        let stats = WorktreeStatsStore(compute: { _, _, _, _ in .init(defaultBranch: nil, stats: nil) }, fetch: { _ in })
        let path = repo + "/.worktrees/feature"
        defer {
            monitor.stopWatchingWorktree(path)
            stats.clear(worktreePath: path)
        }

        let result = await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            await AddWorktreeFlow.add(
                repoPath: repo, worktreeName: "feature",
                branch: .useExisting(name: "feature", source: .local),
                appState: box.binding, worktreeMonitor: monitor, statsStore: stats,
                terminalManager: manager, teamEventDispatcher: testDispatcher(root),
                entryPoint: .pairedClient
            )
        }
        guard case .success = result else {
            Issue.record("creation failed: \(result)")
            return
        }
        try await probe.fireArmedSave()

        #expect(probe.written.last?.worktree(forPath: path)?.state == .running)
    }

    @Test func aRemovalIsSaved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-windowless-remove-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init"], at: root.path)
        var vanished = WorktreeEntry(path: root.appendingPathComponent("vanished").path, branch: "gone")
        vanished.markStale()
        let box = StateBox(AppState(repos: [RepoEntry(path: root.path, displayName: "repo", worktrees: [
            WorktreeEntry(path: root.path, branch: "main"), vanished
        ])]))
        let probe = PersistenceProbe()
        let manager = TerminalManager(socketPath: root.appendingPathComponent("control.sock").path)

        let result = await GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            await DeleteWorktreeFlow.delete(
                worktreePath: vanished.path, force: false, appState: box.binding,
                terminalManager: manager, statsStore: WorktreeStatsStore(),
                prStatusStore: PRStatusStore(), teamEventDispatcher: testDispatcher(root)
            )
        }
        guard case .success = result else {
            Issue.record("removal failed: \(result)")
            return
        }
        try await probe.fireArmedSave()

        let saved = try #require(probe.written.last)
        #expect(saved.worktree(forPath: vanished.path) == nil)
    }
}

/// The four paired-device worktree-management cases that mutate the sidebar
/// or acknowledge attention (`.moveProject`, `.moveWorktree`,
/// `.acknowledgeOccurrence`, `.acknowledge`) each run inside
/// `GrafttyApp.persistingChanges`; the handler itself needs a full
/// `AppServices`, so the shared wrapper is what is exercised here.
@Suite("@spec PERSIST-2.11: When a paired device reorders projects or worktrees or acknowledges attention, the application shall save the change within the save delay even while no window is open.")
@MainActor
struct WindowlessPairedDeviceSaveTests {

    @Test func anAcknowledgementIsSaved() async throws {
        let probe = PersistenceProbe()
        var state = runningWorktreeState().0
        state.repos[0].worktrees[0].attention = Attention(text: "Done", timestamp: Date())
        let box = StateBox(state)

        let response: WorktreeManagementResponse = GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            GrafttyApp.persistingChanges(to: box.binding) {
                box.state.repos[0].worktrees[0].acknowledgeAttention()
                return .ok
            }
        }
        #expect(response == .ok)
        try await probe.fireArmedSave()

        #expect(probe.written.last == box.state)
        #expect(probe.written.last != state)
    }

    @Test func aRejectedRequestSchedulesNoSave() {
        let probe = PersistenceProbe()
        let box = StateBox(runningWorktreeState().0)

        let response: WorktreeManagementResponse = GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            GrafttyApp.persistingChanges(to: box.binding) {
                .error(code: "invalid-move", message: "no", forceAllowed: false, shortStatus: nil)
            }
        }

        #expect(response != .ok)
        #expect(!probe.hasArmedSave)
    }
}

@MainActor
private func waitForArmedSave(_ probe: PersistenceProbe) async {
    let deadline = ContinuousClock.now + .seconds(2)
    while !probe.hasArmedSave, ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@Suite("@spec PERSIST-2.12: When a background source (an attention auto-clear timer or a branch change found by the filesystem monitor) changes `AppState`, the application shall save the change within the save delay even while no window is open.")
@MainActor
struct WindowlessBackgroundSaveTests {

    @Test func anAttentionAutoClearIsSaved() async throws {
        let probe = PersistenceProbe()
        let stamp = Date()
        var state = runningWorktreeState().0
        state.repos[0].worktrees[0].attention = Attention(text: "✓", timestamp: stamp, clearAfter: 0)
        let box = StateBox(state)

        GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            AttentionAutoClear.schedule(after: 0, appState: box.binding, worktreePath: repoPath, stamp: stamp)
        }
        await waitForArmedSave(probe)
        try await probe.fireArmedSave()

        #expect(probe.written.last?.worktree(forPath: repoPath)?.attention == nil)
    }

    @Test func aBranchChangeFoundByTheMonitorIsSaved() async throws {
        let probe = PersistenceProbe()
        var state = runningWorktreeState().0
        state.repos[0].worktrees[0].branch = "old"
        let box = StateBox(state)
        let remoteBranchStore = RemoteBranchStore(list: { _ in RemoteBranchSnapshot() })
        let bridge = WorktreeMonitorBridge(
            appState: box.binding,
            statsStore: WorktreeStatsStore(compute: { _, _, _, _ in .init(defaultBranch: nil, stats: nil) }, fetch: { _ in }),
            prStatusStore: PRStatusStore(remoteBranchStore: remoteBranchStore),
            remoteBranchStore: remoteBranchStore,
            discoverWorktrees: { _ in [DiscoveredWorktree(path: repoPath, branch: "renamed")] }
        )

        GrafttyApp.$appStatePersisterOverride.withValue(probe.persister) {
            bridge.worktreeMonitorDidDetectBranchChange(WorktreeMonitor(), worktreePath: repoPath)
        }
        await waitForArmedSave(probe)
        try await probe.fireArmedSave()

        #expect(probe.written.last?.worktree(forPath: repoPath)?.branch == "renamed")
    }
}
