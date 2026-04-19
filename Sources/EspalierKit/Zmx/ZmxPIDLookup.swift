import Foundation

/// Recovers the inner-shell PID for a zmx session by parsing its
/// daemon log. The zmx daemon writes one
///
///     [<ts>] [info] (default): pty spawned session=<name> pid=<N>
///
/// line per spawn to `<ZMX_DIR>/logs/<session>.log`; the most recent
/// match is the live PID. Backs `PWD-1.3` when OSC 7 is silent.
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
    public static func shellPID(logFile: URL, sessionName: String) -> Int32? {
        guard let contents = try? String(contentsOf: logFile, encoding: .utf8) else {
            return nil
        }
        return shellPID(fromLogContents: contents, sessionName: sessionName)
    }

    private static func parsePID<S: StringProtocol>(from line: S) -> Int32? {
        guard let range = line.range(of: "pid=") else { return nil }
        let digits = line[range.upperBound...].prefix(while: \.isNumber)
        return Int32(digits)
    }
}
