import Foundation
@testable import Graftty

/// Injected `HostManagedZmxSession` for the ownership-model harness.
/// Records every PTY resize and write; fires observability hooks before
/// recording so ownership checks see the store state at the moment of the call.
final class FakeZmxSession: HostManagedZmxSession {
    private let lock = NSLock()
    private var _resizes: [(UInt16, UInt16)] = []
    private var _writes: [Data] = []

    /// Called synchronously inside `resize` before the size is recorded.
    var onResize: ((UInt16, UInt16) -> Void)?
    /// Called synchronously inside `write` before the data is recorded.
    var onWrite: ((Data) -> Void)?

    var resizes: [(UInt16, UInt16)] {
        lock.lock()
        defer { lock.unlock() }
        return _resizes
    }

    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _writes
    }

    func start() throws {}

    func write(_ data: Data) throws {
        onWrite?(data)
        lock.lock()
        _writes.append(data)
        lock.unlock()
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        onResize?(cols, rows)
        lock.lock()
        _resizes.append((cols, rows))
        lock.unlock()
    }

    func close() {}
}
