import AppKit
import Testing
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

@MainActor
struct SidebarReportPreviewTests {
    @Test("@spec LAYOUT-2.129: When the pointer rests on a worktree for 250 milliseconds, the application shall preview its report without selecting the worktree or taking terminal focus, allow 300 milliseconds to enter the preview, and keep a pinned preview open until dismissed.")
    func hoverAndPinPreserveFocus() async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let anchor = SidebarReportAnchorView(frame: NSRect(x: 0, y: 100, width: 300, height: 100))
        window.contentView?.addSubview(anchor)
        let context = SidebarWorktreeContext(worktree: .init(path: "/wt", displayName: "Task", repoDisplayName: "Project", displayBranch: "task", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil))
        let controller = SidebarReportController()
        // Drive hover explicitly; unrelated hosted windows share the real pointer.
        anchor.context = context
        let responder = window.firstResponder
        controller.enter(anchor)
        #expect(controller.activeID == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while controller.activeID == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(controller.activeID == context.item.worktreeIdentity.id)
        #expect(window.firstResponder === responder)
        controller.leave()
        controller.keepOpen()
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.activeID != nil)
        controller.pin()
        controller.leave()
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.activeID != nil)
        controller.close()
        #expect(controller.activeID == nil)
        controller.show(anchor, pinned: true)
        let panel = try #require(window.childWindows?.first as? SidebarReportPanel)
        #expect(panel.isKeyWindow)
        let stalePresentation = controller.presentationID
        controller.close()
        controller.show(anchor, pinned: true)
        controller.close(presentationID: stalePresentation)
        #expect(controller.activeID != nil)
        anchor.controller = controller
        anchor.removeFromSuperview()
        #expect(controller.activeID == nil)
        #expect(window.firstResponder === responder)
        window.contentView?.addSubview(anchor)
        anchor.isHidden = true
        controller.show(anchor, pinned: true)
        #expect(controller.activeID == nil)
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test("@spec LAYOUT-2.130: While a worktree report preview is visible, the application shall constrain it to the parent window and close it when its anchor is removed.")
    func previewFrameFitsWindow() {
        let bounds = NSRect(x: 100, y: 100, width: 700, height: 500)
        for anchor in [NSRect(x: 110, y: 110, width: 250, height: 50), NSRect(x: 600, y: 550, width: 180, height: 40)] {
            let frame = SidebarReportController.frame(anchor: anchor, within: bounds)
            #expect(bounds.contains(frame))
        }
        let controller = SidebarReportController()
        controller.close()
        #expect(controller.activeID == nil)
    }
}
