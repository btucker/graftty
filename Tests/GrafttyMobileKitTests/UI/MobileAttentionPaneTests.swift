#if canImport(UIKit)
import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit

@Suite("Mobile Attention pane")
struct MobileAttentionPaneTests {
    @MainActor
    @Test("@spec IOS-4.33: When a paired Mac sends a stopped-agent recap, GrafttyMobile shall display it through the shared Attention pane within a compact iPhone width.")
    func recapFitsPhoneAttentionPane() {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
            recap: .init(title: "Paired-device push notifications",
                         context: "The client integration is committed.",
                         completed: "CI passed.",
                         next: "Verify delivery on the phone.",
                         need: "Which device should receive the test?"),
            paneTitle: "Verify push delivery")
        let worktree = WorktreePanes(
            path: "/repo/.worktrees/push", displayName: "push",
            repoDisplayName: "graftty", displayBranch: "push",
            state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "push-id", projectID: "project-id",
                           unseenAgentStop: stop, emoji: "📲")
        )
        let items = SidebarProjection.activity([worktree])
        let projects = SidebarProjection.projects([worktree])
        #expect(items.count == 1)
        #expect(items[0].agentStop?.recap?.need == "Which device should receive the test?")

        let navigation = SidebarNavigationState(prefix: "mobile-attention-test.\(UUID().uuidString)")
        navigation.enterAttention(projects: projects, items: items)
        let root = SidebarAttentionList(
            navigation: navigation, items: items, projects: projects,
            onOpen: { _ in true }
        )
        let host = UIHostingController(rootView: root)
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 640))
        #expect(size.width > 0 && size.width <= 320)
        #expect(size.height > 0 && size.height <= 640)
    }
}
#endif
