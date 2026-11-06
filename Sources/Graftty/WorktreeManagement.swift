import Foundation
import SwiftUI
import GrafttyKit
import GrafttyProtocol

/// The Mac's worktree operations behind every transport: the web client's
/// REST routes, the paired-device worktree-management envelope, and the
/// control socket's `graftty worktree add` / `remove`
/// (`CLIWorktreeCreationRequestHandler`, `CLIWorktreeRemovalRequestHandler`).
/// Each transport keeps only a map from these results to its wire.
///
/// Holds no state of its own beyond this Mac's origin: the model, caches and
/// operation stores belong to the app, so every instance acts on the same
/// worktrees.
@MainActor
final class WorktreeManagement: CLIWorktreeCreationPlatform, CLIWorktreeRemovalPlatform {
    let appState: Binding<AppState>
    let terminalManager: TerminalManager
    let teamInbox: TeamInbox
    let teamEventDispatcher: TeamEventDispatcher
    let worktreeMonitor: WorktreeMonitor
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    let remoteBranchStore: RemoteBranchStore
    let worktreeCreations: CLIWorktreeCreationStore
    let worktreeRemovals: CLIWorktreeRemovalStore
    private let promptDirectory: URL?
    /// This Mac, as the owner of the repositories it lists. Resolved on
    /// first use, so a transport that never lists repositories (the control
    /// socket) does not read the device-ID store or the host name.
    private(set) lazy var localOrigin: WorktreeOrigin = SidebarHostController.shared.owner

    init(appState: Binding<AppState>, terminalManager: TerminalManager, teamInbox: TeamInbox,
         teamEventDispatcher: TeamEventDispatcher, worktreeMonitor: WorktreeMonitor,
         statsStore: WorktreeStatsStore, prStatusStore: PRStatusStore, remoteBranchStore: RemoteBranchStore,
         worktreeCreations: CLIWorktreeCreationStore, worktreeRemovals: CLIWorktreeRemovalStore,
         localOrigin: WorktreeOrigin? = nil, agentPromptDirectory: URL? = nil) {
        self.appState = appState
        self.terminalManager = terminalManager
        self.teamInbox = teamInbox
        self.teamEventDispatcher = teamEventDispatcher
        self.worktreeMonitor = worktreeMonitor
        self.statsStore = statsStore
        self.prStatusStore = prStatusStore
        self.remoteBranchStore = remoteBranchStore
        self.worktreeCreations = worktreeCreations
        self.worktreeRemovals = worktreeRemovals
        self.promptDirectory = agentPromptDirectory
        if let localOrigin { self.localOrigin = localOrigin }
    }

    convenience init(appState: Binding<AppState>, terminalManager: TerminalManager, services: AppServices,
                     localOrigin: WorktreeOrigin? = nil) {
        self.init(
            appState: appState, terminalManager: terminalManager, teamInbox: services.teamInbox,
            teamEventDispatcher: services.teamEventDispatcher, worktreeMonitor: services.worktreeMonitor,
            statsStore: services.statsStore, prStatusStore: services.prStatusStore,
            remoteBranchStore: services.remoteBranchStore,
            worktreeCreations: services.cliWorktreeCreations, worktreeRemovals: services.cliWorktreeRemovals,
            localOrigin: localOrigin
        )
    }

    /// Creates a worktree and its first pane, returning once the session a
    /// client attaches to exists. Agent creation starts its backend before
    /// returning; `entryPoint` controls shell-only terminal startup.
    func create(
        repoPath: String,
        worktreeName: String,
        branch: BranchSelection,
        entryPoint: AddWorktreeFlow.CreationEntryPoint,
        agent: WorktreeAgentConfiguration = .init(),
        launchAgent: Bool = true
    ) async -> Result<AddWorktreeFlow.Result, WorktreeCreationError> {
        if launchAgent {
            switch await beginCreation(repoPath: repoPath, worktreeName: worktreeName, branch: branch, agent: agent) {
            case .failure(let error): return .failure(error)
            case .success(let status): return await waitForCreation(status)
            }
        }
        return await AddWorktreeFlow.add(
            repoPath: repoPath,
            worktreeName: worktreeName,
            branch: branch,
            appState: appState,
            worktreeMonitor: worktreeMonitor,
            statsStore: statsStore,
            terminalManager: terminalManager,
            teamEventDispatcher: teamEventDispatcher,
            entryPoint: entryPoint
        )
    }

    /// Admission is quick; Git and agent startup belong to the shared host
    /// operation, so dismissing a sheet cannot cancel creation.
    func beginCreation(repoPath: String, worktreeName: String, branch: BranchSelection,
                       agent: WorktreeAgentConfiguration) async -> Result<WorktreeCreateStatus, WorktreeCreationError> {
        var candidate = state
        if case .failure(let error) = candidate.insertCreatingWorktree(repoPath: repoPath, worktreeName: worktreeName, branch: branch) {
            return .failure(error)
        }
        let explicit = agent.provider.flatMap(TeamHookRuntime.init(rawValue:))
        if agent.provider != nil, explicit == nil { return .failure(.invalidInput("Unknown agent provider.")) }
        let provider: TeamHookRuntime
        do { provider = try AgentPreference.resolve(explicit: explicit, configured: defaultAgentProvider) }
        catch { return .failure(.invalidInput(error.localizedDescription)) }
        let source: BranchSelection.ExistingSource?
        if case .useExisting(_, let existing) = branch { source = existing } else { source = nil }
        let operationID = UUID().uuidString
        let request = CreateWorktreeRequest(callerWorktree: repoPath,
            worktreeName: worktreeName, branchName: branch.branchName, existing: source != nil, base: nil,
            command: nil, agentRuntime: explicit, agentPrompt: agent.initialPrompt,
            operationID: operationID, selectTab: false, existingBranchSource: source)
            .withPrimaryAgent(provider: provider, operationID: operationID)
        let response = await CLIWorktreeCreationRequestHandler.begin(request,
            creationOrigin: .init(date: Date(), source: .user), platform: self)
        switch response {
        case .worktreeCreate(let status): return .success(status)
        case .error(let message): return .failure(.invalidInput(message))
        default: return .failure(.discoveryFailed("Unexpected worktree creation response."))
        }
    }

    func waitForCreation(_ accepted: WorktreeCreateStatus) async -> Result<AddWorktreeFlow.Result, WorktreeCreationError> {
        while let current = worktreeCreationStatus(operationID: accepted.operationID) {
            switch current.state {
            case .pending:
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return .failure(.discoveryFailed("Creation continues on the host.")) }
            case .failed:
                if let error = worktreeCreations.failure(operationID: accepted.operationID) {
                    return .failure(error)
                }
                let message = current.error ?? "Could not create worktree."
                return .failure(.gitFailed(message))
            case .ready:
                guard let worktree = state.worktree(forPath: current.worktreePath),
                      let session = worktree.agents.first?.paneSessionID else {
                    return .failure(.discoveryFailed("The agent did not return a session."))
                }
                return .success(.init(sessionName: ZmxLauncher.sessionName(for: session), worktreePath: current.worktreePath))
            }
        }
        return .failure(.discoveryFailed("The creation operation is no longer available."))
    }

    /// Removes a linked worktree (`DeleteWorktreeFlow`, which refuses a row
    /// whose creation or removal is still running, WEB-7.16). Confirmation
    /// is the caller's job.
    func delete(worktreePath: String, force: Bool) async -> Result<WorktreeRemovalOutcome, WorktreeRemovalError> {
        await DeleteWorktreeFlow.delete(
            worktreePath: worktreePath,
            force: force,
            appState: appState,
            terminalManager: terminalManager,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            teamEventDispatcher: teamEventDispatcher
        )
    }

    /// Why a default-branch pull did not run or failed.
    enum DefaultBranchPullError: Error {
        case repositoryNotTracked
        /// The main checkout is not on origin's default branch or not behind it.
        case notBehind
        case pullFailed(any Error)
    }

    /// Fast-forwards a repository's main checkout to origin's default
    /// branch, then refreshes its divergence stats.
    func pullDefaultBranch(repoPath: String) async -> Result<Void, DefaultBranchPullError> {
        guard let repo = appState.wrappedValue.repos.first(where: { $0.path == repoPath }) else {
            return .failure(.repositoryNotTracked)
        }
        guard let status = defaultBranchStatus(for: repo, stats: statsStore.stats[repo.path]) else {
            return .failure(.notBehind)
        }
        do {
            try await GitDefaultBranchPull.pull(repoPath: repoPath, branchName: status.branchName)
        } catch {
            return .failure(.pullFailed(error))
        }
        if let repo = appState.wrappedValue.repos.first(where: { $0.path == repoPath }) {
            let branch = repo.worktrees.first(where: { $0.path == repo.path })?.branch ?? ""
            statsStore.refresh(worktreePath: repo.path, repoPath: repo.path, branch: branch)
        }
        return .success(())
    }

    /// This Mac's repositories, as the sidebar lists them. Branch choices
    /// (with mounted worktrees and pull requests) are built only when asked
    /// for, since the web client's picker does not show them.
    func repositories(includingBranches: Bool) -> [RemoteRepositoryInfo] {
        appState.wrappedValue.repos.map { repo in
            RemoteRepositoryInfo(
                id: repo.path,
                displayName: repo.displayName,
                origin: localOrigin,
                defaultBranchStatus: defaultBranchStatus(for: repo, stats: statsStore.stats[repo.path]),
                branches: includingBranches ? branches(of: repo) : [],
                originKey: repo.originKey
            )
        }
    }

    private func branches(of repo: RepoEntry) -> [RemoteRepositoryInfo.Branch] {
        var mounted: [String: String] = [:]
        for worktree in repo.worktrees where worktree.state.hasOnDiskWorktree {
            mounted[worktree.branch] = worktree.path
        }
        return BranchPickerViewModel.entries(
            branchSnapshot: remoteBranchStore.branchesByRepo[repo.path] ?? RemoteBranchSnapshot(),
            mountedBranchToPath: mounted,
            prsByBranch: prStatusStore.prsByRepoBranch[repo.path] ?? [:],
            filterText: ""
        ).map { branch in
            RemoteRepositoryInfo.Branch(
                name: branch.name,
                source: branch.source == .local ? .local : .remoteOnly,
                lastCommitDate: branch.lastCommitDate,
                mountedWorktreeID: branch.mountedWorktreePath,
                pullRequest: branch.pr.map { .init(number: $0.number, title: $0.title) }
            )
        }
    }

    /// The directory a web attach to `sessionName` starts in: the running
    /// worktree that owns the pane now. `TerminalManager` maps the session to
    /// its pane without scanning every leaf; the path comes from the model,
    /// because the one `TerminalManager` recorded with the pane goes stale
    /// when a repository is relocated (WEB-4.13). A stale worktree's panes
    /// stay live (GIT-3.4) but have no directory to start in (WEB-4.12).
    func worktreePath(forSessionName sessionName: String) -> String? {
        guard let pane = terminalManager.paneID(forSessionName: sessionName).map(PaneSlotID.init(id:)) else { return nil }
        for repo in appState.wrappedValue.repos {
            for worktree in repo.worktrees where worktree.state == .running && worktree.splitTree.containsLeaf(pane) {
                return worktree.paneSessions[pane].map(ZmxLauncher.sessionName(for:)) == sessionName ? worktree.path : nil
            }
        }
        return nil
    }

    // MARK: - `graftty worktree add` / `remove`

    var state: AppState {
        get { appState.wrappedValue }
        set { appState.wrappedValue = newValue }
    }

    var agentPromptDirectory: URL {
        promptDirectory ?? AppState.defaultDirectory.appendingPathComponent("agent-launch-prompts", isDirectory: true)
    }

    func stateDidChange() { GrafttyApp.persistAppState(appState.wrappedValue) }

    func saveStateNow() throws { try GrafttyApp.persistAppStateSynchronously(appState.wrappedValue) }

    func creationDestinationError(worktreePath: String, repo: RepoEntry) -> String? {
        AddWorktreeFlow.creationDestinationError(worktreePath: worktreePath, repo: repo)?.userMessage
    }

    func creationDidBegin(repoPath: String, worktreePath: String, operationID: String) {
        guard let repo = state.repos.first(where: { $0.path == repoPath }) else { return }
        AddWorktreeFlow.recordCreationBaseline(repo: repo, operationID: operationID)
    }

    /// Phase two of a CLI creation: the backend starts with no view mounted.
    func finishWorktreeCreation(_ plan: CLIWorktreeCreationPlan) async -> String? {
        let operationID = state.worktree(forPath: plan.worktreePath)?.creationProgress?.operationID
        let result = await AddWorktreeFlow.finishCreate(
            repoPath: plan.repoPath,
            worktreePath: plan.worktreePath,
            branch: plan.branch,
            base: plan.base,
            appState: appState,
            worktreeMonitor: worktreeMonitor,
            statsStore: statsStore,
            terminalManager: terminalManager,
            teamEventDispatcher: teamEventDispatcher,
            initialCommand: plan.initialCommand,
            terminalStartTiming: AddWorktreeFlow.terminalStartTiming(for: .cli)
        )
        switch result {
        case .success:
            if plan.selectTab == true, let provider = plan.agentRuntime,
               let tree = state.worktree(forPath: plan.worktreePath), let slot = tree.firstPane,
               let session = tree.paneSessions[slot] {
                AgentNotificationActivation.shared.enqueue(.init(runtime: provider, worktreePath: plan.worktreePath,
                    sessionID: "", paneSessionName: ZmxLauncher.sessionName(for: session), attentionTimestamp: Date()))
            }
            return nil
        case .failure(let error):
            if let operationID { worktreeCreations.recordFailure(operationID: operationID, error: error) }
            return error.operationFailureMessage
        }
    }

    func wakeWorktree(_ path: String) -> Bool { terminalManager.wakeWorktree(path) }

    func removeWorktree(_ path: String, force: Bool) async -> Result<WorktreeRemovalOutcome, WorktreeRemovalError> {
        await delete(worktreePath: path, force: force)
    }
}

// MARK: - Transport maps

extension WebServer.CreateWorktreeOutcome {
    /// `POST /worktrees` (WEB-7.2).
    init(_ result: Result<AddWorktreeFlow.Result, WorktreeCreationError>) {
        switch result {
        case .success(let outcome):
            self = .success(.init(sessionName: outcome.sessionName, worktreePath: outcome.worktreePath))
        case .failure(let error):
            switch error {
            case .gitFailed(let message): self = .gitFailed(message)
            case .repoNotFound: self = .invalid("repository not tracked")
            case .pathCollision: self = .invalid("a worktree at that name already exists")
            case .branchAlreadyMounted: self = .conflict(message: error.userMessage ?? "branch already mounted")
            case .invalidInput(let message): self = .invalid(message)
            case .discoveryFailed(let message): self = .internalFailure(message)
            }
        }
    }
}

extension WebServer.DeleteWorktreeOutcome {
    /// `POST /worktrees/delete` (WEB-7.8).
    init(_ result: Result<WorktreeRemovalOutcome, WorktreeRemovalError>) {
        switch result {
        case .success(let outcome): self = .success(.init(dismissed: outcome.dismissed))
        case .failure(.notFound): self = .notFound("unknown worktree path")
        case .failure(.mainCheckoutRejected): self = .invalid("cannot delete the repo's main checkout")
        case .failure(.gitFailedForceable(let stderr, let status)): self = .gitFailedForceable(stderr: stderr, shortStatus: status)
        case .failure(.gitFailedFinal(let message)): self = .gitFailedFinal(message)
        }
    }
}

extension WorktreeManagementResponse {
    /// The paired-device envelope's `create`.
    init(creation result: Result<AddWorktreeFlow.Result, WorktreeCreationError>) {
        switch result {
        case .success(let outcome):
            self = .created(worktreeID: outcome.worktreePath, paneID: outcome.sessionName)
        case .failure(let error):
            self = .creationFailure(message: error.userMessage)
        }
    }
}

extension WebServer.PullDefaultBranchOutcome {
    /// `POST /repos/default-branch/pull` (WEB-7.12).
    init(_ result: Result<Void, WorktreeManagement.DefaultBranchPullError>) {
        switch result {
        case .success: self = .success(.init(ok: true))
        case .failure(.repositoryNotTracked): self = .invalid("repository not tracked")
        case .failure(.notBehind): self = .invalid("default checkout is not behind origin")
        case .failure(.pullFailed(GitDefaultBranchPull.Error.gitFailed(_, let stderr))): self = .gitFailed(stderr)
        case .failure(.pullFailed(let error)): self = .internalFailure("\(error)")
        }
    }
}

extension WebServer.RepoInfo {
    /// `GET /repos`. Local rows carry no branch list; relayed rows do.
    init(_ repository: RemoteRepositoryInfo, includingBranches: Bool) {
        self.init(path: repository.id, displayName: repository.displayName,
                  defaultBranchStatus: repository.defaultBranchStatus,
                  branches: includingBranches ? repository.branches : nil, origin: repository.origin)
    }
}

extension WorktreeManagementResponse {
    /// The paired-device envelope's `pullDefaultBranch`.
    init(defaultBranchPull result: Result<Void, WorktreeManagement.DefaultBranchPullError>) {
        switch result {
        case .success: self = .ok
        case .failure(.repositoryNotTracked), .failure(.notBehind):
            self = .error(code: "invalid", message: "default checkout is not behind origin", forceAllowed: false, shortStatus: nil)
        case .failure(.pullFailed(let error)):
            self = .error(code: "pull-failed", message: String(describing: error), forceAllowed: false, shortStatus: nil)
        }
    }
}
