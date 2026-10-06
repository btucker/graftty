import AppKit
import SwiftUI
import Testing
import GrafttyProtocol
import GrafttyKit
@testable import Graftty

@Suite("Sidebar PR/MR badge interaction", .serialized)
@MainActor
struct SidebarPRBadgeInteractionTests {
    @Test("@spec PR-3.3: When the user clicks a forge-specific PR/MR reference sidebar badge, the application shall open its URL in the system browser without triggering the row's worktree-selection action.", arguments: [
        "https://github.com/btucker/graftty/pull/5000",
        "https://gitlab.corp.example/team/graftty/-/merge_requests/5000"
    ], [false, true])
    func badgeClickDoesNotSelectWorktree(urlString: String, groupsPanes: Bool) async throws {
        let url = try #require(URL(string: urlString))
        var openedURLs: [URL] = []
        var selections = 0
        var paneSelections = 0
        let worktree = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature",
                                    state: groupsPanes ? .running : .closed)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])
        var state = AppState(repos: [repo])
        let content = WorktreeBlock(
            worktree: worktree, repoID: repo.id, isActive: false, isDropTarget: false,
            groupsPanes: groupsPanes, theme: .fallback,
            appState: Binding(get: { state }, set: { state = $0 }),
            reorderingEnabled: true,
            onSelect: { selections += 1 }, onMovePane: { _, _ in }, onPaneTargeted: { _ in },
            menu: { NSMenu() }
        ) {
            WorktreeRow(entry: worktree, isActive: false, displayName: "feature", isMainCheckout: false,
                        theme: .fallback, stats: nil, baseRef: nil,
                        prBadge: PRBadge(number: 5000, state: .open, checks: .success, url: url),
                        attentionStyle: nil)
                .frame(height: groupsPanes ? 28 : 44)
        } panes: {
            if groupsPanes {
                Button { paneSelections += 1 } label: {
                    Text("Pane").frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .environment(\.openURL, OpenURLAction { openedURLs.append($0); return .handled })
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: groupsPanes ? 72 : 44),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let dragView = try #require(findDragView(in: hosting))
        let badgeRect = try #require(dragView.excludedRects.first)

        let badgePoint = dragView.convert(NSPoint(x: badgeRect.midX, y: badgeRect.midY), to: nil)
        try click(at: badgePoint, in: window, dragView: dragView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(openedURLs == [url])
        #expect(selections == 0)

        let rowPoint = dragView.convert(NSPoint(x: 150, y: dragView.bounds.midY), to: nil)
        try click(at: rowPoint, in: window, dragView: dragView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(openedURLs == [url])
        #expect(selections == 1)
        if groupsPanes {
            let panePoint = dragView.convert(NSPoint(x: 150, y: dragView.bounds.maxY + 14), to: nil)
            try click(at: panePoint, in: window, dragView: dragView)
            try await Task.sleep(for: .milliseconds(50))
            #expect(paneSelections == 1)
            #expect(selections == 1)
            #expect(openedURLs == [url])
        }
    }

    private func findDragView(in view: NSView) -> WorktreeDragSourceView? {
        if let drag = view as? WorktreeDragSourceView { return drag }
        return view.subviews.lazy.compactMap(findDragView).first
    }

    private func click(at location: NSPoint, in window: NSWindow, dragView: WorktreeDragSourceView) throws {
        var target: NSView?
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try NSEvent.syntheticClick(type, at: location, in: window)
            if type == .leftMouseDown {
                let point = try #require(dragView.superview).convert(location, from: nil)
                // Supply the current press explicitly, as AppKit would during
                // dispatch, without running the application's global event loop.
                target = dragView.hitTest(point, event: event)
            }
            if let target {
                if type == .leftMouseDown { target.mouseDown(with: event) }
                else { target.mouseUp(with: event) }
            } else {
                window.sendEvent(event)
            }
        }
    }
}
