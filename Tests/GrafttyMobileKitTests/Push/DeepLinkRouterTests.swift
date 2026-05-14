#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite("DeepLinkRouter")
struct DeepLinkRouterTests {
    /// Build the same userInfo shape `AgentStopNotification.content` emits
    /// on the macOS side (kind/runtime/worktree_path/session_id/
    /// attention_timestamp). The router doesn't need to read the
    /// timestamp, but we include it so the fixture stays faithful to the
    /// over-the-wire payload.
    private static func userInfo(
        worktreePath: String = "/r/wt",
        sessionID: String = "sess",
        runtime: String = "claude"
    ) -> [AnyHashable: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return [
            "kind": "agent_stop",
            "runtime": runtime,
            "worktree_path": worktreePath,
            "session_id": sessionID,
            "attention_timestamp": iso.string(from: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
    }

    @Test("""
@spec PUSH-4.1: When the user taps an iOS alert banner, the application shall decode the `userInfo` as `AgentStopNotificationPayload` and reconstruct the navigation stack to `[HostPicker → WorktreePicker(host) → WorktreeDetail(worktreePath) → TerminalPane(sessionID)]`.
""")
    @MainActor
    func push_4_1_publishesTarget() async {
        let router = DeepLinkRouter()
        router.handleTap(userInfo: Self.userInfo(), isAppLocked: false)
        #expect(router.pendingTarget?.worktreePath == "/r/wt")
        #expect(router.pendingTarget?.sessionID == "sess")
        #expect(router.pendingTarget?.runtime == .claude)
    }

    @Test("""
@spec PUSH-4.2: When the iOS app is locked (IOS-3.1), the deep-link target shall be queued and applied only after Face ID/Touch ID resolves successfully.
""")
    @MainActor
    func push_4_2_queuesWhileLocked() async {
        let router = DeepLinkRouter()
        router.handleTap(userInfo: Self.userInfo(), isAppLocked: true)
        #expect(router.pendingTarget == nil)
        router.unlockDidSucceed()
        #expect(router.pendingTarget?.worktreePath == "/r/wt")
    }

    @Test @MainActor
    func ignoresMalformedPayloads() {
        let router = DeepLinkRouter()
        router.handleTap(userInfo: ["kind": "agent_stop_clear"], isAppLocked: false)
        #expect(router.pendingTarget == nil)
        router.handleTap(userInfo: ["kind": "agent_stop"], isAppLocked: false)
        #expect(router.pendingTarget == nil)
        router.handleTap(
            userInfo: [
                "kind": "agent_stop",
                "runtime": "unknown_runtime",
                "worktree_path": "/r/wt",
                "session_id": "sess",
            ],
            isAppLocked: false
        )
        #expect(router.pendingTarget == nil)
    }

    @Test @MainActor
    func consumeClearsPendingTarget() {
        let router = DeepLinkRouter()
        router.handleTap(userInfo: Self.userInfo(), isAppLocked: false)
        #expect(router.pendingTarget != nil)
        router.consume()
        #expect(router.pendingTarget == nil)
    }
}
#endif
