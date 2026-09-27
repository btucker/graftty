#if canImport(UIKit)
import Foundation
@testable import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import Testing
import UIKit

@Suite("Mobile Attention pane")
struct MobileAttentionPaneTests {
    @MainActor
    @Test("@spec IOS-4.36: While the mobile Attention list is displayed, every card shall remain expanded with its available recap text visible, including unselected and previously viewed cards.")
    func allMobileCardsStayExpanded() {
        let navigation = SidebarNavigationState(prefix: "expanded-attention.\(UUID())")
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
            recap: .init(title: "Push delivery", completed: "Built the client.", next: "Verify delivery."))
        let worktree = WorktreePanes(path: "/push", displayName: "push", repoDisplayName: "graftty",
            displayBranch: "push", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "push", projectID: "project", unseenAgentStop: stop))
        let item = SidebarProjection.activity([worktree])[0]
        let list = SidebarAttentionList(navigation: navigation, items: [item],
            projects: SidebarProjection.projects([worktree]), compactHeader: true, expandsAllCards: true,
            onOpen: { _ in true })
        for style: SidebarAttentionList.RowStyle in [.stopped, .question, .other, .viewed] {
            #expect(list.rowStyle(for: item, requested: style) == .expanded)
        }
        navigation.opened(item)
        #expect(list.rowStyle(for: item, requested: .stopped) == .expanded)
    }

    @MainActor
    @Test("@spec IOS-4.35: While Attention is displayed on a compact mobile screen, the application shall use an inline host title and a single-row filter and search header, revealing the search field only when requested or when a query is active.")
    func compactHeaderReservesSpaceForCards() {
        let navigation = SidebarNavigationState(prefix: "compact-attention.\(UUID())")
        let header = UIHostingController(rootView: SidebarAttentionHeader(navigation: navigation, compact: true))
        let size = header.sizeThatFits(in: CGSize(width: 320, height: 500))
        #expect(size.height <= 52)
        navigation.query = "push"
        let searchHeader = UIHostingController(rootView: SidebarAttentionHeader(navigation: navigation, compact: true))
        let searching = searchHeader.sizeThatFits(in: CGSize(width: 320, height: 500))
        #expect(searching.height > size.height)
        #expect(searching.width <= 320)
    }

    @MainActor
    @Test("@spec IOS-4.33: When a paired Mac sends a stopped-agent recap, GrafttyMobile shall display it through the shared Attention pane within a compact iPhone width.")
    func recapFitsPhoneAttentionPane() async throws {
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
            compactHeader: true, expandsAllCards: true, onOpen: { _ in true }
        )
        let host = UIHostingController(rootView: root)
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 640))
        #expect(size.width > 0 && size.width <= 320)
        #expect(size.height > 0 && size.height <= 640)

        let preview = NavigationStack {
            VStack(spacing: 0) {
                Picker("Navigation", selection: .constant(true)) {
                    Text("Projects").tag(false)
                    Text("Attention 1").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 6)
                root
            }
            .navigationTitle("MacBook Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button {} label: { Image(systemName: "chevron.left") } }
                ToolbarItem(placement: .topBarTrailing) { Button {} label: { Image(systemName: "plus") } }
            }
        }.preferredColorScheme(.light)
        let renderedHost = UIHostingController(rootView: preview)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = renderedHost
        renderedHost.view.frame = window.bounds
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        renderedHost.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: renderedHost.view.bounds).image { context in
            renderedHost.view.layer.render(in: context.cgContext)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-mobile-attention-compact.png")
        try image.pngData()?.write(to: url)
        print("ATTENTION_RENDER: \(url.path)")
    }
}
#endif
