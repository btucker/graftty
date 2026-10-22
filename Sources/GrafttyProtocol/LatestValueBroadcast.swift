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
    /// Serializes publishes and replays so every observer sees values in
    /// publish order. Recursive because a value an observer's buffer drops is
    /// released inside `yield`, and its deinit may publish again.
    private let deliveryLock = NSRecursiveLock()
    /// Guards the fields below. Never held while a value or continuation can
    /// be released: a reference value's deinit may read `latest` or end an
    /// observer, and both take this lock.
    private let stateLock = NSLock()
    private var value: Value?
    private var isFinished = false
    private var observers: [UUID: AsyncStream<Value>.Continuation] = [:]

    public init() {}

    /// An `AsyncStream` never ends on its own when its continuation is
    /// released, so an owner dropped without `finish()` would strand every
    /// observer's `for await` loop.
    deinit { finish() }

    /// The most recently published value; nil until the first publish.
    public var latest: Value? {
        stateLock.withLock { value }
    }

    var observerCount: Int {
        stateLock.withLock { observers.count }
    }

    /// Records `value` and delivers it to every observer. Ignored once the
    /// broadcast has finished.
    public func publish(_ value: Value) {
        var displaced: Value?
        deliveryLock.withLock {
            let observers = stateLock.withLock { () -> [AsyncStream<Value>.Continuation] in
                guard !isFinished else { return [] }
                displaced = self.value
                self.value = value
                return Array(self.observers.values)
            }
            for observer in observers { observer.yield(value) }
        }
        // The replaced value is released here, outside both locks.
        withExtendedLifetime(displaced) {}
    }

    /// The latest value, if any, followed by every later one. The sequence
    /// ends when the broadcast finishes, immediately if it already has.
    public func updates() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            let removed = self.stateLock.withLock { self.observers.removeValue(forKey: id) }
            withExtendedLifetime(removed) {}
        }
        let registered = deliveryLock.withLock { () -> Bool in
            let current = stateLock.withLock { () -> Value?? in
                guard !isFinished else { return .none }
                observers[id] = continuation
                return .some(value)
            }
            guard let current else { return false }
            if let current { continuation.yield(current) }
            return true
        }
        // Finishing runs `onTermination`, which takes the state lock.
        if !registered { continuation.finish() }
        return stream
    }

    /// Ends every observer's sequence and ignores later publishes.
    public func finish() {
        let observers = stateLock.withLock { () -> [AsyncStream<Value>.Continuation] in
            isFinished = true
            defer { self.observers.removeAll() }
            return Array(self.observers.values)
        }
        // Outside the lock: each finish runs `onTermination` and releases
        // any buffered value.
        for observer in observers { observer.finish() }
    }
}
