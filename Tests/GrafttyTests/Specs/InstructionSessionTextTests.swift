import Testing
import Foundation
@testable import GrafttyKit

/// Minimal `CLIExecutor` double: canned stdout per `(command, args)`, and an
/// optional error for a specific arg list. Mirrors the stub in
/// `InstructionStoreTests.swift`.
private func makeTeam() -> TeamView {
    var repo = RepoEntry(path: "/r/acme", displayName: "acme-web")
    repo.worktrees.append(WorktreeEntry(path: "/r/acme", branch: "main"))
    repo.worktrees.append(WorktreeEntry(path: "/r/acme/.worktrees/feature-login", branch: "feature/login"))
    return TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true)!
}

@Suite("@spec INSTR-6.2: When rendering the session-start instructions section for a team member, the application shall resolve committed main-checkout and active-worktree instruction content, omit unavailable individual leaves, and yield the empty string when no committed content can be read, so an instructions problem never blocks the session-start hook.")
struct InstructionSessionTextTests {

    @Test func absentInstructionsDirectoryYieldsEmptyString() async {
        let team = makeTeam()
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: "")

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: "main",
            using: exec
        )

        #expect(text.isEmpty)
    }

    @Test func gitFailureYieldsEmptyString() async {
        let team = makeTeam()
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs,
                  error: .nonZeroExit(command: "git", exitCode: 128, stderr: "not a repo"))

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: "main",
            using: exec
        )

        #expect(text.isEmpty)
    }

    @Test func successfulRenderIncludesOwnAndOtherMembersSharedText() async {
        let team = makeTeam()
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(
            ".graftty/GRAFTTY.md",
            ".graftty/GRAFTTY.main.md",
            ".graftty/GRAFTTY.feature-login.md"
        ))
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"], stdout: "repo wide")
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.main.md"], stdout: "main-only text")
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.feature-login.md"],
                  stdout: "feature-login shared text\n## Private\nfeature-login private text")

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: "main",
            using: exec
        )

        #expect(text.contains("main-only text"))
        #expect(text.contains("feature-login shared text"))
        #expect(!text.contains("feature-login private text"))
        // GRAFTTY.main.md belongs to the viewer's own stack once the caller
        // supplies the default branch; it must not fall into the
        // no-worktree-matches bucket.
        #expect(!text.contains("Instruction files matching no current worktree"))
        // The default branch arrives from in-memory app state; rendering must
        // not shell out to resolve `origin/HEAD`.
        #expect(!exec.invocations.contains { $0.first == "symbolic-ref" })
    }

    @Test func branchOnlyLeafRendersBeforeMainContainsGrafttyDirectory() async {
        let team = makeTeam()
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: "")
        exec.stub(
            args: ["show", "HEAD:.graftty/GRAFTTY.feature-login.md"],
            stdout: "branch-only role"
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: "main",
            using: exec
        )

        #expect(text.contains("branch-only role"))
        #expect(text.contains("feature/login"))
    }

    @Test("""
    @spec INSTR-6.5: When a child agent's session-start hook arrives while its worktree row is still creating, the application shall resolve the viewer's committed leaf from that new checkout so the child receives its role in the first session.
    """)
    func creatingViewerReceivesItsBranchLeafInFirstSession() async {
        var repo = RepoEntry(path: "/r/acme", displayName: "acme-web")
        repo.worktrees.append(WorktreeEntry(path: "/r/acme", branch: "main"))
        repo.worktrees.append(WorktreeEntry(
            path: "/r/acme/.worktrees/research/vector-db",
            branch: "research/vector-db",
            state: .creating
        ))
        let team = TeamView.team(
            for: repo.worktrees[1],
            in: [repo],
            teamsEnabled: true
        )!
        let viewer = team.members.first {
            $0.worktreePath == "/r/acme/.worktrees/research/vector-db"
        }!
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: "")
        exec.stub(
            args: ["show", "HEAD:.graftty/research/GRAFTTY.vector-db.md"],
            stdout: "vector database role\n## Private\nfirst-session details"
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: viewer,
            defaultBranch: "main",
            using: exec
        )

        #expect(text.contains("vector database role"))
        #expect(text.contains("first-session details"))
        #expect(exec.invocationDirectories.contains(viewer.worktreePath))
    }

    @Test("""
    @spec INSTR-6.6: When instruction content exceeds a load limit, the application shall prioritize the viewer's committed leaf ahead of peer-only instruction content so the agent's own role is not displaced by the org chart.
    """)
    func viewerLeafPrecedesPeerLeavesAtTheByteCap() async {
        var repo = RepoEntry(path: "/r/acme", displayName: "acme-web")
        repo.worktrees.append(WorktreeEntry(path: "/r/acme", branch: "main"))
        for index in 0..<3 {
            repo.worktrees.append(WorktreeEntry(
                path: "/r/acme/.worktrees/peer-\(index)",
                branch: "peer-\(index)"
            ))
        }
        repo.worktrees.append(WorktreeEntry(
            path: "/r/acme/.worktrees/child",
            branch: "child"
        ))
        let team = TeamView.team(
            for: repo.worktrees.last!,
            in: [repo],
            teamsEnabled: true
        )!
        let viewer = team.members.first {
            $0.worktreePath == "/r/acme/.worktrees/child"
        }!
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: "")
        let capFiller = String(
            repeating: "p",
            count: InstructionStore.perFileByteCap
        )
        for key in ["main", "peer-0", "peer-1", "peer-2"] {
            exec.stub(
                args: ["show", "HEAD:.graftty/GRAFTTY.\(key).md"],
                stdout: capFiller
            )
        }
        exec.stub(
            args: ["show", "HEAD:.graftty/GRAFTTY.child.md"],
            stdout: "child's own role"
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: viewer,
            defaultBranch: "main",
            using: exec
        )

        #expect(text.contains("child's own role"))
    }

    @Test func nilDefaultBranchLimitsTheMainCheckoutToTheRootFile() async {
        let team = makeTeam()
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(
            ".graftty/GRAFTTY.md",
            ".graftty/GRAFTTY.main.md"
        ))
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"], stdout: "repo wide")
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.main.md"], stdout: "main-only text")

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: nil,
            using: exec
        )

        #expect(text.contains("repo wide"))
        // No key means no leaf file in the viewer's own stack; the unmatched
        // block still surfaces the file's shared text.
        #expect(text.contains("Instruction files matching no current worktree"))
    }

    @Test func staleMemberDoesNotClaimAMainCheckoutLeaf() async {
        var repo = RepoEntry(path: "/r/acme", displayName: "acme-web")
        repo.worktrees.append(WorktreeEntry(path: "/r/acme", branch: "main"))
        repo.worktrees.append(WorktreeEntry(
            path: "/r/acme/.worktrees/feature-login",
            branch: "feature/login",
            state: .stale
        ))
        let team = TeamView.team(
            for: repo.worktrees[0],
            in: [repo],
            teamsEnabled: true
        )!
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(
            ".graftty/GRAFTTY.feature-login.md"
        ))
        exec.stub(
            args: ["show", "HEAD:.graftty/GRAFTTY.feature-login.md"],
            stdout: "retained org-chart role"
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: "main",
            using: exec
        )

        #expect(text.contains("retained org-chart role"))
        #expect(text.contains("Instruction files matching no current worktree"))
        #expect(!exec.invocationDirectories.contains(
            "/r/acme/.worktrees/feature-login"
        ))
    }
}
