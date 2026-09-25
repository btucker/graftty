import Foundation
import GrafttyProtocol
import GrafttyCommandUI
import Testing
@testable import Graftty

@Suite("WorktreeRow PR/MR badge presentation")
struct WorktreeRowPRBadgeTests {
    @Test("@spec LAYOUT-2.81: While a worktree has an assigned emoji and is not in flight, its project-view row shall display the emoji, then any PR/MR badge, then the worktree name; otherwise, the row shall use its type or progress icon in the same position.")
    func leadingIdentityPrecedesPRAndName() {
        #expect(WorktreeRow.leadingSequence(hasEmoji: true, hasPR: true) == [.emoji, .prBadge, .label])
        #expect(WorktreeRow.leadingSequence(hasEmoji: true, hasPR: false) == [.emoji, .label])
        #expect(WorktreeRow.leadingSequence(hasEmoji: false, hasPR: true) == [.typeIcon, .prBadge, .label])
        #expect(WorktreeRow.leadingSequence(hasEmoji: false, hasPR: false) == [.typeIcon, .label])
        #expect(WorktreeRow.leadingSequence(hasEmoji: true, hasPR: true, isInFlight: true) == [.typeIcon, .prBadge, .label])
    }

    @Test("""
    @spec PR-3.4: The forge-specific PR/MR reference sidebar badge shall have an accessibility label of the form "Pull request `<number>`, open|merged|closed[, CI failing|CI running|merge conflict]. Click to open in browser." and a tooltip showing "Open `<reference>` on `<host>`". The optional suffix shall match the badge's `ciFailure`, `ciPending`, or `conflicting` tone per `PR-3.5` and `PR-8.20`.
    """)
    func tooltipAndAccessibilityTextUseBadgePresentation() {
        let github = badge(
            state: .open,
            url: "https://github.com/btucker/graftty/pull/5000"
        )
        let gitlab = badge(
            state: .merged,
            url: "https://gitlab.corp.example/team/graftty/-/merge_requests/5000"
        )
        let closed = badge(
            state: .closed,
            url: "https://github.com/btucker/graftty/pull/5000"
        )

        #expect(SidebarPRBadge.badgeTooltip(for: github) == "Open #5000 on github.com")
        #expect(SidebarPRBadge.badgeTooltip(for: gitlab) == "Open !5000 on gitlab.corp.example")
        #expect(
            SidebarPRBadge.badgeAccessibilityLabel(for: github, tone: .open)
                == "Pull request 5000, open. Click to open in browser."
        )
        #expect(
            SidebarPRBadge.badgeAccessibilityLabel(for: gitlab, tone: .merged)
                == "Pull request 5000, merged. Click to open in browser."
        )
        #expect(
            SidebarPRBadge.badgeAccessibilityLabel(for: github, tone: .ciFailure)
                == "Pull request 5000, open, CI failing. Click to open in browser."
        )
        #expect(
            SidebarPRBadge.badgeAccessibilityLabel(for: github, tone: .ciPending)
                == "Pull request 5000, open, CI running. Click to open in browser."
        )
        #expect(
            SidebarPRBadge.badgeAccessibilityLabel(for: github, tone: .conflicting)
                == "Pull request 5000, open, merge conflict. Click to open in browser."
        )
        #expect(
            SidebarPRBadge.badgeAccessibilityLabel(for: closed, tone: .closed)
                == "Pull request 5000, closed. Click to open in browser."
        )
    }

    private func badge(state: PRInfo.State, url: String) -> PRBadge {
        PRBadge(
            number: 5_000,
            state: state,
            checks: .success,
            url: URL(string: url)!
        )
    }
}
