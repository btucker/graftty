import Testing
@testable import GrafttyKit
import GrafttyProtocol

@Suite("Ownership model harness smoke")
struct SmokeTests {
    @Test func storeIsReachableFromHarnessTarget() throws {
        let store = SessionDisplayOwnershipStore()
        let snap = store.snapshot(sessionName: "s")
        #expect(snap.isOwnerless)
    }
}
