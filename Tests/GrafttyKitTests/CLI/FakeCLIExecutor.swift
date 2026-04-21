import Foundation
@testable import GrafttyKit

/// Test double for `CLIExecutor`. Returns canned `CLIOutput` for matching
/// `(command, args)` tuples. Asserts on unexpected invocations so tests
/// don't silently drift.
final class FakeCLIExecutor: CLIExecutor, @unchecked Sendable {
    struct Key: Hashable { let command: String; let args: [String] }
    enum Response { case output(CLIOutput); case error(CLIError) }

    private var responses: [Key: Response] = [:]
    private(set) var invocations: [(command: String, args: [String], directory: String)] = []
    private let lock = NSLock()

    func stub(command: String, args: [String], output: CLIOutput) {
        lock.lock(); defer { lock.unlock() }
        responses[Key(command: command, args: args)] = .output(output)
    }

    func stub(command: String, args: [String], error: CLIError) {
        lock.lock(); defer { lock.unlock() }
        responses[Key(command: command, args: args)] = .error(error)
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        let out = try lookup(command: command, args: args, directory: directory)
        guard out.exitCode == 0 else {
            throw CLIError.nonZeroExit(
                command: command,
                exitCode: out.exitCode,
                stderr: out.stderr
            )
        }
        return out
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try lookup(command: command, args: args, directory: directory)
    }

    private func lookup(command: String, args: [String], directory: String) throws -> CLIOutput {
        lock.lock()
        invocations.append((command, args, directory))
        let resp = responses[Key(command: command, args: args)]
        lock.unlock()
        switch resp {
        case .output(let o): return o
        case .error(let e): throw e
        case .none:
            throw CLIError.launchFailed(
                command: command,
                message: "FakeCLIExecutor: no stub for \(command) \(args)"
            )
        }
    }
}
