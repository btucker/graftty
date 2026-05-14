import Foundation
import Testing
@testable import GrafttyKit

@Suite("AttentionPushDecider")
struct AttentionPushDeciderTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let path = "/repo/wt"

    private func payload(_ ts: Date) -> AgentStopNotificationPayload {
        AgentStopNotificationPayload(runtime: .claude, worktreePath: path,
                                     sessionID: "sess", attentionTimestamp: ts)
    }

    @Test("""
@spec PUSH-2.1: When `recordAgentStop` fires and `DesktopActivityMonitor.isUserActiveOnDesktop == false`, the application shall send an APNs alert push to every live registered device.
""")
    func push_2_1_pushesWhenInactive() {
        let dedupe = PushDedupeStore()
        #expect(AttentionPushDecider.shouldPush(
            payload: payload(now),
            isUserActiveOnDesktop: false,
            dedupe: dedupe) == true)
    }

    @Test("""
@spec PUSH-2.2: When `recordAgentStop` fires and `isUserActiveOnDesktop == true`, the application shall not send an APNs push.
""")
    func push_2_2_suppressesWhenActive() {
        let dedupe = PushDedupeStore()
        #expect(AttentionPushDecider.shouldPush(
            payload: payload(now),
            isUserActiveOnDesktop: true,
            dedupe: dedupe) == false)
    }

    @Test("""
@spec PUSH-2.4: When the same `(worktreePath, attentionTimestamp)` is observed more than once within a process lifetime, the application shall send at most one alert push.
""")
    func push_2_4_dedupes() {
        let dedupe = PushDedupeStore()
        let p = payload(now)
        #expect(AttentionPushDecider.shouldPush(
            payload: p, isUserActiveOnDesktop: false, dedupe: dedupe) == true)
        dedupe.markPushed(worktree: path, attentionTimestamp: now)
        #expect(AttentionPushDecider.shouldPush(
            payload: p, isUserActiveOnDesktop: false, dedupe: dedupe) == false)
        // A new timestamp on the same worktree pushes again.
        let p2 = payload(now.addingTimeInterval(1))
        #expect(AttentionPushDecider.shouldPush(
            payload: p2, isUserActiveOnDesktop: false, dedupe: dedupe) == true)
    }
}
