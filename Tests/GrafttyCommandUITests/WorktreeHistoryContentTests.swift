#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeHistoryContentTests {
    @Test("@spec CONTEXT-19: When worktree history displays human input and peer messages on Mac or mobile, the application shall align sender and time beside a quiet timeline rail with message text on one reading edge, label a run of human input once as You with each input verbatim, and show each peer run without an enclosing card, with the sender link, a message count for multiple messages, the last two multiline gists with earlier messages behind a control, repeats marked with a count, and the full original text when a message is tapped.", arguments: [260.0, 390.0])
    func humanInputAndPeerMessages(width: Double) async throws {
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
        // The rail's latest label sits below the messages; sender navigation is a separate header.
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
        try await click(x: width / 2, fromBottom: 284)
        #expect(openedPaths == ["/repo/layout"])
        #expect(abs(host.fittingSize.height - collapsedHeight) < 3, "Opening the worktree must not toggle the card")
        try await click(x: width / 2, fromBottom: 202)
        #expect(host.fittingSize.height > collapsedHeight + 400, "Tapping a message must reveal its complete text")
        #expect(openedPaths.count == 1, "Expanding must not navigate to the worktree")
        let expandedHeight = host.fittingSize.height
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        try await click(x: 62, fromBottom: 234)
        #expect(host.fittingSize.height > expandedHeight + 25, "The earlier control must reveal the older message")
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        try capture(host, named: "messages-expanded-\(Int(width))")
    }

    @Test("@spec CONTEXT-43: While a peer message or agent turn is collapsed in Context history on Mac or mobile, the application shall reserve four text lines and a fixed footer, show the first agent response until its completed-turn summary is ready and a skeleton while awaiting a peer summary, truncate overflowing previews with an ellipsis, and reveal the captured text on expansion without shifting later rows when generation finishes.")
    func summariesReserveFourLinesRegardlessOfTextLength() {
        for width in [260.0, 390.0] {
            #expect(abs(summaryHeight("Updated the workflows.", width: width) - summaryHeight(String(repeating: "Long summary with enough words to wrap ", count: 20), width: width)) < 1)
        }
    }

    private func summaryHeight(_ text: String, width: Double) -> CGFloat {
        func height(_ text: String) -> CGFloat {
            var history = WorktreeHistory()
            history.record(.init(text: "<graftty-peer-message agent=\"/repo/layout#claude\">\(text)</graftty-peer-message>", at: .now))
            let host = NSHostingView(rootView: WorktreeHistoryContent(timeline: .init(history: history, brief: nil), secondary: .secondary,
                gists: PeerMessageGistProvider { _ in nil })
                .padding(20).frame(width: width).fixedSize(horizontal: false, vertical: true))
            return host.fittingSize.height
        }
        return height(text)
    }

    private actor SummaryGate {
        var inputs: [String] = []
        private var pending: [CheckedContinuation<String?, Never>] = []
        private var result: String?

        func summarize(_ text: String) async -> String? {
            inputs.append(text)
            if let result { return result }
            return await withCheckedContinuation { pending.append($0) }
        }

        func finish(_ text: String) {
            result = text
            for continuation in pending { continuation.resume(returning: text) }
            pending.removeAll()
        }
    }

    @Test("@spec CONTEXT-47: While an agent turn is running on Mac or mobile, the timeline shall preview its first text response, retain that text through intermediate updates and summary generation, and generate an AI summary from the first and final responses only after the turn completes.", arguments: [260.0, 390.0])
    func turnWaitsForCompletionThenSummarizesEndpointsWithoutMovingFollowingRows(width: Double) async throws {
        let start = Date()
        let gate = SummaryGate()
        let gists = PeerMessageGistProvider { await gate.summarize($0) }
        var history = WorktreeHistory()
        func add(_ id: String, _ text: String, final: Bool) {
            history.record(WorktreeHistory.AgentResponse(id: id, text: text,
                at: start.addingTimeInterval(Double(history.responses.count)), runtime: "codex",
                sessionID: "session", isFinal: final))
        }
        func content() -> some View {
            let turn = WorktreeTimeline(history: history, brief: nil).rows(showAll: false)[0]
            return VStack(alignment: .leading, spacing: 16) {
                TimelineMessageLine(event: turn.events[0], turn: turn, secondary: .secondary, gists: gists)
                Text("Following row")
            }
            .padding(20).frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
            .environment(\.accessibilityEnabled, true)
        }
        add("first", "I will inspect the timeline.", final: false)
        let host = NSHostingView(rootView: content())
        let window = NSWindow(contentRect: .init(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(80))
        let workingHeight = host.fittingSize.height
        #expect(accessibilityLabels(in: host).contains("I will inspect the timeline."))
        add("middle", "This intermediate update must not reach the model.", final: false)
        host.rootView = content()
        try await Task.sleep(for: .milliseconds(80))
        #expect(await gate.inputs.isEmpty)
        #expect(accessibilityLabels(in: host).contains("I will inspect the timeline."))
        #expect(abs(host.fittingSize.height - workingHeight) < 1)
        add("last", "Fixed the timeline and checked both clients.", final: true)
        host.rootView = content()
        for _ in 0..<100 {
            if await !gate.inputs.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        let pendingHeight = host.fittingSize.height
        let pendingImage = try snapshot(host)
        #expect(accessibilityLabels(in: host).contains("I will inspect the timeline."))
        try capture(host, named: "turn-preview-\(Int(width))")
        let summary = "Fixed the timeline on Mac and mobile. Agent turns now use one expandable summary with four reserved lines, keeping later rows in place while the on-device model summarizes the first and last messages."
        await gate.finish(summary)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if try snapshot(host) != pendingImage { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        #expect(await gate.inputs == ["First agent message:\nI will inspect the timeline.\n\nLast agent message:\nFixed the timeline and checked both clients."])
        #expect(abs(host.fittingSize.height - pendingHeight) < 1)
        #expect(abs(host.fittingSize.height - workingHeight) < 1)
        #expect(try snapshot(host) != pendingImage, "The resolved summary must visibly replace the first response")
        try capture(host, named: "turn-summary-\(Int(width))")
    }

    @Test(arguments: [260.0, 390.0], [ColorScheme.dark, .light])
    func agentRepliesUseTheSharedWrappingSummary(width: Double, scheme: ColorScheme) async throws {
        let start = Date()
        var history = WorktreeHistory()
        history.record(.init(text: "I like B.", at: start))
        history.record(WorktreeHistory.AgentResponse(id: "reply", text: "I will implement B on both Mac and Mobile: a slim rail, sender and time on one line where they fit, multiline summaries, and no enclosing peer cards. Human input will share the same reading edge without the extra quote indent.\n\nThe map already has a click handler, so I am checking why it fails to receive clicks rather than adding a second handler.", at: start.addingTimeInterval(1), runtime: "codex"))
        let summary = "Implementing B on Mac and Mobile, with a slim rail and multiline summaries. Investigating why map clicks reach the terminal."
        let gists = PeerMessageGistProvider { _ in summary }
        let host = NSHostingView(rootView: WorktreeHistoryContent(timeline: .init(history: history, brief: nil),
            secondary: .secondary, gists: gists)
            .padding(20).frame(width: width).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: .init(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.width - width) < 1)
        #expect(host.fittingSize.height > 200)
        try capture(host, named: "agent-reply-\(Int(width))-\(scheme == .dark ? "dark" : "light")")
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

    private func accessibilityLabels(in root: NSView) -> Set<String> {
        var pending: [NSObject] = [root], seen: Set<ObjectIdentifier> = [], labels: Set<String> = []
        let label = NSSelectorFromString("accessibilityLabel")
        let children = NSSelectorFromString("accessibilityChildren")
        while let object = pending.popLast(), seen.count < 4096 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if object.responds(to: label), let value = object.perform(label)?.takeUnretainedValue() as? String {
                labels.insert(value)
            }
            if object.responds(to: children), let values = object.perform(children)?.takeUnretainedValue() as? [NSObject] {
                pending.append(contentsOf: values)
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return labels
    }

    private func capture(_ host: NSView, named name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_RENDER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try snapshot(host).write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func snapshot(_ host: NSView) throws -> Data {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
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
