#if canImport(UIKit)
import Foundation
@testable import GrafttyMobileKit

/// Test-only Clock whose `sleep(for:)` only resolves when the test
/// explicitly calls `advance(by:)`. Lets us assert backoff timing
/// without real time passing.
final class VirtualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    init(start: Date = Date(timeIntervalSince1970: 1_000_000_000)) {
        self._now = start
    }

    var now: Date { lock.withLock { _now } }

    func sleep(for duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                let deadline = _now.addingTimeInterval(duration)
                sleepers.append((deadline, continuation))
            }
        }
    }

    /// Move clock forward and resume any sleepers whose deadlines fell within
    /// the elapsed window. Resumes outside the lock so continuations are free
    /// to call back into the clock.
    func advance(by duration: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            _now = _now.addingTimeInterval(duration)
            let due = sleepers.filter { $0.deadline <= _now }
            sleepers.removeAll { $0.deadline <= _now }
            return due.map(\.continuation)
        }
        for cont in ready { cont.resume() }
    }

    /// Count of pending sleepers — useful for asserting "the watchdog
    /// is currently parked waiting for time to pass."
    var pendingSleepCount: Int { lock.withLock { sleepers.count } }
}
#endif
