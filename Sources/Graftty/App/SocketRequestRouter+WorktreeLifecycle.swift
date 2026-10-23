import Foundation
import GrafttyKit

/// `graftty worktree add` / `remove` run on the shared `WorktreeManagement`.
extension SocketRequestRouter {
    var worktreeCreation: any CLIWorktreeCreationPlatform { worktreeManagement }
    var worktreeRemoval: any CLIWorktreeRemovalPlatform { worktreeManagement }
}
