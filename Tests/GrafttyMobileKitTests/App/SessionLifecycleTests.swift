import Foundation
import SwiftUI
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
struct LiveSessionReadinessTests {

    @Test("""
@spec IOS-7.1: When the application enters the background, it shall close every active authenticated terminal channel, invalidate each paired host connection, and tear down every `InMemoryTerminalSession`. The zmx daemon remains alive per `ZMX-4.4`, so reconnect picks up the same session.
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

    @Test("""
@spec IOS-10.1: While `scenePhase` is `.inactive` or `.background`, the application shall tear down active terminal channels and unmount live `TerminalPaneView` instances so libghostty's display link stops. Entering `.background` shall additionally suspend and invalidate every paired host connection; `.inactive` may retain the shared paired connection for prompt foreground recovery.
""")
    func shouldTearDownOnInactiveAndBackground() {
        #expect(!LiveSessionReadiness.shouldTearDown(scene: .active))
        #expect(LiveSessionReadiness.shouldTearDown(scene: .inactive))
        #expect(LiveSessionReadiness.shouldTearDown(scene: .background))
    }
}

#if canImport(UIKit)
@Suite("paired transport downgrade policy")
struct PairedTransportDowngradeTests {

    @Test("""
@spec IOS-4.28: When an authenticated connection to a paired Mac is \
unavailable, GrafttyMobile shall fail closed and shall not downgrade the \
terminal to the legacy unauthenticated `/ws` transport.
""")
    func productionPolicyFailsClosed() {
        #expect(SessionClient.legacyWebSocketFallbackEnabledByDefault == false)
    }
}
#endif

@Suite
struct SessionRehydrationTests {

    @Test("""
@spec IOS-7.2: When the application foregrounds and the biometric gate is satisfied (either the ≥5 min path with re-prompt per `IOS-3.2` or the within-5-min fast path), the application shall fetch a fresh authenticated panes-state snapshot for each paired Mac whose panes were previously active and re-dial every pane whose session name is still present, re-mounting its `TerminalView`. Per `PERSIST-4.1` the application does not persist scrollback itself; whatever the zmx daemon still has is what the user sees.
""")
    func dialsWhenSessionStillListed() {
        let worktrees = [worktree(withSessions: ["alpha", "beta"])]
        let decision = SessionRehydration.decide(
            sessionName: "alpha",
            worktreesResult: .success(worktrees)
        )
        #expect(decision == .dial)
    }

    @Test("""
@spec IOS-7.3: When a previously active pane's session name is absent from the fresh authenticated panes-state snapshot (e.g., the worktree was stopped on the Mac while the iOS app was backgrounded), the application shall mark that pane as `sessionEnded` with a non-retryable banner and shall not open a terminal channel for it. The banner shall offer "Back to worktrees" as the only action.
""")
    func endsWhenSessionGoneFromList() {
        let worktrees = [worktree(withSessions: ["beta"])]
        let decision = SessionRehydration.decide(
            sessionName: "alpha",
            worktreesResult: .success(worktrees)
        )
        #expect(decision == .ended)
    }

    /// A transient panes-state transport blip on foreground shouldn't
    /// strand the user behind a non-retryable banner. Falling through
    /// to a terminal dial keeps connection-level failure handling in charge.
    @Test
    func dialsOnTransportFailureToAvoidStrandingUser() {
        let decision = SessionRehydration.decide(
            sessionName: "alpha",
            worktreesResult: .failure(URLError(.notConnectedToInternet))
        )
        #expect(decision == .dial)
    }

    private func worktree(withSessions sessions: [String]) -> WorktreePanes {
        let nodes = sessions.map {
            PaneLayoutNode.leaf(
                sessionName: $0,
                title: $0,
                attentionText: nil,
                isBusy: false,
                attentionSource: nil
            )
        }
        let layout = nodes.dropFirst().reduce(nodes.first) { accumulated, node in
            guard let accumulated else { return node }
            return .split(
                direction: .horizontal,
                ratio: 0.5,
                left: accumulated,
                right: node
            )
        }
        return WorktreePanes(
            path: "/repo",
            displayName: "repo",
            repoDisplayName: "repo",
            displayBranch: "main",
            state: .running,
            isMainCheckout: true,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: layout
        )
    }
}
