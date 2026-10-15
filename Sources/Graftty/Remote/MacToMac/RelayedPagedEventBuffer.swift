import Foundation
import GrafttyProtocol

/// One consumer drains this attachment's ordered events. Adjacent output can
/// share a batch; checkpoints, grids and history remain ordering barriers.
final class RelayedPagedEventBuffer: @unchecked Sendable {
    enum EnqueueResult: Equatable { case accepted, overflow, finished }
    static let byteLimit = 4 * 1024 * 1024
    private static let eventLimit = 256
    private static let batchByteLimit = 256 * 1024
    private let lock = NSLock()
    private var buffered: [PagedTerminalEvent] = []
    private var bufferedBytes = 0
    private var waiter: CheckedContinuation<PagedTerminalEvent?, Never>?
    private var finished = false
    // Reserve one terminal outcome independently of the output budget.
    private var exitStatus: Int32?

    func enqueue(_ event: PagedTerminalEvent) -> EnqueueResult {
        if case .ended(let status) = event {
            finish(exitStatus: status)
            return .accepted
        }
        lock.lock()
        guard !finished else { lock.unlock(); return .finished }
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: event)
            return .accepted
        }
        let bytes = Self.payloadBytes(event)
        guard bytes <= Self.byteLimit - bufferedBytes else { lock.unlock(); return .overflow }
        if case .output(let data) = event,
           let lastBytes = buffered.last.flatMap(Self.outputByteCount),
           lastBytes <= Self.batchByteLimit - data.count {
            // Remove the old event before appending, so its Data can grow
            // without the queue retaining a second copy of every partial batch.
            if case .output(var batch) = buffered.removeLast() {
                batch.append(data)
                buffered.append(.output(batch))
            }
        } else {
            guard buffered.count < Self.eventLimit else { lock.unlock(); return .overflow }
            buffered.append(event)
        }
        bufferedBytes += bytes
        lock.unlock()
        return .accepted
    }

    func next() async -> PagedTerminalEvent? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !buffered.isEmpty {
                let event = buffered.removeFirst()
                bufferedBytes -= Self.payloadBytes(event)
                lock.unlock()
                continuation.resume(returning: event)
            } else if let status = exitStatus {
                exitStatus = nil
                lock.unlock()
                continuation.resume(returning: .ended(status))
            } else if finished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                precondition(waiter == nil, "A relayed terminal has one event consumer")
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func finish(exitStatus: Int32? = nil) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        self.exitStatus = exitStatus
        let waiter = self.waiter
        self.waiter = nil
        if waiter != nil { self.exitStatus = nil }
        lock.unlock()
        waiter?.resume(returning: exitStatus.map(PagedTerminalEvent.ended))
    }

    func cancel() {
        lock.lock()
        finished = true
        buffered.removeAll()
        bufferedBytes = 0
        exitStatus = nil
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    private static func outputByteCount(_ event: PagedTerminalEvent) -> Int? {
        if case .output(let data) = event { return data.count }
        return nil
    }

    private static func payloadBytes(_ event: PagedTerminalEvent) -> Int {
        switch event {
        case .output(let bytes): return bytes.count
        case .checkpoint(let checkpoint): return checkpoint.ready.count
        case .page(let page): return page.data.count
        case .grid, .unavailable, .ended: return 0
        }
    }
}
