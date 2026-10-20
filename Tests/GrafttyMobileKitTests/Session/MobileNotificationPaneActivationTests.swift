#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite("@spec NOTIF-1.28: When a resolved notification attaches its mobile pane, the application shall consume recovery intent once within that window for the matching host and pane, preserve its in-flight recovery task identity, and discard intent superseded by newer navigation.")
@MainActor
struct MobileNotificationPaneActivationTests {
    @Test("An active window cannot consume another window's notification activation")
    func windowsKeepIndependentActivation() {
        let first = MobileNotificationPaneActivation()
        let second = MobileNotificationPaneActivation()
        let host = UUID()
        first.activate(hostID: host, sessionName: "target")
        #expect(!second.consume(hostID: host, sessionName: "target"))
        second.activate(hostID: host, sessionName: "target")
        #expect(second.consume(hostID: host, sessionName: "target"))
        #expect(first.consume(hostID: host, sessionName: "target"))
    }

    @Test("Resolved notification attachment is consumed once by its matching host and pane")
    @MainActor func paneActivationDoesNotReplayAcrossRemounts() throws {
        let notifications = MobileNotificationPaneActivation()
        let host = UUID()
        notifications.activate(hostID: host, sessionName: "target")
        let occurrence = try #require(notifications.request?.id)
        #expect(!notifications.consume(hostID: UUID(), sessionName: "target"))
        #expect(!notifications.consume(hostID: host, sessionName: "other"))
        #expect(notifications.consume(hostID: host, sessionName: "target"))
        #expect(notifications.request?.id == occurrence,
                "Claiming must not cancel the task sending the recovery request")
        #expect(!notifications.consume(hostID: host, sessionName: "target"),
                "A healthy first attachment must also consume the notification before later ordinary reentry")
        notifications.activate(hostID: host, sessionName: "target")
        #expect(notifications.request?.id != occurrence)
        #expect(notifications.consume(hostID: host, sessionName: "target"))
    }

    @Test("Newer navigation discards pending notification recovery and unrelated panes cannot claim it")
    @MainActor func paneActivationHonorsNewerSelection() {
        let notifications = MobileNotificationPaneActivation()
        let host = UUID()
        notifications.activate(hostID: host, sessionName: "target")
        notifications.discard(unlessHostID: host, sessionName: "target")
        #expect(notifications.request != nil)
        notifications.discard(unlessHostID: host, sessionName: "other")
        #expect(!notifications.consume(hostID: host, sessionName: "target"))
        notifications.activate(hostID: host, sessionName: "target")
        notifications.activate(hostID: host, sessionName: "newer")
        #expect(!notifications.consume(hostID: host, sessionName: "target"))
        #expect(notifications.consume(hostID: host, sessionName: "newer"))
    }
}
#endif
