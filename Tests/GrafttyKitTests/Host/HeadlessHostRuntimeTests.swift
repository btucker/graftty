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

private actor HostPluginExecutor: CLIExecutor {
    var commands: [String] = []
    let missing: Bool
    init(missing: Bool = false) { self.missing = missing }
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        commands.append(command)
        if missing { throw CLIError.notFound(command: command) }
        return CLIOutput(stdout: "", stderr: "", exitCode: 0)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
}

@Suite @MainActor
struct HeadlessHostRuntimeTests {
    private func fixture() throws -> (URL, HostConfiguration, AppState) {
        let rawRoot = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("gh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: CanonicalPath.canonicalize(rawRoot.path), isDirectory: true)
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
        let stored = try TeamInbox(rootDirectory: config.stateDirectory.appendingPathComponent("team-inbox")).messages(teamID: root.path)
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
        let saved = try AppState.load(from: root)
        let expectedPath = CanonicalPath.canonicalize(root.path)
        #expect(saved.repos.first?.worktrees.first?.path == expectedPath)
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

    @Test("@spec REMOTE-22.8: When a headless host consumes a file-based stopped-turn recap, the application shall persist the recap and clear it only after matching provider progress.")
    func fileAttentionHandoff() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("attention"))
        let recap = AttentionRecap(title: "Host done", completed: "Created host", next: "Review host", emoji: "🖥️")
        try handoff.stage(recap, worktree: root.path, agentID: "codex-test")
        #expect(try handoff.stop(worktree: root.path, agentID: "codex-test", runtime: .codex,
            sessionID: "test", paneSessionName: nil, stopHookActive: false) == .queued)
        try runtime.consumeAttentionActivities(handoff: handoff)
        #expect(runtime.state.worktree(forPath: root.path)?.unseenAgentStop?.recap == recap)
        try handoff.progress(worktree: root.path, agentID: "codex-other", runtime: .codex, sessionID: "other")
        try runtime.consumeAttentionActivities(handoff: handoff)
        #expect(runtime.state.worktree(forPath: root.path)?.unseenAgentStop != nil)
        try handoff.progress(worktree: root.path, agentID: "codex-test", runtime: .codex, sessionID: "test")
        try runtime.consumeAttentionActivities(handoff: handoff)
        #expect(runtime.state.worktree(forPath: root.path)?.unseenAgentStop == nil)
        #expect(try AppState.load(from: root).worktree(forPath: root.path)?.unseenAgentStop == nil)
    }

    @Test("@spec REMOTE-22.9: When Git worktree membership or branches change externally, the headless host shall reconcile saved worktrees and publish branch choices for the remote client.")
    func gitMetadataRefresh() async throws {
        let (root, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main"], at: root.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Host Test", "-c", "user.email=host@example.invalid",
            "commit", "--allow-empty", "-m", "initial"], at: root.path)
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake())
        let repo = try await runtime.registerRepository(root.path)
        _ = try await GitRunner.run(args: ["branch", "feature"], at: repo.path)
        try await runtime.refreshRepository(repo.path)
        let info = await runtime.repositoryInfo()
        #expect(Set(info.first?.branches.map(\.name) ?? []) == ["main", "feature"])
        _ = try await GitRunner.run(args: ["checkout", "feature"], at: repo.path)
        try await runtime.refreshRepository(repo.path)
        #expect(runtime.state.worktree(forPath: repo.path)?.branch == "feature")
        #expect(runtime.snapshot().first?.displayBranch == "feature")
    }

    @Test("@spec REMOTE-22.10: When a headless host creates or deletes a linked worktree, the application shall mutate Git, persist registration, and start or terminate its pane sessions.")
    func worktreeCreationAndDeletion() async throws {
        let (root, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main"], at: root.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Host Test", "-c", "user.email=host@example.invalid",
            "commit", "--allow-empty", "-m", "initial"], at: root.path)
        let terminals = HostTerminalFake()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals)
        let repo = try await runtime.registerRepository(root.path)
        let created = try await runtime.createWorktree(repository: repo.path, name: "feature", branch: "feature", command: "echo task")
        #expect(FileManager.default.fileExists(atPath: created.path))
        #expect(runtime.state.worktree(forPath: created.path)?.state == .running)
        #expect(terminals.starts.first?.env["GRAFTTY_INITIAL_COMMAND"] == "echo task")
        try await runtime.deleteWorktree(created.path)
        #expect(!FileManager.default.fileExists(atPath: created.path))
        #expect(runtime.state.worktree(forPath: created.path) == nil)
        #expect(terminals.killed == [created.session])
        #expect(try AppState.load(from: root).worktree(forPath: created.path) == nil)
    }

    @Test("@spec REMOTE-22.11: When the headless host receives an administration request on its private Unix socket, the application shall return the live runtime state.")
    func administrationSocket() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try config.prepareDirectories()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        let server = HostAdministrationServer(configuration: config) { _ in
            await MainActor.run { .status(HostStatus(running: true, configuration: config,
                repositoryCount: runtime.state.repos.count, paneCount: runtime.sessions().count)) }
        }
        try server.start()
        defer { server.stop() }
        // Exercise peer-initiated close racing our post-response cleanup.
        for _ in 0..<100 {
            let response = try await HostAdministrationServer.request(.status, configuration: config)
            if case .status(let status) = response { #expect(status.running); #expect(status.repositoryCount == 1) }
            else { Issue.record("unexpected administration response") }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: HostAdministrationServer.socketPath(configuration: config))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("@spec REMOTE-22.12: When a headless host chooses storage and socket paths, the application shall honor absolute state and XDG overrides and keep fallback CLI socket discovery consistent.")
    func hostPaths() {
        #expect(HostConfiguration.defaultStateDirectory(environment: ["GRAFTTY_STATE_DIR": "/srv/graftty", "XDG_DATA_HOME": "/data"]).path == "/srv/graftty")
        #expect(HostConfiguration.defaultStateDirectory(environment: ["XDG_DATA_HOME": "/data"]).path == "/data/graftty")
        #expect(HostConfiguration.defaultRuntimeDirectory(environment: ["XDG_RUNTIME_DIR": "/run/user/1000"]).path == "/run/user/1000/graftty")
        #expect(HostConfiguration.defaultRuntimeDirectory(environment: ["GRAFTTY_STATE_DIR": "/srv/graftty"]).path == "/srv/graftty")
    }

    @Test("@spec REMOTE-22.13: When headless agent setup is requested for one provider, the application shall install only that provider's Graftty plugin and report actionable errors for a missing provider CLI.")
    func providerSetup() async throws {
        let (root, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = HostPluginExecutor()
        try await HostAgentSetup.install(configuration: config, provider: .codex, executor: executor)
        #expect(Set(await executor.commands) == ["codex"])
        let missing = HostPluginExecutor(missing: true)
        do {
            try await HostAgentSetup.install(configuration: config, provider: .claude, executor: missing)
            Issue.record("missing provider accepted")
        } catch {
            #expect(String(describing: error).contains("Install and authenticate"))
        }
    }

    @Test("@spec REMOTE-22.14: While the headless host owns its process lease, explicit agent-plugin setup shall remain available without changing host configuration or identity, and plain setup shall remain exclusive.")
    func pluginSetupWhileHostIsRunning() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try config.prepareDirectories()
        try config.save()
        try state.save(to: root)
        let configFile = root.appendingPathComponent("host-config.json")
        let stateFile = root.appendingPathComponent("state.json")
        let savedConfig = try Data(contentsOf: configFile)
        let savedState = try Data(contentsOf: stateFile)
        let holder = Process()
        let ready = Pipe()
        let input = Pipe()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        holder.arguments = ["python3", "-c", """
        import fcntl, os, sys
        fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.lockf(fd, fcntl.LOCK_EX)
        sys.stdout.buffer.write(b"1")
        sys.stdout.flush()
        sys.stdin.buffer.read(1)
        """, root.appendingPathComponent("host.lock").path]
        holder.standardOutput = ready
        holder.standardInput = input
        try holder.run()
        defer {
            try? input.fileHandleForWriting.close()
            holder.waitUntilExit()
        }
        #expect(try ready.fileHandleForReading.read(upToCount: 1) == Data([49]))
        let executor = HostPluginExecutor()
        let identity = try await HostSetup.prepare(configuration: config, installAgentPlugins: true, executor: executor)
        #expect(identity == nil)
        #expect(Set(await executor.commands) == ["codex", "claude"])
        #expect(try Data(contentsOf: configFile) == savedConfig)
        #expect(try Data(contentsOf: stateFile) == savedState)
        #expect(!FileManager.default.fileExists(atPath: config.identityDirectory.appendingPathComponent("host-identity.json").path))
        #expect(!FileManager.default.fileExists(atPath: config.hooksDirectory.path))
        await #expect(throws: HostRuntimeError.self) {
            try await HostSetup.prepare(configuration: config, installAgentPlugins: false, executor: executor)
        }
    }

}
