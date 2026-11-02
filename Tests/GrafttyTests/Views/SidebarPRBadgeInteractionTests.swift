import AppKit
import SwiftUI
import XCTest
import GrafttyProtocol
@testable import GrafttyCommandUI
import GrafttyKit
@testable import Graftty

// Native window fixtures use XCTest's synchronous lifecycle. In the Swift
// Testing async runner these fixtures exited before reporting completed results.
@MainActor
final class SidebarPRBadgeInteractionTests: XCTestCase {
    func testMergedRemovalClickUsesOwningWindowWithoutSelectingRow() throws {
        let worktree = WorktreeEntry(path: "/repo/.worktrees/merged", branch: "merged", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [worktree])
        var selections = 0
        var removalWindow: NSWindow?
        let hosting = NSHostingView(rootView: WorktreeBlock(
            worktree: worktree, repoID: repo.id, isActive: false, isDropTarget: false,
            groupsPanes: false, theme: .fallback, appState: .constant(AppState(repos: [repo])),
            reorderingEnabled: true, onSelect: { selections += 1 }, onMovePane: { _, _ in },
            onPaneTargeted: { _ in }, menu: { _ in NSMenu() }
        ) {
            WorktreeRow(entry: worktree, isActive: false, displayName: "merged", isMainCheckout: false,
                theme: .fallback, stats: nil, baseRef: nil,
                prBadge: .init(number: 806, state: .merged, checks: .success,
                    url: URL(string: "https://github.com/btucker/graftty/pull/806")!),
                attentionStyle: nil, onRemove: { removalWindow = $0 })
        } panes: { EmptyView() })
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 320, height: 44),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        func findButton(_ view: NSView) -> SidebarRemoveWorktreeButtonView? {
            if let button = view as? SidebarRemoveWorktreeButtonView { return button }
            return view.subviews.lazy.compactMap(findButton).first
        }
        let button = try XCTUnwrap(findButton(hosting))
        let overlay = try XCTUnwrap(findDragView(in: hosting))
        let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let point = try XCTUnwrap(overlay.superview).convert(location, from: nil)
        let event = try NSEvent.syntheticClick(.leftMouseDown, at: location, in: window)
        XCTAssertTrue(overlay.hitTest(point, event: event) == nil, "Removal must bypass the worktree selection overlay")
        button.performClick(nil)
        XCTAssertTrue(removalWindow === window)
        XCTAssertTrue(selections == 0)
    }

    /// @spec PR-3.3: When the user clicks a forge-specific PR/MR reference sidebar badge, the application shall open its URL in the system browser without triggering the row's worktree-selection action.
    func testBadgeClickDoesNotSelectWorktree() throws {
        for url in ["https://github.com/btucker/graftty/pull/5000", "https://gitlab.corp.example/team/graftty/-/merge_requests/5000"] {
            for grouped in [false, true] { try verifyBadgeClick(urlString: url, groupsPanes: grouped) }
        }
    }

    private func verifyBadgeClick(urlString: String, groupsPanes: Bool) throws {
        let url = try XCTUnwrap(URL(string: urlString))
        var openedURLs: [URL] = []
        var selections = 0
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
                Button {} label: {
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
        hosting.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let dragView = try XCTUnwrap(findDragView(in: hosting))
        let badgeRect = try XCTUnwrap(dragView.excludedRects.min { $0.width * $0.height < $1.width * $1.height })

        let badgePoint = dragView.convert(NSPoint(x: badgeRect.midX, y: badgeRect.midY), to: nil)
        let badgePress = try NSEvent.syntheticClick(.leftMouseDown, at: badgePoint, in: window)
        XCTAssertTrue(dragView.hitTest(try XCTUnwrap(dragView.superview).convert(badgePoint, from: nil), event: badgePress) == nil)
        // Validate the exact production URL action separately from hit testing.
        // SwiftUI's mouse tracking requires a real application event loop.
        SidebarPRBadge(badge: PRBadge(number: 5000, state: .open, checks: .success, url: url))
            .open(using: { openedURLs.append($0) })
        XCTAssertTrue(openedURLs == [url])
        XCTAssertTrue(selections == 0)

        let rowPoint = dragView.convert(NSPoint(x: 150, y: badgeRect.midY), to: nil)
        try click(at: rowPoint, in: window, dragView: dragView)
        XCTAssertTrue(openedURLs == [url])
        XCTAssertTrue(selections == 1)
        if groupsPanes {
            let paneRect = try XCTUnwrap(dragView.excludedRects.max { $0.width * $0.height < $1.width * $1.height })
            let panePoint = dragView.convert(NSPoint(x: paneRect.midX, y: paneRect.midY), to: nil)
            let panePress = try NSEvent.syntheticClick(.leftMouseDown, at: panePoint, in: window)
            XCTAssertTrue(dragView.hitTest(try XCTUnwrap(dragView.superview).convert(panePoint, from: nil), event: panePress) == nil)
            XCTAssertTrue(selections == 1)
        XCTAssertTrue(openedURLs == [url])
        }
    }

    /// @spec GIT-5.5: While a worktree is creating, the application shall show a working indicator, hide terminal panes and Git statistics, suppress worktree actions, and allow selecting the row to inspect creation in the terminal content area.
    func testCreationOutputOwnsItsClickTarget() throws {
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
        hosting.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        hosting.layoutSubtreeIfNeeded()
        let overlay = try XCTUnwrap(findDragView(in: hosting))
        XCTAssertTrue(overlay.excludedRects.isEmpty)
        let location = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY), to: nil)
        let down = try NSEvent.syntheticClick(.leftMouseDown, at: location, in: window)
        let point = try XCTUnwrap(overlay.superview).convert(location, from: nil)
        // Dispatch directly to the production nonmodal row target. A native
        // Button.mouseDown can enter AppKit tracking and block a headless CI
        // runner before the synthetic mouseUp can be delivered.
        let hit = try XCTUnwrap(overlay.hitTest(point, event: down))
        XCTAssertTrue(hit === overlay)
        hit.mouseDown(with: down)
        hit.mouseUp(with: try NSEvent.syntheticClick(.leftMouseUp, at: location, in: window))
        XCTAssertTrue(selections == 1)
        if let directory = ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_RENDER_DIR"] {
            let progress = try XCTUnwrap(worktree.creationProgress)
            let detail = NSHostingView(rootView: MainWindowDetailLayout {
                Text("repo / feature").font(.caption).padding(12)
            } content: {
                WorktreeCreationDetailView(progress: progress,
                    foreground: GhosttyTheme.fallback.foreground, background: GhosttyTheme.fallback.background)
            }.background(GhosttyTheme.fallback.background).foregroundStyle(GhosttyTheme.fallback.foreground))
            let detailWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 440),
                styleMask: .borderless, backing: .buffered, defer: false)
            detailWindow.contentView = detail
            detailWindow.orderFront(nil)
            defer { detailWindow.orderOut(nil) }
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for (name, view) in [("creation-row", hosting as NSView), ("creation-output", detail as NSView)] {
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
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
        let down = try NSEvent.syntheticClick(.leftMouseDown, at: location, in: window)
        let point = try XCTUnwrap(dragView.superview).convert(location, from: nil)
        let target = try XCTUnwrap(dragView.hitTest(point, event: down))
        target.mouseDown(with: down)
        target.mouseUp(with: try NSEvent.syntheticClick(.leftMouseUp, at: location, in: window))
    }
}
