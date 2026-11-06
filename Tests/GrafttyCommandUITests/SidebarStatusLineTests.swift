#if os(macOS)
import AppKit
import SwiftUI
import Testing
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

    @Test("@spec LAYOUT-2.210: While a project has worktrees asking for input, the application shall show how many as a count in the attention color rather than a hand.")
    func projectBadgeCountsInsteadOfShowingAHand() {
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
