import Foundation

/// Lets a terminal's receive loop wait while its parser is behind. The parser
/// entry point never blocks, so without this the transport's backlog moves
/// into memory the transport cannot see (IOS-4.60).
public final class TerminalOutputBacklogGate: @unchecked Sendable {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let deadline: Task<Void, Never>

        func finish() {
            deadline.cancel()
            continuation.resume()
        }
    }

    private let lock = NSLock()
    private var backlogged = false
    private var waiters: [UUID: Waiter] = [:]

    public init() {}

    public func setBacklogged(_ value: Bool) {
        let released = lock.withLock { () -> [Waiter] in
            backlogged = value
            guard !value else { return [] }
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        released.forEach { $0.finish() }
    }

    /// Returns when the backlog clears, the timeout passes or the task is
    /// cancelled. The timeout keeps a parser that cannot drain (no surface is
    /// attached, for example) from stopping every later control frame.
    public func waitUntilClear(timeout: Duration) async {
        // Every output frame passes here, and almost none find a backlog.
        guard lock.withLock({ backlogged }) else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let wait = lock.withLock {
                    guard backlogged, !Task.isCancelled else { return false }
                    // Armed under the lock, so even an immediate expiry finds this waiter.
                    let deadline = Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.release(id)
                    }
                    waiters[id] = Waiter(continuation: continuation, deadline: deadline)
                    return true
                }
                if !wait { continuation.resume() }
            }
        } onCancel: {
            release(id)
        }
    }

    private func release(_ id: UUID) {
        lock.withLock { waiters.removeValue(forKey: id) }?.finish()
    }
}
