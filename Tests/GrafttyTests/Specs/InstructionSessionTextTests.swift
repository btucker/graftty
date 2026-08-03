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

@Suite("@spec INSTR-6.2: When rendering the session-start instructions section for a team member, the application shall load and resolve `.graftty/` for the viewer's repository and yield the empty string on any failure to do so, so the session-start hook is never blocked by an instructions problem.")
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
}
