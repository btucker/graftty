import Foundation
import GrafttyProtocol

/// Holds one terminal's forwarding task while its client has a full window of
/// unconsumed output. Control frames do not pass through here, so they keep
/// moving while terminal bytes wait (REMOTE-9.19).
final class TerminalOutputCreditGate: @unchecked Sendable {
    private let window: UInt64
    private let lock = NSLock()
    private var sent: UInt64 = 0
    private var consumed: UInt64 = 0
    private var closed = false
    private var waiter: (bytes: UInt64, id: UUID, continuation: CheckedContinuation<Void, Error>)?

    init(windowBytes: Int) { window = UInt64(windowBytes) }

    /// Waits until `bytes` fit in the window, then counts them as sent. There
    /// is one waiter: a repeated `shell` request can start a second forwarding
    /// task, and failing that one closes the channel.
    func reserve(_ bytes: Int) async throws {
        let id = UUID()
        let bytes = UInt64(bytes)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                defer { lock.unlock() }
                if closed || Task.isCancelled || waiter != nil {
                    continuation.resume(throwing: CancellationError())
                } else if fits(bytes) {
                    sent += bytes
                    continuation.resume()
                } else {
                    waiter = (bytes, id, continuation)
                }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard waiter?.id == id else { return nil }
                defer { waiter = nil }
                return waiter?.continuation
            }
            cancelled?.resume(throwing: CancellationError())
        }
    }

    /// Applies a client's cumulative total. A claim past what was sent is not
    /// a valid acknowledgement, and an older total changes nothing.
    func acknowledge(consumed total: UInt64) {
        let released = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard total <= sent, total > consumed else { return nil }
            consumed = total
            guard let waiter, fits(waiter.bytes) else { return nil }
            sent += waiter.bytes
            self.waiter = nil
            return waiter.continuation
        }
        released?.resume()
    }

    func close() {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            closed = true
            defer { waiter = nil }
            return waiter?.continuation
        }
        pending?.resume(throwing: CancellationError())
    }

    private func fits(_ bytes: UInt64) -> Bool { sent - consumed + bytes <= window }
}
