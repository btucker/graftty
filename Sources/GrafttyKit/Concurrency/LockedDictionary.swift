import Foundation

/// Thread-safe dictionary wrapper using `NSLock`. Used by registries
/// that need synchronous reads and writes from arbitrary contexts —
/// hook callbacks (off main), SwiftUI observers (on main), and delivery
/// tasks. An `actor` would force the call sites async; the underlying
/// contention is microscopic, so a non-reentrant lock is the lightest fit.
public final class LockedDictionary<K: Hashable, V>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [K: V] = [:]

    public init() {}

    public func get(_ key: K) -> V? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ key: K, _ value: V) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func remove(_ key: K) {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    /// Atomic compare-and-update. The transform runs under the lock so
    /// reads and writes can't race. Setting the inout `V?` to nil
    /// removes the key. Used for conditional transitions like "flip
    /// state only if currently `.idle`".
    public func update(_ key: K, _ transform: (inout V?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var value = storage[key]
        transform(&value)
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}
