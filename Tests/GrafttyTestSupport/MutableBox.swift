import Foundation

/// A lock-guarded reference cell for state a test shares with `@Sendable`
/// closures or across tasks.
///
/// `value` locks the read and the write separately, so a read-modify-write
/// such as `box.value += 1` from concurrent tasks can lose updates. Use
/// `withValue` for those.
public final class MutableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    public init(_ value: T) { _value = value }
    public var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    /// Runs `body` with exclusive access to the stored value.
    @discardableResult
    public func withValue<R>(_ body: (inout T) throws -> R) rethrows -> R {
        try lock.withLock { try body(&_value) }
    }
}
