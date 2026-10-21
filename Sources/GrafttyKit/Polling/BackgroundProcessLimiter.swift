/// FIFO asynchronous permit pool for recurring background process pipelines.
///
/// Graftty's stats, remote-ref, and PR pollers have different cadences, but
/// their ticks periodically align. Sharing one limiter keeps those aligned
/// ticks from multiplying into an unbounded burst of background pipelines.
/// Waiting tasks suspend without occupying a thread. A pipeline can still
/// contain provider-specific internal fan-out, such as GitLab MR detail calls.
public actor BackgroundProcessLimiter {
    private let capacity: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public func run<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if activeCount < capacity {
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            activeCount -= 1
        } else {
            // Transfer the active permit directly to the oldest waiter.
            waiters.removeFirst().resume()
        }
    }
}
