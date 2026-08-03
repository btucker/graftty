import Foundation

/// Loads `.graftty/` for a team's repository and renders the session-start
/// instructions section for one viewer.
///
/// @spec INSTR-6.2
/// Every failure path — unresolvable repository, absent directory, git error,
/// timeout — yields the empty string so the session-start hook still returns
/// its team context and queued messages.
public enum InstructionSessionText {

    public static func render(
        team: TeamView,
        viewer: TeamMember,
        using executor: CLIExecutor? = nil
    ) async -> String {
        guard let set = await InstructionStore.load(
            repoPath: team.repoPath,
            using: executor
        ) else { return "" }

        let defaultBranch = await GitOriginDefaultBranch.resolve(
            repoPath: team.repoPath,
            timeout: InstructionStore.gitTimeout
        )

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

        return InstructionRenderer.render(
            viewer: audience(viewer),
            others: team.members
                .filter { $0.worktreePath != viewer.worktreePath }
                .map(audience),
            set: set
        )
    }
}
