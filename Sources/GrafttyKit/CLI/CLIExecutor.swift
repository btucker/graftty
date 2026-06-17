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
    /// The process exceeded the caller-supplied timeout and was
    /// terminated (SIGTERM). The polling fetches (stats `git fetch`, PR
    /// `gh`/`glab`) pass a bounded timeout so a wedged network subprocess
    /// — a socket stuck across a sleep/wake or a dead VPN link, which
    /// `git`/`gh` will otherwise wait on indefinitely — surfaces as a
    /// failure that feeds the per-repo backoff instead of hanging the
    /// poller and leaking the process. Complements the in-flight
    /// abandonment guards (DIVERGE-4.4 / DIVERGE-4.11 / PR-8.17).
    case timedOut(command: String, seconds: Double)
}

public protocol CLIExecutor: Sendable {
    /// Run a command. Throws `CLIError.nonZeroExit` if the process exits non-zero.
    /// Use when non-zero exit means the call failed.
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput

    /// Run a command. Returns the `CLIOutput` regardless of exit code.
    /// Use when exit code is diagnostic (e.g. `git show-ref --verify`).
    /// Still throws on launch failure.
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput

    /// Run a command, terminating it (and throwing `CLIError.timedOut`)
    /// if it does not exit within `timeout`. A `nil` timeout is identical
    /// to `run(command:args:at:)` — unbounded. Declared as a protocol
    /// requirement (not merely a protocol-extension method) so the
    /// production executor's real implementation is reached through
    /// dynamic dispatch; the extension default below lets the many test
    /// stubs ignore the timeout without each having to implement it.
    func run(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput
}

public extension CLIExecutor {
    /// Default: ignore the timeout and defer to the unbounded `run`.
    /// Production `CLIRunner` overrides this with a real terminating
    /// timeout; stubs inherit this no-op so existing conformers keep
    /// compiling unchanged.
    func run(
        command: String,
        args: [String],
        at directory: String,
        timeout _: Duration?
    ) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
}
