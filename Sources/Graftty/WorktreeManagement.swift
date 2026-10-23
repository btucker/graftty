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
    /// This Mac, as the owner of the repositories it lists. Resolved on
    /// first use, so a transport that never lists repositories (the control
    /// socket) does not read the device-ID store or the host name.
    private(set) lazy var localOrigin: WorktreeOrigin = SidebarHostController.shared.owner

    init(appState: Binding<AppState>, terminalManager: TerminalManager, teamInbox: TeamInbox,
         teamEventDispatcher: TeamEventDispatcher, worktreeMonitor: WorktreeMonitor,
         statsStore: WorktreeStatsStore, prStatusStore: PRStatusStore, remoteBranchStore: RemoteBranchStore,
         worktreeCreations: CLIWorktreeCreationStore, worktreeRemovals: CLIWorktreeRemovalStore,
         localOrigin: WorktreeOrigin? = nil) {
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
    /// client attaches to exists. `entryPoint` chooses when the terminal
    /// backend starts (`AddWorktreeFlow.terminalStartTiming`).
    func create(
        repoPath: String,
        worktreeName: String,
        branch: BranchSelection,
        entryPoint: AddWorktreeFlow.CreationEntryPoint
    ) async -> Result<AddWorktreeFlow.Result, WorktreeCreationError> {
        await AddWorktreeFlow.add(
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

    /// Removes a linked worktree (`DeleteWorktreeFlow`). Confirmation is the
    /// caller's job.
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
                branches: includingBranches ? branches(of: repo) : []
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

    /// The worktree a zmx session's pane belongs to, as recorded when the
    /// pane's session was mapped. Web attaches start their shell there, so
    /// a worktree without its directory (stale panes stay live, GIT-3.4)
    /// resolves to nil: the attach child cannot `chdir` into it (WEB-4.12).
    func worktreePath(forSessionName sessionName: String) -> String? {
        guard let path = terminalManager.worktreePath(forSessionName: sessionName),
              appState.wrappedValue.worktree(forPath: path)?.state.hasOnDiskWorktree == true else { return nil }
        return path
    }

    // MARK: - `graftty worktree add` / `remove`

    var state: AppState {
        get { appState.wrappedValue }
        set { appState.wrappedValue = newValue }
    }

    var agentPromptDirectory: URL {
        AppState.defaultDirectory.appendingPathComponent("agent-launch-prompts", isDirectory: true)
    }

    func stateDidChange() { GrafttyApp.persistAppState(appState.wrappedValue) }

    func saveStateNow() throws { try GrafttyApp.persistAppStateSynchronously(appState.wrappedValue) }

    /// Phase two of a CLI creation: the backend starts with no view mounted.
    func finishWorktreeCreation(_ plan: CLIWorktreeCreationPlan) async -> String? {
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
        case .success: return nil
        case .failure(let error): return error.operationFailureMessage
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
            self = .error(code: "create-failed", message: error.userMessage ?? "could not create worktree",
                          forceAllowed: false, shortStatus: nil)
        }
    }

    /// The paired-device envelope's `delete`.
    init(removal result: Result<WorktreeRemovalOutcome, WorktreeRemovalError>) {
        switch result {
        case .success(let outcome): self = .deleted(dismissed: outcome.dismissed)
        case .failure(.notFound):
            self = .error(code: "not-found", message: "unknown worktree", forceAllowed: false, shortStatus: nil)
        case .failure(.mainCheckoutRejected):
            self = .error(code: "invalid", message: "cannot delete the main checkout", forceAllowed: false, shortStatus: nil)
        case .failure(.gitFailedForceable(let stderr, let status)):
            self = .error(code: "git-failed", message: stderr, forceAllowed: true, shortStatus: status)
        case .failure(.gitFailedFinal(let message)):
            self = .error(code: "git-failed", message: message, forceAllowed: false, shortStatus: nil)
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
