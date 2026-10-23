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
    /// `graftty worktree add` / `remove` operations, shared with the Mac app.
    let worktreeCreations = CLIWorktreeCreationStore()
    let worktreeRemovals = CLIWorktreeRemovalStore()
    /// Provider hook busy/idle state per pane session, fed by the shared
    /// control core. The headless host does not poll `claude agents`.
    let agentLiveness = ClaudeSessionRegistry()
    lazy var controlPlatform = HeadlessControlPlatform(runtime: self)
    var deliveryTask: Task<Void, Never>?
    public var remoteTeamSender: (@MainActor @Sendable (TeamSendRequest) async -> ResponseMessage)?
    var maintenance: HostMaintenance?
    var repositoryBranches: [String: RemoteBranchSnapshot] = [:]
    var operationGeneration: UInt64 = 0
    var worktreeStats: [String: WorktreeWireStats] = [:]
    public var origin: WorktreeOrigin?

    public init(configuration: HostConfiguration, terminals: (any HostTerminalDriver)? = nil,
                initialState: AppState? = nil, portScanner: PortScanner? = nil,
                agentSetup: HostAgentSetup? = nil) throws {
        self.configuration = configuration
        self.portScanner = portScanner ?? PortScanner()
        self.agentSetup = agentSetup ?? HostAgentSetup(configuration: configuration)
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

    /// Creates a linked worktree and starts its first pane, as a paired
    /// client's worktree-management request does.
    public func createWorktree(repository: String, name: String, branch: String,
        existing: Bool = false, remoteOnly: Bool = false, command: String? = nil) async throws -> (path: String, session: String) {
        guard let repo = state.repos.first(where: { $0.path == repository }) else { throw HostRuntimeError.notFound("repository is not registered") }
        // Validate the name before probing the destination it names.
        if let error = WorktreeCreationInput.validationError(worktreeName: name, branchName: branch, existing: existing) {
            throw HostRuntimeError.invalid(error)
        }
        let selection: BranchSelection = existing ? .useExisting(name: branch, source: remoteOnly ? .remoteOnly : .local) : .createNew(name: branch)
        let path = AppState.linkedWorktreePath(repoPath: repo.path, worktreeName: name)
        if let error = creationDestinationError(worktreePath: path, repo: repo) { throw HostRuntimeError.invalid(error) }
        switch state.insertCreatingWorktree(repoPath: repo.path, worktreeName: name, branch: selection) {
        case .success: try? save()
        case .failure(let error): throw HostRuntimeError.invalid(error.userMessage ?? "could not begin worktree creation")
        }
        let session = try await finishCreatingWorktree(CLIWorktreeCreationPlan(repoPath: repo.path, worktreePath: path,
            branch: selection, base: nil, initialCommand: command, agentRuntime: nil))
        return (path, session)
    }

    /// Rejects destinations the placeholder check cannot see: an existing
    /// directory or a symlink anywhere under `.worktrees`.
    func creationDestinationError(worktreePath path: String, repo: RepoEntry) -> String? {
        let container = (repo.path as NSString).appendingPathComponent(".worktrees")
        guard path.hasPrefix(container + "/"), !FileManager.default.fileExists(atPath: path) else {
            return "worktree destination already exists or is invalid"
        }
        // Reject existing symlink parents, including .worktrees itself.
        var ancestor = (path as NSString).deletingLastPathComponent
        while ancestor.hasPrefix(container) {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                return "worktree destination contains a symlink"
            }
            let parent = (ancestor as NSString).deletingLastPathComponent
            if parent == ancestor { break }
            ancestor = parent
        }
        return nil
    }

    /// Phase two for a `.creating` row: Git, then the first pane. A Git
    /// failure drops the row; a pane failure leaves the worktree closed.
    func finishCreatingWorktree(_ plan: CLIWorktreeCreationPlan) async throws -> String {
        let path = plan.worktreePath
        do { try acquire(path) } catch {
            _ = state.removeWorktree(atPath: path)
            try? save()
            throw error
        }
        defer { busyPaths.remove(path) }
        do {
            if let agent = plan.agentRuntime { try await agentSetup.ensure(agent) }
            let startPoint = await GitWorktreeAdd.startPoint(for: plan.branch, base: plan.base, repoPath: plan.repoPath)
            try await GitWorktreeAdd.add(repoPath: plan.repoPath, worktreePath: path, branch: plan.branch, startPoint: startPoint)
        } catch {
            _ = state.removeWorktree(atPath: path)
            try? save()
            throw error is GitWorktreeAdd.Error ? WorktreeCreationError(gitAddFailure: error) : error
        }
        try? save() // Retain successful Git creation even if shell startup fails.
        if let repo = state.repo(forWorktreePath: path) {
            TeamMembershipEvents.fireJoined(repo: repo, joinerWorktreePath: path, dispatcher: controlPlatform.teamEventDispatcher)
        }
        do {
            return try await openUnlocked(path, command: plan.initialCommand)
        } catch {
            if let index = state.indices(forWorktreePath: path), state.repos[index.repo].worktrees[index.worktree].state == .creating {
                state.repos[index.repo].worktrees[index.worktree].state = .closed
                try? save()
            }
            throw error
        }
    }

    /// Removes a linked worktree with the Mac's `DeleteWorktreeFlow`
    /// semantics: the row reads `.deleting` while Git runs, a vanished
    /// directory is pruned, and a refusal `--force` could resolve carries
    /// `git status --short`.
    func removeWorktree(_ path: String, force: Bool) async -> Result<WorktreeRemovalOutcome, WorktreeRemovalError> {
        guard let index = state.indices(forWorktreePath: path) else { return .failure(.notFound) }
        let repo = state.repos[index.repo]
        let worktree = repo.worktrees[index.worktree]
        guard path != repo.path else { return .failure(.mainCheckoutRejected) }
        guard repo.isGitTracked else { return .failure(.gitFailedFinal("not a git repository")) }
        do { try acquire(path) } catch { return .failure(.gitFailedFinal(String(describing: error))) }
        defer { busyPaths.remove(path) }
        let priorState = worktree.state
        state.repos[index.repo].worktrees[index.worktree].state = .deleting
        try? save()
        let result = await GitWorktreeRemove.removeOrPrune(repoPath: repo.path, worktreePath: path, force: force)
        switch result {
        case .success: await finishRemoval(worktree, repoPath: repo.path)
        case .failure: restoreState(priorState, of: path)
        }
        return result
    }

    private func restoreState(_ prior: WorktreeState, of path: String) {
        guard let index = state.indices(forWorktreePath: path) else { return }
        state.repos[index.repo].worktrees[index.worktree].state = prior
        try? save()
    }

    private func finishRemoval(_ worktree: WorktreeEntry, repoPath: String) async {
        for session in worktree.paneSessions.values { try? await terminals.kill(launcher.sessionName(for: session)) }
        worktreeStats[worktree.path] = nil
        state.removeWorktree(atPath: worktree.path)
        try? save()
        if let repo = state.repo(forWorktreePath: repoPath) {
            TeamMembershipEvents.fireLeft(repo: repo, leaverBranch: worktree.branch, leaverPath: worktree.path,
                reason: .removed, dispatcher: controlPlatform.teamEventDispatcher)
        }
        await refreshPortBindings()
    }

    public func deleteWorktree(_ path: String, force: Bool = false) async throws {
        guard try !requireWorktree(path).isPinned else { throw HostRuntimeError.invalid("unpin the worktree before deleting it") }
        if case .failure(let error) = await removeWorktree(path, force: force) { throw error }
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
        let liveness = agentLiveness.livenessBySession
        return state.repos.flatMap { repo in
            let siblingPaths = repo.worktrees.map(\.path)
            return SidebarHostNavigation.displayedWorktrees(in: repo).map { worktree in
                WorktreePanes(entry: worktree, repo: repo, inputs: WorktreeRowInputs(
                    origin: origin, projectID: repo.path,
                    displayName: worktree.displayName(amongSiblingPaths: siblingPaths),
                    stats: worktreeStats[worktree.path],
                    paneTitles: worktree.paneTitleMetadata.compactMapValues(\.title), liveness: liveness,
                    portBindings: wirePortBindings(for: worktree)))
            }
        }
    }
}
