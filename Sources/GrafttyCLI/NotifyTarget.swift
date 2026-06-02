import Foundation
import GrafttyKit

public enum NotifyTargetError: Error, Equatable { case conflictingTargets }

/// Pure mapping of `graftty notify` flags + environment to a wire message.
/// `--session` → pane-scoped; `--worktree` → that worktree; no flag with
/// `$ZMX_SESSION` → caller pane; no flag without it → CWD worktree.
public enum NotifyTarget {
    public static func message(
        text: String,
        session: String?,
        worktree: String?,
        env: [String: String],
        resolveWorktreePath: () throws -> String,
        clearAfter: TimeInterval? = nil
    ) throws -> NotificationMessage {
        if session != nil && worktree != nil { throw NotifyTargetError.conflictingTargets }
        let path = try resolveWorktreePath()
        let pane = paneSessionName(session: session, worktree: worktree, env: env)
        return .notify(path: path, text: text, clearAfter: clearAfter, paneSessionName: pane)
    }

    /// The pane a notification scopes to: `--session` wins; otherwise an
    /// in-pane caller (`$ZMX_SESSION`) targets its own pane — unless an
    /// explicit `--worktree` was given, which is worktree-scoped (nil pane).
    /// Shared by `message(...)` and the `--clear` path so they can't drift.
    public static func paneSessionName(session: String?, worktree: String?, env: [String: String]) -> String? {
        session ?? (worktree == nil ? env["ZMX_SESSION"] : nil)
    }
}
