import AppKit
import Foundation
import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

@MainActor
struct SidebarAttentionDismissalMenuTests {
    private func asking() -> WorktreePanes {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 100),
            recap: .init(title: "Reconnect", completed: "Reproduced", next: "Implement", need: "Retry silently?"),
            providerSessionKey: "agent")
        return .init(path: "/wt", displayName: "Task", repoDisplayName: "Project", displayBranch: "task",
                     state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
                     layout: nil, sidebar: .init(id: "/wt", projectID: "p", unseenAgentStop: stop, lastAgentStop: stop))
    }

    @Test func rowMenuLeadsWithDismissRequest() throws {
        let navigation = SidebarNavigationState(prefix: "mac-dismissal.\(UUID())")
        let row = asking()
        let menu = NSMenu()
        SidebarAttentionDismissalMenu.add(to: menu, context: navigation.worktreeContext(row)) { navigation.dismissRequest(in: $0) }
        #expect(menu.items.first?.title == "Dismiss Request")
        #expect(menu.items.last?.isSeparatorItem == true)

        // Sent to the item's own target: `performActionForItem` needs a running NSApp.
        let item = try #require(menu.items.first)
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        #expect(!SidebarAttentionDismissal.isAvailable(navigation.worktreeContext(row)))

        let empty = NSMenu()
        SidebarAttentionDismissalMenu.add(to: empty, context: navigation.worktreeContext(row)) { navigation.dismissRequest(in: $0) }
        #expect(empty.items.isEmpty)
    }

    @Test("@spec LAYOUT-2.218: When the user dismisses a worktree's request on any client, the application shall retire it on the owning host, so no client keeps showing it under Needs You.")
    func dismissalRetiresRequestsOnTheHost() throws {
        var worktree = WorktreeEntry(path: "/repo/wt", branch: "wt")
        worktree.recordAgentStop(.init(agentName: "Codex", stoppedAt: Date(),
            recap: .init(title: "Deploy", completed: "Built it", next: "Ship", need: "Ship it?")))
        worktree.attention = Attention(text: "Deploy finished", timestamp: Date())
        var state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo",
            worktrees: [WorktreeEntry(path: "/repo", branch: "main"), worktree])])
        let owner = WorktreeOrigin(deviceID: .init(value: "host"), deviceLabel: "Host", relayDepth: 0)
        func row() throws -> WorktreePanes {
            try #require(sidebarLocalWorktree(atPath: "/repo/wt", state: state, owner: owner,
                                              titles: [:], liveness: [:], prBadge: nil))
        }
        let context = SidebarWorktreeContext(worktree: try row())
        #expect(context.pending.count == 2)
        // A host too old for exact acknowledgement keeps the device-only dismissal.
        #expect(SidebarAttentionDismissal.requests(for: context, supportsExactAcknowledgement: false).isEmpty)

        let requests = SidebarAttentionDismissal.requests(for: context, supportsExactAcknowledgement: true)
        #expect(requests.count == 2)
        SidebarAttentionDismissalMenu.acknowledge(requests, in: &state)
        // Another client, which never dismissed anything, sees nothing pending.
        #expect(SidebarWorktreeContext(worktree: try row()).pending.isEmpty)
    }
}
