import Testing
import Foundation
@testable import GrafttyKit

/// Minimal `CLIExecutor` double: canned stdout per `(command, args)`, and an
/// optional error for a specific arg list. `delay` makes every call consume
/// wall time so aggregate-deadline behavior is observable; `timeouts` records
/// the bound each call was given.
private final class StubExecutor: CLIExecutor, @unchecked Sendable {
    private var outputs: [[String]: String] = [:]
    private var errors: [[String]: CLIError] = [:]
    private(set) var invocations: [[String]] = []
    private(set) var timeouts: [Duration?] = []
    var delay: Duration?
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
        try await run(command: command, args: args, at: directory, timeout: nil)
    }

    func run(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        let (error, stdout, delay) = withLock { () -> (CLIError?, String?, Duration?) in
            invocations.append(args)
            timeouts.append(timeout)
            return (errors[args], outputs[args], self.delay)
        }
        if let delay { try? await Task.sleep(for: delay) }
        if let error { throw error }
        guard let stdout else {
            throw CLIError.nonZeroExit(command: command, exitCode: 128, stderr: "no stub")
        }
        return CLIOutput(stdout: stdout, stderr: "", exitCode: 0)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }

    func capture(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: timeout)
    }
}

private let lsTreeArgs = ["ls-tree", "-r", "-z", "--name-only", "HEAD", ".graftty/"]

/// `git ls-tree -z` terminates each path with NUL rather than newline.
private func lsTreeOutput(_ paths: String...) -> String {
    paths.map { $0 + "\0" }.joined()
}

/// Creates a throwaway git repository containing `.graftty/<name>` with
/// `body` committed at `HEAD`. Returns the repo path; the caller removes it.
private func makeCommittedInstructionRepo(name: String, body: String) throws -> String {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("graftty-instr-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    func git(_ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = root
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
    try body.write(
        to: dir.appendingPathComponent(name),
        atomically: true,
        encoding: .utf8
    )
    try git(["add", "."])
    try git(["commit", "-q", "-m", "add instructions"])
    return root.path
}

@Suite("@spec INSTR-1.1: The application shall read instruction files from the committed tree at HEAD in the repository main checkout rather than from the working tree, and shall produce no instruction set when the directory is absent or git fails.")
struct InstructionStoreTests {

    @Test func loadsAndParsesCommittedFiles() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: lsTreeOutput(
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

    @Test func unrecognizedFilenamesAreSkipped() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: lsTreeOutput(
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
        let repo = try makeCommittedInstructionRepo(
            name: "GRAFTTY.caf\u{e9}.md",
            body: "accented leaf"
        )
        defer { try? FileManager.default.removeItem(atPath: repo) }

        // Explicit budget: the production 1s bound is calibrated for a warm
        // repo on an idle machine, and spawning real git from a fully
        // parallel test suite can outrun it. Timing is INSTR-7.2's subject,
        // not this test's.
        let set = await InstructionStore.load(repoPath: repo, budget: .seconds(30))

        #expect(set?.documents["GRAFTTY.caf\u{e9}.md"]?.shared == "accented leaf")
    }
}

@Suite("@spec INSTR-7.1: The application shall bound one instruction load to at most 64 files, truncate any single file to 32768 bytes and the whole set to 131072 bytes, and mark every truncated file with a visible truncation marker.")
struct InstructionStoreLimitTests {

    @Test func perFileCapTruncatesWithAMarker() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: lsTreeOutput(".graftty/GRAFTTY.md"))
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
        exec.stub(args: lsTreeArgs, stdout: names.map { $0 + "\0" }.joined())
        for name in names {
            exec.stub(args: ["show", "HEAD:\(name)"], stdout: "body")
        }

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        #expect(set?.documents.count == InstructionStore.maxFiles)
    }

    @Test func totalByteCapBoundsTheWholeSet() async {
        let exec = StubExecutor()
        // Five maximum-size files: four exhaust the total cap exactly, so the
        // fifth is never read at all.
        let names = (0..<5).map { ".graftty/GRAFTTY.w\($0).md" }
        exec.stub(args: lsTreeArgs, stdout: names.map { $0 + "\0" }.joined())
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
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: lsTreeOutput(".graftty/GRAFTTY.md"))
        exec.stub(args: ["show", "HEAD:.graftty/GRAFTTY.md"],
                  stdout: String(repeating: "x", count: InstructionStore.perFileByteCap + 500))

        let set = await InstructionStore.load(repoPath: "/repo", using: exec)
        let shared = set?.documents["GRAFTTY.md"]?.shared ?? ""

        #expect(shared.hasSuffix(InstructionStore.truncationMarker))
        #expect(shared.utf8.count <= InstructionStore.perFileByteCap)
    }

    @Test func truncationNeverSplitsMultiByteScalars() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: lsTreeOutput(".graftty/GRAFTTY.md"))
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
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, error: .timedOut(command: "git", seconds: 1))
        #expect(await InstructionStore.load(repoPath: "/repo", using: exec) == nil)
    }

    @Test func eachGitCommandIsBoundedByTheRemainingBudget() async {
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: lsTreeOutput(
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
        let exec = StubExecutor()
        let names = (0..<8).map { ".graftty/GRAFTTY.w\($0).md" }
        exec.stub(args: lsTreeArgs, stdout: names.map { $0 + "\0" }.joined())
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
        let exec = StubExecutor()
        exec.stub(args: lsTreeArgs, stdout: lsTreeOutput(".graftty/GRAFTTY.md"))
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
