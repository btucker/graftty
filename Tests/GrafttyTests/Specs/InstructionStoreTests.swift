import Testing
import Foundation
@testable import GrafttyKit

@Suite("@spec INSTR-1.1: The application shall read instruction files from the committed tree at HEAD in the repository main checkout rather than from the working tree, and shall produce no instruction set when the directory is absent or git fails.")
struct InstructionStoreTests {

    @Test func loadsAndParsesCommittedFiles() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(
            ".graftty/GRAFTTY.md",
            ".graftty/research/GRAFTTY.md",
            ".graftty/research/GRAFTTY.vector-db.md"
        ))
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"], stdout: "repo wide")
        exec.stub(args: ["show", "HEAD:.graftty/research/GRAFTTY.md"],
                  stdout: "group shared\n## Private\ngroup private")
        exec.stub(args: ["show", "HEAD:.graftty/research/GRAFTTY.vector-db.md"],
                  stdout: "leaf text")

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)

        #expect(set?.documents["GRAFTTY.md"]?.shared == "repo wide")
        #expect(set?.documents["research/GRAFTTY.md"]?.privateText == "group private")
        #expect(set?.documents["research/GRAFTTY.vector-db.md"]?.shared == "leaf text")
    }

    @Test func absentDirectoryProducesNoSet() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: "")
        #expect(await InstructionStore.load(repoPath: "/repo", using: exec) == nil)
    }

    @Test func gitFailureProducesNoSet() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs,
                  error: .nonZeroExit(command: "git", exitCode: 128, stderr: "not a repo"))
        #expect(await InstructionStore.load(repoPath: "/repo", using: exec) == nil)
    }

    @Test func unrecognizedFilenamesAreSkipped() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(
            ".graftty/README.md",
            ".graftty/GRAFTTY..md",
            ".graftty/GRAFTTY.ok.md"
        ))
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.ok.md"], stdout: "kept")

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)

        #expect(set?.documents.count == 1)
        #expect(set?.documents["GRAFTTY.ok.md"]?.shared == "kept")
        #expect(!exec.invocations.contains(["show", "HEAD:.graftty/README.md"]))
    }

    /// Real git, because the defect being guarded is git's own path quoting:
    /// without `-z`, `ls-tree` renders a non-ASCII path as an octal-escaped,
    /// double-quoted string that no stub would reproduce faithfully.
    @Test func nonASCIIFilenamesAreRead() async throws {
        let root = try makeCommittedInstructionRepo(
            name: "GRAFTTY.caf\u{e9}.md",
            body: "accented leaf"
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // Explicit budget: the production 1s bound is calibrated for a warm
        // repo on an idle machine, and spawning real git from a fully
        // parallel test suite can outrun it. Timing is INSTR-7.2's subject,
        // not this test's.
        let set = await InstructionStore.load(repoPath: root.path, budget: .seconds(30))

        #expect(set?.documents["GRAFTTY.caf\u{e9}.md"]?.shared == "accented leaf")
    }
}

@Suite("@spec INSTR-7.1: The application shall bound one instruction load to at most 64 files, truncate any single file to 32768 bytes and the whole set to 131072 bytes, and mark every truncated file with a visible truncation marker.")
struct InstructionStoreLimitTests {

    @Test func perFileCapTruncatesWithAMarker() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(".graftty/GRAFTTY.md"))
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"],
                  stdout: String(repeating: "x", count: InstructionStore.perFileByteCap + 500))

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        let shared = set?.documents["GRAFTTY.md"]?.shared ?? ""

        #expect(shared.count < InstructionStore.perFileByteCap + 500)
        #expect(shared.hasSuffix(InstructionStore.truncationMarker))
    }

    @Test func fileCountIsBounded() async {
        let exec = InstructionStubExecutor()
        let names = (0..<(InstructionStore.maxFiles + 10))
            .map { ".graftty/GRAFTTY.w\($0).md" }
        exec.stub(args: instructionLsTreeArgs, stdout: names.map { $0 + "\0" }.joined())
        for name in names {
            exec.stub(args: ["show", "HEAD:\(name)"], stdout: "body")
        }

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        #expect(set?.documents.count == InstructionStore.maxFiles)
    }

    @Test func totalByteCapBoundsTheWholeSet() async {
        let exec = InstructionStubExecutor()
        // Five maximum-size files: four exhaust the total cap exactly, so the
        // fifth is never read at all.
        let names = (0..<5).map { ".graftty/GRAFTTY.w\($0).md" }
        exec.stub(args: instructionLsTreeArgs, stdout: names.map { $0 + "\0" }.joined())
        for name in names {
            exec.stub(args: ["show", "HEAD:\(name)"],
                      stdout: String(repeating: "x", count: InstructionStore.perFileByteCap + 500))
        }

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        let total = set?.documents.values
            .reduce(0) { $0 + $1.shared.utf8.count + $1.privateText.utf8.count } ?? 0

        #expect(total <= InstructionStore.totalByteCap)
        #expect(set?.documents.count == InstructionStore.totalByteCap / InstructionStore.perFileByteCap)
    }

    @Test func truncatedDocumentStaysWithinPerFileCap() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(".graftty/GRAFTTY.md"))
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"],
                  stdout: String(repeating: "x", count: InstructionStore.perFileByteCap + 500))

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        let shared = set?.documents["GRAFTTY.md"]?.shared ?? ""

        #expect(shared.hasSuffix(InstructionStore.truncationMarker))
        #expect(shared.utf8.count <= InstructionStore.perFileByteCap)
    }

    @Test func truncationNeverSplitsMultiByteScalars() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(".graftty/GRAFTTY.md"))
        // "—" (em dash, U+2014) is 3 bytes in UTF-8; perFileByteCap (32_768) is not
        // a multiple of 3, so a naive byte-offset slice lands mid-scalar.
        let longMultiByte = String(repeating: "\u{2014}", count: InstructionStore.perFileByteCap)
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"], stdout: longMultiByte)

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        let shared = set?.documents["GRAFTTY.md"]?.shared ?? ""

        #expect(shared.utf8.count <= InstructionStore.perFileByteCap)
        #expect(!shared.unicodeScalars.contains(Unicode.Scalar(0xFFFD)!))
    }
}

@Suite("@spec INSTR-7.2: The application shall bound every git command of one instruction load by a single aggregate deadline, passing each command only the budget remaining, and shall produce no instruction set once that budget lapses.")
struct InstructionStoreDeadlineTests {

    @Test func gitTimeoutProducesNoSet() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, error: .timedOut(command: "git", seconds: 1))
        #expect(await InstructionStore.load(repoPath: "/repo", using: exec) == nil)
    }

    @Test func eachGitCommandIsBoundedByTheRemainingBudget() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(
            ".graftty/GRAFTTY.md",
            ".graftty/GRAFTTY.a.md"
        ))
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"], stdout: "one")
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.a.md"], stdout: "two")
        exec.delay = .milliseconds(20)

        _ = await InstructionStore.load(
            repoPath: "/repo",
            budget: .milliseconds(500),
            using: exec
        )

        let bounds = exec.timeouts.compactMap { $0 }
        #expect(bounds.count == exec.timeouts.count)
        #expect(bounds.allSatisfy { $0 <= .milliseconds(500) })
        #expect(zip(bounds, bounds.dropFirst()).allSatisfy { $0.0 > $0.1 })
    }

    @Test func lapsedBudgetProducesNoSet() async {
        let exec = InstructionStubExecutor()
        let names = (0..<8).map { ".graftty/GRAFTTY.w\($0).md" }
        exec.stub(args: instructionLsTreeArgs, stdout: names.map { $0 + "\0" }.joined())
        for name in names {
            exec.stub(args: ["show", "HEAD:\(name)"], stdout: "body")
        }
        exec.delay = .milliseconds(30)

        let set = await InstructionStore.load(
            repoPath: "/repo",
            budget: .milliseconds(100),
            using: exec
        )

        #expect(set == nil)
    }

    @Test func exhaustedBudgetStopsIssuingGitCommands() async {
        let exec = InstructionStubExecutor()
        exec.stub(args: instructionLsTreeArgs, stdout: instructionLsTreeOutput(".graftty/GRAFTTY.md"))
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"], stdout: "body")

        let set = await InstructionStore.load(
            repoPath: "/repo",
            budget: .zero,
            using: exec
        )

        #expect(set == nil)
        #expect(exec.invocations.isEmpty)
    }
}
