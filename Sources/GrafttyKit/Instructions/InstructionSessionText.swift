import Foundation

/// Loads `.graftty/` for a team's repository and renders the session-start
/// instructions section for one viewer.
///
/// @spec INSTR-6.2
/// When rendering the session-start instructions section for a team member,
/// the application shall resolve instruction content for that viewer from the
/// filesystem overlay, omit unavailable files, and yield the empty string
/// when no content can be read, so an instructions problem never blocks the
/// session-start hook.
public enum InstructionSessionText {

    /// `defaultBranch` is the main checkout's instruction key. The caller
    /// supplies it from in-memory app state so instruction loading remains
    /// filesystem-only. A `nil` value means the main checkout gets the root
    /// file only.
    public static func render(
        team: TeamView,
        viewer: TeamMember,
        defaultBranch: String?,
        applicationSupportDirectory: URL =
            InstructionStore.defaultApplicationSupportDirectory,
        loadBudget: Duration = InstructionStore.loadBudget
    ) async -> String {
        func audience(_ member: TeamMember) -> InstructionAudience {
            InstructionAudience(
                key: InstructionKey.key(
                    worktreePath: member.worktreePath,
                    repoPath: team.repoPath,
                    defaultBranch: defaultBranch
                ),
                displayName: member.name
            )
        }

        let viewerAudience = audience(viewer)
        // Stale peers remain in the public team roster, but do not claim
        // instruction paths in the active org chart. The viewer is the
        // exception: receipt of its hook proves its checkout and agent
        // process exist, even if worktree creation has not yet promoted the
        // app-state row from `.creating` to `.running`.
        let readableMembers = [viewer] + team.members.filter {
            $0.worktreePath != viewer.worktreePath && $0.hasOnDiskWorktree
        }
        let otherAudiences = readableMembers
            .filter { $0.worktreePath != viewer.worktreePath }
            .map(audience)
        let preferredPaths = readableMembers.map(audience).flatMap {
            audience in
            guard let key = audience.key else { return ["GRAFTTY.md"] }
            return InstructionChain.paths(forKey: key)
        }

        guard let set = await InstructionStore.load(
            repoPath: team.repoPath,
            worktreePath: viewer.worktreePath,
            applicationSupportDirectory: applicationSupportDirectory,
            preferredPaths: preferredPaths,
            budget: loadBudget
        ) else { return "" }

        return InstructionRenderer.render(
            viewer: viewerAudience,
            others: otherAudiences,
            set: set
        )
    }
}
