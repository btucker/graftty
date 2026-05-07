import Foundation

/// @spec TEAM-IDLE-2.6
/// Test seam over the in-process zmx PTY-write path. Production
/// implementation calls into the same writer used by the existing
/// `zmx send` CLI subcommand (graftty owns the zmx integration —
/// no subprocess fork). Tests stub it to record invocations.
public protocol ZmxWriter: Sendable {
    /// Writes `text` into the resolved pane's PTY. When `submit` is
    /// true, also dispatches a synthetic Return key event after the
    /// text so a TUI receiver (Codex / Claude in raw mode) treats the
    /// content as committed input. A trailing `\r` byte alone is not
    /// enough — TUI key handlers parse key events, not raw bytes, and
    /// ignore stray CR/LF in the input stream.
    func write(sessionName: String, text: String, submit: Bool) async throws
}
