import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@Suite("@spec LAYOUT-2.114: While Attention rows are displayed, the application shall use the worktree name as the heading and show the branch name dimmed on the next line only if it is nonempty and differs from the worktree name.")
struct SidebarAttentionIdentityTests {
    private func worktree(name: String = "review-checkout", branch: String = "feature/review") -> WorktreePanes {
        WorktreePanes(path: "/repo/review-checkout", displayName: name, repoDisplayName: "Repo",
            displayBranch: branch, state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: "Review changes",
            layout: .leaf(sessionName: "pane", title: "Agent", attentionText: "Choose a plan",
                          isBusy: false, attentionSource: .userNotify),
            sidebar: .init(id: "stable", projectID: "project",
                unseenAgentStop: .init(agentName: "Codex", stoppedAt: .now,
                    recap: .init(title: "Review changes", completed: "Checked changes", next: "Apply fixes"))))
    }

    @Test func everyAttentionSourceUsesWorktreeName() {
        let items = SidebarProjection.activity([worktree()])
        #expect(items.count == 3)
        for item in items {
            #expect(item.worktreeName == "review-checkout")
            #expect(item.branchName == "feature/review")
            #expect(SidebarAttentionCardContent(item: item).headerName == "review-checkout")
            #expect(SidebarAttentionCardContent(item: item).branchName == "feature/review")
        }
    }

    @Test func retainedAndViewedCardsRefreshWorktreeName() throws {
        let item = try #require(SidebarProjection.activity([worktree()]).first)
        var workspace = SidebarAttentionWorkspace()
        workspace.merge([item])
        var history = SidebarRecentHistory()
        history.open(item)
        let renamed = worktree(name: "renamed-checkout", branch: "feature/updated")
        workspace.reconcile(worktrees: [renamed])
        history.reconcile(worktrees: [renamed], availableProjectIDs: ["project"])
        #expect(workspace.items.first?.worktreeName == "renamed-checkout")
        #expect(workspace.items.first?.branchName == "feature/updated")
        #expect(history.entries.first?.item.worktreeName == "renamed-checkout")
        #expect(history.entries.first?.item.branchName == "feature/updated")
    }

    @Test(arguments: [nil, "", "review-checkout", "feature/review", "Review-checkout"] as [String?])
    func branchLineDependsOnExactNameDifference(branch: String?) throws {
        var item = try #require(SidebarProjection.activity([worktree()]).first)
        item.branchName = branch
        for busy in [false, true] {
            item.isBusy = busy
            let card = SidebarAttentionCardContent(item: item)
            #expect(card.headerName == "review-checkout")
            switch branch {
            case "feature/review": #expect(card.branchName == "feature/review")
            case "Review-checkout": #expect(card.branchName == "Review-checkout")
            default: #expect(card.branchName == nil)
            }
        }
    }

    @Test func bothNamesSurviveRelaunchAndRemainSearchable() throws {
        var workspace = SidebarAttentionWorkspace()
        workspace.merge(SidebarProjection.activity([worktree()]))
        let restored = try JSONDecoder().decode(SidebarAttentionWorkspace.self, from: JSONEncoder().encode(workspace))
        #expect(restored == workspace)
        for query in ["review-checkout", "feature/review"] {
            #expect(SidebarActivityFilter.all.apply(to: restored.items, query: query).count == restored.items.count)
        }
    }

    @Test func olderSavedCardsDecodeAndRefreshFromSnapshot() throws {
        let item = try #require(SidebarProjection.activity([worktree()]).first)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "branchName")
        json["worktreeName"] = "feature/review"
        let old = try JSONDecoder().decode(SidebarActivityItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.branchName == nil)
        #expect(SidebarAttentionCardContent(item: old).branchName == nil)
        var workspace = SidebarAttentionWorkspace()
        workspace.merge([old])
        workspace.reconcile(worktrees: [worktree()])
        #expect(workspace.items.first?.worktreeName == "review-checkout")
        #expect(workspace.items.first?.branchName == "feature/review")
    }

    @Test func resumedCardsRefreshNamesWhileKeepingReport() throws {
        let item = try #require(SidebarProjection.activity([worktree()]).first)
        var workspace = SidebarAttentionWorkspace()
        workspace.merge([item])
        var resumed = item
        resumed.occurrence = nil
        resumed.isBusy = true
        resumed.worktreeName = "renamed-checkout"
        resumed.branchName = "feature/updated"
        workspace.merge([resumed])
        let retained = try #require(workspace.items.first)
        #expect(retained.worktreeName == "renamed-checkout")
        #expect(retained.branchName == "feature/updated")
        #expect(retained.occurrence == item.occurrence)
        #expect(retained.isBusy)
    }
}
