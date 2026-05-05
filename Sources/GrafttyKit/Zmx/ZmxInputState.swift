import Foundation

/// @spec TEAM-IDLE-2.2
/// Tracks per-zmx-session bytes typed since the last CR/LF. Used by the
/// idle-delivery service to gate zmx-send: when a session has uncommitted
/// input, it would clobber the user's typing to inject a nudge.
///
/// # Where the bytes come from
///
/// Graftty's in-app panes route keystrokes through libghostty's
/// `ghostty_surface_key` / `ghostty_surface_text` C entry points, which
/// write directly into the PTY without surfacing the bytes back to Swift —
/// so we cannot observe local-pane keystrokes from this layer. We instead
/// instrument the boundaries graftty *does* control:
///
/// - `WebSession.write(_:)` — bytes from a remote WebSocket client.
/// - `SurfaceHandle.typeText(_:)` — programmatic text injection (e.g. the
///   default-command primer).
///
/// The native-keyboard gap is acceptable for the idle-delivery use case:
/// a user actively typing into a Codex pane is by definition not idle, so
/// the 60 s freshness gate (TEAM-IDLE-2.1) already covers them. The
/// uncommitted-byte gate exists to catch the narrower case where the user
/// is typing through a path graftty *does* see (web client, scripted
/// injection) and would otherwise have a partial line clobbered.
public final class ZmxInputState: @unchecked Sendable {
    private var counts: [String: Int] = [:]
    private let lock = NSLock()

    public init() {}

    public func recordInput(_ data: Data, forSession sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        var count = counts[sessionID] ?? 0
        for byte in data {
            if byte == 0x0A || byte == 0x0D {  // LF or CR
                count = 0
            } else {
                count += 1
            }
        }
        counts[sessionID] = count
    }

    public func uncommittedBytes(forSession sessionID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[sessionID] ?? 0
    }

    public func removeSession(_ sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        counts.removeValue(forKey: sessionID)
    }
}
