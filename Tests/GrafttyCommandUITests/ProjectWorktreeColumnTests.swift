import AppKit
import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@Suite("Project worktree column empty space")
@MainActor
struct ProjectWorktreeColumnTests {
    @Test("@spec LAYOUT-2.69: When the user double-clicks empty space after the last worktree in the project column, the application shall open Add Worktree for the selected editable project without changing a worktree row's click behavior.")
    func doubleClickOpensAddWorktree() throws {
        var openings = 0
        let view = ProjectWorktreeEmptySpaceView()
        view.onDoubleClick = { openings += 1 }

        view.mouseDown(with: try mouseDown(clickCount: 1))
        #expect(openings == 0)

        view.mouseDown(with: try mouseDown(clickCount: 2))
        #expect(openings == 1)
    }

    @Test func emptySpaceFillsAreaBelowRows() async throws {
        let hosting = NSHostingView(rootView: ProjectWorktreeColumn(onDoubleClickEmptySpace: {}) {
            Text("Worktree").frame(height: 44)
        })
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let blank = try #require(findEmptySpace(in: hosting))
        #expect(blank.frame.height > 100)
    }

    @Test("@spec LAYOUT-2.89: While the project worktree list scrolls, the application shall scroll Sort order and Add Worktree with the list between Pinned Agents and temporary worktrees for the selected editable project.")
    func controlsScrollWithWorktrees() async throws {
        let hosting = NSHostingView(rootView: ProjectWorktreeColumn {
            SidebarWorktreeRows(worktrees: [], beforeTasks: AnyView(PinnedHeaderMarker().frame(height: 44))) { _ in
                EmptyView()
            }
            ForEach(0..<50) { index in Text("Worktree \(index)").frame(height: 44) }
        })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let marker = try #require(findMarker(in: hosting))
        var ancestor = marker.superview
        var scrollView: NSScrollView?
        while let view = ancestor {
            if let scroll = view as? NSScrollView { scrollView = scroll; break }
            ancestor = view.superview
        }
        let scroll = try #require(scrollView)
        #expect(marker.bounds.height == 44)
        let originalY = marker.convert(marker.bounds, to: hosting).midY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(marker.convert(marker.bounds, to: hosting).midY != originalY)
    }

    @Test("@spec LAYOUT-2.115: While the sidebar displays Pinned Agents, the application shall place that section below search and above temporary worktrees, including remote projects.", arguments: [false, true])
    func pinnedRowsPrecedeTemporaryRows(collapsed: Bool) async throws {
        let projectID = UUID().uuidString
        let key = "sidebar.pinned.collapsed." + projectID
        UserDefaults.standard.set(collapsed, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        func row(_ id: String, pinned: Bool) -> WorktreePanes {
            WorktreePanes(path: id, displayName: id, repoDisplayName: "Project", displayBranch: id,
                state: .closed, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                sidebar: .init(id: id, projectID: projectID, isPinned: pinned))
        }
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            PinnedHeaderMarker().frame(height: 10)
            SidebarWorktreeRows(worktrees: [row("task", pinned: false), row("agent", pinned: true)],
                beforeTasks: AnyView(PinnedHeaderMarker().frame(height: 44))) { worktree in
                PinnedHeaderMarker().frame(height: worktree.path == "agent" ? 30 : 40)
            }
        })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        let markers = findMarkers(in: hosting)
        let search = try #require(markers.first { $0.bounds.height == 10 })
        let controls = try #require(markers.first { $0.bounds.height == 44 })
        let task = try #require(markers.first { $0.bounds.height == 40 })
        func precedes(_ first: NSView, _ second: NSView) -> Bool {
            let firstY = first.convert(first.bounds, to: hosting).midY
            let secondY = second.convert(second.bounds, to: hosting).midY
            return hosting.isFlipped ? firstY < secondY : firstY > secondY
        }
        #expect(precedes(search, controls))
        #expect(precedes(controls, task))
        if collapsed {
            #expect(!markers.contains { $0.bounds.height == 30 })
        } else {
            let agent = try #require(markers.first { $0.bounds.height == 30 })
            #expect(precedes(search, agent))
            #expect(precedes(agent, controls))
        }
    }

    private func findMarkers(in view: NSView) -> [PinnedHeaderMarkerView] {
        if let marker = view as? PinnedHeaderMarkerView { return [marker] }
        return view.subviews.flatMap(findMarkers)
    }

    private func findMarker(in view: NSView) -> PinnedHeaderMarkerView? {
        if let marker = view as? PinnedHeaderMarkerView { return marker }
        return view.subviews.lazy.compactMap(findMarker).first
    }

    private func findEmptySpace(in view: NSView) -> ProjectWorktreeEmptySpaceView? {
        if let emptySpace = view as? ProjectWorktreeEmptySpaceView { return emptySpace }
        return view.subviews.lazy.compactMap(findEmptySpace).first
    }

    private func mouseDown(clickCount: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }
}

private final class PinnedHeaderMarkerView: NSView {}

private struct PinnedHeaderMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> PinnedHeaderMarkerView { PinnedHeaderMarkerView() }
    func updateNSView(_ view: PinnedHeaderMarkerView, context: Context) {}
}
