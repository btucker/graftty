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
        var fired: [String] = []
        registry.onLastDetach = { fired.append($0) }

        registry.detach(sessionName: "never-attached")
        #expect(fired.isEmpty)
        #expect(!registry.isRemoteAttached(sessionName: "never-attached"))
    }

    @Test func onLastDetachFiresOnlyWhenCountReachesZero() {
        let registry = RemoteAttachmentRegistry()
        var fired: [String] = []
        registry.onLastDetach = { fired.append($0) }

        registry.attach(sessionName: "s1")
        registry.attach(sessionName: "s1")
        registry.detach(sessionName: "s1")
        #expect(fired.isEmpty)

        registry.detach(sessionName: "s1")
        #expect(fired == ["s1"])
    }

    @Test func observerCanReenterRegistryWithoutDeadlock() {
        // Locking rule: onLastDetach is invoked outside the registry lock,
        // so an observer may query the registry synchronously.
        let registry = RemoteAttachmentRegistry()
        var observedDuringCallback: Bool? = nil
        registry.onLastDetach = { name in
            observedDuringCallback = registry.isRemoteAttached(sessionName: name)
        }
        registry.attach(sessionName: "s1")
        registry.detach(sessionName: "s1")
        #expect(observedDuringCallback == false)
    }
}
