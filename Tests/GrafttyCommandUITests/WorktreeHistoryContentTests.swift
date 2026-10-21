#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeHistoryContentTests {
    @Test("@spec CONTEXT-19: When worktree history displays human input and peer messages on Mac or mobile, the application shall label human text only as 'Your input' and show peer messages as distinct sender-labelled disclosures collapsed by default, with their full content available on expansion.", arguments: [260.0, 390.0])
    func humanInputAndCollapsedAgentMessages(width: Double) async throws {
        let start = Date(timeIntervalSince1970: 1_792_411_200)
        let peerID = UUID()
        let peerText = String(repeating: "The agent checked the layout and kept the full investigation available. ", count: 25)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var openedPaths: [String] = []
        func content(_ message: String) -> some View {
            var history = WorktreeHistory()
            history.record(.init(text: "I lean toward TypeScript.", at: start))
            history.record(.init(id: peerID, text: "<graftty-peer-message agent=\"/repo/layout#claude\">\(message)</graftty-peer-message>", at: start.addingTimeInterval(1)))
            return WorktreeHistoryContent(timeline: .init(history: history, brief: nil), secondary: .secondary,
                openWorktree: { openedPaths.append($0); return true })
                .padding(20).frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
        }
        let host = NSHostingView(rootView: content(peerText))
        let short = NSHostingView(rootView: content("Short message."))
        #expect(abs(host.fittingSize.height - short.fittingSize.height) < 3, "Collapsed peer content must not increase the row height")
        let window = NSWindow(contentRect: .init(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try capture(host, named: "messages-collapsed-\(Int(width))")
        let collapsedHeight = host.fittingSize.height
        func click(_ x: Double) throws {
            let point = host.convert(NSPoint(x: x, y: host.isFlipped ? 178 : host.bounds.height - 178), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let click = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(click)
            }
        }
        try click(width / 2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(openedPaths == ["/repo/layout"])
        #expect(abs(host.fittingSize.height - collapsedHeight) < 3, "Opening the worktree must not toggle the message")
        try click(72)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > collapsedHeight + 400, "Clicking the chevron must reveal the complete peer message")
        #expect(openedPaths.count == 1, "Expanding must not navigate to the worktree")
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        try capture(host, named: "messages-expanded-\(Int(width))")
    }

    private func capture(_ host: NSView, named name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test("@spec CONTEXT-15: When Context is opened on Mac or mobile, the application shall show its history section without a disclosure, label human input separately from agent progress, and show a local date and time for each visible event while fitting the available width.")
    func historyRendersImmediatelyAtSidebarAndPhoneWidths() throws {
        let start = Date(timeIntervalSince1970: 1_792_411_200)
        var history = WorktreeHistory(origin: .init(date: start, source: .user))
        history.record(.init(text: "Keep my decisions visible, and let me expand all the steps.", at: start.addingTimeInterval(150)))
        var brief = WorktreeBrief(recap: .init(title: "How we got here", completed: "Reviewed the shared context view.", next: "Compare the timeline.", checkpoint: "Current timeline reviewed"), at: start.addingTimeInterval(60))
        brief.update(.init(title: "How we got here", completed: "Kept creation and user input visible.", next: "Verify Mac and mobile.", checkpoint: "Timeline implemented"), at: start.addingTimeInterval(300))
        for width in [260.0, 360.0, 390.0] {
            let short = NSHostingView(rootView: WorktreeHistoryContent(timeline: .init(history: history, brief: nil), secondary: .secondary)
                .padding(24).frame(width: width).fixedSize(horizontal: false, vertical: true))
            let host = NSHostingView(rootView: WorktreeHistoryContent(timeline: .init(history: history, brief: brief), secondary: .secondary)
                .padding(24).frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            let size = host.fittingSize
            #expect(abs(size.width - width) < 1)
            #expect(size.height > short.fittingSize.height + 90)
            if let path = ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("history-\(Int(width)).png"))
            }
        }
    }
}
#endif
