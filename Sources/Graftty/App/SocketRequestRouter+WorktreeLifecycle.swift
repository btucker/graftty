import Foundation
import GrafttyKit

/// `graftty worktree add` / `remove` run on the shared `WorktreeManagement`.
extension SocketRequestRouter {
    var worktreeManagement: WorktreeManagement {
        WorktreeManagement(
            appState: appState, terminalManager: terminalManager, teamInbox: teamInbox,
            teamEventDispatcher: teamEventDispatcher, worktreeMonitor: worktreeMonitor,
            statsStore: statsStore, prStatusStore: prStatusStore,
            worktreeCreations: worktreeCreations, worktreeRemovals: worktreeRemovals
        )
    }

    var worktreeCreation: any CLIWorktreeCreationPlatform { worktreeManagement }
    var worktreeRemoval: any CLIWorktreeRemovalPlatform { worktreeManagement }
}
