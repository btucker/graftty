import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@MainActor
private final class HostTerminalFake: HostTerminalDriver {
    var live: Set<String> = []
    var starts: [ZmxSpawnConfiguration] = []
    var killed: [String] = []
    var failStart = false
    func sessions() async throws -> Set<String> { live }
    func start(_ configuration: ZmxSpawnConfiguration) async throws {
        if failStart { throw CocoaError(.fileReadUnknown) }
        starts.append(configuration)
        live.insert(configuration.sessionName)
    }
    func kill(_ session: String) async throws { killed.append(session); live.remove(session) }
    func send(_ text: String, to session: String) async throws {}
    func show(_ session: String, lines: Int) async throws -> String { "hello" }
    func detachAll() {}
}

@Suite @MainActor
struct HeadlessHostRuntimeTests {
    private func fixture() throws -> (URL, HostConfiguration, AppState) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = HostConfiguration(stateDirectory: root, runtimeDirectory: root.appendingPathComponent("run"), zmxExecutable: URL(fileURLWithPath: "/bin/true"))
        let state = AppState(repos: [RepoEntry(path: root.path, displayName: "project", worktrees: [WorktreeEntry(path: root.path, branch: "main")])])
        return (root, configuration, state)
    }

    @Test("@spec REMOTE-22.1: When a headless host opens a worktree, the application shall start and persist its zmx pane without waiting for a visible client.")
    func opensWithoutViewer() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminals = HostTerminalFake()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals, initialState: state)
        let session = try await runtime.openWorktree(root.path, command: "echo ready")
        #expect(terminals.starts.count == 1)
        #expect(terminals.starts.first?.env["GRAFTTY_INITIAL_COMMAND"] == "echo ready")
        let saved = try AppState.load(from: root)
        #expect(saved.worktree(forPath: root.path)?.state == .running)
        #expect(saved.worktree(forPath: root.path)?.paneSessions.values.map(ZmxLauncher.sessionName(for:)) == [session])
    }

    @Test("@spec REMOTE-22.2: When a headless host restarts, the application shall retain saved pane session IDs and reuse surviving zmx sessions without rerunning startup commands.")
    func restoresSurvivingSessions() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminals = HostTerminalFake()
        let first = try HeadlessHostRuntime(configuration: config, terminals: terminals, initialState: state)
        let session = try await first.openWorktree(root.path, command: "echo first")
        let restored = try HeadlessHostRuntime(configuration: config, terminals: terminals)
        try await restored.restore()
        #expect(terminals.starts.count == 1)
        #expect(restored.sessions().map(\.name) == [session])
        #expect(restored.snapshot().first?.layout != nil)
    }

    @Test("@spec REMOTE-22.3: When a headless host splits, resizes, or closes a pane, the application shall persist the layout and terminate only the explicitly closed zmx session.")
    func paneLifecycle() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminals = HostTerminalFake()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals, initialState: state)
        let first = try await runtime.openWorktree(root.path)
        let second = try await runtime.splitPane(target: first, direction: .right)
        #expect(runtime.sessions().count == 2)
        #expect(await runtime.control(.resize(target: first, direction: .right, amount: 10, viewportExtent: 100)) == .ok)
        try await runtime.closePane(target: second)
        #expect(terminals.killed == [second])
        #expect(runtime.sessions().map(\.name) == [first])
        let saved = try AppState.load(from: root)
        #expect(saved.worktree(forPath: root.path)?.splitTree.leafCount == 1)
    }

    @Test("@spec REMOTE-22.4: If headless pane startup fails, then the application shall preserve the prior persisted layout and return an error.")
    func failedSplitDoesNotPublishPane() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminals = HostTerminalFake()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals, initialState: state)
        let session = try await runtime.openWorktree(root.path)
        terminals.failStart = true
        await #expect(throws: (any Error).self) { try await runtime.splitPane(target: session, direction: .down) }
        #expect(runtime.sessions().count == 1)
        #expect(try AppState.load(from: root).worktree(forPath: root.path)?.splitTree.leafCount == 1)
    }
    @Test("@spec REMOTE-22.5: When a headless host receives local team messages and agent hooks, the application shall persist inbox messages and expose a reported recap on the next stopped turn.")
    func teamAndAttention() async throws {
        let (root, config, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let peerPath = root.appendingPathComponent("peer").path
        var state = initial
        state.repos[0].worktrees.append(WorktreeEntry(path: peerPath, branch: "peer"))
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        #expect(await runtime.handle(.teamSend(callerWorktree: root.path, recipient: peerPath, text: "hello peer", priority: .normal)) == .ok)
        let stored = try TeamInbox(rootDirectory: config.stateDirectory.appendingPathComponent("teams")).messages(teamID: root.path)
        #expect(stored.map(\.body) == ["hello peer"])
        let recap = AttentionRecap(title: "Host running", completed: "Started panes", next: "Connect viewer", emoji: "🖥️")
        #expect(await runtime.handle(.attentionReport(callerWorktree: root.path, callerAgentID: "codex-test", recap: recap)) == .ok)
        _ = await runtime.handle(.teamHook(callerWorktree: root.path, callerAgentID: "codex-test", runtime: .codex,
            event: .stop, sessionID: "test", paneSessionName: nil, stopHookActive: false))
        #expect(runtime.state.worktree(forPath: root.path)?.unseenAgentStop?.recap == recap)
        #expect(runtime.snapshot().first?.sidebar?.unseenAgentStop?.recap == recap)
        #expect(try AppState.load(from: root).worktree(forPath: root.path)?.emoji == "🖥️")
    }

    @Test("@spec REMOTE-22.6: When a headless host registers a repository, the application shall discover its Git worktrees and persist one canonical registration.")
    func registration() async throws {
        let (root, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main"], at: root.path)
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake())
        let first = try await runtime.registerRepository(root.path)
        let second = try await runtime.registerRepository(root.path + "/.")
        #expect(first.id == second.id)
        #expect(runtime.state.repos.count == 1)
        #expect(try AppState.load(from: root).repos.first?.worktrees.first?.path == root.path)
        await #expect(throws: (any Error).self) {
            try await runtime.createWorktree(repository: root.path, name: "../outside", branch: "bad")
        }
    }

    @Test("@spec REMOTE-22.7: When a headless host shuts down, the application shall detach clients while preserving zmx sessions for restart.")
    func shutdownPreservesSessions() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminals = HostTerminalFake()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals, initialState: state)
        let session = try await runtime.openWorktree(root.path)
        try runtime.shutdown()
        #expect(terminals.killed.isEmpty)
        #expect(terminals.live.contains(session))
        #expect(try AppState.load(from: root).worktree(forPath: root.path)?.state == .running)
    }

}
