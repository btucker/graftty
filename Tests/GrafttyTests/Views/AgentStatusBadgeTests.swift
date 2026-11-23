import AppKit
import SwiftUI
import Testing
import GrafttyCommandUI

@MainActor
@Suite(.serialized)
struct AgentStatusBadgeTests {
    @Test("@spec LAYOUT-2.187: While an agent tab is visible, the application shall omit the running spinner and display static indicators for idle, waiting, completed, failed, or disconnected agents.")
    func tabBadgeOmitsProgress() async throws {
        for (status, busy, needsInput, failure, disconnected, expectsIcon) in [
            ("running", true as Bool?, false, nil as String?, false, false),
            ("running", nil, false, nil, false, false),
            ("running", false, false, nil, false, true),
            ("running", true, true, nil, false, true),
            ("running", true, false, "Launch failed", false, true),
            ("running", true, false, nil, true, true),
            ("awaiting-cleanup", nil, false, nil, false, true),
            ("closed", nil, false, nil, false, true),
            ("failed", nil, false, nil, false, true),
            ("disconnected", nil, false, nil, false, true)
        ] {
            let hosted = NSHostingView(rootView: HStack {
                AgentStatusBadge(status: status, needsInput: needsInput, failure: failure,
                    disconnected: disconnected, isBusy: busy)
            }.fixedSize())
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 80, height: 40),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosted
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await Task.sleep(for: .milliseconds(50))
            hosted.layoutSubtreeIfNeeded()
            #expect(progress(in: hosted) == nil)
            #expect((hosted.fittingSize.width > 0) == expectsIcon)
        }
    }

    private func progress(in view: NSView) -> NSProgressIndicator? {
        if let indicator = view as? NSProgressIndicator { return indicator }
        return view.subviews.lazy.compactMap { progress(in: $0) }.first
    }
}
