import Foundation
import NIO

/// One-reader PTY output queue. Only the dedicated blocking PTY reader may call
/// append; async consumers never block a cooperative executor or NIO event loop.
final class TerminalEventBuffer<Element: Sendable>: @unchecked Sendable {
    // Installed once during engine initialization, before any consumer runs.
    var onCancel: (@Sendable () -> Void)?
    var onBackpressure: (@Sendable () -> Void)?
    private let condition = NSCondition()
    private let byteLimit: Int
    private let frameLimit: Int
    private let size: @Sendable (Element) -> Int
    private var frames = CircularBuffer<Element>()
    private var byteCount = 0
    private var finished = false
    private var waiter: CheckedContinuation<Element?, Never>?

    init(byteLimit: Int = 2 * 1024 * 1024, frameLimit: Int = 256, size: @escaping @Sendable (Element) -> Int) {
        self.size = size
        self.byteLimit = byteLimit
        self.frameLimit = frameLimit
    }

    /// Returns false on cancellation/close. The engine submits bounded PTY reads
    /// with at most a short replay header, so each frame fits the budget.
    func append(_ data: Element) -> Bool {
        let count = size(data)
        condition.lock()
        defer { condition.unlock() }
        precondition(count >= 0 && count <= byteLimit)
        var reportedPressure = false
        while !finished && (frames.count >= frameLimit || count > byteLimit - byteCount) {
            if !reportedPressure, let onBackpressure {
                reportedPressure = true
                condition.unlock()
                onBackpressure()
                condition.lock()
                continue
            }
            condition.wait()
        }
        guard !finished else { return false }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            frames.append(data)
            byteCount += count
        }
        return true
    }

    func next() async -> Element? {
        await withCheckedContinuation { continuation in
            condition.lock()
            defer { condition.unlock() }
            if !frames.isEmpty {
                let data = frames.removeFirst()
                byteCount -= size(data)
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

typealias TerminalOutputBuffer = TerminalEventBuffer<Data>

extension TerminalEventBuffer where Element == Data {
    convenience init(byteLimit: Int = 2 * 1024 * 1024, frameLimit: Int = 256) {
        self.init(byteLimit: byteLimit, frameLimit: frameLimit, size: { $0.count })
    }
}
