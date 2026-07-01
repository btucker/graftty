#if canImport(UIKit)
import Foundation
import NIOConcurrencyHelpers
@testable import GrafttyMobileKit

/// Deterministic `Clock` for the ownership-model harness iOS tests.
///
/// Time never advances on its own.  `sleep(for:)` parks the calling task
/// in a continuation until either `advance(by:)` fires it or the task is
/// cancelled.  This keeps the idle-watchdog and reconnect-backoff paths
/// suspended for the duration of the test without consuming real time.
///
/// Identical contract to `VirtualClock` in `GrafttyMobileKitTests`; duplicated
/// here because `GrafttyMobileKitTests` is a separate test target.
final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NIOLock()
    private var _now: Date
    private var _nextID: Int = 0
    private var sleepers: [Int: (deadline: Date, cont: CheckedContinuation<Void, Error>)] = [:]

    init(start: Date = Date(timeIntervalSince1970: 1_000_000_000)) {
        _now = start
    }

    var now: Date { lock.withLock { _now } }

    func sleep(for duration: TimeInterval) async throws {
        let id = lock.withLock { () -> Int in
            let i = _nextID; _nextID += 1; return i
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.withLock {
                    let deadline = _now.addingTimeInterval(duration)
                    sleepers[id] = (deadline, cont)
                }
            }
        } onCancel: {
            let cont = self.lock.withLock { self.sleepers.removeValue(forKey: id)?.cont }
            cont?.resume(throwing: CancellationError())
        }
    }

    /// Advance virtual time, resuming any sleepers whose deadline has passed.
    func advance(by duration: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            _now = _now.addingTimeInterval(duration)
            let due = sleepers.filter { $0.value.deadline <= _now }.map(\.key)
            let conts = due.map { sleepers[$0]!.cont }
            for k in due { sleepers.removeValue(forKey: k) }
            return conts
        }
        for c in ready { c.resume() }
    }

    var pendingSleepCount: Int { lock.withLock { sleepers.count } }
}
#endif
