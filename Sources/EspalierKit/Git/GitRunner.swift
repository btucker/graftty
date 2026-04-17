import Foundation

/// Shared wrapper around `/usr/bin/git` invocation.
///
/// stderr is routed to `/dev/null` via `FileHandle.nullDevice` rather than an
/// unread `Pipe()` — an unread pipe can block git if its buffer fills
/// (seen with commands that emit warnings over large or broken ranges).
public enum GitRunner {

    public enum Error: Swift.Error, Equatable {
        case gitFailed(terminationStatus: Int32)
    }

    /// Runs git and returns stdout as a UTF-8 string. Throws
    /// `Error.gitFailed` on non-zero exit, or rethrows Process launch errors.
    /// Use when a non-zero exit means the call failed.
    public static func run(args: [String], at directory: String) throws -> String {
        let (out, code) = try capture(args: args, at: directory)
        guard code == 0 else {
            throw Error.gitFailed(terminationStatus: code)
        }
        return out
    }

    /// Runs git and returns `(stdout, terminationStatus)` without throwing
    /// on non-zero exit. Rethrows only on Process launch failure.
    /// Use when the exit code is diagnostic (e.g., `show-ref --verify`).
    public static func capture(args: [String], at directory: String) throws -> (stdout: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (stdout: out, exitCode: process.terminationStatus)
    }

    /// Runs git and returns `(stdout, stderr, exitCode)`. Use for mutation
    /// operations where stderr carries the user-visible error on failure
    /// (e.g. `worktree add` reporting "branch already exists"). Both
    /// streams are bounded-output commands in practice; the pipe-deadlock
    /// risk flagged elsewhere applies to chatty read commands, not
    /// mutations.
    public static func captureAll(args: [String], at directory: String) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
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
