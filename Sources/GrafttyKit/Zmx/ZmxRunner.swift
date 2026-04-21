import Foundation

/// Sync subprocess wrapper for invoking `zmx` (or any other executable
/// with explicit env). Three flavors mirror `GitRunner`:
///
/// - `run` — throws on non-zero exit; returns stdout
/// - `capture` — returns (stdout, exitCode) without throwing
/// - `captureAll` — returns (stdout, stderr, exitCode) for diagnostics
///
/// Differs from `GitRunner` in two ways: the executable URL is a
/// parameter (not a hardcoded path), and env is explicit (the caller
/// passes exactly what the child should see — empty dict means an
/// almost-empty env, not "inherit").
public enum ZmxRunner {

    public enum Error: Swift.Error, Equatable {
        case zmxFailed(terminationStatus: Int32)
    }

    /// Throws on non-zero exit. Use when nonzero means "the call failed".
    public static func run(
        executable: URL,
        args: [String],
        env: [String: String]
    ) throws -> String {
        let result = try capture(executable: executable, args: args, env: env)
        guard result.exitCode == 0 else {
            throw Error.zmxFailed(terminationStatus: result.exitCode)
        }
        return result.stdout
    }

    /// Returns (stdout, exitCode). Use when the exit code is diagnostic
    /// (e.g., `zmx kill` of a session that already died — nonzero is fine).
    public static func capture(
        executable: URL,
        args: [String],
        env: [String: String]
    ) throws -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = env
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        // stderr → /dev/null per GitRunner's pattern (avoids pipe deadlock
        // on chatty commands; we use captureAll if we need stderr).
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (stdout: out, exitCode: process.terminationStatus)
    }

    /// Returns (stdout, stderr, exitCode). Use when stderr carries the
    /// user-visible error on failure. Both pipes are read; safe for
    /// bounded-output commands. Don't use for chatty long-running output.
    public static func captureAll(
        executable: URL,
        args: [String],
        env: [String: String]
    ) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = env
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (stdout: out, stderr: err, exitCode: process.terminationStatus)
    }
}
