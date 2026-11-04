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

    @Test func handKeepsItsOwnLabelBesideTheLine() {
        #expect(elements(.notification("Build done", paneID: nil)).map(\.text) == ["Input requested", "Build done"])
    }

    @Test func handHangsImmediatelyBeforeTheText() throws {
        let line = elements(.notification("Build done", paneID: nil))
        try #require(line.count == 2)
        #expect(line[0].frame.maxX <= line[1].frame.minX)
        #expect(line[1].frame.minX - line[0].frame.maxX < 10)
    }

    @Test func questionLabelSpeaksForTheHand() {
        #expect(elements(.question("Which image?", paneID: "a")).map(\.text) == ["Needs your input: Which image?"])
    }

    @Test(arguments: [SidebarRowStatus.working("w"), .whereWeAre("w", isUnread: false)])
    func lineThatNeedsNoAttentionHasNoHand(status: SidebarRowStatus) {
        #expect(elements(status).map(\.text) == ["w"])
    }

    /// The line's accessibility leaves, in reading order from the leading edge.
    private func elements(_ status: SidebarRowStatus) -> [Element] {
        let host = NSHostingView(rootView: SidebarStatusLine(status: status, secondary: .secondary)
            .padding(.leading, SidebarStatusLine.mobileLeadingInset)
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
