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
}
