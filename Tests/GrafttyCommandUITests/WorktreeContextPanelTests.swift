#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeContextPanelTests {
    @Test("@spec CONTEXT-27: When Context is opened on Mac or mobile, the application shall pin the current brief above the timeline, capped at half the panel height and scrolling internally only when it exceeds that cap, and shall scroll the oldest-first timeline independently, opening at its latest event.", arguments: [260.0, 390.0])
    func pinnedBriefAboveBottomAnchoredTimeline(width: Double) async throws {
        let panelHeight = 700.0
        let start = Date(timeIntervalSince1970: 1_792_411_200)
        var history = WorktreeHistory(origin: .init(date: start, source: .user))
        for index in 0..<40 {
            history.record(.init(text: "Request \(index): adjust the layout and check it again.", at: start.addingTimeInterval(Double(index) * 700)))
        }
        func context(decisions: Int) -> SidebarWorktreeContext {
            let brief = WorktreeBrief(recap: .init(title: "Refine the panel", completed: "Pinned the brief.",
                next: "Verify the timeline.", decisions: (0..<decisions).map { "Decision \($0) keeps the layout readable on every width." }),
                at: start)
            return SidebarWorktreeContext(worktree: WorktreePanes(path: "/task", displayName: "Task", repoDisplayName: "Project",
                displayBranch: "task", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
                layout: nil, sidebar: .init(id: "task", projectID: "p", brief: brief, history: history)))
        }

        func scrollViews(_ context: SidebarWorktreeContext) async throws -> (window: NSWindow, views: [NSScrollView]) {
            let host = NSHostingView(rootView: WorktreeContextPanel(context: context, onClose: {})
                .frame(width: width, height: panelHeight))
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: panelHeight),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            return (window, Self.find(NSScrollView.self, in: host))
        }

        // A short brief renders without its own scroll view; only the timeline scrolls.
        let short = try await scrollViews(context(decisions: 1))
        defer { short.window.close() }
        try #require(short.views.count == 1)
        let timeline = try #require(short.views.first)
        let document = try #require(timeline.documentView)
        let timelineFrame = timeline.convert(timeline.bounds, to: nil)
        #expect(document.frame.height > timelineFrame.height, "The timeline content overflows and scrolls")
        #expect(timelineFrame.maxY < panelHeight - 150, "The brief is pinned above the timeline")
        let visible = timeline.contentView.documentVisibleRect
        let atBottom = document.isFlipped ? visible.maxY >= document.bounds.maxY - 2 : visible.minY <= document.bounds.minY + 2
        #expect(atBottom, "The timeline opens at its latest event")

        // A long brief scrolls inside a cap of half the panel.
        let long = try await scrollViews(context(decisions: 30))
        defer { long.window.close() }
        try #require(long.views.count == 2)
        let frames = long.views.map { $0.convert($0.bounds, to: nil) }.sorted { $0.maxY > $1.maxY }
        #expect(frames[0].height <= panelHeight / 2 + 1, "The pinned brief is capped at half the panel")
        #expect(frames[1].height > panelHeight / 3, "The timeline keeps the remaining height")
    }

    private static func context(path: String, decisions: Int = 1) -> SidebarWorktreeContext {
        let start = Date(timeIntervalSince1970: 1_792_411_200)
        var history = WorktreeHistory(origin: .init(date: start, source: .user))
        for index in 0..<40 {
            history.record(.init(text: "Request \(index) in \(path): adjust the layout and check it again.", at: start.addingTimeInterval(Double(index) * 700)))
        }
        let brief = WorktreeBrief(recap: .init(title: "Refine the panel", completed: "Pinned the brief.",
            next: "Verify the timeline.", decisions: (0..<decisions).map { "Decision \($0) keeps the layout readable on every width." }),
            at: start)
        return SidebarWorktreeContext(worktree: WorktreePanes(path: path, displayName: "Task", repoDisplayName: "Project",
            displayBranch: "task", state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: nil, sidebar: .init(id: path, projectID: "p", brief: brief, history: history)))
    }

    private static func host<V: View>(_ view: V, height: Double) async throws -> (window: NSWindow, host: NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 320, height: height),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        try await settle(host)
        return (window, host)
    }

    private static func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
    }

    /// Points between the visible bottom and the end of the timeline's content.
    private static func distanceFromBottom(_ scrollView: NSScrollView) throws -> Double {
        let document = try #require(scrollView.documentView)
        let visible = scrollView.contentView.documentVisibleRect
        return document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
    }

    private static func scroll(_ scrollView: NSScrollView, toDistanceFromBottom distance: Double) throws {
        let document = try #require(scrollView.documentView)
        let visible = scrollView.contentView.documentVisibleRect
        let y = document.isFlipped ? document.bounds.maxY - visible.height - distance : document.bounds.minY + distance
        scrollView.contentView.scroll(to: NSPoint(x: visible.minX, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @Test func switchingWorktreesReopensTheTimelineAtItsLatestEvent() async throws {
        func panel(_ path: String) -> some View {
            WorktreeContextPanel(context: Self.context(path: path), onClose: {}).frame(width: 320, height: 700)
        }
        let (window, host) = try await Self.host(panel("/first"), height: 700)
        defer { window.close() }
        let first = try #require(Self.find(NSScrollView.self, in: host).first)
        try Self.scroll(first, toDistanceFromBottom: 10_000)
        try await Self.settle(host)
        #expect(try Self.distanceFromBottom(first) > 500, "The reader scrolled back through the first worktree")
        host.rootView = panel("/second")
        try await Self.settle(host)
        let second = try #require(Self.find(NSScrollView.self, in: host).first)
        #expect(try Self.distanceFromBottom(second) < 2, "Another worktree's timeline opens at its latest event")
    }

    @Test func collapsingAndRestoringTheBriefSettles() async throws {
        let (window, host) = try await Self.host(WorktreeContextPanel(context: Self.context(path: "/task"), collapsesBrief: true,
            onClose: {}).frame(width: 320, height: 700), height: 700)
        defer { window.close() }
        let expandedHeight = try #require(Self.find(NSScrollView.self, in: host).first).frame.height
        func settledHeights(afterScrollingTo distance: Double) async throws -> [Double] {
            try Self.scroll(try #require(Self.find(NSScrollView.self, in: host).first), toDistanceFromBottom: distance)
            try await Self.settle(host)
            var heights: [Double] = []
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                heights.append(try #require(Self.find(NSScrollView.self, in: host).first).frame.height)
            }
            return heights
        }
        let nearBottom = try await settledHeights(afterScrollingTo: 60)
        #expect(nearBottom.allSatisfy { abs($0 - expandedHeight) < 1 }, "Near the bottom the brief stays expanded: \(nearBottom)")
        let collapsed = try await settledHeights(afterScrollingTo: 500)
        #expect(Set(collapsed).count == 1, "The brief must settle instead of collapsing and expanding repeatedly: \(collapsed)")
        #expect(collapsed.last.map { $0 > expandedHeight + 100 } == true, "A reader scrolled far away sees the collapsed brief")
        let restored = try await settledHeights(afterScrollingTo: 10)
        #expect(restored.allSatisfy { abs($0 - expandedHeight) < 1 }, "Returning to the bottom restores the brief for good: \(restored)")
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
}
#endif
