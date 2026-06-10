import Foundation
import os

/// @spec TERM-11.5
/// The application shall track the number of remote clients attached to each
/// zmx session; a session is remote-attached while its count is positive, and
/// an observer fires when the count returns to zero.
///
/// Fed by both remote attach paths — `WebSession` (WebSocket `/ws` bridge)
/// and `ZmxAttachStream` (SSH-over-WebRTC terminal channel). Consulted by
/// `HostManagedZmxBackend` to decide whether the IOS-12.1 silent gate
/// applies: the Mac pane withholds PTY resizes only while a remote client
/// is attached to the same session.
///
/// Locking: `onLastDetach` is invoked OUTSIDE the registry lock, on the
/// detaching caller's thread. Observers may take their own locks (the
/// host-managed backend does) without deadlocking against `isRemoteAttached`
/// calls made under those locks. Because the lock is released before the
/// callback runs, the count may have gone positive again by the time the
/// observer executes — observers should re-check `isRemoteAttached` rather
/// than treat the callback as authoritative.
public final class RemoteAttachmentRegistry: @unchecked Sendable {
    /// Render-desync diagnostic trail (TERM-11.x): `log stream --predicate
    /// 'subsystem == "com.graftty.app" AND category == "resize-trace"'`.
    private static let trace = Logger(subsystem: "com.graftty.app", category: "resize-trace")
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var storedOnLastDetach: (@Sendable (String) -> Void)?

    /// Fires when a session's attach count drops to zero. Single observer
    /// slot — assigning replaces any prior observer. Invoked outside the
    /// registry's lock, on the detaching caller's thread.
    public var onLastDetach: (@Sendable (String) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedOnLastDetach
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedOnLastDetach = newValue
        }
    }

    public init() {}

    public func attach(sessionName: String) {
        lock.lock()
        counts[sessionName, default: 0] += 1
        let newCount = counts[sessionName] ?? 0
        lock.unlock()
        Self.trace.notice("attach \(sessionName, privacy: .public) count=\(newCount)")
    }

    public func detach(sessionName: String) {
        lock.lock()
        let current = counts[sessionName] ?? 0
        let droppedToZero = current == 1
        if current <= 1 {
            counts.removeValue(forKey: sessionName)
        } else {
            counts[sessionName] = current - 1
        }
        let callback = droppedToZero ? storedOnLastDetach : nil
        lock.unlock()
        Self.trace.notice("detach \(sessionName, privacy: .public) count=\(max(0, current - 1)) wasTracked=\(current > 0)")
        callback?(sessionName)
    }

    public func isRemoteAttached(sessionName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (counts[sessionName] ?? 0) > 0
    }
}
