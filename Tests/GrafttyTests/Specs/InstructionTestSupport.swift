import Testing
import Foundation
@testable import GrafttyKit

/// Shared fixtures for the `.graftty/` instruction-file suites
/// (`InstructionStoreTests`, `InstructionSessionTextTests`,
/// `InstructionCommittedReadTests`). Kept in one file so the stub's
/// `CLIExecutor` conformance and the git-repo setup only have to be
/// maintained once.

/// Minimal `CLIExecutor` double: canned stdout per `(command, args)`, and an
/// optional error for a specific arg list. `delay` makes every call consume
/// wall time so aggregate-deadline behavior is observable; `timeouts` records
/// the bound each call was given.
final class InstructionStubExecutor: CLIExecutor, @unchecked Sendable {
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

let instructionLsTreeArgs = ["ls-tree", "-r", "-z", "--name-only", "HEAD", ".graftty/"]

/// `git ls-tree -z` terminates each path with NUL rather than newline.
func instructionLsTreeOutput(_ paths: String...) -> String {
    paths.map { $0 + "\0" }.joined()
}

/// Creates a throwaway git repository containing `.graftty/<name>` with
/// `body` committed at `HEAD`. Returns the repo root; the caller removes it.
func makeCommittedInstructionRepo(name: String, body: String) throws -> URL {
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
    return root
}
