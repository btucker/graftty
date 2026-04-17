import Foundation

public struct CLIOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CLIError: Error, Equatable {
    /// The executable couldn't be found on the PATH.
    case notFound(command: String)
    /// The process ran but exited non-zero. Callers that use `run(...)` see this;
    /// `capture(...)` returns the CLIOutput instead.
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)
    /// Process launch itself failed (permission denied, bad cwd, etc.).
    case launchFailed(command: String, message: String)
}

public protocol CLIExecutor: Sendable {
    /// Run a command. Throws `CLIError.nonZeroExit` if the process exits non-zero.
    /// Use when non-zero exit means the call failed.
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput

    /// Run a command. Returns the `CLIOutput` regardless of exit code.
    /// Use when exit code is diagnostic (e.g. `git show-ref --verify`).
    /// Still throws on launch failure.
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput
}
