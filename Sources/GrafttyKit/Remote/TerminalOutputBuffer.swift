import Foundation
import NIO

/// One-reader PTY output queue. Only the dedicated blocking PTY reader may call
/// append; async consumers never block a cooperative executor or NIO event loop.
final class TerminalOutputBuffer: @unchecked Sendable {
    // Installed once during engine initialization, before any consumer runs.
    var onCancel: (@Sendable () -> Void)?
    private let condition = NSCondition()
    private let byteLimit: Int
    private let frameLimit: Int
    private var frames = CircularBuffer<Data>()
    private var byteCount = 0
    private var finished = false
    private var waiter: CheckedContinuation<Data?, Never>?

    init(byteLimit: Int = 2 * 1024 * 1024, frameLimit: Int = 256) {
        self.byteLimit = byteLimit
        self.frameLimit = frameLimit
    }

    /// Returns false on cancellation/close. The engine submits bounded PTY reads
    /// with at most a short replay header, so each frame fits the budget.
    func append(_ data: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        precondition(data.count <= byteLimit)
        while !finished && (frames.count >= frameLimit || data.count > byteLimit - byteCount) {
            condition.wait()
        }
        guard !finished else { return false }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            frames.append(data)
            byteCount += data.count
        }
        return true
    }

    func next() async -> Data? {
        await withCheckedContinuation { continuation in
            condition.lock()
            defer { condition.unlock() }
            if !frames.isEmpty {
                let data = frames.removeFirst()
                byteCount -= data.count
                condition.signal()
                continuation.resume(returning: data)
            } else if finished {
                continuation.resume(returning: nil)
            } else {
                precondition(waiter == nil, "TerminalByteStream has one consumer")
                waiter = continuation
            }
        }
    }

    /// EOF drains the finite queue; explicit close/cancellation discards it.
    func finish(discard: Bool = false) {
        condition.lock()
        finished = true
        if discard {
            frames = CircularBuffer()
            byteCount = 0
        }
        let waiter = self.waiter
        self.waiter = nil
        condition.broadcast()
        condition.unlock()
        waiter?.resume(returning: nil)
    }
}
