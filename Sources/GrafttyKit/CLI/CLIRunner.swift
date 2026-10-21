import Foundation

/// Production `CLIExecutor` that invokes external commands via `/usr/bin/env`
/// so PATH is searched (rather than hardcoding `/usr/bin/git` or similar).
/// Prepends common install directories so Finder-launched apps can find
/// Homebrew-installed tools like `gh` and `glab`.
public struct CLIRunner: CLIExecutor {
    public init() {}

    public func run(
        command: String,
        args: [String],
        at directory: String
    ) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: nil)
    }

    public func run(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        let out = try await execute(command: command, args: args, at: directory, timeout: timeout)
        guard out.exitCode == 0 else {
            throw CLIError.nonZeroExit(
                command: command,
                exitCode: out.exitCode,
                stderr: out.stderr
            )
        }
        return out
    }

    public func capture(
        command: String,
        args: [String],
        at directory: String
    ) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory, timeout: nil)
    }

    public func capture(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        try await execute(command: command, args: args, at: directory, timeout: timeout)
    }

    /// Augmented PATH that includes common install locations. Finder-launched
    /// apps inherit a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), which
    /// misses Homebrew-installed tools. Prepending keeps user overrides
    /// winning when the app is launched from the terminal.
    static func enrichedEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.bun/bin"
        ]
        let existing = env["PATH"] ?? ""
        let existingParts = existing.split(separator: ":").map(String.init)
        let combined = (extras + existingParts).reduce(into: [String]()) { acc, p in
            if !p.isEmpty && !acc.contains(p) { acc.append(p) }
        }
        env["PATH"] = combined.joined(separator: ":")
        // Force English output from every external tool so our parsers
        // (git diff --shortstat "insertion"/"deletion", gh pr checks
        // bucket names, zmx status text) keep working for Andy on
        // `LANG=de_DE.UTF-8` or any other non-English locale. LC_ALL
        // trumps LANG/LC_MESSAGES/LC_*, so one assignment suffices.
        env["LC_ALL"] = "C"
        return env
    }

    private func execute(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        let output: SubprocessOutput
        do {
            output = try await Subprocess.run(SubprocessLaunch(
                executable: "/usr/bin/env",
                arguments: [command] + args,
                directory: directory,
                timeout: timeout,
                timeoutLabel: command
            ))
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.launchFailed(command: command, message: error.localizedDescription)
        }
        let stdout = String(data: output.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: output.stderr, encoding: .utf8) ?? ""

        // `/usr/bin/env` exits with 127 and emits "env: <cmd>: No such file
        // or directory" on stderr when the command is not found. The prefix
        // discriminates env's own error from a child that exits 127 for some
        // other reason — but since `env` itself can only exit 127 on
        // missing-command, stderr matching is belt-and-braces (the exit code
        // is already conclusive).
        if output.status == 127, stderr.hasPrefix("env:") && stderr.contains("No such file") {
            throw CLIError.notFound(command: command)
        }
        return CLIOutput(stdout: stdout, stderr: stderr, exitCode: output.status)
    }
}
