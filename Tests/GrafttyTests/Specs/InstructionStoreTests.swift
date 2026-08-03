import Testing
import Foundation
@testable import GrafttyKit

/// Minimal `CLIExecutor` double: canned stdout per `(command, args)`, and an
/// optional error for a specific arg list.
private final class StubExecutor: CLIExecutor, @unchecked Sendable {
    private var outputs: [[String]: String] = [:]
    private var errors: [[String]: CLIError] = [:]
    private(set) var invocations: [[String]] = []
    private let lock = NSLock()

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func stub(args: [String], stdout: String) {
        withLock { outputs[args] = stdout }
    }

    func stub(args: [String], error: CLIError) {
        withLock { errors[args] = error }
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        let (error, stdout) = withLock { () -> (CLIError?, String?) in
            invocations.append(args)
            return (errors[args], outputs[args])
        }
        if let error { throw error }
        guard let stdout else {
            throw CLIError.nonZeroExit(command: command, exitCode: 128, stderr: "no stub")
        }
        return CLIOutput(stdout: stdout, stderr: "", exitCode: 0)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
}

private let lsTreeArgs = ["ls-tree", "-r", "--name-only", "HEAD", ".graftty/"]

@Suite("@spec INSTR-1.1: The application shall read instruction files from the committed tree at HEAD in the repository main checkout rather than from the working tree, and shall produce no instruction set when the directory is absent or git fails.")
struct InstructionStoreTests {

    @Test func loadsAndParsesCommittedFiles() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: """
        .graftty/GRAFTTY.md
        .graftty/research/GRAFTTY.md
        .graftty/research/GRAFTTY.vector-db.md
        """)
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"], stdout: "repo wide")
        exec.stub(args: ["show", "HEAD:.graftty/research/GRAFTTY.md"],
                  stdout: "group shared\n## Private\ngroup private")
        exec.stub(args: ["show", "HEAD:.graftty/research/GRAFTTY.vector-db.md"],
                  stdout: "leaf text")

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)

        #expect(set?.documents["GRAFTTY.md"]?.shared == "repo wide")
        #expect(set?.documents["research/GRAFTTY.md"]?.privateText == "group private")
        #expect(set?.documents["research/GRAFTTY.vector-db.md"]?.shared == "leaf text")
        #expect(set?.files["research/GRAFTTY.vector-db.md"] == .leaf(key: "research/vector-db"))
    }

    @Test func absentDirectoryProducesNoSet() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: "")
        #expect(await InstructionStore.load(repoPath: "/repo", using: exec) == nil)
    }

    @Test func gitFailureProducesNoSet() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs,
                  error: .nonZeroExit(command: "git", exitCode: 128, stderr: "not a repo"))
        #expect(await InstructionStore.load(repoPath: "/repo", using: exec) == nil)
    }

    @Test func timeoutProducesNoSet() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, error: .timedOut(command: "git", seconds: 5))
        #expect(await InstructionStore.load(repoPath: "/repo", using: exec) == nil)
    }

    @Test func unrecognizedFilenamesAreSkipped() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: """
        .graftty/README.md
        .graftty/GRAFTTY..md
        .graftty/GRAFTTY.ok.md
        """)
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.ok.md"], stdout: "kept")

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)

        #expect(set?.documents.count == 1)
        #expect(set?.documents["GRAFTTY.ok.md"]?.shared == "kept")
        #expect(!exec.invocations.contains(["show", "HEAD:.graftty/README.md"]))
    }

    @Test func perFileCapTruncatesWithAMarker() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: ".graftty/GRAFTTY.md")
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"],
                  stdout: String(repeating: "x", count: InstructionStore.perFileByteCap + 500))

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        let shared = set?.documents["GRAFTTY.md"]?.shared ?? ""

        #expect(shared.count < InstructionStore.perFileByteCap + 500)
        #expect(shared.hasSuffix(InstructionStore.truncationMarker))
    }

    @Test func fileCountIsBounded() async {
        let exec = StubExecutor()
        let names = (0..<(InstructionStore.maxFiles + 10))
            .map { ".graftty/GRAFTTY.w\($0).md" }
        exec.stub(args: lsTreeArgs, stdout: names.joined(separator: "\n"))
        for name in names {
            exec.stub(args: ["show", "HEAD:\(name)"], stdout: "body")
        }

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        #expect(set?.documents.count == InstructionStore.maxFiles)
    }

    @Test func truncatedDocumentStaysWithinPerFileCap() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: ".graftty/GRAFTTY.md")
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"],
                  stdout: String(repeating: "x", count: InstructionStore.perFileByteCap + 500))

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        let shared = set?.documents["GRAFTTY.md"]?.shared ?? ""

        #expect(shared.hasSuffix(InstructionStore.truncationMarker))
        #expect(shared.utf8.count <= InstructionStore.perFileByteCap)
    }

    @Test func truncationNeverSplitsMultiByteScalars() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: ".graftty/GRAFTTY.md")
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
