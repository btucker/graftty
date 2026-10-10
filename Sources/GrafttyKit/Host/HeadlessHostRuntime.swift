import Foundation
import GrafttyProtocol

/// Shared model and operations for the headless executable. The main actor
/// serializes model changes; worktree leases prevent overlapping operations
/// from racing while Git or zmx awaits run off the actor.
@MainActor
public final class HeadlessHostRuntime {
    public let configuration: HostConfiguration
    public let launcher: ZmxLauncher
    public internal(set) var state: AppState
    let terminals: any HostTerminalDriver
    let inbox: TeamInbox
    let presence: TeamPresenceStorage
    let recaps = AttentionRecapCoordinator()
    let agentSetup: HostAgentSetup
    let portScanner: PortScanner
    var portScanInFlight = false
    var registeredPortSessions: [PaneSlotID: String] = [:]
    var portBindingSessions: [PaneSlotID: String] = [:]
    var portBindingsByPane: [PaneSlotID: [PortBinding]] = [:]
    var projectIconRefreshTask: Task<Void, Never>?
    var projectIcons: [UUID: HostProjectIcon] = [:]
    var projectIconLoads: [UUID: HostProjectIconLoad] = [:]
    var busyPaths: Set<String> = []
    var creations: [String: WorktreeCreateStatus] = [:]
    var removals: [String: WorktreeRemoveStatus] = [:]
    var busyAgents: Set<String> = []
    var deliveryTask: Task<Void, Never>?
    public var remoteTeamSender: (@MainActor @Sendable (NotificationMessage) async -> ResponseMessage)?
    var maintenance: HostMaintenance?
    var repositoryBranches: [String: RemoteBranchSnapshot] = [:]
    var operationGeneration: UInt64 = 0
    var worktreeStats: [String: WorktreeWireStats] = [:]
    public var origin: WorktreeOrigin?

    public init(configuration: HostConfiguration, terminals: (any HostTerminalDriver)? = nil,
                initialState: AppState? = nil, portScanner: PortScanner? = nil) throws {
        self.configuration = configuration
        self.portScanner = portScanner ?? PortScanner()
        agentSetup = HostAgentSetup(configuration: configuration)
        launcher = ZmxLauncher(executable: configuration.zmxExecutable, zmxDir: configuration.zmxDirectory)
        self.terminals = terminals ?? ZmxHostTerminalDriver(launcher: launcher)
        state = try initialState ?? AppState.load(from: configuration.stateDirectory)
        inbox = TeamInbox(rootDirectory: configuration.stateDirectory.appendingPathComponent("team-inbox"))
        presence = TeamPresenceStorage(rootDirectory: configuration.stateDirectory.appendingPathComponent("teams"))
    }

    func save() throws { try state.save(to: configuration.stateDirectory) }

    func indices(_ path: String) throws -> (repo: Int, worktree: Int) {
        guard let indices = state.indices(forWorktreePath: path) else { throw HostRuntimeError.notFound("worktree is not registered: \(path)") }
        return indices
    }

    func acquire(_ path: String) throws {
        guard !busyPaths.contains(path) else { throw HostRuntimeError.busy("worktree operation in progress: \(path)") }
        busyPaths.insert(path)
        operationGeneration &+= 1
    }

    public func registerRepository(_ rawPath: String) async throws -> RepoEntry {
        let path = CanonicalPath.canonicalize(URL(fileURLWithPath: rawPath).standardizedFileURL.path)
        try acquire(path)
        defer { busyPaths.remove(path) }
        let discovered = try await GitWorktreeDiscovery.discover(repoPath: path)
        // Normalize linked-checkout registrations to Git's main checkout.
        guard let main = discovered.first else { throw HostRuntimeError.invalid("repository has no worktrees") }
        let canonical = main.path
        if let repo = state.repos.first(where: { $0.path == canonical }) { return repo }
        let repo = RepoEntry(path: canonical, displayName: URL(fileURLWithPath: canonical).lastPathComponent,
            worktrees: discovered.map { WorktreeEntry(path: $0.path, branch: $0.branch) }, defaultBranchHint: main.branch)
        let previous = state
        state.addRepo(repo)
        do { try save() } catch { state = previous; throw error }
        return repo
    }

    public func restore() async throws {
        let live = try await terminals.sessions()
        for ri in state.repos.indices {
            for wi in state.repos[ri].worktrees.indices {
                let path = state.repos[ri].worktrees[wi].path
                guard FileManager.default.fileExists(atPath: path) else {
                    state.repos[ri].worktrees[wi].state = .stale
                    continue
                }
                guard state.repos[ri].worktrees[wi].state == .running else { continue }
                state.repos[ri].worktrees[wi].ensurePaneSessionsForRunningRestore()
                for slot in state.repos[ri].worktrees[wi].splitTree.allLeaves {
                    let session = state.repos[ri].worktrees[wi].ensurePaneSession(for: slot)
                    let name = launcher.sessionName(for: session)
                    // A surviving daemon needs no new startup attach. Remote
                    // clients will attach when they choose this pane.
                    if !live.contains(name) {
                        try await terminals.start(spawn(session: session, path: path))
                    }
                }
            }
        }
        try save()
        await refreshPortBindings()
    }

    public func openWorktree(_ path: String, command: String? = nil) async throws -> String {
        try acquire(path)
        defer { busyPaths.remove(path) }
        return try await openUnlocked(path, command: command)
    }

    func openUnlocked(_ path: String, command: String? = nil) async throws -> String {
        let initialIndex = try indices(path)
        let initialWorktree = state.repos[initialIndex.repo].worktrees[initialIndex.worktree]
        guard FileManager.default.fileExists(atPath: path) else { throw HostRuntimeError.notFound("worktree directory is missing") }
        if initialWorktree.state == .running, let slot = initialWorktree.splitTree.allLeaves.first,
           let session = initialWorktree.paneSessions[slot] { return launcher.sessionName(for: session) }
        let slot = PaneSlotID()
        let session = PaneSessionID()
        try await terminals.start(spawn(session: session, path: path, command: command))
        let index = try indices(path)
        // Pane startup may accept attention or pin updates while suspended.
        var worktree = state.repos[index.repo].worktrees[index.worktree]
        worktree.recordPaneSession(session, for: slot)
        worktree.splitTree = SplitTree(root: .leaf(slot))
        worktree.focusedPaneSlotID = slot
        worktree.primaryPaneSlotID = slot
        worktree.state = .running
        let previous = state
        state.repos[index.repo].worktrees[index.worktree] = worktree
        state.selectedWorktreePath = path
        do { try save() } catch {
            state = previous
            try? await terminals.kill(launcher.sessionName(for: session))
            throw error
        }
        await refreshPortBindings()
        return launcher.sessionName(for: session)
    }

    public func splitPane(target: String, direction: PaneControlRequest.SplitDirection, command: String? = nil) async throws -> String {
        let (path, slot) = try resolve(target)
        try acquire(path)
        defer { busyPaths.remove(path) }
        let newSlot = PaneSlotID()
        let session = PaneSessionID()
        try await terminals.start(spawn(session: session, path: path, command: command))
        let index = try indices(path)
        var worktree = state.repos[index.repo].worktrees[index.worktree]
        worktree.recordPaneSession(session, for: newSlot)
        let axis: SplitDirection = direction == .left || direction == .right ? .horizontal : .vertical
        worktree.splitTree = direction == .left || direction == .up
            ? worktree.splitTree.insertingBefore(newSlot, at: slot, direction: axis)
            : worktree.splitTree.inserting(newSlot, at: slot, direction: axis)
        worktree.focusedPaneSlotID = newSlot
        let previous = state
        state.repos[index.repo].worktrees[index.worktree] = worktree
        do { try save() } catch {
            state = previous
            try? await terminals.kill(launcher.sessionName(for: session))
            throw error
        }
        await refreshPortBindings()
        return launcher.sessionName(for: session)
    }

    public func closePane(target: String) async throws {
        let (path, slot) = try resolve(target)
        try acquire(path)
        defer { busyPaths.remove(path) }
        try await terminals.kill(target)
        let index = try indices(path)
        var worktree = state.repos[index.repo].worktrees[index.worktree]
        worktree.splitTree = worktree.splitTree.removing(slot)
        worktree.clearPaneSession(for: slot)
        worktree.paneAttention[slot] = nil
        if worktree.focusedPaneSlotID == slot { worktree.focusedPaneSlotID = worktree.splitTree.allLeaves.first }
        _ = worktree.ensurePrimaryPane()
        if worktree.splitTree.leafCount == 0 { worktree.state = .closed }
        state.repos[index.repo].worktrees[index.worktree] = worktree
        try save()
        await refreshPortBindings()
    }

    public func createWorktree(repository: String, name: String, branch: String,
        existing: Bool = false, remoteOnly: Bool = false, base: String? = nil, command: String? = nil,
        agent: TeamHookRuntime? = nil, prompt: String? = nil, callerPath: String? = nil) async throws -> (path: String, session: String) {
        guard let repo = state.repos.first(where: { $0.path == repository }) else { throw HostRuntimeError.notFound("repository is not registered") }
        if let error = WorktreeCreationInput.validationError(worktreeName: name, branchName: branch, existing: existing, base: base) {
            throw HostRuntimeError.invalid(error)
        }
        if let error = WorktreeAgentLaunchCommand.validationError(prompt: prompt) { throw HostRuntimeError.invalid(error) }
        let container = (repo.path as NSString).appendingPathComponent(".worktrees")
        let path = (container as NSString).appendingPathComponent(name)
        guard path.hasPrefix(container + "/"), !FileManager.default.fileExists(atPath: path), state.worktree(forPath: path) == nil else {
            throw HostRuntimeError.invalid("worktree destination already exists or is invalid")
        }
        // Reject existing symlink parents, including .worktrees itself.
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor.hasPrefix(container) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw HostRuntimeError.invalid("worktree destination contains a symlink")
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            if parent == ancestor { break }
            ancestor = parent
        }
        try acquire(path)
        defer { busyPaths.remove(path) }
        if let agent { try await agentSetup.ensure(agent) }
        let launch = try WorktreeAgentLaunchCommand.prepare(agent: agent, prompt: prompt, exactCommand: command,
            promptDirectory: configuration.stateDirectory.appendingPathComponent("agent-launch-prompts"))
        do {
            let selection: BranchSelection = existing ? .useExisting(name: branch, source: remoteOnly ? .remoteOnly : .local) : .createNew(name: branch)
            try await GitWorktreeAdd.add(repoPath: repo.path, worktreePath: path, branch: selection,
                startPoint: existing ? nil : base, startPointResolutionPath: callerPath ?? repo.path)
        } catch { launch.discardPromptFile(); throw error }
        guard let ri = state.repos.firstIndex(where: { $0.path == repo.path }) else { throw HostRuntimeError.notFound("repository removed during creation") }
        state.repos[ri].worktrees.append(WorktreeEntry(path: path, branch: branch))
        try save() // Retain successful Git creation even if shell startup fails.
        if let agent {
            try WorktreeAgentLaunchCommand.saveInitialPrompt(prompt, runtime: agent, repo: repo,
                worktreePath: path, branchName: branch, inbox: inbox)
        }
        do { return (path, try await openUnlocked(path, command: launch.command)) }
        catch { launch.discardPromptFile(); throw error }
    }

    public func deleteWorktree(_ path: String, force: Bool = false, allowPinned: Bool = false) async throws {
        let index = try indices(path)
        let repo = state.repos[index.repo]
        let worktree = repo.worktrees[index.worktree]
        guard path != repo.path else { throw HostRuntimeError.invalid("cannot delete the main checkout") }
        guard !worktree.isPinned || allowPinned else { throw HostRuntimeError.invalid("unpin the worktree before deleting it") }
        try acquire(path)
        defer { busyPaths.remove(path) }
        try await GitWorktreeRemove.remove(repoPath: repo.path, worktreePath: path, force: force)
        for session in worktree.paneSessions.values { try? await terminals.kill(launcher.sessionName(for: session)) }
        state.removeWorktree(atPath: path)
        try save()
        await refreshPortBindings()
    }

    public func shutdown() throws { deliveryTask?.cancel(); deliveryTask = nil; maintenance?.stop(); maintenance = nil; try save(); terminals.detachAll() }

    public func spawn(session: PaneSessionID, path: String, command: String? = nil) -> ZmxSpawnConfiguration {
        var environment = ProcessInfo.processInfo.environment
        for key in ZmxLauncher.leakyEnvKeysToStripAtAppLaunch { environment.removeValue(forKey: key) }
        #if os(Linux)
        environment["PATH"] = HostAgentEnvironment.path(
            inheritedPath: environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin", home: NSHomeDirectory())
        #endif
        environment["SHELL"] = configuration.shell
        environment["GRAFTTY_STATE_DIR"] = configuration.stateDirectory.path
        let config = ZmxSpawnConfiguration.make(launcher: launcher, paneSessionID: session, worktreePath: path,
            socketPath: configuration.socketPath, processEnv: environment,
            bundleURL: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
            ghosttyResourcesDir: nil, agentHooksDisabled: false, agentHooksRoot: configuration.hooksDirectory,
            initialCommand: command)
        if let command, !config.runsInitialCommand {
            let script = command + "\nexec " + WorktreeAgentLaunchCommand.shellLiteral(configuration.shell) + " -l"
            return ZmxSpawnConfiguration(sessionName: config.sessionName,
                argv: [launcher.executable.path, "attach", config.sessionName, "/bin/sh", "-c", script],
                env: config.env, workingDirectory: config.workingDirectory, shellReadySignalAvailable: false)
        }
        return config
    }

    public func resolve(_ target: String) throws -> (path: String, slot: PaneSlotID) {
        for repo in state.repos {
            for worktree in repo.worktrees where worktree.state == .running {
                if let slot = worktree.paneSlot(forSessionName: target), worktree.splitTree.containsLeaf(slot) {
                    return (worktree.path, slot)
                }
            }
        }
        throw HostRuntimeError.notFound("pane session is not registered: \(target)")
    }

    public func sessionConfiguration(_ target: String) throws -> ZmxSpawnConfiguration {
        let (path, slot) = try resolve(target)
        guard let session = state.worktree(forPath: path)?.paneSessions[slot] else { throw HostRuntimeError.notFound("pane session is missing") }
        return spawn(session: session, path: path)
    }

    public func sessions() -> [SessionInfo] {
        state.repos.flatMap { repo in
            repo.worktrees.filter { $0.state == .running }.flatMap { worktree in
                worktree.splitTree.allLeaves.compactMap { slot in
                    worktree.paneSessions[slot].map { SessionInfo(name: launcher.sessionName(for: $0), worktreePath: worktree.path,
                        repoDisplayName: repo.displayName, worktreeDisplayName: worktree.displayName(amongSiblingPaths: repo.worktrees.map(\.path))) }
                }
            }
        }
    }

    public func snapshot() -> [WorktreePanes] {
        state.repos.flatMap { repo in
            repo.worktrees.map { worktree in
                WorktreePanes(path: worktree.path, displayName: worktree.displayName(amongSiblingPaths: repo.worktrees.map(\.path)),
                    repoDisplayName: repo.displayName, repositoryID: repo.path, displayBranch: worktree.displayBranch,
                    state: worktree.state.wireState, isMainCheckout: worktree.path == repo.path, prBadge: nil, stats: worktreeStats[worktree.path],
                    attentionText: worktree.attention?.text, attentionSource: worktree.attention?.source,
                    attentionTimestamp: worktree.attention?.timestamp,
                    layout: worktree.state == .running ? worktree.splitTree.root.flatMap { layout($0, worktree: worktree) } : nil,
                    origin: origin, sidebar: SidebarHostNavigation.metadata(for: worktree, projectID: repo.path,
                        folders: [], repositoryPath: repo.path), portBindings: wirePortBindings(for: worktree))
            }
        }
    }

    private func layout(_ node: SplitTree.Node, worktree: WorktreeEntry) -> PaneLayoutNode? {
        switch node {
        case .leaf(let slot):
            guard let session = worktree.paneSessions[slot] else { return nil }
            let name = launcher.sessionName(for: session)
            let attention = worktree.paneAttention[slot]
            return .leaf(sessionName: name, title: worktree.paneTitleMetadata[slot]?.title ?? "shell",
                attentionText: attention?.text, isBusy: busyAgents.contains(name), attentionSource: attention?.source,
                attentionTimestamp: attention?.timestamp)
        case .split(let split):
            guard let left = layout(split.left, worktree: worktree), let right = layout(split.right, worktree: worktree) else { return nil }
            return .split(direction: split.direction == .horizontal ? .horizontal : .vertical, ratio: split.ratio, left: left, right: right)
        }
    }
}
