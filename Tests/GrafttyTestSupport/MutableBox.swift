import Foundation

/// A lock-guarded reference cell for state a test shares with `@Sendable`
/// closures or across tasks.
public final class MutableBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    public init(_ value: T) { _value = value }
    public var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
