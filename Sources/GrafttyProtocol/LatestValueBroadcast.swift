import Foundation

/// @spec REMOTE-6.12
/// When a client observes a changing value through a latest-value broadcast,
/// the application shall first deliver the latest published value, then
/// deliver only the newest value published while the observer was busy, and
/// shall end every observation once the broadcast finishes.
///
/// The latest value of something that changes, handed to any number of async
/// observers. Publishing never awaits, so an actor and `@MainActor` code can
/// both feed it; each observer buffers only the newest unread value, so a
/// slow observer coalesces bursts instead of replaying stale ones. Equality
/// filtering is left to observers. See
/// docs/superpowers/specs/2026-10-22-observable-worktree-store.md.
public final class LatestValueBroadcast<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var isFinished = false
    private var observers: [UUID: AsyncStream<Value>.Continuation] = [:]

    public init() {}

    /// The most recently published value; nil until the first publish.
    public var latest: Value? {
        lock.withLock { value }
    }

    var observerCount: Int {
        lock.withLock { observers.count }
    }

    /// Records `value` and delivers it to every observer. Ignored once the
    /// broadcast has finished.
    public func publish(_ value: Value) {
        // Yield under the lock so concurrent publishers cannot leave an
        // observer holding an older value than `latest`. Yielding never
        // re-enters the lock; only termination does.
        lock.withLock {
            guard !isFinished else { return }
            self.value = value
            for observer in observers.values { observer.yield(value) }
        }
    }

    /// The latest value, if any, followed by every later one. The sequence
    /// ends when the broadcast finishes, immediately if it already has.
    public func updates() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.observers.removeValue(forKey: id) }
        }
        let registered = lock.withLock { () -> Bool in
            guard !isFinished else { return false }
            observers[id] = continuation
            if let value { continuation.yield(value) }
            return true
        }
        // Finishing outside the lock: termination re-enters it.
        if !registered { continuation.finish() }
        return stream
    }

    /// Ends every observer's sequence and ignores later publishes.
    public func finish() {
        let observers = lock.withLock { () -> [AsyncStream<Value>.Continuation] in
            isFinished = true
            defer { self.observers.removeAll() }
            return Array(self.observers.values)
        }
        // Outside the lock: each finish runs `onTermination`, which takes it.
        for observer in observers { observer.finish() }
    }
}
