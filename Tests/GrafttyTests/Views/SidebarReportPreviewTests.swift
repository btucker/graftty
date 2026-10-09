import AppKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

@Suite(.serialized)
@MainActor
struct SidebarReportPreviewTests {
    private func context(need: String? = nil, long: Bool = false) -> SidebarWorktreeContext {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date().addingTimeInterval(-420),
            recap: .init(title: "Worktree reports unified", context: long ? String(repeating: "Report context wraps within the available width. ", count: 100) : "Reports now live alongside the worktree list.",
                         completed: "Kept pane navigation and pending requests together.", next: "Try the report button.", need: need), paneTitle: "Codex")
        return SidebarWorktreeContext(worktree: .init(path: "/wt", displayName: "merge-recent-activity-attention", repoDisplayName: "Project", displayBranch: "task", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "wt", projectID: "p", unseenAgentStop: stop, lastAgentStop: stop)))
    }

    @Test("@spec LAYOUT-2.129: When the user activates the information button beside a worktree name, the application shall show a native Mac report popover without selecting the worktree or acknowledging its request, and hovering shall not open it.")
    func explicitButtonOpensNativePopover() async throws {
        let controller = SidebarReportController()
        let context = context(need: "Set auto-merge?")
        var selections = 0
        let worktree = WorktreeEntry(path: "/wt", branch: "task", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "Project", worktrees: [worktree])
        let host = NSHostingView(rootView: WorktreeBlock(
            worktree: worktree, repoID: repo.id, isActive: false, isDropTarget: false,
            groupsPanes: true, theme: .fallback, appState: .constant(AppState(repos: [repo])),
            reorderingEnabled: true, onSelect: { selections += 1 }, onMovePane: { _, _ in },
            onPaneTargeted: { _ in }, menu: { _ in NSMenu() }
        ) {
            WorktreeRow(entry: worktree, isActive: false, displayName: "Worktree",
                        isMainCheckout: false, theme: .fallback, stats: nil, baseRef: nil, prBadge: nil, attentionStyle: nil,
                        reportButton: SidebarReportButton(controller: controller, context: context, theme: .fallback))
        } panes: {
            SidebarWorktreeQuestion(context: context).padding(.leading, 33)
        }.frame(width: 380).background(GhosttyTheme.fallback.sidebarBackground).foregroundStyle(GhosttyTheme.fallback.foreground))
        let window = makeWindow()
        window.contentView = host
        window.orderFront(nil)
        defer { controller.close(); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let button = try #require(findButton(host))
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.superview)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: button.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let dragSources = findDragSources(host)
        #expect(!dragSources.isEmpty)
        dragSources.forEach { $0.currentEvent = { down } }
        let hit = host.hitTest(point)
        dragSources.forEach { $0.currentEvent = { NSApp.currentEvent } }
        #expect(hit === button, "Information button must own its hit target")
        button.mouseEntered(with: try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.activeID == nil)
        button.performClick(nil)
        #expect(controller.popover?.isShown == true)
        #expect(controller.popover?.behavior == .transient)
        #expect(controller.activeID == context.item.worktreeIdentity.id)
        #expect(selections == 0)
        #expect(context.pending.count == 1)
        try capture(host, name: "report-button-row")
        controller.popover?.performClose(nil)
        #expect(controller.activeID == nil)
    }

    @Test("@spec LAYOUT-2.130: While a Mac report popover is visible, the application shall close it when its information button is removed and cap long reports with scrolling.")
    func removalAndLongReport() throws {
        let window = makeWindow()
        defer { window.close() }
        let button = SidebarReportButtonView()
        window.contentView?.addSubview(button)
        let controller = SidebarReportController()
        button.controller = controller
        button.context = context(long: true)
        controller.show(button)
        let popover = try #require(controller.popover)
        let scroll = try #require(popover.contentViewController?.view as? NSScrollView)
        #expect(popover.contentSize.height == 540)
        #expect((scroll.documentView?.frame.height ?? 0) > 540)
        button.removeFromSuperview()
        #expect(controller.activeID == nil)
        #expect(!popover.isShown)
    }

    @Test("@spec LAYOUT-2.132: While a Mac worktree report popover is visible, the application shall fit short reports to their content and use the highlighted worktree background and Ghostty foreground colors in light and dark themes.")
    func reportFitsContentAndTheme() throws {
        let window = makeWindow()
        defer { window.close() }
        let button = SidebarReportButtonView()
        window.contentView?.addSubview(button)
        let controller = SidebarReportController()
        defer { controller.close() }
        button.context = context()
        let themes: [GhosttyTheme] = [.fallback, .init(backgroundRGB: .init(r: 0.95, g: 0.91, b: 0.83), foregroundRGB: .init(r: 0.2, g: 0.16, b: 0.1))]
        for theme in themes {
            controller.close()
            button.theme = theme
            controller.show(button)
            let popover = try #require(controller.popover)
            #expect(popover.contentSize.height < 340)
            #expect(popover.contentSize.height > 100)
            #expect(popover.appearance?.bestMatch(from: [.darkAqua, .aqua]) == (theme.isDark ? .darkAqua : .aqua))
            let view = try #require(popover.contentViewController?.view)
            #expect((view as? NSScrollView)?.backgroundColor == theme.highlightedWorktreeBackgroundNSColor)
            view.layoutSubtreeIfNeeded()
            try capture(view, name: theme.isDark ? "report-dark" : "report-light")
        }
    }

    @Test("@spec LAYOUT-2.134: When a worktree question's pane is not displayed, the application shall show its question beneath the worktree instead of hiding it.")
    func questionSurvivesMissingPaneRows() {
        #expect(SidebarView.showsWorktreeQuestion(questionPaneID: "agent", displayedPaneSessions: []))
        #expect(SidebarView.showsWorktreeQuestion(questionPaneID: "agent", displayedPaneSessions: ["shell"]))
        #expect(SidebarView.showsWorktreeQuestion(questionPaneID: nil, displayedPaneSessions: ["shell"]))
        #expect(!SidebarView.showsWorktreeQuestion(questionPaneID: "agent", displayedPaneSessions: ["agent", "shell"]))
    }

    private func findDragSources(_ view: NSView) -> [WorktreeDragSourceView] {
        (view as? WorktreeDragSourceView).map { [$0] } ?? view.subviews.flatMap(findDragSources)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func findButton(_ view: NSView) -> SidebarReportButtonView? {
        if let button = view as? SidebarReportButtonView { return button }
        return view.subviews.lazy.compactMap { findButton($0) }.first
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_RENDER_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name + ".png"))
    }
}
