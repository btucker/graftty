#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite("""
@spec PUSH-5.2: When iOS receives a remote notification with `userInfo.kind == "agent_stop_clear"`, the application shall call `UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [userInfo.collapse_id])`.
""")
struct PushReceiverTests {
    private actor FakeCenter: NotificationCenterRemover {
        private(set) var removedIDs: [String] = []
        func removeNotifications(ids: [String]) async {
            removedIDs.append(contentsOf: ids)
        }
        func snapshot() -> [String] { removedIDs }
    }

    @Test func handlesAgentStopClear() async {
        let center = FakeCenter()
        let recv = PushReceiver(remover: center)
        let userInfo: [AnyHashable: Any] = [
            "kind": "agent_stop_clear",
            "collapse_id": "/r/wt:2026-05-13T12:00:00.000Z",
        ]
        let handled = await recv.handleSilentPush(userInfo: userInfo)
        #expect(handled == true)
        let snap = await center.snapshot()
        #expect(snap == ["/r/wt:2026-05-13T12:00:00.000Z"])
    }

    @Test func ignoresUnknownKind() async {
        let center = FakeCenter()
        let recv = PushReceiver(remover: center)
        let handled = await recv.handleSilentPush(userInfo: ["kind": "something_else"])
        #expect(handled == false)
        let snap = await center.snapshot()
        #expect(snap.isEmpty)
    }

    @Test func ignoresMissingCollapseID() async {
        let center = FakeCenter()
        let recv = PushReceiver(remover: center)
        let handled = await recv.handleSilentPush(userInfo: ["kind": "agent_stop_clear"])
        #expect(handled == false)
        let snap = await center.snapshot()
        #expect(snap.isEmpty)
    }
}
#endif
