import AppKit
import SwiftUI
import Testing
import GrafttyCommandUI

@MainActor
@Suite(.serialized)
struct AgentStatusBadgeTests {
    @Test("@spec LAYOUT-2.187: While an agent is running without a failure or input request, its shared tab and sidebar status badge shall display an indeterminate progress indicator; waiting, completed, failed, and disconnected agents shall display their corresponding static status symbols.")
    func runningBadgeUsesProgress() async throws {
        for (status, needsInput, failure, expected) in [
            ("running", false, nil as String?, true),
            ("running", true, nil, false),
            ("running", false, "Launch failed", false),
            ("awaiting-cleanup", false, nil, false),
            ("closed", false, nil, false),
            ("failed", false, nil, false),
            ("disconnected", false, nil, false)
        ] {
            let hosted = NSHostingView(rootView: AgentStatusBadge(status: status, needsInput: needsInput, failure: failure))
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 80, height: 40),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosted
            window.orderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil }
            try await Task.sleep(for: .milliseconds(50))
            hosted.layoutSubtreeIfNeeded()
            let indicator = progress(in: hosted)
            #expect((indicator != nil) == expected, "Status: \(status), input: \(needsInput), failure: \(failure ?? "none")")
            if let indicator { #expect(indicator.isIndeterminate) }
        }
    }

    private func progress(in view: NSView) -> NSProgressIndicator? {
        if let indicator = view as? NSProgressIndicator { return indicator }
        return view.subviews.lazy.compactMap { progress(in: $0) }.first
    }
}
