#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeContextPanelTests {
    @Test("@spec CONTEXT-27: When Context is opened on Mac or mobile, the application shall pin the current brief above the timeline, capped at half the panel height by default and scrolling internally only when it exceeds its allocated height, and shall scroll the oldest-first timeline independently, opening at its latest event.", arguments: [260.0, 390.0])
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

    @Test("@spec CONTEXT-50: When Context shows an empty or populated brief on Mac or mobile, the application shall align its content to the top of its allocated area and let a short brief use its natural height by default.", arguments: [false, true])
    func briefStartsAtTop(hasBrief: Bool) async throws {
        let context = Self.context(path: "/task", decisions: 0, hasBrief: hasBrief)
        func panel(height: Double) -> some View {
            WorktreeContextPanel(context: context, foreground: .white, secondary: .white.opacity(0.65), onClose: {})
                .frame(width: 320, height: height).background(.black).environment(\.colorScheme, .dark)
        }
        let (window, host) = try await Self.host(panel(height: 700), height: 700)
        defer { window.close() }
        for height in [700.0, 1100.0] {
            host.rootView = panel(height: height)
            window.setContentSize(.init(width: 320, height: height))
            try await Self.settle(host)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let scale = Double(bitmap.pixelsHigh) / height
            let firstTextY = (Int(70 * scale)..<Int(400 * scale)).first { y in
                (Int(24 * scale)..<Int(290 * scale)).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent > 0.8
                }
            }
            #expect(Double(try #require(firstTextY)) / scale < 140, "Brief text must start immediately under the header")
            if !hasBrief {
                let timeline = try #require(Self.find(NSScrollView.self, in: host).first)
                let frame = timeline.convert(timeline.bounds, to: host)
                #expect(frame.minY < 300, "The empty brief must not reserve half of a tall panel")
            }
        }
    }

    @Test func contextUsesOpaqueThemeSurface() async throws {
        let themes: [(String, GhosttyThemeColors)] = [
            ("dark", .init(backgroundRGB: .init(r: 0.145, g: 0.161, b: 0.184),
                foregroundRGB: .init(r: 0.92, g: 0.93, b: 0.94))),
            ("light", .init(backgroundRGB: .init(r: 0.98, g: 0.97, b: 0.94),
                foregroundRGB: .init(r: 0.23, g: 0.25, b: 0.27))),
            ("warm", .init(backgroundRGB: .init(r: 0.16, g: 0.15, b: 0.13),
                foregroundRGB: .init(r: 0.90, g: 0.86, b: 0.76)))
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-context-sidebar-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, theme) in themes {
            for hasBrief in [false, true] {
                let panel = WorktreeContextPanel(context: Self.context(path: "/task", decisions: 0, hasBrief: hasBrief),
                    theme: theme, onClose: {})
                    .frame(width: 360, height: 800).background(.red)
                    .environment(\.colorScheme, theme.isDark ? .dark : .light)
                let (window, host) = try await Self.host(panel, height: 800, width: 360)
                defer { window.close() }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let scale = Double(bitmap.pixelsWide) / 360
                // Compare the cached sRGB channel values without applying a second profile conversion.
                let fill = try #require(bitmap.colorAt(x: Int(8 * scale), y: Int(70 * scale)))
                let expected = theme.contextBackgroundRGB
                #expect(abs(fill.redComponent - expected.r) < 0.01)
                #expect(abs(fill.greenComponent - expected.g) < 0.01)
                #expect(abs(fill.blueComponent - expected.b) < 0.01)
                #expect(fill.alphaComponent > 0.99)
                let edge = try #require(bitmap.colorAt(x: 0, y: Int(70 * scale)))
                #expect(abs(edge.redComponent - fill.redComponent) > 0.02, "The inspector must have a visible leading edge")
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(name)-\(hasBrief ? "brief" : "empty").png"))
            }
        }
    }

    private static func context(path: String, decisions: Int = 1, hasBrief: Bool = true) -> SidebarWorktreeContext {
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
            layout: nil, sidebar: .init(id: path, projectID: "p", brief: hasBrief ? brief : nil, history: history)))
    }

    private static func host<V: View>(_ view: V, height: Double, width: Double = 320) async throws -> (window: NSWindow, host: NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: width, height: height),
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

    @Test("@spec CONTEXT-46: When the user drags the divider between the Context summary and timeline on Mac or mobile, the application shall resize those sections independently, reserve 96 points for each when space permits, retain the chosen height during content updates, and restore automatic sizing when switching worktrees.", arguments: [false, true])
    func dividerResizesBriefAndTimeline(collapsesBrief: Bool) async throws {
        func panel(_ path: String, decisions: Int = 30) -> some View {
            WorktreeContextPanel(context: Self.context(path: path, decisions: decisions), collapsesBrief: collapsesBrief,
                onClose: {}).frame(width: 320, height: 700)
        }
        let (window, host) = try await Self.host(panel("/task"), height: 700)
        defer { window.close() }
        let views = Self.find(NSScrollView.self, in: host).sorted {
            $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY
        }
        let summary = try #require(views.first)
        let timeline = try #require(views.last)
        #expect(summary !== timeline)
        let originalSummary = summary.bounds.height, originalTimeline = timeline.bounds.height
        func handle(in view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "Resize context summary" { return view }
            return view.subviews.lazy.compactMap { handle(in: $0) }.first
        }
        func drag(by delta: Double) async throws {
            let divider = try #require(handle(in: host))
            let start = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
            func event(_ type: NSEvent.EventType, translation: Double) throws -> NSEvent {
                try #require(NSEvent.mouseEvent(with: type, location: .init(x: start.x, y: start.y - translation),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
            }
            divider.mouseDown(with: try event(.leftMouseDown, translation: 0))
            for translation in [delta / 2, delta] {
                divider.mouseDragged(with: try event(.leftMouseDragged, translation: translation))
                try await Self.settle(host)
            }
            divider.mouseUp(with: try event(.leftMouseUp, translation: delta))
            try await Self.settle(host)
        }
        try await drag(by: 80)
        #expect(abs(summary.bounds.height - originalSummary - 80) < 1)
        #expect(abs(timeline.bounds.height - originalTimeline + 80) < 1)
        try await drag(by: -50)
        #expect(abs(summary.bounds.height - originalSummary - 30) < 1)
        host.rootView = panel("/task", decisions: 40)
        try await Self.settle(host)
        #expect(abs(summary.bounds.height - originalSummary - 30) < 1)
        try await drag(by: 10000)
        #expect(timeline.bounds.height >= 96)
        try await drag(by: -10000)
        #expect(abs(summary.bounds.height - 96) < 1)
        host.rootView = panel("/other")
        try await Self.settle(host)
        #expect(Self.find(NSScrollView.self, in: host).allSatisfy { $0.bounds.height > 96 })
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
}
#endif
