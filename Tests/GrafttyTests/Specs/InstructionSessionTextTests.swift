import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
@spec INSTR-6.2: When rendering the session-start instructions section for a team member, the application shall resolve instruction content for that viewer from the filesystem overlay, omit unavailable files, and yield the empty string when no content can be read, so an instructions problem never blocks the session-start hook.
""")
struct InstructionSessionTextTests {

    @Test func absentInstructionsDirectoryYieldsEmptyString() async throws {
        let fixture = try InstructionFilesystemFixture(
            prefix: "graftty-session-instr"
        )
        defer { fixture.remove() }
        let team = try fixture.makeTeam()

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: "main",
            applicationSupportDirectory: fixture.applicationSupport
        )

        #expect(text.isEmpty)
    }

    @Test func unavailableInstructionFileYieldsEmptyString() async throws {
        let fixture = try InstructionFilesystemFixture(
            prefix: "graftty-session-instr"
        )
        defer { fixture.remove() }
        let team = try fixture.makeTeam()
        let instructionDirectory = fixture.repo.appendingPathComponent(
            InstructionStore.directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: instructionDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: instructionDirectory.appendingPathComponent("GRAFTTY.md"),
            withDestinationURL: fixture.root.appendingPathComponent("missing")
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: "main",
            applicationSupportDirectory: fixture.applicationSupport
        )

        #expect(text.isEmpty)
    }

    @Test func successfulRenderIncludesOwnAndOtherMembersSharedText() async throws {
        let fixture = try InstructionFilesystemFixture(
            prefix: "graftty-session-instr"
        )
        defer { fixture.remove() }
        let team = try fixture.makeTeam()
        try fixture.write("repo wide", at: fixture.repo, relativePath: "GRAFTTY.md")
        try fixture.write(
            "main-only text",
            at: fixture.repo,
            relativePath: "main/GRAFTTY.md"
        )
        try fixture.write(
            "feature-login shared text\n## Private\nfeature-login private text",
            at: fixture.repo,
            relativePath: "feature-login/GRAFTTY.md"
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: "main",
            applicationSupportDirectory: fixture.applicationSupport
        )

        #expect(text.contains("main-only text"))
        #expect(text.contains("feature-login shared text"))
        #expect(!text.contains("feature-login private text"))
        #expect(!text.contains("Instruction files matching no current worktree"))
    }

    @Test("""
    @spec INSTR-6.5: When a child agent's session-start hook arrives while its worktree row is still creating, the application shall resolve the viewer's exact-worktree instruction file from that new checkout's filesystem so the child receives its role in the first session.
    """)
    func creatingViewerReceivesItsWorktreeLeafInFirstSession() async throws {
        let fixture = try InstructionFilesystemFixture(
            prefix: "graftty-session-instr"
        )
        defer { fixture.remove() }
        let team = try fixture.makeTeam(
            linked: [("research/vector-db", "research/vector-db", .creating)],
            selectedKey: "research/vector-db"
        )
        let viewer = try #require(team.members.first {
            $0.worktreePath == fixture.linkedWorktree("research/vector-db").path
        })
        try fixture.write(
            "vector database role\n## Private\nfirst-session details",
            at: fixture.linkedWorktree("research/vector-db"),
            relativePath: "research/vector-db/GRAFTTY.md"
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: viewer,
            defaultBranch: "main",
            applicationSupportDirectory: fixture.applicationSupport
        )

        #expect(text.contains("vector database role"))
        #expect(text.contains("first-session details"))
    }

    @Test("""
    @spec INSTR-6.6: When instruction content exceeds a load limit, the application shall prioritize the viewer's instruction stack ahead of peer-only instruction content so the agent's own role is not displaced by the org chart.
    """)
    func viewerInstructionsPrecedePeerInstructionsAtTheByteCap() async throws {
        let fixture = try InstructionFilesystemFixture(
            prefix: "graftty-session-instr"
        )
        defer { fixture.remove() }
        let peers: [(key: String, branch: String, state: WorktreeState)] =
            (0..<4).map {
                ("aa-peer-\($0)", "aa-peer-\($0)", .closed)
            }
        let team = try fixture.makeTeam(
            linked: peers + [("zz-child", "zz-child", .closed)],
            selectedKey: "zz-child"
        )
        let viewer = try #require(team.members.first {
            $0.worktreePath == fixture.linkedWorktree("zz-child").path
        })
        let capFiller = String(
            repeating: "p",
            count: InstructionStore.perFileByteCap
        )
        for index in 0..<4 {
            try fixture.write(
                capFiller,
                at: fixture.linkedWorktree("zz-child"),
                relativePath: "aa-peer-\(index)/GRAFTTY.md"
            )
        }
        try fixture.write(
            "child's own role",
            at: fixture.linkedWorktree("zz-child"),
            relativePath: "zz-child/GRAFTTY.md"
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: viewer,
            defaultBranch: "main",
            applicationSupportDirectory: fixture.applicationSupport
        )

        #expect(text.contains("child's own role"))
    }

    @Test func nilDefaultBranchLimitsTheMainCheckoutToTheRootFile() async throws {
        let fixture = try InstructionFilesystemFixture(
            prefix: "graftty-session-instr"
        )
        defer { fixture.remove() }
        let team = try fixture.makeTeam()
        try fixture.write("repo wide", at: fixture.repo, relativePath: "GRAFTTY.md")
        try fixture.write(
            "main-only text",
            at: fixture.repo,
            relativePath: "main/GRAFTTY.md"
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: nil,
            applicationSupportDirectory: fixture.applicationSupport
        )

        #expect(text.contains("repo wide"))
        #expect(text.contains("Instruction files matching no current worktree"))
    }

    @Test func staleMemberDoesNotClaimItsInstructionFile() async throws {
        let fixture = try InstructionFilesystemFixture(
            prefix: "graftty-session-instr"
        )
        defer { fixture.remove() }
        let team = try fixture.makeTeam(
            linked: [("feature-login", "feature/login", .stale)]
        )
        try fixture.write(
            "retained org-chart role",
            at: fixture.repo,
            relativePath: "feature-login/GRAFTTY.md"
        )

        let text = await InstructionSessionText.render(
            team: team,
            viewer: team.mainWorktree,
            defaultBranch: "main",
            applicationSupportDirectory: fixture.applicationSupport
        )

        #expect(text.contains("retained org-chart role"))
        #expect(text.contains("Instruction files matching no current worktree"))
    }
}
