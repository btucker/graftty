#if canImport(UIKit)
import Foundation
import NIOConcurrencyHelpers
@testable import GrafttyMobileKit

/// A fake `WebSocketClient` for the ownership-model harness iOS tests.
///
/// `receive()` suspends (via a `CheckedContinuation`) until the harness
/// enqueues a frame via `enqueueIncoming(_:)`, feeding the real
/// `SessionClient` receive loop without wall-clock waits.
///
/// `awaitDrained()` suspends until the queue is empty AND `receive()` has
/// re-parked in its continuation — i.e. the client is quiescent.  Use this
/// in `pumpIOS()` after enqueueing a batch of frames to synchronise without
/// `Task.sleep`.
final class FakeWebSocketClient: WebSocketClient, @unchecked Sendable {
    private let lock = NIOLock()
    private var queue: [WebSocketFrame] = []
    private var waitingReceiveCont: CheckedContinuation<WebSocketFrame, Error>?
    private var drainedCont: CheckedContinuation<Void, Never>?

    // Ownership transport requires web-control text frames.
    var supportsWebControlTextFrames: Bool { true }

    // MARK: WebSocketClient

    func send(_ frame: WebSocketFrame) async throws {
        // Outbound frames are not consumed by these tests; discard them.
    }

    /// Suspends until a frame is available via `enqueueIncoming(_:)`.
    ///
    /// When the queue becomes empty the method signals the drain continuation
    /// (set by `awaitDrained()`) before parking — this is the quiescence
    /// signal that `pumpIOS()` waits on.
    func receive() async throws -> WebSocketFrame {
        // Fast path: frame already queued.
        if let frame = lock.withLock({ queue.isEmpty ? nil : queue.removeFirst() }) {
            return frame
        }
        // Queue empty — wake anyone waiting for drain, then park.
        let drained = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let c = drainedCont
            drainedCont = nil
            return c
        }
        drained?.resume()

        return try await withCheckedThrowingContinuation { cont in
            lock.withLock { waitingReceiveCont = cont }
        }
    }

    /// Called by `SessionClient.stop()` to clean up the parked receive loop.
    func close() {
        let cont = lock.withLock { () -> CheckedContinuation<WebSocketFrame, Error>? in
            let c = waitingReceiveCont
            waitingReceiveCont = nil
            return c
        }
        cont?.resume(throwing: CancellationError())
    }

    // MARK: Harness controls

    /// Feed one frame to the receive loop.
    ///
    /// If `receive()` is already parked the continuation is resumed immediately
    /// (no enqueue); otherwise the frame is appended to the FIFO queue for the
    /// next `receive()` call.
    func enqueueIncoming(_ frame: WebSocketFrame) {
        let waiting = lock.withLock { () -> CheckedContinuation<WebSocketFrame, Error>? in
            if let c = waitingReceiveCont {
                waitingReceiveCont = nil
                return c
            }
            queue.append(frame)
            return nil
        }
        waiting?.resume(returning: frame)
    }

    /// Wait until all enqueued frames have been consumed AND the receive loop
    /// has re-parked in `receive()`.
    ///
    /// Mechanism: when `receive()` is called with an empty queue it signals
    /// `drainedCont` before suspending.  So this method either returns
    /// immediately (already parked) or sets `drainedCont` and awaits.
    func awaitDrained() async {
        // Fast path: already parked.
        let parked = lock.withLock { queue.isEmpty && waitingReceiveCont != nil }
        if parked { return }

        await withCheckedContinuation { continuation in
            lock.withLock {
                if queue.isEmpty && waitingReceiveCont != nil {
                    // Re-check inside lock to avoid race between outer check and
                    // the continuation setup.
                    continuation.resume()
                } else {
                    drainedCont = continuation
                }
            }
        }
    }
}
#endif
