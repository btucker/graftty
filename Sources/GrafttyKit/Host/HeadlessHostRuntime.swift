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
    /// Captured before dispatch so tests can observe the actual presence read.
    @TaskLocal static var presenceRecordsReader: @Sendable (TeamPresenceStorage) throws -> [TeamPresenceRecord] = {
        try $0.listAll()
    }
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
    let devContainers: DevContainerPreparer
    let placements: HostPlacementLedger
    let skillTransfers: RemoteSkillTransferReceiver
    public var mcpProfiles: MCPProfileService?
    var placementTasks: [UUID: Task<Void, Never>] = [:]
    var isShuttingDown = false
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
    public internal(set) var hostResources: HostResourceSnapshot?
    public var origin: WorktreeOrigin?

    public init(configuration: HostConfiguration, terminals: (any HostTerminalDriver)? = nil,
                initialState: AppState? = nil, portScanner: PortScanner? = nil,
                agentSetup: HostAgentSetup? = nil, devContainers: DevContainerPreparer? = nil) throws {
        placements = try HostPlacementLedger(fileURL: configuration.stateDirectory.appendingPathComponent("placements.json"))
        skillTransfers = RemoteSkillTransferReceiver(directory: configuration.stateDirectory.appendingPathComponent("agent-skills"))
        self.devContainers = devContainers ?? DevContainerPreparer(profileDirectory: configuration.stateDirectory.appendingPathComponent("agent-profiles"))
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
        for record in placements.retainedRecords where record.state == .created && record.environment?.mcpConfigured == true {
            guard FileManager.default.fileExists(atPath: record.intent.worktreePath),
                  let grants = record.intent.devContainer?.mcpGrants else { continue }
            guard let mcpProfiles else { throw HostRuntimeError.invalid("Managed MCP profile service is unavailable") }
            _ = try mcpProfiles.prepare(operationID: record.operationID, configurations: grants.map { .init(parent: record.owner, scope: $0) })
        }
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
        existing: Bool = false, remoteOnly: Bool = false, command: String? = nil, relativeGitPaths: Bool = false,
        prepareEnvironment: (@MainActor @Sendable (String) async throws -> Void)? = nil) async throws -> (path: String, session: String) {
        guard !isShuttingDown, placements.drain == nil else { throw HostRuntimeError.busy("Host is shutting down or draining") }
        guard let repo = state.repos.first(where: { $0.path == repository }) else { throw HostRuntimeError.notFound("repository is not registered") }
        // Validate the name before probing the destination it names.
        if let error = WorktreeCreationInput.validationError(worktreeName: name, branchName: branch, existing: existing) {
            throw HostRuntimeError.invalid(error)
        }
        let selection: BranchSelection = existing ? .useExisting(name: branch, source: remoteOnly ? .remoteOnly : .local) : .createNew(name: branch)
        let path = AppState.linkedWorktreePath(repoPath: repo.path, worktreeName: name)
        // The paired-client envelope has always reported a tracked
        // destination as an invalid one.
        if state.worktree(forPath: path) != nil { throw HostRuntimeError.invalid("worktree destination already exists or is invalid") }
        if let error = creationDestinationError(worktreePath: path, repo: repo) { throw HostRuntimeError.invalid(error) }
        switch state.insertCreatingWorktree(repoPath: repo.path, worktreeName: name, branch: selection) {
        case .success: try? save()
        case .failure(let error): throw HostRuntimeError.invalid(error.userMessage ?? "could not begin worktree creation")
        }
        let session = try await finishCreatingWorktree(CLIWorktreeCreationPlan(repoPath: repo.path, worktreePath: path,
            branch: selection, base: nil, initialCommand: command, agentRuntime: nil),
            relativeGitPaths: relativeGitPaths, prepareEnvironment: prepareEnvironment)
        return (path, session)
    }

    /// Rejects destinations the placeholder check cannot see: an existing
    /// directory or a symlink anywhere under `.worktrees`.
    func creationDestinationError(worktreePath path: String, repo: RepoEntry) -> String? {
        guard !isShuttingDown, placements.drain == nil else { return "Host is shutting down or draining" }
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
    func finishCreatingWorktree(_ plan: CLIWorktreeCreationPlan, relativeGitPaths: Bool = false,
        prepareEnvironment: (@MainActor @Sendable (String) async throws -> Void)? = nil) async throws -> String {
        let path = plan.worktreePath
        do { try acquire(path) } catch {
            _ = state.removeWorktree(atPath: path)
            try? save()
            throw error
        }
        defer { busyPaths.remove(path) }
        do {
            if let agent = plan.agentRuntime { try await agentSetup.ensure(agent) }
            guard !isShuttingDown, placements.drain == nil else { throw HostRuntimeError.busy("Host is shutting down or draining") }
            let startPoint = await GitWorktreeAdd.startPoint(for: plan.branch, base: plan.base, repoPath: plan.repoPath)
            try await GitWorktreeAdd.add(repoPath: plan.repoPath, worktreePath: path, branch: plan.branch, startPoint: startPoint, relativePaths: relativeGitPaths)
        } catch {
            _ = state.removeWorktree(atPath: path)
            try? save()
            throw error
        }
        do {
            try save() // Retain successful Git creation even if shell startup fails.
        } catch {
            closeCreatingRow(path)
            throw error
        }
        if let repo = state.repo(forWorktreePath: path) {
            TeamMembershipEvents.fireJoined(repo: repo, joinerWorktreePath: path, dispatcher: controlPlatform.teamEventDispatcher)
        }
        do {
            try Task.checkCancellation()
            try await prepareEnvironment?(path)
            try Task.checkCancellation()
            guard !isShuttingDown, placements.drain == nil else { throw HostRuntimeError.busy("Host is shutting down or draining") }
            return try await openUnlocked(path, command: plan.initialCommand)
        } catch {
            closeCreatingRow(path)
            throw error
        }
    }

    /// A worktree Git created whose first pane did not start stays registered, closed.
    private func closeCreatingRow(_ path: String) {
        guard let index = state.indices(forWorktreePath: path),
              state.repos[index.repo].worktrees[index.worktree].state == .creating else { return }
        state.repos[index.repo].worktrees[index.worktree].state = .closed
        try? save()
    }

    /// Removes a linked worktree. The row reads `.deleting` while Git runs
    /// and gets its prior state back if Git refuses. Git's and the final
    /// save's errors are thrown unchanged, so each caller keeps its own wire:
    /// `graftty worktree remove` maps them like the Mac's `DeleteWorktreeFlow`
    /// (`HeadlessWorktreeLifecycle`), the paired-client envelope as it always
    /// has. `pruneVanished` is GIT-4.13: when Git refuses a worktree whose
    /// directory is already gone, prune Git's record and report a dismissal.
    func removeWorktree(_ path: String, force: Bool, pruneVanished: Bool = false) async throws -> WorktreeRemovalOutcome {
        let index = try indices(path)
        let repo = state.repos[index.repo]
        let worktree = repo.worktrees[index.worktree]
        guard path != repo.path else { throw HostRuntimeError.invalid("cannot delete the main checkout") }
        try acquire(path)
        defer { busyPaths.remove(path) }
        let placement = placements.record(for: path)
        let containerID: String?
        if let placement, placement.intent.devContainer != nil {
            // Refuse an already-dirty deletion before interrupting its running processes.
            if !force, FileManager.default.fileExists(atPath: path),
               !(try await GitRunner.run(args: ["status", "--porcelain"], at: path)).isEmpty {
                throw GitWorktreeRemove.Error.gitFailed(exitCode: 128, stderr: "Worktree contains modified or untracked files; use --force to delete it")
            }
            if let retained = placement.environment?.containerID { containerID = retained }
            else { containerID = try await devContainers.findPlacementContainer(operationID: placement.operationID, workspace: path) }
        } else { containerID = nil }
        let restartContainer: Bool
        if let containerID { restartContainer = try await devContainers.stopForDeletion(containerID: containerID) }
        else { restartContainer = false }
        var priorState = worktree.state
        var dismissed = false
        do {
            // Preflight and Docker suspend. Another worktree can be deleted or
            // reordered while this path is leased, invalidating its old index.
            let current = try indices(path)
            priorState = state.repos[current.repo].worktrees[current.worktree].state
            state.repos[current.repo].worktrees[current.worktree].state = .deleting
            try? save()
            try await GitWorktreeRemove.remove(repoPath: repo.path, worktreePath: path, force: force)
        } catch GitWorktreeRemove.Error.gitFailed where pruneVanished && !FileManager.default.fileExists(atPath: path) {
            try? await GitWorktreePrune.run(repoPath: repo.path)
            dismissed = true
        } catch {
            let deletionError = error
            if let current = state.indices(forWorktreePath: path) {
                state.repos[current.repo].worktrees[current.worktree].state = priorState
                try? save()
            }
            if restartContainer, let containerID {
                do {
                    // Restore the environment even if the requesting channel was
                    // canceled. This compensation still uses the Docker timeout.
                    try await Task { [devContainers] in
                        try await devContainers.restartAfterRejectedDeletion(containerID: containerID)
                    }.value
                }
                catch { throw HostRuntimeError.invalid("Worktree deletion failed: \(deletionError). Container restart also failed: \(error)") }
            }
            throw error
        }
        if let placement { await mcpProfiles?.stop(operationID: placement.operationID) }
        for session in worktree.paneSessions.values { try? await terminals.kill(launcher.sessionName(for: session)) }
        worktreeStats[path] = nil
        state.removeWorktree(atPath: path)
        if let repo = state.repo(forWorktreePath: repo.path) {
            TeamMembershipEvents.fireLeft(repo: repo, leaverBranch: worktree.branch, leaverPath: path,
                reason: .removed, dispatcher: controlPlatform.teamEventDispatcher)
        }
        try save()
        try placements.releaseDeletedWorktree(path)
        await refreshPortBindings()
        if let containerID, let placement {
            do { try await devContainers.removeStoppedContainer(containerID: containerID) }
            catch {
                try placements.recordCleanupFailure(operationID: placement.operationID, containerID: containerID, message: String(describing: error))
                throw error
            }
        }
        return WorktreeRemovalOutcome(dismissed: dismissed)
    }

    public func deleteWorktree(_ path: String, force: Bool = false, allowPinned: Bool = false) async throws {
        let index = try indices(path)
        let repo = state.repos[index.repo]
        guard path != repo.path else { throw HostRuntimeError.invalid("cannot delete the main checkout") }
        guard !repo.worktrees[index.worktree].isPinned || allowPinned else {
            throw HostRuntimeError.invalid("unpin the worktree before deleting it")
        }
        _ = try await removeWorktree(path, force: force)
    }

    public func shutdown() async throws {
        isShuttingDown = true
        await skillTransfers.discardIncomplete()
        deliveryTask?.cancel(); deliveryTask = nil
        maintenance?.stop(); maintenance = nil
        let jobs = Array(placementTasks.values)
        for job in jobs { job.cancel() }
        for job in jobs { await job.value }
        await mcpProfiles?.stop()
        try save()
        terminals.detachAll()
    }

    public func spawn(session: PaneSessionID, path: String, command: String? = nil) -> ZmxSpawnConfiguration {
        let command = placements.environment(for: path).map { DevContainerPreparer.shellCommand(for: $0, command: command) } ?? command
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
