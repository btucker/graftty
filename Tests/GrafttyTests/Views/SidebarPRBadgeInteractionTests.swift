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
        let paneID = PaneSlotID()
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
            menu: { _ in NSMenu() }
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
                    .transformAnchorPreference(key: WorktreeControlAnchors.self, value: .bounds) { $0[.pane(paneID)] = $1 }
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
        let badgeRect = try #require(dragView.excludedRects.min { $0.width * $0.height < $1.width * $1.height })

        let badgePoint = dragView.convert(NSPoint(x: badgeRect.midX, y: badgeRect.midY), to: nil)
        try click(at: badgePoint, in: window, dragView: dragView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(openedURLs == [url])
        #expect(selections == 0)

        let rowPoint = dragView.convert(NSPoint(x: 150, y: badgeRect.midY), to: nil)
        try click(at: rowPoint, in: window, dragView: dragView)
        try await Task.sleep(for: .milliseconds(50))
        #expect(openedURLs == [url])
        #expect(selections == 1)
        if groupsPanes {
            let paneRect = try #require(dragView.excludedRects.max { $0.width * $0.height < $1.width * $1.height })
            let panePoint = dragView.convert(NSPoint(x: paneRect.midX, y: paneRect.midY), to: nil)
            try click(at: panePoint, in: window, dragView: dragView)
            try await Task.sleep(for: .milliseconds(50))
            #expect(paneSelections == 1)
            #expect(selections == 1)
            #expect(openedURLs == [url])
        }
    }

    @Test("The creating row passes output-inspector clicks through the production selection overlay")
    func creationOutputOwnsItsClickTarget() async throws {
        var worktree = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .creating)
        worktree.creationProgress = WorktreeCreationProgress()
        worktree.creationProgress?.startedAt = Date().addingTimeInterval(-612)
        worktree.creationProgress?.transition(to: .git)
        worktree.creationProgress?.output = "Preparing worktree (new branch 'feature')\nHEAD is now at a5bfc04 initial\npost-checkout: waiting for shared setup lock\n"
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])
        var selections = 0
        let hosting = NSHostingView(rootView: WorktreeBlock(
            worktree: worktree, repoID: repo.id, isActive: false, isDropTarget: false,
            groupsPanes: false, theme: .fallback, appState: .constant(AppState(repos: [repo])),
            reorderingEnabled: true, onSelect: { selections += 1 }, onMovePane: { _, _ in },
            onPaneTargeted: { _ in }, menu: { _ in NSMenu() }
        ) {
            WorktreeRow(entry: worktree, isActive: false, displayName: "feature", isMainCheckout: false,
                theme: .fallback, stats: nil, baseRef: nil, prBadge: nil, attentionStyle: nil)
        } panes: { EmptyView() }
            .background(GhosttyTheme.fallback.sidebarBackground)
            .foregroundStyle(GhosttyTheme.fallback.foreground))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 70),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let overlay = try #require(findDragView(in: hosting))
        let rect = try #require(overlay.excludedRects.first)
        let location = overlay.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let down = try NSEvent.syntheticClick(.leftMouseDown, at: location, in: window)
        let point = try #require(overlay.superview).convert(location, from: nil)
        #expect(overlay.hitTest(point, event: down) == nil)
        let visibleWindows = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
        try click(at: location, in: window, dragView: overlay)
        try await Task.sleep(for: .milliseconds(150))
        #expect(selections == 0)
        let popover = try #require(NSApp.windows.first { $0.isVisible && !visibleWindows.contains(ObjectIdentifier($0)) })
        defer { popover.orderOut(nil) }
        if let directory = ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, view) in [("creation-row", hosting as NSView), ("creation-output", try #require(popover.contentView))] {
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name + ".png"))
            }
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
