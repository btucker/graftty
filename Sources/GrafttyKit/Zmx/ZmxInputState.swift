import Foundation

/// Tracks per-zmx-session bytes typed since the last CR/LF, specifically
/// bytes from web-session routes (`WebSession.write(_:)` and
/// `SurfaceHandle.typeText(_:)`). Per-session instances are optional and
/// owned by the callers that need them (web-attached sessions).
///
/// Note: this type was part of an earlier idle-delivery design. The
/// current event-driven design (TEAM-IDLE-2.2) uses `PaneInputActivityRegistry`
/// to observe all keystroke boundaries (native + web) and gates on a 60s
/// inactivity timer. `ZmxInputState` is retained for web-session typing
/// state tracking and may be used by future refinements.
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
