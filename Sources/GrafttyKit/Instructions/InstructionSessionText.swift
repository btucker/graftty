import Foundation

/// Loads `.graftty/` for a team's repository and renders the session-start
/// instructions section for one viewer.
///
/// @spec INSTR-6.2
/// When rendering the session-start instructions section for a team member,
/// the application shall resolve committed main-checkout and active-worktree
/// instruction content, omit unavailable individual leaves, and yield the
/// empty string when no committed content can be read, so an instructions
/// problem never blocks the session-start hook.
public enum InstructionSessionText {

    /// `defaultBranch` is the main checkout's instruction key. It is supplied
    /// by the caller from in-memory app state rather than resolved here:
    /// `GitOriginDefaultBranch.resolve` costs up to four subprocesses when
    /// `refs/remotes/origin/HEAD` is missing, which the session-start budget
    /// cannot afford. A `nil` value means the main checkout gets the root
    /// file only.
    public static func render(
        team: TeamView,
        viewer: TeamMember,
        defaultBranch: String?,
        using executor: CLIExecutor? = nil
    ) async -> String {
        func audience(_ member: TeamMember) -> InstructionAudience {
            InstructionAudience(
                key: InstructionKey.key(
                    worktreePath: member.worktreePath,
                    repoPath: team.repoPath,
                    defaultBranch: defaultBranch
                ),
                displayName: member.name,
                worktreePath: member.worktreePath
            )
        }

        let viewerAudience = audience(viewer)
        let otherAudiences = team.members
            .filter { $0.worktreePath != viewer.worktreePath }
            .map(audience)
        let leafSources = ([viewerAudience] + otherAudiences).compactMap {
            audience -> InstructionLeafSource? in
            guard let key = audience.key,
                  let leafPath = InstructionChain.paths(forKey: key).last,
                  let worktreePath = audience.worktreePath else { return nil }
            return InstructionLeafSource(
                worktreePath: worktreePath,
                relativePath: leafPath
            )
        }

        guard let set = await InstructionStore.load(
            repoPath: team.repoPath,
            leafSources: leafSources,
            using: executor
        ) else { return "" }

        return InstructionRenderer.render(
            viewer: viewerAudience,
            others: otherAudiences,
            set: set
        )
    }
}
