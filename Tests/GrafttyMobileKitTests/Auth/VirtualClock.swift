#if canImport(UIKit)
import Foundation
@testable import GrafttyMobileKit

final class VirtualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var sleepers: [UUID: Sleeper] = [:]

    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    init(start: Date = Date(timeIntervalSince1970: 1_000_000_000)) {
        self._now = start
    }

    var now: Date { lock.withLock { _now } }

    func sleep(for duration: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    let deadline = _now.addingTimeInterval(duration)
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                }
            }
        } onCancel: {
            let toCancel = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                let sleeper = sleepers.removeValue(forKey: id)
                return sleeper?.continuation
            }
            toCancel?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            _now = _now.addingTimeInterval(duration)
            let dueIds = sleepers.compactMap { $0.value.deadline <= _now ? $0.key : nil }
            let conts = dueIds.map { sleepers[$0]!.continuation }
            for id in dueIds { sleepers.removeValue(forKey: id) }
            return conts
        }
        for cont in ready { cont.resume() }
    }

    var pendingSleepCount: Int { lock.withLock { sleepers.count } }
}
#endif
