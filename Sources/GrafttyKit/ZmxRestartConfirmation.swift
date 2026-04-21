import Foundation

/// Pure logic for composing the "Restart ZMX" confirmation alert text.
/// Pluralization of pane / worktree counts is fiddly enough (0/1/many,
/// pane vs. worktree singulars) that keeping it out of the SwiftUI layer
/// lets tests pin every branch without touching NSAlert.
public enum ZmxRestartConfirmation {
    /// Informative body copy shown in the "Restart ZMX?" NSAlert. Always
    /// warns that unsaved work will be lost when any session is running;
    /// explicitly says "nothing will happen" when no sessions are live so
    /// the user doesn't confirm a no-op thinking it will do something.
    public static func informativeText(paneCount: Int, worktreeCount: Int) -> String {
        guard paneCount > 0 else {
            return "There are no running terminal sessions. Restarting ZMX will have no effect."
        }
        let sessionWord = paneCount == 1 ? "session" : "sessions"
        let wtWord = worktreeCount == 1 ? "worktree" : "worktrees"
        return "This will end all \(paneCount) running terminal \(sessionWord) "
            + "across \(worktreeCount) \(wtWord). "
            + "Any unsaved work in those sessions will be lost."
    }
}
