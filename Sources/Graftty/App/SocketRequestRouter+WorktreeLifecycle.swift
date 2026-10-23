import Foundation
import SwiftUI
import GrafttyKit

/// The Mac app's side of `graftty worktree add` (`CLIWorktreeCreationRequestHandler`).
/// Phase two runs `AddWorktreeFlow`, starting the backend without a view.
@MainActor
final class MacCLIWorktreeCreation: CLIWorktreeCreationPlatform {
    let appState: Binding<AppState>
    let terminalManager: TerminalManager
    let teamInbox: TeamInbox
    let teamEventDispatcher: TeamEventDispatcher
    let worktreeMonitor: WorktreeMonitor
    let statsStore: WorktreeStatsStore
    let worktreeCreations: CLIWorktreeCreationStore

    init(appState: Binding<AppState>, terminalManager: TerminalManager, teamInbox: TeamInbox,
         teamEventDispatcher: TeamEventDispatcher, worktreeMonitor: WorktreeMonitor,
         statsStore: WorktreeStatsStore, worktreeCreations: CLIWorktreeCreationStore) {
        self.appState = appState
        self.terminalManager = terminalManager
        self.teamInbox = teamInbox
        self.teamEventDispatcher = teamEventDispatcher
        self.worktreeMonitor = worktreeMonitor
        self.statsStore = statsStore
        self.worktreeCreations = worktreeCreations
    }

    var state: AppState {
        get { appState.wrappedValue }
        set { appState.wrappedValue = newValue }
    }

    var agentPromptDirectory: URL {
        AppState.defaultDirectory.appendingPathComponent("agent-launch-prompts", isDirectory: true)
    }

    func stateDidChange() { GrafttyApp.persistAppState(appState.wrappedValue) }

    func saveStateNow() throws { try GrafttyApp.persistAppStateSynchronously(appState.wrappedValue) }

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
}

extension SocketRequestRouter: CLIWorktreeRemovalPlatform {
    var worktreeRemoval: any CLIWorktreeRemovalPlatform { self }

    var worktreeCreation: any CLIWorktreeCreationPlatform {
        MacCLIWorktreeCreation(
            appState: appState, terminalManager: terminalManager, teamInbox: teamInbox,
            teamEventDispatcher: teamEventDispatcher, worktreeMonitor: worktreeMonitor,
            statsStore: statsStore, worktreeCreations: worktreeCreations
        )
    }

    func wakeWorktree(_ path: String) -> Bool { terminalManager.wakeWorktree(path) }

    func removeWorktree(_ path: String, force: Bool) async -> Result<WorktreeRemovalOutcome, WorktreeRemovalError> {
        await DeleteWorktreeFlow.delete(
            worktreePath: path,
            force: force,
            appState: appState,
            terminalManager: terminalManager,
            statsStore: statsStore,
            prStatusStore: prStatusStore,
            teamEventDispatcher: teamEventDispatcher
        )
    }
}
