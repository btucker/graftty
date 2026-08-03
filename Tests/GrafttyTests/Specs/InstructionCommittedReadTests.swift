import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec INSTR-1.2: The application shall deliver the committed content of an instruction file even when the main checkout working tree holds a different uncommitted version of that file.")
struct InstructionCommittedReadTests {

    @Test func uncommittedEditsAreNotDelivered() async throws {
        let root = try makeCommittedInstructionRepo(name: "GRAFTTY.md", body: "COMMITTED")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.path

        // Dirty the working tree after committing.
        let file = root
            .appendingPathComponent(".graftty", isDirectory: true)
            .appendingPathComponent("GRAFTTY.md")
        try "WORKING TREE".write(to: file, atomically: true, encoding: .utf8)

        // Explicit budget: the production 1s bound is calibrated for a warm
        // repo on an idle machine, and spawning real git from a fully
        // parallel test suite can outrun it. Timing is INSTR-7.2's subject,
        // not this test's.
        let set = await InstructionStore.load(repoPath: repo, budget: .seconds(30))
        let shared = set?.documents["GRAFTTY.md"]?.shared

        #expect(shared == "COMMITTED")
        #expect(shared != "WORKING TREE")
    }
    @Test("""
    @spec INSTR-1.3: When an active worktree has a committed leaf instruction file, the application shall load that leaf from the worktree's own HEAD even when the main checkout does not contain it.
    """)
    func linkedWorktreeLeafUsesItsCommittedHead() async throws {
        let root = try makeCommittedInstructionRepo(name: "GRAFTTY.md", body: "repo wide")
        defer { try? FileManager.default.removeItem(at: root) }

        let linked = root
            .appendingPathComponent(".worktrees", isDirectory: true)
            .appendingPathComponent("feature-login", isDirectory: true)
        try runInstructionGit(
            ["worktree", "add", "-q", "-b", "feature-login", linked.path],
            at: root
        )
        let leaf = linked
            .appendingPathComponent(".graftty", isDirectory: true)
            .appendingPathComponent("GRAFTTY.feature-login.md")
        try "COMMITTED BRANCH ROLE".write(to: leaf, atomically: true, encoding: .utf8)
        try runInstructionGit(["add", ".graftty/GRAFTTY.feature-login.md"], at: linked)
        try runInstructionGit(["commit", "-q", "-m", "add branch role"], at: linked)
        try "DIRTY BRANCH ROLE".write(to: leaf, atomically: true, encoding: .utf8)

        let set = await InstructionStore.load(
            repoPath: root.path,
            leafSources: [
                InstructionLeafSource(
                    worktreePath: linked.path,
                    relativePath: "GRAFTTY.feature-login.md"
                ),
            ],
            budget: .seconds(30)
        )

        let shared = set?.leafDocumentsByWorktreePath[linked.path]?.shared
        #expect(shared == "COMMITTED BRANCH ROLE")
        #expect(shared != "DIRTY BRANCH ROLE")
    }
}
