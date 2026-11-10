#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

/// What the line renders and announces. `SidebarRowStatusTests` covers which
/// status each row resolves to and what its heading shows.
@MainActor
struct SidebarStatusLineTests {
    private struct Element {
        let text: String
        let frame: CGRect
    }

    @Test func questionAnnouncesThatItNeedsInput() {
        #expect(elements(.question("Which image?", paneID: "a")).map(\.text) == ["Needs your input: Which image?"])
    }

    @Test(arguments: [SidebarRowStatus.notification("w", paneID: nil), .working("w"), .whereWeAre("w", isUnread: true), .whereWeAre("w", isUnread: false)])
    func otherLinesAnnounceOnlyTheirText(status: SidebarRowStatus) {
        #expect(elements(status).map(\.text) == ["w"])
    }

    @Test("@spec LAYOUT-2.210: While a project has worktrees waiting for the user, pinned or not, with a question, a notification, or a finished turn the user has not opened, the application shall show how many as a count in the attention color rather than a hand.")
    func projectBadgeCountsInsteadOfShowingAHand() {
        func row(_ name: String, project: String, stop: SidebarAgentStop?) -> WorktreePanes {
            .init(path: "/" + name, displayName: name, repoDisplayName: "app", displayBranch: name, state: .running,
                  isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                  sidebar: .init(id: name, projectID: project, unseenAgentStop: stop, isPinned: name == "pinned"))
        }
        let asked = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 9),
            recap: .init(title: "Ask", completed: "Done", next: "Next", need: "Which one?"))
        let finished = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSinceReferenceDate: 8),
            recap: .init(title: "Stop", completed: "Done", next: "Next"))
        let rows = [row("asks", project: "p", stop: asked), row("pinned", project: "p", stop: finished),
                    row("quiet", project: "p", stop: nil), row("other", project: "q", stop: finished)]
        #expect(SidebarWaitingCounts.byProject(rows) { SidebarWorktreeContext(worktree: $0) } == ["p": 2, "q": 1])
        #expect(SidebarActivityBadge(3).text == "3")
        #expect(SidebarActivityBadge(100).text == "99+")
        #expect(SidebarActivityBadge(1).label == "1 waiting for you")
        #expect(SidebarActivityBadge(2).label == "2 waiting for you")
        #expect(SidebarActivityBadge(2, kind: .working).label == "2 agents working")
    }

    /// The line's accessibility leaves, in reading order from the leading edge.
    private func elements(_ status: SidebarRowStatus) -> [Element] {
        let host = NSHostingView(rootView: SidebarStatusLine(status: status, secondary: .secondary)
            .frame(width: 260)
            .environment(\.accessibilityEnabled, true))
        let window = NSWindow(contentRect: .init(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        return leaves(of: host).sorted { $0.frame.minX < $1.frame.minX }
    }

    /// SwiftUI's nodes answer these without declaring `NSAccessibilityProtocol`.
    private func leaves(of element: NSObject) -> [Element] {
        func value<T>(_ selector: String) -> T? {
            element.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? T
        }
        let children: [NSObject] = value("accessibilityChildren") ?? []
        if !children.isEmpty { return children.flatMap { leaves(of: $0) } }
        guard let text: String = value("accessibilityLabel") ?? value("accessibilityValue"),
              let frame = (element as? NSAccessibilityElementProtocol)?.accessibilityFrame() else { return [] }
        return [Element(text: text, frame: frame)]
    }
}
#endif
