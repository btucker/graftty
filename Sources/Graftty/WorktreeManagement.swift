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
/// Holds no state of its own: the model, caches and operation stores belong
/// to the app, so every instance acts on the same worktrees.
@MainActor
final class WorktreeManagement: CLIWorktreeCreationPlatform, CLIWorktreeRemovalPlatform {
    let appState: Binding<AppState>
    let terminalManager: TerminalManager
    let teamInbox: TeamInbox
    let teamEventDispatcher: TeamEventDispatcher
    let worktreeMonitor: WorktreeMonitor
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    let worktreeCreations: CLIWorktreeCreationStore
    let worktreeRemovals: CLIWorktreeRemovalStore

    init(appState: Binding<AppState>, terminalManager: TerminalManager, teamInbox: TeamInbox,
         teamEventDispatcher: TeamEventDispatcher, worktreeMonitor: WorktreeMonitor,
         statsStore: WorktreeStatsStore, prStatusStore: PRStatusStore,
         worktreeCreations: CLIWorktreeCreationStore, worktreeRemovals: CLIWorktreeRemovalStore) {
        self.appState = appState
        self.terminalManager = terminalManager
        self.teamInbox = teamInbox
        self.teamEventDispatcher = teamEventDispatcher
        self.worktreeMonitor = worktreeMonitor
        self.statsStore = statsStore
        self.prStatusStore = prStatusStore
        self.worktreeCreations = worktreeCreations
        self.worktreeRemovals = worktreeRemovals
    }

    convenience init(appState: Binding<AppState>, terminalManager: TerminalManager, services: AppServices) {
        self.init(
            appState: appState, terminalManager: terminalManager, teamInbox: services.teamInbox,
            teamEventDispatcher: services.teamEventDispatcher, worktreeMonitor: services.worktreeMonitor,
            statsStore: services.statsStore, prStatusStore: services.prStatusStore,
            worktreeCreations: services.cliWorktreeCreations, worktreeRemovals: services.cliWorktreeRemovals
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
