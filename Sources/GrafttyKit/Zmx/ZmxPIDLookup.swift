import Foundation

/// Recovers the inner-shell PID for a zmx session by parsing its
/// daemon log. The zmx daemon writes one
///
///     [<ts>] [info] (default): pty spawned session=<name> pid=<N>
///
/// line per spawn to `<ZMX_DIR>/logs/<session>.log`; the most recent
/// match is the live PID. Backs the right-click "Move to current
/// worktree" menu (PWD-1.1), which needs the inner-shell PID to ask
/// the kernel for its cwd.
public enum ZmxPIDLookup {

    public static func shellPID(
        fromLogContents contents: String,
        sessionName: String
    ) -> Int32? {
        // Reverse order → first match is newest spawn.
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains("pty spawned"),
                  line.contains("session=\(sessionName)"),
                  let pid = parsePID(from: line)
            else { continue }
            return pid
        }
        return nil
    }

    /// Nil on missing/unreadable log — caller skips the poll for that pane.
    ///
    /// zmx rotates each session's `<session>.log` to `<session>.log.old`
    /// once it reaches its size threshold (~5MB). The `pty spawned` line
    /// that `shellPID(fromLogContents:sessionName:)` parses can therefore
    /// live in the rotated file while the post-rotation `.log` is still
    /// too fresh to contain one. We look in the current log first (so a
    /// post-rotation respawn supersedes stale PIDs in `.log.old`) and
    /// fall back to the rotated file only when the current log has no
    /// matching line — otherwise the PID-based cwd lookup (PWD-1.1)
    /// stays silent for the remaining lifetime of every long-lived
    /// session, which is exactly how this bug manifested in practice.
    public static func shellPID(logFile: URL, sessionName: String) -> Int32? {
        if let contents = try? String(contentsOf: logFile, encoding: .utf8),
           let pid = shellPID(fromLogContents: contents, sessionName: sessionName) {
            return pid
        }
        let rotated = rotatedLogURL(for: logFile)
        guard let contents = try? String(contentsOf: rotated, encoding: .utf8) else {
            return nil
        }
        return shellPID(fromLogContents: contents, sessionName: sessionName)
    }

    /// Compute the rotated sibling path (`<name>.log` → `<name>.log.old`).
    /// Extracted so the fallback path is testable without hardcoding the
    /// suffix at the call site.
    static func rotatedLogURL(for logFile: URL) -> URL {
        logFile.deletingLastPathComponent()
            .appendingPathComponent(logFile.lastPathComponent + ".old")
    }

    private static func parsePID<S: StringProtocol>(from line: S) -> Int32? {
        guard let range = line.range(of: "pid=") else { return nil }
        let digits = line[range.upperBound...].prefix(while: \.isNumber)
        return Int32(digits)
    }
}
