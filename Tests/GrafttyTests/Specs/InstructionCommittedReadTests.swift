import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec INSTR-1.2: The application shall deliver the committed content of an instruction file even when the main checkout working tree holds a different uncommitted version of that file.")
struct InstructionCommittedReadTests {

    @Test func uncommittedEditsAreNotDelivered() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("graftty-instr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.path

        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + args
            process.currentDirectoryURL = URL(fileURLWithPath: repo)
            process.environment = ProcessInfo.processInfo.environment.merging([
                "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
            ]) { _, new in new }
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(args.joined(separator: " "))")
        }

        try git(["init", "-q", "."])
        let dir = root.appendingPathComponent(".graftty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("GRAFTTY.md")
        try "COMMITTED".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-q", "-m", "add instructions"])

        // Dirty the working tree after committing.
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
