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
    /// still pending; the launch command still carries the task. Returns whether a row was written. Performs inbox file I/O,
    /// so app callers run it off the main actor (ATTN-2.19).
    @discardableResult
    public static func saveInitialPrompt(
        _ prompt: String?,
        runtime: TeamHookRuntime,
        repo: RepoEntry,
        worktreePath: String,
        branchName: String,
        inbox: TeamInbox,
        presenceRecords: [TeamPresenceRecord],
        liveness: any TeamDeliveryLivenessChecking
    ) throws -> Bool {
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let key = TeamDeliveryOwnerKey(
            teamID: TeamLookup.id(forRepoPath: repo.path), worktree: worktreePath, runtime: runtime
        )
        let resolver = TeamDeliveryOwnershipResolver(records: { presenceRecords }, liveness: liveness)
        guard resolver.owner(for: key) == nil else { return false }
        // An implementer that has not registered yet still has its own task
        // pending; saving would supersede it and could hand it this one.
        let implementerStarting = try inbox.worktreePendingMessages(
            teamID: repo.path, recipientWorktree: worktreePath
        ).contains { $0.kind == "agent_initial_prompt" && $0.to.runtime == runtime.rawValue }
        guard !implementerStarting else { return false }
        try WorktreeAgentLaunchCommand.saveInitialPrompt(
            prompt, runtime: runtime, repo: repo,
            worktreePath: worktreePath, branchName: branchName, inbox: inbox
        )
        return true
    }
}
