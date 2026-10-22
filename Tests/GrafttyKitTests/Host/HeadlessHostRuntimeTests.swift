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
    var duringStart: (@MainActor () async throws -> Void)?
    func sessions() async throws -> Set<String> { live }
    func start(_ configuration: ZmxSpawnConfiguration) async throws {
        if failStart { throw CocoaError(.fileReadUnknown) }
        try await duringStart?()
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

private actor HostDevContainerFake: CLIExecutor {
    let failure: String?
    init(failure: String? = nil) { self.failure = failure }
    var calls: [[String]] = []
    var successfulRestarts = 0
    private var nextStop: (@Sendable () throws -> Void)?
    func onNextStop(_ callback: @escaping @Sendable () throws -> Void) { nextStop = callback }
    private var nextHelp: (@Sendable () async -> Void)?
    func onNextHelp(_ callback: @escaping @Sendable () async -> Void) { nextHelp = callback }
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        calls.append([command] + args)
        if command == "docker", args.first == "stop", let callback = nextStop { nextStop = nil; try callback() }
        if command == "docker", args.first == "start" { try Task.checkCancellation(); successfulRestarts += 1 }
        if args.contains("--help"), let callback = nextHelp { nextHelp = nil; await callback() }
        if (command == "devcontainer" && !args.contains("--help") && args.first == failure) || (command == "docker" && args.first == "rm" && failure == "cleanup") {
            throw CLIError.nonZeroExit(command: command, exitCode: 1, stderr: "simulated failure")
        }
        let text: String
        if command == "docker" { text = args.first == "inspect" ? "true" : args.first == "ps" ? String(repeating: "a", count: 64) : "" }
        else if args.contains("--help") { text = failure == "compatibility" ? "old CLI" : "--mount-git-worktree-common-dir" }
        else if args.first == "read-configuration" { text = #"{"configuration":{"image":"example:test"}}"# }
        else if args.first == "up" { text = #"{"outcome":"success","containerId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","remoteWorkspaceFolder":"/workspace","remoteUser":"dev"}"# }
        else { text = "" }
        return CLIOutput(stdout: text, stderr: "", exitCode: 0)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput { try await run(command: command, args: args, at: directory) }
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

    private func completedPlacement(_ runtime: HeadlessHostRuntime, id: UUID, owner: RemoteMacConnectionSummary.ID) async throws -> WorktreeManagementResponse {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            let response = await runtime.place(.status(operationID: id), owner: owner)
            if case .placement(let record) = response, record.state == .preparing {
                try await Task.sleep(for: .milliseconds(10))
            } else { return response }
        }
        throw HostRuntimeError.busy("Placement did not finish")
    }

    @Test("@spec REMOTE-24.19: When a placement is admitted, the host shall return its preparing status without waiting for setup, continue independently of the request lifetime, and finish canceling owned jobs before shutdown returns.", arguments: [false, true])
    func placementOutlivesRequestButNotShutdown(stop: Bool) async throws {
        let (root, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main"], at: root.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Host Test", "-c", "user.email=host@example.invalid", "commit", "--allow-empty", "-m", "initial"], at: root.path)
        let terminals = HostTerminalFake()
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals)
        _ = try await runtime.registerRepository(root.path)
        runtime.hostResources = .init(sampledAt: Date().timeIntervalSince1970, architecture: "arm64", operatingSystem: "linux",
            cpuCount: 8, cpuUtilization: 0.1, memoryTotalBytes: 16 << 30, memoryAvailableBytes: 12 << 30,
            diskPath: root.path, diskAvailableBytes: 100 << 30, activeWorktrees: 0, pendingWorktreeOperations: 0)
        let owner = RemoteMacConnectionSummary.ID(deviceID: .init(value: "parent"), fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)))
        let id = UUID()
        let intent = HostPlacementIntent(repositoryID: root.path, worktreeName: "background", branchName: "background",
            demand: .init(architecture: "arm64", cpus: 1, memoryBytes: 1 << 30, diskBytes: 1 << 20))
        var entered = false
        var exited = false
        var caller: Task<WorktreeManagementResponse, Never>?
        terminals.duringStart = {
            entered = true
            defer { exited = true }
            caller?.cancel()
            #expect(!Task.isCancelled)
            try await Task.sleep(for: stop ? .seconds(1) : .milliseconds(100))
        }
        caller = Task { await runtime.place(.create(operationID: id, intent: intent), owner: owner) }
        let response = await caller!.value
        guard case .placement(let pending) = response else { Issue.record("No admission"); return }
        #expect(pending.state == .preparing)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(entered)
        if stop {
            try await runtime.shutdown()
            #expect(exited && terminals.starts.isEmpty)
        }
        guard case .placement(let result) = try await completedPlacement(runtime, id: id, owner: owner) else { Issue.record("Missing result"); return }
        #expect(result.state == (stop ? .outcomeUnknown : .created))
        #expect(terminals.starts.count == (stop ? 0 : 1))
        if stop {
            guard case .error = await runtime.place(.create(operationID: UUID(), intent: intent), owner: owner) else { Issue.record("Shutdown admitted new work"); return }
        }
    }

    @Test("@spec REMOTE-24.17: When a host admits a placement, the application shall persist the parent-bound operation before creating its worktree, return the retained result on retries, and expose uncertain creation without starting it again.", arguments: [false, true])
    func admittedWorktreeCreationIsIdempotent(failStart: Bool) async throws {
        let (root, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main"], at: root.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Host Test", "-c", "user.email=host@example.invalid",
            "commit", "--allow-empty", "-m", "initial"], at: root.path)
        let terminals = HostTerminalFake(); terminals.failStart = failStart
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals)
        _ = try await runtime.registerRepository(root.path)
        runtime.hostResources = .init(sampledAt: Date().timeIntervalSince1970, architecture: "arm64", operatingSystem: "linux",
            cpuCount: 8, cpuUtilization: 0.1, memoryTotalBytes: 16 << 30, memoryAvailableBytes: 12 << 30,
            diskPath: root.path, diskAvailableBytes: 100 << 30, activeWorktrees: 0, pendingWorktreeOperations: 0)
        let owner = RemoteMacConnectionSummary.ID(deviceID: .init(value: "parent"), fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)))
        let id = UUID()
        let intent = HostPlacementIntent(repositoryID: root.path, worktreeName: "placed", branchName: "placed",
            demand: .init(architecture: "arm64", cpus: 2, memoryBytes: 1 << 30, diskBytes: 1 << 20))
        terminals.duringStart = {
            let retry = await runtime.place(.create(operationID: id, intent: intent), owner: owner)
            guard case .placement(let record) = retry else { Issue.record("Missing pending placement"); return }
            #expect(record.state == .preparing)
        }
        let admitted = await runtime.place(.create(operationID: id, intent: intent), owner: owner)
        guard case .placement(let pending) = admitted else { Issue.record("Admission failed"); return }
        #expect(pending.state == .preparing)
        let response = try await completedPlacement(runtime, id: id, owner: owner)
        guard case .placement(let record) = response else { Issue.record("Admission failed: \(response)"); return }
        #expect(record.state == (failStart ? .outcomeUnknown : .created))
        #expect(record.worktreeID == (failStart ? nil : intent.worktreePath))
        #expect(terminals.starts.count == (failStart ? 0 : 1))
        #expect(await runtime.place(.create(operationID: id, intent: intent), owner: owner) == response)
        #expect(await runtime.place(.status(operationID: id), owner: owner) == response)
        let restored = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake())
        #expect(await restored.place(.create(operationID: id, intent: intent), owner: owner) == response)
        #expect(terminals.starts.count == (failStart ? 0 : 1))
        let stranger = RemoteMacConnectionSummary.ID(deviceID: owner.deviceID, fingerprint: try .init(rawBytes: Data(repeating: 2, count: 32)))
        guard case .error = await runtime.place(.status(operationID: id), owner: stranger) else { Issue.record("Foreign peer read operation"); return }
        try await runtime.deleteWorktree(intent.worktreePath)
        guard case .placement(let deleted) = await runtime.place(.create(operationID: id, intent: intent), owner: owner) else {
            Issue.record("Missing tombstone"); return
        }
        #expect(deleted.state == .released)
    }

    @Test("@spec REMOTE-25.7: When a parent requests Dev Container placement, the host shall prepare the selected configuration before pane startup, retain its container identity for later panes, stop and remove that container when deleting the worktree, and restart it if Git refuses deletion even when the caller cancels.", arguments: [Optional<String>.none, "compatibility", "up", "exec", "cleanup", "cancel-delete"])
    func devContainerPlacementRetainsEnvironmentAndCleansUp(failure: String?) async throws {
        let (root, config, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "--initial-branch=main"], at: root.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".devcontainer"), withIntermediateDirectories: true)
        try Data(#"{"image":"example:test"}"#.utf8).write(to: root.appendingPathComponent(".devcontainer/devcontainer.json"))
        _ = try await GitRunner.run(args: ["add", ".devcontainer"], at: root.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Host Test", "-c", "user.email=host@example.invalid", "commit", "-m", "initial"], at: root.path)
        let terminals = HostTerminalFake()
        let executor = HostDevContainerFake(failure: failure)
        let runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals, devContainers: .init(executor: executor))
        _ = try await runtime.registerRepository(root.path)
        runtime.hostResources = .init(sampledAt: Date().timeIntervalSince1970, architecture: "arm64", operatingSystem: "linux",
            cpuCount: 8, cpuUtilization: 0.1, memoryTotalBytes: 16 << 30, memoryAvailableBytes: 12 << 30,
            diskPath: root.path, diskAvailableBytes: 100 << 30, activeWorktrees: 0, pendingWorktreeOperations: 0)
        let owner = RemoteMacConnectionSummary.ID(deviceID: .init(value: "parent"), fingerprint: try .init(rawBytes: Data(repeating: 1, count: 32)))
        let id = UUID()
        let intent = HostPlacementIntent(repositoryID: root.path, worktreeName: "container", branchName: "container",
            demand: .init(architecture: "arm64", cpus: 1, memoryBytes: 1 << 30, diskBytes: 1 << 20), devContainer: .init())
        if failure == nil {
            await executor.onNextHelp {
                guard case .placement(let retry) = await runtime.place(.createInDevContainer(operationID: id, intent: intent), owner: owner) else {
                    Issue.record("Concurrent retry did not return an operation"); return
                }
                #expect(retry.state == .preparing)
            }
        }
        let response = await runtime.place(.createInDevContainer(operationID: id, intent: intent), owner: owner)
        if failure == "compatibility" {
            guard case .error = response else { Issue.record("Missing tool support must fail before admission"); return }
            #expect(runtime.placements.pendingCount == 0 && terminals.starts.isEmpty)
            #expect(runtime.state.repos[0].worktrees.count == 1)
            return
        }
        let help = try await GitRunner.captureAll(args: ["worktree", "add", "-h"], at: root.path)
        if !(help.stdout + help.stderr).contains("relative-paths") {
            guard case .error = response else { Issue.record("Unsupported Git must fail before admission"); return }
            #expect(terminals.starts.isEmpty && runtime.placements.pendingCount == 0)
            return
        }
        let completed = try await completedPlacement(runtime, id: id, owner: owner)
        guard case .placement(let record) = completed else { Issue.record("Placement failed: \(response)"); return }
        if failure == "up" || failure == "exec" {
            #expect(record.state == .outcomeUnknown)
            #expect(record.environment == nil && terminals.starts.isEmpty)
            #expect(record.message?.contains(failure == "up" ? "lifecycle" : "git-access") == true)
            try await runtime.deleteWorktree(intent.worktreePath)
            let cleanup = await executor.calls
            #expect(cleanup.contains { $0.contains("label=graftty.placement=" + id.uuidString.lowercased()) })
            #expect(cleanup.contains { $0.starts(with: ["docker", "stop"]) })
            #expect(cleanup.contains { $0.starts(with: ["docker", "rm"]) })
            return
        }
        #expect(record.state == .created)
        let environment = try #require(record.environment)
        #expect(!environment.agentReady)
        #expect(environment.workspace == intent.worktreePath)
        #expect(terminals.starts.count == 1)
        #expect((terminals.starts[0].env["GRAFTTY_INITIAL_COMMAND"] ?? terminals.starts[0].argv.joined(separator: " ")).contains("devcontainer"))
        let restored = try HeadlessHostRuntime(configuration: config, terminals: HostTerminalFake())
        let spawned = restored.spawn(session: PaneSessionID(), path: intent.worktreePath)
        #expect((spawned.env["GRAFTTY_INITIAL_COMMAND"] ?? spawned.argv.joined(separator: " ")).contains(environment.containerID))
        let custom = restored.spawn(session: PaneSessionID(), path: intent.worktreePath, command: "printf 'project command'")
        let customCommand = custom.env["GRAFTTY_INITIAL_COMMAND"] ?? custom.argv.joined(separator: " ")
        #expect(customCommand.contains(environment.containerID) && customCommand.contains("project command"))
        let dirtyFile = URL(fileURLWithPath: intent.worktreePath).appendingPathComponent(".devcontainer/devcontainer.json")
        let original = try Data(contentsOf: dirtyFile)
        try Data(#"{"image":"changed:test"}"#.utf8).write(to: dirtyFile)
        await #expect(throws: (any Error).self) { try await runtime.deleteWorktree(intent.worktreePath) }
        #expect(runtime.state.worktree(forPath: intent.worktreePath) != nil)
        #expect(await !executor.calls.contains { $0.starts(with: ["docker", "stop"]) })
        #expect(await !executor.calls.contains { $0.starts(with: ["docker", "rm"]) })
        try original.write(to: dirtyFile)
        if failure == "cancel-delete" {
            await executor.onNextStop {
                // A writer dirties the worktree after preflight but before Git removal.
                try Data("changed during stop".utf8).write(to: dirtyFile)
                withUnsafeCurrentTask { $0?.cancel() }
            }
            let deletion = Task { try await runtime.deleteWorktree(intent.worktreePath) }
            await #expect(throws: (any Error).self) { try await deletion.value }
            #expect(await executor.successfulRestarts == 1)
            #expect(runtime.state.worktree(forPath: intent.worktreePath) != nil)
            #expect(FileManager.default.fileExists(atPath: intent.worktreePath))
            return
        }
        if failure == "cleanup" {
            await #expect(throws: (any Error).self) { try await runtime.deleteWorktree(intent.worktreePath) }
            #expect(runtime.state.worktree(forPath: intent.worktreePath) == nil)
        } else { try await runtime.deleteWorktree(intent.worktreePath) }
        let calls = await executor.calls
        #expect(calls.contains { $0.starts(with: ["docker", "stop"]) })
        #expect(calls.contains { $0.starts(with: ["docker", "rm"]) })
        guard case .placement(let released) = await runtime.place(.status(operationID: id), owner: owner) else { Issue.record("Missing result"); return }
        #expect(released.state == .released)
        if failure == "cleanup" { #expect(released.message?.contains("cleanup of stopped container") == true) }
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
        try await runtime.shutdown()
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
        _ = try await runtime.createWorktree(repository: root.path, name: provider.rawValue,
            branch: provider.rawValue, base: "HEAD", agent: provider, prompt: "Setup regression")
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
