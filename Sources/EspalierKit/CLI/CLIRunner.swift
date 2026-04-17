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
        let out = try await execute(command: command, args: args, at: directory)
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
        try await execute(command: command, args: args, at: directory)
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
            "\(NSHomeDirectory())/.local/bin"
        ]
        let existing = env["PATH"] ?? ""
        let existingParts = existing.split(separator: ":").map(String.init)
        let combined = (extras + existingParts).reduce(into: [String]()) { acc, p in
            if !p.isEmpty && !acc.contains(p) { acc.append(p) }
        }
        env["PATH"] = combined.joined(separator: ":")
        return env
    }

    private func execute(
        command: String,
        args: [String],
        at directory: String
    ) async throws -> CLIOutput {
        let captured: (String, String, Int32) = try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.environment = Self.enrichedEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
                let stderrStr = String(data: errData, encoding: .utf8) ?? ""

                // `/usr/bin/env` exits with 127 when the command is not found.
                if proc.terminationStatus == 127 && stderrStr.contains("No such file") {
                    cont.resume(throwing: CLIError.notFound(command: command))
                    return
                }
                cont.resume(returning: (stdoutStr, stderrStr, proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: CLIError.launchFailed(
                    command: command,
                    message: error.localizedDescription
                ))
            }
        }
        return CLIOutput(stdout: captured.0, stderr: captured.1, exitCode: captured.2)
    }
}
