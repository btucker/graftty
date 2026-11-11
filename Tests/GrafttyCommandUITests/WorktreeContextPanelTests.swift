#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeContextPanelTests {
    @Test("@spec CONTEXT-27: When Context is opened on Mac or mobile, the application shall show the worktree's title in a pinned header in place of a static Context label, and every other section in one scroll that opens at its latest content.", arguments: [260.0, 390.0])
    func titleHeaderAboveOneBottomAnchoredScroll(width: Double) async throws {
        for decisions in [1, 30] {
            let (window, host) = try await Self.host(WorktreeContextPanel(context: Self.context(path: "/task", decisions: decisions),
                onClose: {}).frame(width: width, height: 700), height: 700, width: width)
            defer { window.close() }
            let views = Self.find(NSScrollView.self, in: host)
            try #require(views.count == 1, "Only one region scrolls, whatever the brief's length")
            let scroll = try #require(views.first)
            let document = try #require(scroll.documentView)
            #expect(document.frame.height > scroll.frame.height, "The content overflows and scrolls")
            #expect(try Self.distanceFromBottom(scroll) < 2, "The scroll opens at its latest content")
            #expect(scroll.convert(scroll.bounds, to: nil).height > 600, "Only the header sits above the scroll")
        }
        #expect(WorktreeContextPanel.headerTitle(for: Self.context(path: "/task")) == "Refine the panel")
        #expect(WorktreeContextPanel.headerTitle(for: Self.context(path: "/task", hasBrief: false)) == "Task")
    }

    @Test("@spec CONTEXT-58: While Context shows a brief on Mac or mobile, the application shall end the scroll with the present state, its completed sentence above a dimmer Next line, after the timeline, followed by any waiting question and a status line.")
    func presentStateEndsTheScroll() {
        let context = Self.context(path: "/task")
        #expect(WorktreeContextPanel.sections(for: context, showsDetails: false) == [.timeline, .now, .status])
        let empty = Self.context(path: "/task", hasBrief: false)
        #expect(WorktreeContextPanel.sections(for: empty, showsDetails: false) == [.timeline, .empty],
            "With no brief and no running agent there is no status to show")
    }

    @Test("@spec CONTEXT-59: When the user activates the Context title on Mac or mobile, the application shall show or hide the worktree path, purpose, decisions and completed agents above the timeline, hidden by default.")
    func titleDisclosesDetails() {
        let context = Self.context(path: "/task")
        #expect(WorktreeContextPanel.sections(for: context, showsDetails: true) == [.details, .timeline, .now, .status])
        #expect(!WorktreeContextPanel.sections(for: context, showsDetails: false).contains(.details))
    }

    /// The scroll opens at its end, so details inserted at its top must be brought into view.
    @Test func activatingTheTitleRevealsTheDetails() async throws {
        let (window, host) = try await Self.host(WorktreeContextPanel(context: Self.context(path: "/task"), onClose: {})
            .frame(width: 320, height: 700).environment(\.accessibilityEnabled, true), height: 700)
        defer { window.close() }
        let scroll = try #require(Self.find(NSScrollView.self, in: host).first)
        #expect(try Self.distanceFromBottom(scroll) < 2)
        try await Self.settle(host)
        #expect(accessibilityPress("worktree.context.title", in: host))
        let document = try #require(scroll.documentView)
        var fromTop = Double.infinity
        // The scroll to the details waits a turn for them to exist.
        for _ in 0..<20 where fromTop >= 26 {
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let visible = scroll.contentView.documentVisibleRect
            fromTop = document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
        }
        // Only the scroll's 24-point padding may sit above the details.
        #expect(fromTop < 26, "The details at the top of the scroll are visible, not \(fromTop) points below them")
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
        // Let the panel finish opening (a scroller can still appear and re-wrap rows) before the reader scrolls.
        try await Self.settle(host)
        let first = try #require(Self.find(NSScrollView.self, in: host).first)
        try Self.scroll(first, toDistanceFromBottom: 10_000)
        try await Self.settle(host)
        let scrolledBack = try Self.distanceFromBottom(first)
        #expect(scrolledBack > 500, "The reader scrolled back through the first worktree, not \(scrolledBack) points")
        host.rootView = panel("/second")
        try await Self.settle(host)
        let second = try #require(Self.find(NSScrollView.self, in: host).first)
        #expect(try Self.distanceFromBottom(second) < 2, "Another worktree's timeline opens at its latest event")
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }
}
#endif
