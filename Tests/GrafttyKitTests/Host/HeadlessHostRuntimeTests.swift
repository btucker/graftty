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
    var duringStart: (@MainActor () async -> Void)?
    func sessions() async throws -> Set<String> { live }
    func start(_ configuration: ZmxSpawnConfiguration) async throws {
        if failStart { throw CocoaError(.fileReadUnknown) }
        await duringStart?()
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
    var removedLegacy = false
    let missing: Bool
    init(missing: Bool = false) { self.missing = missing }
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        commands.append(command)
        if missing { throw CLIError.notFound(command: command) }
        if args.prefix(2) == ["plugin", "remove"] { removedLegacy = true }
        let inventory: String
        if command == "codex" {
            inventory = removedLegacy
                ? #"{"installed":[{"pluginId":"graftty@graftty","installed":true,"enabled":true}]}"#
                : #"{"installed":[{"pluginId":"graftty@graftty","installed":true,"enabled":true},{"pluginId":"graftty-team@graftty","installed":true,"enabled":true}]}"#
        } else {
            inventory = #"[{"id":"graftty@graftty","scope":"user","enabled":true}]"#
        }
        return CLIOutput(stdout: args.prefix(2) == ["plugin", "list"] ? inventory : "", stderr: "", exitCode: 0)
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

    @Test func userPromptHandoffPersistsAndPublishesHistory() throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("attention"))
        try handoff.progress(worktree: root.path, agentID: "agent", runtime: .codex,
            sessionID: "session", userPrompt: "yes, implement it")
        try runtime.consumeAttentionActivities(handoff: handoff)
        #expect(runtime.state.repos[0].worktrees[0].history?.inputs.first?.text == "yes, implement it")
        #expect(try AppState.load(from: root).repos[0].worktrees[0].history?.inputs.count == 1)
        #expect(runtime.snapshot().first?.sidebar?.history?.inputs.count == 1)
        try runtime.consumeAttentionActivities(handoff: handoff)
        #expect(runtime.state.repos[0].worktrees[0].history?.inputs.count == 1)
    }

    @Test("@spec LAYOUT-2.153: When a remote client changes a repository's worktree order mode, the owning host shall persist the mode and publish that order while preserving pinned order and the saved manual order.")
    func remoteOrderPersistsAndPublishesHostOrder() async throws {
        let (root, config, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var state = initial
        var pinned = WorktreeEntry(path: root.path + "/.worktrees/role", branch: "role")
        pinned.isPinned = true
        var older = WorktreeEntry(path: root.path + "/.worktrees/older", branch: "older")
        older.attention = Attention(text: "Older", timestamp: Date(timeIntervalSince1970: 100))
        var newer = WorktreeEntry(path: root.path + "/.worktrees/newer", branch: "newer")
        newer.attention = Attention(text: "Newer", timestamp: Date(timeIntervalSince1970: 200))
        state.repos[0].worktrees += [pinned, older, newer]
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        func request(_ mode: String, repository: String) throws -> WorktreeManagementRequest {
            let json: [String: String] = ["type": "set_worktree_order", "repositoryID": repository, "mode": mode]
            return try JSONDecoder().decode(WorktreeManagementRequest.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(await runtime.manage(try request("recentActivity", repository: root.path)) == .ok)
        #expect(runtime.state.repos[0].worktrees == state.repos[0].worktrees)
        #expect(try AppState.load(from: root).repos[0].worktreeOrderMode == .recentActivity)
        #expect(runtime.snapshot().map(\.path) == [root.path, pinned.path, newer.path, older.path])
        guard case .snapshot(_, let sidebar) = runtime.panesMessage() else { Issue.record("Missing snapshot"); return }
        let metadata = try #require(sidebar?.projects.first)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        #expect(json["worktreeOrderMode"] as? String == "recentActivity")
        #expect(await runtime.manage(try request("manual", repository: root.path)) == .ok)
        #expect(runtime.snapshot().map(\.path) == [root.path, pinned.path, older.path, newer.path])
        #expect(try AppState.load(from: root).repos[0].worktreeOrderMode == .manual)
        guard case .error = await runtime.manage(try request("recentActivity", repository: "/missing")) else {
            Issue.record("Unknown repository must fail"); return
        }
        #expect(runtime.state.repos == state.repos)
    }

    @Test func failedOrderPersistenceLeavesHostSnapshotUnchanged() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        // Block atomic state-file replacement without depending on Unix permissions.
        let blocked = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: blocked.appendingPathComponent("entry"))
        guard case .error = await runtime.manage(.setWorktreeOrder(repositoryID: root.path, mode: .recentActivity)) else {
            Issue.record("Expected persistence failure"); return
        }
        #expect(runtime.state == state)
        guard case .snapshot(_, let sidebar) = runtime.panesMessage() else { Issue.record("Missing snapshot"); return }
        #expect(sidebar?.projects.first?.worktreeOrderMode == .manual)
    }

    @Test("@spec REMOTE-22.18: When a headless host has a project image, the application shall advertise its revision and serve its bytes only for the registered repository and matching revision.")
    func servesProjectLogo() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!
        try Data("version https://git-lfs.github.com/spec/v1".utf8).write(to: root.appendingPathComponent("favicon.ico"))
        try image.write(to: root.appendingPathComponent("favicon.png"))
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        await runtime.refreshProjectIcons()
        let revision = ProjectIconDiscovery.revision(image)
        #expect(await runtime.manage(.projectIcon(repositoryID: root.path, revision: revision)) == .icon(image))
        #expect(await runtime.manage(.projectIcon(repositoryID: root.path, revision: "stale")) == .icon(nil))
        #expect(await runtime.manage(.projectIcon(repositoryID: root.deletingLastPathComponent().path, revision: revision)) == .icon(nil))
        guard case .snapshot(_, let sidebar) = runtime.panesMessage() else { Issue.record("Missing snapshot"); return }
        #expect(sidebar?.projects.first?.iconRevision == revision)
        runtime.state.repos[0].iconOverride = .initials("AB")
        guard case .snapshot(_, let initials) = runtime.panesMessage() else { Issue.record("Missing snapshot"); return }
        #expect(initials?.projects.first?.initials == "AB")
        #expect(initials?.projects.first?.iconRevision == nil)
        #expect(await runtime.manage(.projectIcon(repositoryID: root.path, revision: revision)) == .icon(nil))
        runtime.state.repos[0].iconOverride = .image(image)
        await runtime.refreshProjectIcons()
        #expect(await runtime.manage(.projectIcon(repositoryID: root.path, revision: revision)) == .icon(image))
        runtime.state.repos.removeAll()
        #expect(await runtime.manage(.projectIcon(repositoryID: root.path, revision: revision)) == .icon(nil))
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

    @Test("@spec REMOTE-22.40: When a headless host publishes a pane that has not reported a title, the application shall send an empty title, as Mac hosts do, so clients apply their own untitled-pane fallback (IOS-4.10) instead of a host-supplied placeholder.")
    func untitledPanePublishesEmptyTitle() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        let session = try await runtime.openWorktree(root.path)
        let leaves = runtime.snapshot().first?.layout?.leaves ?? []
        #expect(leaves.map(\.sessionName) == [session])
        #expect(leaves.map(\.title) == [""])
        #expect(leaves.map(\.displayTitle) == ["shell"])
    }

    @Test("@spec REMOTE-22.41: If a headless host worktree has no on-disk checkout, then the application shall omit its cached divergence stats from the published row.")
    func staleWorktreeOmitsCachedStats() throws {
        let (root, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent(".worktrees/gone").path
        let state = AppState(repos: [RepoEntry(path: root.path, displayName: "project", worktrees: [
            WorktreeEntry(path: root.path, branch: "main"),
            WorktreeEntry(path: gone, branch: "gone", state: .stale),
        ])])
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        let stats = WorktreeWireStats(ahead: 2, behind: 0, hasUncommittedChanges: true, baseRef: "origin/main")
        runtime.worktreeStats = [root.path: stats, gone: stats]
        let rows = Dictionary(uniqueKeysWithValues: runtime.snapshot().map { ($0.path, $0) })
        #expect(rows[root.path]?.stats == stats)
        #expect(rows[gone]?.state == .stale)
        #expect(rows[gone]?.stats == nil)
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

    @Test("@spec REMOTE-22.17: When notifications, pin changes, or attention acknowledgements arrive while a headless pane starts, the application shall preserve those updates when publishing the opened or split pane.",
          arguments: [false, true], ["notify", "pin", "acknowledge"])
    func paneStartupPreservesConcurrentUpdates(split: Bool, update: String) async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let terminals = HostTerminalFake()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals, initialState: state)
        let first = split ? try await runtime.openWorktree(root.path) : nil
        #expect(await runtime.handle(.notify(path: root.path, text: "original")) == .ok)
        // Deliver requests while the runtime is awaiting terminal startup.
        terminals.duringStart = {
            switch update {
            case "notify":
                #expect(await runtime.handle(.notify(path: root.path, text: "new")) == .ok)
            case "pin":
                #expect(await runtime.handle(.setWorktreePinned(worktreePath: root.path, isPinned: true)) == .ok)
            default:
                #expect(await runtime.manage(.acknowledge(worktreeID: root.path, paneID: nil)) == .ok)
            }
        }
        if let first { _ = try await runtime.splitPane(target: first, direction: .right) }
        else { _ = try await runtime.openWorktree(root.path) }
        terminals.duringStart = nil
        for result in [runtime.state, try AppState.load(from: root)] {
            let worktree = try #require(result.worktree(forPath: root.path))
            #expect(worktree.state == .running)
            #expect(worktree.splitTree.leafCount == (split ? 2 : 1))
            #expect(worktree.isPinned == (update == "pin"))
            #expect(worktree.attention?.text == (update == "acknowledge" ? nil : update == "notify" ? "new" : "original"))
        }
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

    // MARK: - Shared control dispatcher (ControlRequestCore) behavior on Linux

    private func runningRuntime() async throws -> (URL, HeadlessHostRuntime, String) {
        let (root, config, state) = try fixture()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        let session = try await runtime.openWorktree(root.path)
        return (root, runtime, session)
    }

    private func hook(_ runtime: HeadlessHostRuntime, _ path: String, _ provider: TeamHookRuntime = .codex,
                      _ event: TeamHookEvent, session: String? = "s1", pane: String? = nil,
                      reason: AgentHookAttentionReason? = nil, agent: String? = "codex-test") async -> ResponseMessage {
        await runtime.handle(.teamHook(callerWorktree: path, callerAgentID: agent, runtime: provider, event: event,
            sessionID: session, paneSessionName: pane, attentionReason: reason, stopHookActive: true))
    }

    @Test("@spec REMOTE-22.42: When a headless host receives an attention-only provider hook, the application shall answer an empty hook output without consulting the team inbox, even for an untracked worktree.")
    func attentionOnlyHookFastPath() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        for event: TeamHookEvent in [.preToolUse, .permissionRequest, .userPromptSubmit, .postToolUseFailure, .postToolUse] {
            #expect(await hook(runtime, "/untracked/worktree", .codex, event) == .teamHookOutput("{}"))
        }
    }

    @Test("@spec REMOTE-22.43: When a headless host receives a provider hook for a pane in the caller's worktree, the application shall publish that pane busy from prompt submission through tool use and idle at a stop, a session start, or a blocking attention reason, and shall ignore panes outside the caller's worktree.")
    func hookLivenessMatchesMac() async throws {
        let (root, runtime, session) = try await runningRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        func busy() -> Bool? {
            guard case .leaf(_, _, _, let isBusy, _, _)? = runtime.snapshot().first?.layout else { return nil }
            return isBusy
        }
        _ = await hook(runtime, root.path, .claude, .userPromptSubmit, pane: session)
        #expect(busy() == true)
        _ = await hook(runtime, root.path, .claude, .postToolUse, pane: session)
        #expect(busy() == true)
        _ = await hook(runtime, root.path, .claude, .preToolUse, pane: session, reason: .permission)
        #expect(busy() == false)
        _ = await hook(runtime, root.path, .claude, .preToolUse, pane: session)
        _ = await hook(runtime, root.path, .claude, .sessionStart, pane: session)
        #expect(busy() == false)
        // A hook naming another worktree's pane does not mark this pane busy.
        _ = await hook(runtime, "/elsewhere", .claude, .userPromptSubmit, pane: session)
        #expect(busy() == false)
    }

    @Test("@spec REMOTE-22.44: When a headless host renders session-start instructions for the main checkout, the application shall key them by the repository's refreshed default branch, falling back to the saved hint.")
    func sessionStartUsesRefreshedDefaultBranch() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".graftty/trunk", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "Trunk role: keep the release green.".write(to: directory.appendingPathComponent("GRAFTTY.md"), atomically: true, encoding: .utf8)
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        runtime.repositoryBranches[root.path] = RemoteBranchSnapshot(defaultBranch: "trunk")
        guard case .teamHookOutput(let output) = await hook(runtime, root.path, .claude, .sessionStart) else {
            Issue.record("expected session-start hook output")
            return
        }
        // Keyed by the stale hint, the file would still render, but as an
        // unclaimed file rather than the main checkout's own role.
        #expect(output.contains("Your instructions:"), "\(output)")
        #expect(output.contains("Trunk role: keep the release green."))
        #expect(!output.contains("Instruction files matching no current worktree"), "\(output)")
    }

    @Test("@spec REMOTE-22.45: When a headless host records a provider's stopped turn, the application shall label it with the provider's display name and drop a stop older than that session's recorded progress.")
    func stoppedTurnMatchesMac() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        // No stop is recorded yet, so only the session's progress can drop
        // the stale stop (not the newer-recorded-stop rule).
        let handoff = AttentionFileHandoff(rootDirectory: root.appendingPathComponent("attention"))
        try handoff.progress(worktree: root.path, agentID: "codex-late", runtime: .codex, sessionID: "late")
        try runtime.consumeAttentionActivities(handoff: handoff)
        try handoff.stage(AttentionRecap(title: "Stale", completed: "Old", next: "None", emoji: "🧊"),
            worktree: root.path, agentID: "codex-late")
        _ = try handoff.stop(worktree: root.path, agentID: "codex-late", runtime: .codex, sessionID: "late",
            paneSessionName: nil, stopHookActive: false, stoppedAt: Date(timeIntervalSinceNow: -3600))
        try runtime.consumeAttentionActivities(handoff: handoff)
        #expect(runtime.state.worktree(forPath: root.path)?.lastAgentStop == nil)

        _ = await hook(runtime, root.path, .codex, .stop)
        #expect(runtime.state.worktree(forPath: root.path)?.lastAgentStop?.agentName == "Codex")
    }

    @Test("@spec REMOTE-22.46: When a headless host receives provider hooks for a session that raised blocking attention, the application shall keep that attention through PreToolUse and clear it on PostToolUseFailure.")
    func hookAttentionTransitionsMatchMac() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        _ = await hook(runtime, root.path, .codex, .permissionRequest, reason: .permission)
        #expect(runtime.state.worktree(forPath: root.path)?.attention?.source == .agentStop)
        _ = await hook(runtime, root.path, .codex, .preToolUse)
        #expect(runtime.state.worktree(forPath: root.path)?.attention?.source == .agentStop)
        _ = await hook(runtime, root.path, .codex, .postToolUseFailure)
        #expect(runtime.state.worktree(forPath: root.path)?.attention == nil)
        #expect(try AppState.load(from: root).worktree(forPath: root.path)?.attention == nil)
    }

    @Test("@spec REMOTE-22.47: When a headless host receives a notification with an auto-clear duration, the application shall store the normalized duration on the attention it persists.")
    func notifyStoresNormalizedAutoClear() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        #expect(await runtime.handle(.notify(path: root.path, text: "Later", clearAfter: 1_000_000)) == .ok)
        #expect(try AppState.load(from: root).worktree(forPath: root.path)?.attention?.clearAfter == Attention.clearAfterMaxSeconds)
    }

    @Test("The headless host advertises every control capability except pane agents and remote worktrees")
    func headlessCapabilities() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        #expect(await runtime.handle(.capabilities) == .capabilities([
            "agent_prompt_staging", "worktree_base", "worktree_create_idempotency", "worktree_remove",
            "worktree_pinned_removal", "worktree_pin",
        ]))
        #expect(await runtime.handle(.paneAgentCapability) == .error("operation is unavailable on this host"))
        #expect(await runtime.handle(.remoteWorktreeCapability) == .error("operation is unavailable on this host"))
    }

    @Test("@spec REMOTE-22.48: When a headless host receives a team send or message for a graftty-mac address, the application shall forward it to the paired peer only for a tracked caller.")
    func remoteTeamMessagesForward() async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        var forwarded: [TeamSendRequest] = []
        runtime.remoteTeamSender = { request in forwarded.append(request); return .ok }
        let address = "graftty-mac://peer-device/Users/me/project"
        #expect(await runtime.handle(.teamSend(callerWorktree: root.path, recipient: address, text: "hi", priority: .normal)) == .ok)
        #expect(await runtime.handle(.teamSend(callerWorktree: root.path, callerAgentID: "codex-test", recipient: address,
            text: "urgent", priority: .urgent)) == .ok)
        #expect(forwarded == [
            TeamSendRequest(callerWorktree: root.path, callerAgentID: nil, recipient: address, text: "hi", priority: .normal),
            TeamSendRequest(callerWorktree: root.path, callerAgentID: "codex-test", recipient: address, text: "urgent",
                            priority: .urgent),
        ])
        #expect(await runtime.handle(.teamSend(callerWorktree: "/untracked", recipient: address, text: "x", priority: .normal))
            == .error(TeamInboxRequestError.callerNotTracked.description))
        #expect(forwarded.count == 2)
    }

    @Test("@spec REMOTE-22.49: When a headless host receives a provider hook without a caller agent ID, the application shall resolve the agent from the provider session's presence record before delivering its targeted messages.")
    func hookResolvesAgentFromPresence() async throws {
        let (root, config, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let peerPath = root.appendingPathComponent("peer").path
        var state = initial
        state.repos[0].worktrees.append(WorktreeEntry(path: peerPath, branch: "peer"))
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake(), initialState: state)
        let agentID = "claude-0123456789ab"
        try TeamPresenceStorage(rootDirectory: config.stateDirectory.appendingPathComponent("teams")).write(TeamPresenceRecord(
            teamID: root.path, worktree: root.path, runtime: .claude, paneSessionName: nil, pid: getpid(),
            registeredAt: Date(), runtimeSessionID: "native-session", agentID: agentID))
        #expect(await runtime.handle(.teamSend(callerWorktree: peerPath, recipient: "\(root.path)#\(agentID)",
            text: "for the exact agent", priority: .urgent)) == .ok)
        guard case .teamHookOutput(let output) = await hook(runtime, root.path, .claude, .postToolUse,
            session: "native-session", agent: nil) else {
            Issue.record("expected hook output")
            return
        }
        #expect(output.contains("for the exact agent"), "\(output)")
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

    @Test("@spec REMOTE-22.13: When headless agent setup is requested for one provider, the application shall install only that provider's Graftty plugin, migrate its legacy plugin after verifying the replacement, and report actionable errors for a missing provider CLI.")
    func providerSetup() async throws {
        let (root, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = HostPluginExecutor()
        try await HostAgentSetup.install(configuration: config, provider: .codex, executor: executor, installer: AgentPluginInstaller(codexConfigurationURL: root.appendingPathComponent("codex-config.toml"), claudeSettingsURL: root.appendingPathComponent("claude-settings.json")))
        #expect(await executor.removedLegacy)
        #expect(Set(await executor.commands) == ["codex"])
        let missing = HostPluginExecutor(missing: true)
        do {
            try await HostAgentSetup.install(configuration: config, provider: .claude, executor: missing, installer: AgentPluginInstaller(codexConfigurationURL: root.appendingPathComponent("codex-config.toml"), claudeSettingsURL: root.appendingPathComponent("claude-settings.json")))
            Issue.record("missing provider accepted")
        } catch {
            #expect(String(describing: error).contains("Install and authenticate"))
        }
    }

    @Test("@spec REMOTE-22.38: When a headless runtime receives an explicit agent installer, automatic provider setup shall retain its CLI hook path.", arguments: [TeamHookRuntime.claude, .codex])
    func automaticProviderSetupRetainsInstaller(provider: TeamHookRuntime) async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main"], at: root.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Host Test", "-c", "user.email=host@example.invalid",
            "commit", "--allow-empty", "-m", "initial"], at: root.path)
        let cli = root.appendingPathComponent("CLI tools/graftty")
        let installer = AgentPluginInstaller(grafttyCLIPath: cli.path,
            codexConfigurationURL: root.appendingPathComponent("codex-config.toml"),
            claudeSettingsURL: root.appendingPathComponent("claude-settings.json"))
        let executor = HostPluginExecutor()
        let setup = HostAgentSetup(configuration: config, executor: executor, installer: installer)
        let terminals = HostTerminalFake()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals,
            initialState: state, agentSetup: setup)
        // Agent launches arrive as `graftty worktree add`; setup runs before Git.
        guard case .worktreeCreate(var status) = await runtime.handle(.createWorktree(callerWorktree: root.path,
            worktreeName: provider.rawValue, branchName: provider.rawValue, existing: false, base: "HEAD",
            command: nil, agentRuntime: provider, agentPrompt: "Setup regression", operationID: nil)) else {
            Issue.record("worktree creation was rejected")
            return
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while status.state == .pending, ContinuousClock.now < deadline,
              case .worktreeCreate(let next) = await runtime.handle(.worktreeCreateStatus(operationID: status.operationID)) {
            status = next
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(status.state == .ready, "\(status.error ?? "creation did not finish")")
        let hooksURL = config.stateDirectory.appendingPathComponent(
            "agent-plugins/\(provider.rawValue)/plugins/graftty/hooks/hooks.json")
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL))
        func commands(in value: Any) -> [String] {
            if let object = value as? [String: Any] {
                if let command = object["command"] as? String { return [command] }
                return object.values.flatMap { commands(in: $0) }
            }
            return (value as? [Any] ?? []).flatMap { commands(in: $0) }
        }
        let hooks = commands(in: document)
        #expect(!hooks.isEmpty)
        #expect(hooks.allSatisfy { $0.contains(AgentPluginInstallStep.shellToken(cli.path) + " team hook") })
        #expect(Set(await executor.commands) == [provider.rawValue])

    }

    @Test("@spec REMOTE-22.39: When a headless host advertises agent prompt staging, the application shall replace bare agent fallback commands with a staged structured or bootstrap prompt, preserve legacy explicit commands without structured prompts, and deliver the selected prompt unchanged to the provider.", arguments: [TeamHookRuntime.claude, .codex])
    func headlessWireStagesStructuredAgentPrompt(provider: TeamHookRuntime) async throws {
        let (root, config, state) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main"], at: root.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Host Test", "-c", "user.email=host@example.invalid",
            "commit", "--allow-empty", "-m", "initial"], at: root.path)
        let installer = AgentPluginInstaller(grafttyCLIPath: root.appendingPathComponent("graftty").path,
            codexConfigurationURL: root.appendingPathComponent("codex-config.toml"),
            claudeSettingsURL: root.appendingPathComponent("claude-settings.json"))
        let terminals = HostTerminalFake()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals, initialState: state,
            agentSetup: HostAgentSetup(configuration: config, executor: HostPluginExecutor(), installer: installer))
        #expect(await runtime.handle(.agentPromptStagingCapability) == .ok)

        // Record the argv received by an executable through the actual /bin/sh
        // loader, including quotes and trailing newlines in the staged prompt.
        let binaryDirectory = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let recordedPrompt = root.appendingPathComponent("provider-prompt")
        let recordedArguments = root.appendingPathComponent("provider-arguments")
        let recorder = binaryDirectory.appendingPathComponent(provider.rawValue)
        try ("#!/bin/sh\n/usr/bin/printf '%s\\n' \"$#\" \"$1\" > "
            + WorktreeAgentLaunchCommand.shellLiteral(recordedArguments.path)
            + "\n/usr/bin/printf '%s' \"$2\" > " + WorktreeAgentLaunchCommand.shellLiteral(recordedPrompt.path) + "\n")
            .write(to: recorder, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recorder.path)
        let prompt = "GRAFTTY_TEST_BEGIN \(provider.rawValue)\nA 'quoted' task with $HOME and $(false)\n"
        let legacyCommand = provider.rawValue + " -- " + WorktreeAgentLaunchCommand.shellLiteral("legacy task")
        let cases: [(name: String, command: String?, agent: TeamHookRuntime?, prompt: String?, expected: String)] = [
            ("structured", provider.rawValue, provider, prompt, prompt),
            ("no-command", nil, provider, prompt, prompt),
            ("bootstrap", provider.rawValue, provider, nil, WorktreeAgentLaunchCommand.bootstrapPrompt),
            ("empty", provider.rawValue, provider, "", WorktreeAgentLaunchCommand.bootstrapPrompt),
            ("legacy", legacyCommand, provider, nil, "legacy task"),
            ("structured-wins", legacyCommand, provider, prompt, prompt),
            ("command-only", legacyCommand, nil, nil, "legacy task"),
        ]
        for item in cases {
            let name = provider.rawValue + "-" + item.name
            let response = await runtime.handle(.createWorktree(callerWorktree: root.path,
                worktreeName: name, branchName: name, existing: false, base: "HEAD", command: item.command,
                agentRuntime: item.agent, agentPrompt: item.prompt, operationID: UUID().uuidString))
            guard case .worktreeCreate(var status) = response else {
                Issue.record("worktree creation was rejected for \(item.name): \(response)")
                return
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while status.state == .pending, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
                guard case .worktreeCreate(let updated) = await runtime.handle(.worktreeCreateStatus(operationID: status.operationID)) else {
                    Issue.record("worktree creation status was lost for \(item.name)")
                    return
                }
                status = updated
            }
            try #require(status.state == .ready, "\(item.name): \(status.error ?? "creation did not finish")")
            let command = try #require(terminals.starts.last?.env["GRAFTTY_INITIAL_COMMAND"])
            if item.name == "legacy" || item.name == "command-only" {
                #expect(command == legacyCommand, "Explicit command compatibility must be preserved")
            }
            _ = try await CLIRunner().run(command: "/bin/sh", args: ["-c",
                "export PATH=" + WorktreeAgentLaunchCommand.shellLiteral(binaryDirectory.path + ":/usr/bin:/bin")
                    + "\n" + command], at: status.worktreePath, timeout: .seconds(5))
            #expect(try String(contentsOf: recordedArguments, encoding: .utf8) == "2\n--\n",
                    "Structured agent prompt must reach the provider argv")
            #expect(try String(contentsOf: recordedPrompt, encoding: .utf8) == item.expected,
                    "Structured agent prompt must reach the provider argv")
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
        let identity = try await HostSetup.prepare(configuration: config, installAgentPlugins: true, executor: executor, pluginInstaller: AgentPluginInstaller(codexConfigurationURL: root.appendingPathComponent("codex-config.toml"), claudeSettingsURL: root.appendingPathComponent("claude-settings.json")))
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
