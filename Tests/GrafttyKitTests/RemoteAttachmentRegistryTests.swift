import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec TERM-11.5: The application shall track the number of remote clients attached to each zmx session; a session is remote-attached while its count is positive, and an observer fires when the count returns to zero.")
struct RemoteAttachmentRegistryTests {
    @Test func attachIncrementsAndDetachDecrements() {
        let registry = RemoteAttachmentRegistry()
        #expect(!registry.isRemoteAttached(sessionName: "s1"))

        registry.attach(sessionName: "s1")
        #expect(registry.isRemoteAttached(sessionName: "s1"))
        #expect(!registry.isRemoteAttached(sessionName: "s2"))

        registry.attach(sessionName: "s1")
        registry.detach(sessionName: "s1")
        #expect(registry.isRemoteAttached(sessionName: "s1"))

        registry.detach(sessionName: "s1")
        #expect(!registry.isRemoteAttached(sessionName: "s1"))
    }

    @Test func detachBelowZeroIsClampedAndDoesNotFireObserver() {
        let registry = RemoteAttachmentRegistry()
        let fired = LockedNames()
        registry.onLastDetach = { fired.append($0) }

        registry.detach(sessionName: "never-attached")
        #expect(fired.values().isEmpty)
        #expect(!registry.isRemoteAttached(sessionName: "never-attached"))
    }

    @Test func onLastDetachFiresOnlyWhenCountReachesZero() {
        let registry = RemoteAttachmentRegistry()
        let fired = LockedNames()
        registry.onLastDetach = { fired.append($0) }

        registry.attach(sessionName: "s1")
        registry.attach(sessionName: "s1")
        registry.detach(sessionName: "s1")
        #expect(fired.values().isEmpty)

        registry.detach(sessionName: "s1")
        #expect(fired.values() == ["s1"])
    }

    @Test func observerCanReenterRegistryWithoutDeadlock() {
        // Locking rule: onLastDetach is invoked outside the registry lock,
        // so an observer may query the registry synchronously.
        let registry = RemoteAttachmentRegistry()
        let observedDuringCallback = LockedBox<Bool?>(nil)
        registry.onLastDetach = { name in
            observedDuringCallback.set(registry.isRemoteAttached(sessionName: name))
        }
        registry.attach(sessionName: "s1")
        registry.detach(sessionName: "s1")
        #expect(observedDuringCallback.value() == false)
    }
}

/// `onLastDetach` is `@Sendable`, so test observers record through these
/// lock-protected boxes instead of capturing local mutable state.
private final class LockedNames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    func values() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func value() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
