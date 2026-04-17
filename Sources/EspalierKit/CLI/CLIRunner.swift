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

            // Drain pipes into in-memory buffers while the process runs.
            // If we waited until termination to read, a process that writes
            // more than the pipe buffer (~16–64 KB) would block on write and
            // never exit — leaking the continuation. `readabilityHandler`
            // fires on background queues, so guard shared state with a lock.
            let buffers = PipeBuffers()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                buffers.appendStdout(chunk)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                buffers.appendStderr(chunk)
            }

            process.terminationHandler = { proc in
                // Stop the handlers and drain any remaining bytes synchronously.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let finalOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let finalErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                buffers.appendStdout(finalOut)
                buffers.appendStderr(finalErr)

                let stdoutStr = String(data: buffers.stdoutData, encoding: .utf8) ?? ""
                let stderrStr = String(data: buffers.stderrData, encoding: .utf8) ?? ""

                // `/usr/bin/env` exits with 127 and emits a line prefixed with
                // "env:" when the command is not found. The prefix discriminates
                // env's own error from a child command that happens to say
                // "No such file" while coincidentally exiting 127.
                if proc.terminationStatus == 127,
                   stderrStr.hasPrefix("env:") && stderrStr.contains("No such file") {
                    cont.resume(throwing: CLIError.notFound(command: command))
                    return
                }
                cont.resume(returning: (stdoutStr, stderrStr, proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: CLIError.launchFailed(
                    command: command,
                    message: error.localizedDescription
                ))
            }
        }
        return CLIOutput(stdout: captured.0, stderr: captured.1, exitCode: captured.2)
    }
}

/// Thread-safe byte accumulator for pipe drain handlers. `readabilityHandler`
/// fires on background queues, and `terminationHandler` fires on yet another
/// queue, so appends and final reads need a lock.
private final class PipeBuffers: @unchecked Sendable {
    private var _stdout = Data()
    private var _stderr = Data()
    private let lock = NSLock()

    var stdoutData: Data {
        lock.lock(); defer { lock.unlock() }
        return _stdout
    }

    var stderrData: Data {
        lock.lock(); defer { lock.unlock() }
        return _stderr
    }

    func appendStdout(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        _stdout.append(chunk)
    }

    func appendStderr(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        _stderr.append(chunk)
    }
}
