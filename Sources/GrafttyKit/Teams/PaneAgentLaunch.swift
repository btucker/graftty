import Foundation

/// Launch rules for `graftty pane add`, which shares `graftty worktree add`'s
/// staged agent launch but adds a pane to a worktree that may already have a
/// live implementer.
public enum PaneAgentLaunch {
    /// Shell input for the new pane. Surface creation runs it once the shell
    /// is ready; typing it after the split can land before shell startup.
    public static func initialInput(_ command: String?) -> String? {
        guard let command,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return command + "\r"
    }

    /// AGENT-6.57: The durable copy is addressed to the runtime, so the
    /// runtime's current delivery owner would receive it. Skip it when a live
    /// agent of that runtime owns delivery or a same-runtime initial task is
    /// still pending, or presence cannot be read; the launch command still
    /// carries the task. Returns the saved row, or nil when none was written.
    /// Performs inbox file I/O, so app callers run it off the main actor
    /// (ATTN-2.19).
    @discardableResult
    public static func saveInitialPrompt(
        _ prompt: String?,
        runtime: TeamHookRuntime,
        repo: RepoEntry,
        worktreePath: String,
        branchName: String,
        inbox: TeamInbox,
        presenceRecords: () throws -> [TeamPresenceRecord],
        liveness: any TeamDeliveryLivenessChecking
    ) throws -> TeamInboxMessage? {
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // An implementer that has not registered yet still has its own task
        // pending; saving would supersede it and could hand it this one.
        // Check that before reading presence: an implementer registers
        // before taking its task, so one whose task is gone by now is
        // already in the presence read below.
        let implementerStarting = try !WorktreeAgentLaunchCommand.pendingInitialPrompts(
            runtime: runtime, repo: repo, worktreePath: worktreePath, inbox: inbox
        ).isEmpty
        guard !implementerStarting,
              let records = try? presenceRecords() else { return nil }
        let key = TeamDeliveryOwnerKey(
            teamID: TeamLookup.id(forRepoPath: repo.path), worktree: worktreePath, runtime: runtime
        )
        let resolver = TeamDeliveryOwnershipResolver(records: { records }, liveness: liveness)
        guard resolver.owner(for: key) == nil else { return nil }
        return try WorktreeAgentLaunchCommand.saveInitialPrompt(
            prompt, runtime: runtime, repo: repo,
            worktreePath: worktreePath, branchName: branchName, inbox: inbox
        )
    }

    /// Withdraws a saved task whose pane never launched, so a later agent of
    /// that runtime cannot inherit it. Performs inbox file I/O.
    public static func withdrawInitialPrompt(_ message: TeamInboxMessage, inbox: TeamInbox) throws {
        try inbox.acknowledgeMessages(
            teamID: message.repoPath, worktree: message.to.worktree, messageIDs: [message.id]
        )
    }
}
