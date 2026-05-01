import Foundation
import SwiftUI
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
struct LiveSessionReadinessTests {

    @Test
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

    @Test
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

    /// IOS-7.3: a previously-active pane whose session vanished from
    /// `/sessions` (e.g., the worktree was stopped on the Mac while
    /// iOS was in the background) shall not silently re-open a doomed
    /// WebSocket — surface the banner instead.
    @Test
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
