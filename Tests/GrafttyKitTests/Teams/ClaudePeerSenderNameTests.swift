import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
    @spec AGENT-6.18: When the application delivers inbox rows through Claude's native peer socket, it shall identify the sender as `<team>/<worktree-member>#<agent-id>` for agent-authored rows (omitting the `#` suffix when no agent ID was persisted), as the originating SCM's display name for system rows with a persisted source, and as `Graftty team` for other system rows.
""")
struct ClaudePeerSenderNameTests {
    @Test func agentRowUsesTeamMemberAndAgentID() {
        let name = ClaudePeerSenderName.name(for: message(
            from: TeamInboxEndpoint(
                member: "main",
                worktree: "/repo",
                runtime: "codex",
                agentID: "codex-0123456789ab"
            )
        ))
        #expect(name == "repo/main#codex-0123456789ab")
    }

    @Test func agentRowWithoutAgentIDOmitsSuffix() {
        let name = ClaudePeerSenderName.name(for: message(
            from: TeamInboxEndpoint(member: "alice", worktree: "/repo/alice", runtime: nil)
        ))
        #expect(name == "repo/alice")
    }

    @Test func githubSystemRowUsesForgeDisplayName() {
        let name = ClaudePeerSenderName.name(for: message(
            from: .system(repoPath: "/repo"),
            source: "github"
        ))
        #expect(name == "GitHub")
    }

    @Test func gitlabSystemRowUsesForgeDisplayName() {
        let name = ClaudePeerSenderName.name(for: message(
            from: .system(repoPath: "/repo"),
            source: "gitlab"
        ))
        #expect(name == "GitLab")
    }

    @Test func unknownSourceIsCapitalized() {
        let name = ClaudePeerSenderName.name(for: message(
            from: .system(repoPath: "/repo"),
            source: "sourcehut"
        ))
        #expect(name == "Sourcehut")
    }

    @Test func sourcelessSystemRowStaysGrafttyTeam() {
        let name = ClaudePeerSenderName.name(for: message(
            from: .system(repoPath: "/repo")
        ))
        #expect(name == "Graftty team")
    }

    private func message(
        from: TeamInboxEndpoint,
        source: String? = nil
    ) -> TeamInboxMessage {
        TeamInboxMessage(
            id: "m1",
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800),
            team: "repo",
            repoPath: "/repo",
            from: from,
            to: TeamInboxEndpoint(
                member: "recipient",
                worktree: "/repo/recipient",
                runtime: "claude",
                agentID: "claude-abcdef012345"
            ),
            priority: .normal,
            body: "hello",
            source: source
        )
    }
}
