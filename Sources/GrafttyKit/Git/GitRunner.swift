import Foundation

/// Shared async wrapper around `git` invocations. Delegates to `CLIRunner`
/// so all the PATH enrichment and launch-failure handling lives in one place.
/// Retained as a distinct type so call sites read as "git-specific" and so
/// we have an obvious seam for future git-only helpers.
public enum GitRunner {

    public typealias Error = CLIError

    /// Injected in tests via `configure`. Defaults to a fresh `CLIRunner`.
    private static var executor: CLIExecutor = CLIRunner()

    /// Test seam. Restore to `CLIRunner()` at the end of a test suite.
    public static func configure(executor: CLIExecutor) {
        self.executor = executor
    }

    public static func resetForTests() {
        self.executor = CLIRunner()
    }

    /// Runs `git <args>` and returns stdout. Throws `CLIError.nonZeroExit`
    /// on non-zero exit. Use when non-zero means "the call failed."
    ///
    /// `timeout` bounds the subprocess: pass a value for recurring work so
    /// a wedged socket or filesystem read is SIGTERMed and surfaced as
    /// `CLIError.timedOut` rather than hanging. `nil` (the default) is
    /// unbounded, preserving interactive call sites.
    public static func run(
        args: [String],
        at directory: String,
        timeout: Duration? = nil,
        using executorOverride: CLIExecutor? = nil
    ) async throws -> String {
        let out = try await (executorOverride ?? executor).run(
            command: "git",
            args: args,
            at: directory,
            timeout: timeout
        )
        return out.stdout
    }

    /// Runs `git <args>` and returns `(stdout, exitCode)` without throwing on
    /// non-zero exit. Use when exit code is diagnostic.
    public static func capture(
        args: [String],
        at directory: String,
        timeout: Duration? = nil,
        using executorOverride: CLIExecutor? = nil
    ) async throws -> (stdout: String, exitCode: Int32) {
        let out = try await (executorOverride ?? executor).capture(
            command: "git",
            args: args,
            at: directory,
            timeout: timeout
        )
        return (stdout: out.stdout, exitCode: out.exitCode)
    }

    /// Runs `git <args>` and returns the full `CLIOutput` (stdout/stderr/exit).
    /// Use for mutation commands where stderr carries the user-visible error.
    public static func captureAll(
        args: [String],
        at directory: String,
        timeout: Duration? = nil,
        using executorOverride: CLIExecutor? = nil
    ) async throws -> CLIOutput {
        try await (executorOverride ?? executor).capture(
            command: "git",
            args: args,
            at: directory,
            timeout: timeout
        )
    }
}

/// One absolute budget shared by a sequence of Git subprocesses.
/// Each command receives only the time remaining, so a fallback pipeline
/// cannot outlive the poller's task-level replacement threshold merely by
/// starting another individually bounded child.
struct GitCommandDeadline: Sendable {
    private let instant: ContinuousClock.Instant
    private let timeoutSeconds: Double

    init(timeout: Duration) {
        instant = ContinuousClock().now.advanced(by: timeout)
        let components = timeout.components
        timeoutSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1e18
    }

    func remaining() throws -> Duration {
        let duration = ContinuousClock().now.duration(to: instant)
        guard duration > .zero else {
            throw CLIError.timedOut(command: "git", seconds: timeoutSeconds)
        }
        return duration
    }
}
