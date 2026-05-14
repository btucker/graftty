import Foundation

public enum AttentionPushDecider {
    /// Returns true iff the user is not active at the desktop AND we have
    /// not already pushed this exact (worktreePath, attentionTimestamp) pair.
    public static func shouldPush(
        payload: AgentStopNotificationPayload,
        isUserActiveOnDesktop: Bool,
        dedupe: PushDedupeStore
    ) -> Bool {
        if isUserActiveOnDesktop { return false }
        return dedupe.lastPushed(forWorktree: payload.worktreePath) != payload.attentionTimestamp
    }
}
