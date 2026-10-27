#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeHistoryContentTests {
    @Test("@spec CONTEXT-19: When worktree history displays human input and peer messages on Mac or mobile, the application shall label a run of human input once as You with each input verbatim, and show each run of peer messages from one sender as one card with the sender link, a message count, the last two messages as one-line gists with earlier messages behind a control, repeats marked with a count, and the full original text when a message is tapped.", arguments: [260.0, 390.0])
    func humanInputAndPeerCards(width: Double) async throws {
        let start = Date(timeIntervalSince1970: 1_792_411_200)
        let firstPeer = UUID(), longPeer = UUID()
        let peerText = String(repeating: "The agent checked the layout and kept the full investigation available. ", count: 25)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let gists = PeerMessageGistProvider { _ in "Checked the layout." }
        var openedPaths: [String] = []
        func content(_ message: String) -> some View {
            var history = WorktreeHistory()
            history.record(.init(text: "I lean toward TypeScript.", at: start))
            history.record(.init(text: "Also check iPad.", at: start.addingTimeInterval(60)))
            for (offset, (id, text)) in [(firstPeer, "First note."), (longPeer, message), (UUID(), "Short message."), (UUID(), "Short message.")].enumerated() {
                history.record(.init(id: id, text: "<graftty-peer-message agent=\"/repo/layout#claude\">\(text)</graftty-peer-message>",
                    at: start.addingTimeInterval(Double(120 + offset))))
            }
            return WorktreeHistoryContent(timeline: .init(history: history, brief: nil), secondary: .secondary,
                openWorktree: { openedPaths.append($0); return true }, gists: gists)
                .padding(20).frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
        }
        let host = NSHostingView(rootView: content(peerText))
        let short = NSHostingView(rootView: content("A brief note."))
        #expect(abs(host.fittingSize.height - short.fittingSize.height) < 3, "A long peer message must collapse to one line")
        let window = NSWindow(contentRect: .init(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        try capture(host, named: "messages-collapsed-\(Int(width))")
        // Card rows from the bottom: 20 padding, 10 card inset, 32-point lines, 2-point spacing.
        let collapsedHeight = host.fittingSize.height
        func click(x: Double, fromBottom offset: Double) async throws {
            let top = collapsedHeight - offset
            let point = host.convert(NSPoint(x: x, y: host.isFlipped ? top : host.bounds.height - top), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let click = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(click)
            }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
        }
        try await click(x: width / 2, fromBottom: 154)
        #expect(openedPaths == ["/repo/layout"])
        #expect(abs(host.fittingSize.height - collapsedHeight) < 3, "Opening the worktree must not toggle the card")
        try await click(x: width / 2, fromBottom: 80)
        #expect(host.fittingSize.height > collapsedHeight + 400, "Tapping a message must reveal its complete text")
        #expect(openedPaths.count == 1, "Expanding must not navigate to the worktree")
        let expandedHeight = host.fittingSize.height
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        try await click(x: 62, fromBottom: 114)
        #expect(host.fittingSize.height > expandedHeight + 25, "The earlier control must reveal the older message")
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        try capture(host, named: "messages-expanded-\(Int(width))")
    }

    @Test func earlierControlCountsHiddenMessagesIncludingRepeats() throws {
        let start = Date(timeIntervalSince1970: 1_792_411_200)
        var history = WorktreeHistory()
        for (offset, text) in ["Same note.", "Same note.", "Same note.", "Middle.", "Last.", "Last."].enumerated() {
            history.record(.init(text: "<graftty-peer-message agent=\"/repo/layout#claude\">\(text)</graftty-peer-message>",
                at: start.addingTimeInterval(Double(offset))))
        }
        let row = try #require(WorktreeTimeline(history: history, brief: nil).rows(showAll: false).first { $0.kind == .peerMessages })
        try #require(row.events.count == 6 && row.entries.count == 3)
        #expect(WorktreeHistoryContent.hiddenMessageCount(row, visibleEntries: 2) == 3,
            "Three repeated messages hide behind the control, matching the card's message count")
        #expect(WorktreeHistoryContent.hiddenMessageCount(row, visibleEntries: 3) == 0)
    }

    private func capture(_ host: NSView, named name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
    }

    @Test("@spec CONTEXT-15: When Context is opened on Mac or mobile, the application shall show its history section without a disclosure, label human input separately from agent progress, separate rows by local day with Today, Yesterday, or a medium date, and show a short local time for each visible row while fitting the available width.")
    func historyRendersImmediatelyAtSidebarAndPhoneWidths() throws {
        let start = Date(timeIntervalSince1970: 1_792_411_200)
        var history = WorktreeHistory(origin: .init(date: start, source: .user))
        history.record(.init(text: "Show me what changed and why.", at: start.addingTimeInterval(150)))
        var brief = WorktreeBrief(recap: .init(title: "How we got here", completed: "Reviewed the shared context view.", next: "Compare the timeline.", decisions: ["Support both platforms"], historyEntry: .init(headline: "Found why the history repeats itself.", detail: "Checkpoints copied the entire decision list.")), at: start.addingTimeInterval(60))
        brief.update(.init(title: "How we got here", completed: "Kept creation and user input visible.", next: "Verify Mac and mobile.", decisions: ["Support both platforms"], historyEntry: .init(headline: "Separated history entries from status updates.", detail: "Routine reports now update only the current brief.")), at: start.addingTimeInterval(300))
        let noon = Calendar.current.startOfDay(for: start).addingTimeInterval(12 * 3600)
        #expect(WorktreeHistoryContent.day(noon.addingTimeInterval(-3600), now: noon) == "Today")
        #expect(WorktreeHistoryContent.day(noon.addingTimeInterval(-86400), now: noon) == "Yesterday")
        let older = noon.addingTimeInterval(-3 * 86400)
        #expect(WorktreeHistoryContent.day(older, now: noon) == older.formatted(date: .abbreviated, time: .omitted))
        #expect(WorktreeHistoryContent.time(older.timeIntervalSinceReferenceDate) == older.formatted(date: .omitted, time: .shortened))
        func twoInputs(apart interval: TimeInterval) -> NSHostingView<some View> {
            var history = WorktreeHistory()
            history.record(.init(text: "First request.", at: noon))
            history.record(.init(text: "Second request.", at: noon.addingTimeInterval(interval)))
            return NSHostingView(rootView: WorktreeHistoryContent(timeline: .init(history: history, brief: nil), secondary: .secondary)
                .frame(width: 320).fixedSize(horizontal: false, vertical: true))
        }
        #expect(twoInputs(apart: 2 * 86400).fittingSize.height > twoInputs(apart: 3600).fittingSize.height + 10, "A new day must add a separator")
        // A merged run is shown under its first day, so the next row compares against that day.
        var spanning = WorktreeHistory()
        for at in [older, noon.addingTimeInterval(-60)] {
            spanning.record(.init(text: "<graftty-peer-message agent=\"/repo/a#claude\">Status.</graftty-peer-message>", at: at))
        }
        spanning.record(.init(text: "Thanks.", at: noon))
        let spanningRows = WorktreeTimeline(history: spanning, brief: nil).rows(showAll: false)
        #expect(spanningRows.map(\.kind) == [.peerMessages, .inputs])
        #expect(WorktreeHistoryContent.dayLabels(spanningRows, now: noon) == [WorktreeHistoryContent.day(older, now: noon), "Today"])
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
