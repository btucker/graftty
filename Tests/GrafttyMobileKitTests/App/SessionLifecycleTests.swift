import Foundation
import SwiftUI
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
struct LiveSessionReadinessTests {

    @Test("""
@spec IOS-7.1: When the application enters the background, it shall close every active `URLSessionWebSocketTask` with WebSocket close code 1000 (normal closure) and tear down every `InMemoryTerminalSession`. The server's response (SIGTERM to each `zmx attach` child per `WEB-4.5`) leaves the zmx daemon alive per `ZMX-4.4`, so reconnect picks up the same session.
""")
    func isActiveOnlyWhenForegroundedAndUnlocked() {
        // Foreground + unlocked: dial.
        #expect(LiveSessionReadiness.isActive(scene: .active, gateUnlocked: true))
        // Foreground + locked: don't open WSes behind the lock overlay (IOS-3.1).
        #expect(!LiveSessionReadiness.isActive(scene: .active, gateUnlocked: false))
        // Backgrounded: never.
        #expect(!LiveSessionReadiness.isActive(scene: .background, gateUnlocked: true))
        #expect(!LiveSessionReadiness.isActive(scene: .inactive, gateUnlocked: true))
    }
}

@Suite
struct SessionRehydrationTests {

    @Test("""
@spec IOS-7.2: When the application foregrounds and the biometric gate is satisfied (either the ≥5 min path with re-prompt per `IOS-3.2` or the within-5-min fast path), the application shall re-fetch `/sessions` for each host whose panes were previously active and then re-dial every pane whose session name is still present in the response, re-mounting its `TerminalView`. Per `PERSIST-4.1` the application does not persist scrollback itself; whatever the zmx daemon still has is what the user sees.
""")
    func dialsWhenSessionStillListed() {
        let sessions = [
            SessionInfo(name: "alpha", worktreePath: "/", repoDisplayName: "r", worktreeDisplayName: "alpha"),
            SessionInfo(name: "beta", worktreePath: "/", repoDisplayName: "r", worktreeDisplayName: "beta"),
        ]
        let decision = SessionRehydration.decide(
            sessionName: "alpha",
            sessionsResult: .success(sessions)
        )
        #expect(decision == .dial)
    }

    @Test("""
@spec IOS-7.3: When a previously active pane's session name is absent from the fresh `/sessions` response (e.g., the worktree was stopped on the Mac while the iOS app was backgrounded), the application shall mark that pane as `sessionEnded` with a non-retryable banner and shall not open a WebSocket for it. The banner shall offer "Back to sessions" as the only action.
""")
    func endsWhenSessionGoneFromList() {
        let sessions = [
            SessionInfo(name: "beta", worktreePath: "/", repoDisplayName: "r", worktreeDisplayName: "beta"),
        ]
        let decision = SessionRehydration.decide(
            sessionName: "alpha",
            sessionsResult: .success(sessions)
        )
        #expect(decision == .ended)
    }

    /// A transient `/sessions` transport blip on foreground shouldn't
    /// strand the user behind a non-retryable banner. Falling through
    /// to a WS dial keeps WS-level failure handling in charge of the
    /// genuinely-broken case.
    @Test
    func dialsOnTransportFailureToAvoidStrandingUser() {
        let decision = SessionRehydration.decide(
            sessionName: "alpha",
            sessionsResult: .failure(URLError(.notConnectedToInternet))
        )
        #expect(decision == .dial)
    }
}
