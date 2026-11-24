#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
private final class FakeScrollback: TerminalScrollback {
    var rows: [String]
    var ready = true
    var reads = 0
    var scrolled: [Int] = []
    var firstRowReads = 0
    init(rows: [String]) { self.rows = rows }
    func firstRowText() -> String? {
        firstRowReads += 1
        return ready ? rows.first : nil
    }
    func scrollbackRows(limit: Int) -> ScrollbackRows? {
        reads += 1
        guard ready else { return nil }
        return ScrollbackRows(rows: rows, firstRow: 0, totalRows: rows.count)
    }
    func scroll(toRow row: Int) { scrolled.append(row) }
}

private let start = Date(timeIntervalSince1970: 1_792_411_200)

/// A human input, then a peer message, then a second human input.
private func sampleTimeline() -> WorktreeTimeline {
    var history = WorktreeHistory()
    history.record(.init(text: "open a pr for the sidebar fix", at: start))
    history.record(.init(text: "<graftty-peer-message agent=\"/repo/layout#claude\">The layout agent finished checking every split view and found no regressions in the sidebar.</graftty-peer-message>",
                         at: start.addingTimeInterval(600)))
    history.record(.init(text: "keep going, this is not security related", at: start.addingTimeInterval(1200)))
    return WorktreeTimeline(history: history, brief: nil)
}

private func sampleRows() -> [String] {
    var rows = Array(repeating: "⏺ working…", count: 600)
    rows[40] = "> open a pr for the sidebar fix"
    rows[300] = "The layout agent finished checking every split view and found no regressions in the sidebar."
    rows[560] = "> keep going, this is not security related"
    return rows
}

@MainActor private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

/// Shows `view` offscreen long enough for preview cards, hidden until measured, to settle.
@MainActor private func settledWindow(showing view: some View, size: CGSize) async throws -> NSWindow {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.orderFront(nil)
    try await Task.sleep(for: .milliseconds(400))
    window.contentView?.layoutSubtreeIfNeeded()
    return window
}

private final class FocusedRowProbe: @unchecked Sendable {
    var anchorsFocusedRow: Bool?
    func record(_ anchors: Bool) { anchorsFocusedRow = anchors }
}

private func render(_ view: some View, size: CGSize, named name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_RENDER_DIR"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
        .background(Color(red: 0.11, green: 0.12, blue: 0.15)).environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
}

@MainActor
@Suite("@spec CONTEXT-34: While an agent pane contains located messages, the application shall show a map of the entire scrollback with marks for human inputs, peer messages, and agent responses, merge marks closer than three points or whose bars overlap, and outline the visible rows. If no message is located, then the application shall hide the map.")
struct ScrollbackMapPresenceTests {
    @Test func rowsMapProportionallyOntoTheStrip() {
        let layout = ScrollbackMapLayout(height: 100, totalRows: 1000)
        #expect(layout.y(forRow: 0) == 0)
        #expect(layout.y(forRow: 500) == 50)
        #expect(layout.y(forRow: 1000) == 100)
        #expect(layout.row(forY: 50) == 500)
        #expect(layout.row(forY: -5) == 0)
        #expect(layout.row(forY: 500) == 999)
    }

    @Test func nearbyMarksMergeAndHumanInputWinsTheColor() {
        let layout = ScrollbackMapLayout(height: 100, totalRows: 1000)
        let marks = [
            ScrollbackMap.Mark(row: 100, kind: .peer, eventID: "a"),
            ScrollbackMap.Mark(row: 120, kind: .input, eventID: "b"),  // 2 pt below a
            ScrollbackMap.Mark(row: 400, kind: .peer, eventID: "c"),
            ScrollbackMap.Mark(row: 430, kind: .peer, eventID: "d"),   // 3 pt below c
        ]
        let clusters = layout.clusters(marks)
        #expect(clusters.map { $0.marks.map(\.eventID) } == [["a", "b"], ["c"], ["d"]])
        #expect(clusters.map(\.kind) == [.input, .peer, .peer])
        let edge = layout.clusters([ScrollbackMap.Mark(row: 1000, kind: .input, eventID: "e")])
        #expect(edge[0].y == 100 - ScrollbackMapLayout.markHeight, "A mark on the last row stays inside the strip")
    }

    @Test func aChainOfCloseMarksNeverMergesMarksThreePointsApart() {
        let layout = ScrollbackMapLayout(height: 100, totalRows: 1000)
        // Each mark is 2 pt below the previous one, so neighbors are close but a and c are 4 pt apart.
        let marks = ["a", "b", "c", "d"].enumerated().map { index, id in
            ScrollbackMap.Mark(row: 100 + index * 20, kind: .peer, eventID: id)
        }
        #expect(layout.clusters(marks).map { $0.marks.map(\.eventID) } == [["a", "b"], ["c", "d"]])
    }

    @Test func viewportBoxCoversTheVisibleRows() {
        let layout = ScrollbackMapLayout(height: 100, totalRows: 1000)
        let box = layout.viewportBox(ScrollbackViewport(offset: 800, length: 100, total: 1000))
        #expect(box.y == 80 && box.height == 10)
        let tiny = layout.viewportBox(ScrollbackViewport(offset: 1000, length: 5, total: 1000))
        #expect(tiny.height == ScrollbackMapLayout.minimumViewportHeight)
        #expect(tiny.y + tiny.height <= 100, "The box stays inside the strip")
        let grown = ScrollbackMapLayout(height: 100, map: ScrollbackMap(totalRows: 500, marks: []),
                                        viewport: ScrollbackViewport(offset: 0, length: 50, total: 1000))
        #expect(grown.totalRows == 1000, "Rows added since the last scan still fit on the strip")
    }

    @Test func macRailFillsTheAvailableHeightAndHidesWithoutMarks() throws {
        let timeline = sampleTimeline()
        let map = ScrollbackMap.locate(ScrollbackMap.messages(in: timeline), rows: sampleRows())
        #expect(map.marks.map(\.kind) == [.input, .peer, .input])
        let entries = ScrollbackMapEntry.entries(in: timeline)
        let viewport = ScrollbackViewport(offset: 520, length: 60, total: 600)
        let shown = NSHostingView(rootView: ScrollbackMapOverlay(map: map, viewport: viewport, entries: entries,
                                                                 availableHeight: 264, scroll: { _ in }))
        #expect(shown.fittingSize.width == 14)
        #expect(shown.fittingSize.height == 264)
        let empty = NSHostingView(rootView: ScrollbackMapOverlay(map: ScrollbackMap(totalRows: 600, marks: []), viewport: viewport,
                                                                 entries: entries, scroll: { _ in }))
        #expect(empty.fittingSize == .zero)
        try render(ScrollbackMapOverlay(map: map, viewport: viewport, entries: entries, availableHeight: 180, scroll: { _ in })
            .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing),
            size: CGSize(width: 320, height: 200), named: "scrollback-map-idle")
    }
}

@MainActor
@Suite("@spec CONTEXT-35: When the user hovers over, touches, or drags along the scrollback map, the application shall preview the nearest visible mark using a message of the kind shown by that mark, with human input verbatim and a sparkle next to a generated peer gist. While the user drags, the application shall center the row under the pointer or finger. When the user clicks or taps a mark, the application shall scroll its row to the top of the terminal.")
struct ScrollbackMapScrubTests {
    @Test("@spec CONTEXT-57.3: When the pointer enters an idle Mac scrollback rail, the application shall use the window’s pointer tracking to reveal previews. While the pointer moves from the rail into its previews, the application shall keep the previews fixed until the pointer leaves the rail and preview area and shall pass input outside the message boxes through to the terminal.", arguments: [1.0, 7.0, 13.0])
    func nativeTerminalAndGutterEachReceiveTheirOwnInput(x: Double) async throws {
        _ = NSApplication.shared
        let terminal = MapTerminalFixture()
        let timeline = sampleTimeline()
        let map = ScrollbackMap.locate(ScrollbackMap.messages(in: timeline), rows: sampleRows())
        let viewport = ScrollbackViewport(offset: 520, length: 60, total: 600)
        let scrollback = FakeScrollback(rows: sampleRows())
        let model = ScrollbackMapModel(terminal: scrollback, debounce: .zero)
        model.update(viewport: viewport)
        let content = MapTerminalRepresentable(view: terminal)
            .macScrollbackMapGutter(timeline: timeline, model: model, background: .black, topInset: 24)
            .onTapGesture { }
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await waitUntil { model.map != nil }
        host.layoutSubtreeIfNeeded()
        let terminalPoint = terminal.convert(NSPoint(x: 20, y: 200), to: host.superview)
        #expect(host.hitTest(terminalPoint) === terminal, "The map host must leave the rest of the terminal available for input")
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let pointer = try #require(descendants(host).compactMap { $0 as? ScrollbackMapPointerView }.first)
        let railFrame = pointer.convert(pointer.bounds, to: host)
        let terminalFrame = terminal.convert(terminal.bounds, to: host)
        #expect(railFrame.minX == terminalFrame.maxX)
        #expect(pointer.bounds.height == 264)
        #expect(pointer.previewArea == nil, "The fixture begins with the rail idle")
        let idleTracking = try #require(host.trackingAreas.first { $0.owner === pointer },
            "The window must pick up pointer motion before the first preview is displayed")
        #expect(idleTracking.options.contains(.mouseMoved))
        let layout = ScrollbackMapLayout(height: 252, map: map, viewport: viewport)
        let markY = layout.y(forRow: 40)
        let point = pointer.convert(NSPoint(x: x, y: ScrollbackMapLayout.stripInset.top + markY), to: nil)
        let hit = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
        #expect(hit === pointer, "The map owns hit testing in the gutter")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(scrollback.scrolled == [40], "The full gutter width receives clicks")
        #expect(terminal.clicks == 0, "Map clicks must not reach the terminal")

        pointer.scrollWheel(with: MapWheelEvent(point: point))
        #expect(terminal.wheels == 1, "Wheel scrolling over the map must reach the adjacent terminal")

        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        pointer.mouseMoved(with: moved)
        host.layoutSubtreeIfNeeded()
        #expect(pointer.convert(pointer.bounds, to: host) == railFrame)
        #expect(terminal.convert(terminal.bounds, to: host) == terminalFrame)
        let previewPoint = terminal.convert(NSPoint(x: 20, y: 36), to: host.superview)
        #expect(host.hitTest(previewPoint) === terminal, "Terminal space outside the cards still receives input")
        pointer.onClick?(ScrollbackMapLayout.stripInset.top + layout.y(forRow: 300))
        #expect(scrollback.scrolled.last == 300)
        await waitUntil { pointer.previewArea != nil }
        let area = try #require(pointer.previewArea)
        #expect(area.minX < 0 && area.maxX == railFrame.width)
        #expect(host.trackingAreas.contains { $0 === idleTracking }, "Showing previews keeps the original tracking area")
        func moveEvent(x: CGFloat) throws -> NSEvent {
            let location = pointer.convert(NSPoint(x: x, y: area.midY), to: nil)
            return try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        let overCard = try moveEvent(x: area.minX + 1)
        pointer.mouseMoved(with: overCard)
        await Task.yield()
        host.layoutSubtreeIfNeeded()
        #expect(pointer.previewArea == area, "Moving off the rail toward the cards keeps the layout fixed")
        pointer.mouseMoved(with: try moveEvent(x: area.minX - 1))
        await waitUntil { pointer.previewArea == nil }
        #expect(pointer.previewArea == nil)
        #expect(host.trackingAreas.contains { $0 === idleTracking }, "The idle rail remains ready to open again")
        #expect(pointer.convert(pointer.bounds, to: host) == railFrame)

        let dragY: CGFloat = 217
        for (type, y) in [(NSEvent.EventType.leftMouseDown, markY), (.leftMouseDragged, dragY), (.leftMouseUp, dragY)] {
            let y = ScrollbackMapLayout.stripInset.top + y
            let location = pointer.convert(NSPoint(x: x, y: y), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
        }
        let scrolled = try #require(scrollback.scrolled.last)
        #expect(abs(scrolled - layout.scrubTopRow(atY: dragY, viewportLength: viewport.length)) <= 1,
                "Native event coordinates may round to the nearest pixel")
        #expect(terminal.clicks == 0)
    }

    @Test("@spec CONTEXT-57.7: When the user clicks or taps a scrollback message box, the application shall scroll to the first message associated with the box, including when its excerpt is hidden.")
    func clickingGroupedBoxJumpsToItsEarliestMessage() async throws {
        _ = NSApplication.shared
        let terminal = MapTerminalFixture()
        var history = WorktreeHistory()
        var rows = Array(repeating: "", count: 400)
        for index in 0..<5 {
            let prompt = "This is distinct message number \(index) in the group"
            rows[100 + index * 4] = "> " + prompt
            history.record(.init(text: prompt, at: start.addingTimeInterval(Double(index))))
        }
        let transcript = FakeScrollback(rows: rows)
        let model = ScrollbackMapModel(terminal: transcript, debounce: .zero)
        let host = NSHostingView(rootView: MapTerminalRepresentable(view: terminal)
            .macScrollbackMapGutter(timeline: .init(history: history, brief: nil), model: model,
                                    background: .black, topInset: 0))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 440, height: 412),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await waitUntil { model.map?.marks.count == 5 }
        #expect(model.map?.marks.map(\.row) == [100, 104, 108, 112, 116])
        host.layoutSubtreeIfNeeded()
        let pointer = try #require(host.hitTest(NSPoint(x: host.bounds.maxX - 6, y: host.bounds.midY)) as? ScrollbackMapPointerView)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: pointer.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        let railPoint = CGPoint(x: 7, y: 120)
        pointer.mouseMoved(with: try event(.mouseMoved, at: railPoint))
        await waitUntil { pointer.previewArea != nil }
        let area = try #require(pointer.previewArea)
        let cardPoint = CGPoint(x: area.minX + 24, y: area.midY)
        pointer.mouseMoved(with: try event(.mouseMoved, at: cardPoint))
        let cardHit = try #require(host.hitTest(pointer.convert(cardPoint, to: host.superview)))
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                         wheel1: 1, wheel2: 0, wheel3: 0).flatMap(NSEvent.init(cgEvent:)))
        cardHit.scrollWheel(with: wheel)
        #expect(terminal.wheels == 1, "Scrolling over a preview still scrolls the terminal")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try event(type, at: cardPoint))
        }
        await waitUntil { !transcript.scrolled.isEmpty }
        #expect(transcript.scrolled == [100])
        #expect(terminal.clicks == 0)
    }

    @Test func scrubbingCentersTheRowUnderThePointer() {
        let layout = ScrollbackMapLayout(height: 100, totalRows: 1000)
        #expect(layout.scrubTopRow(atY: 50, viewportLength: 40) == 480)
        #expect(layout.scrubTopRow(atY: 1, viewportLength: 40) == 0, "Scrubbing never scrolls above the first row")
    }

    @Test func clicksLandOnMarksWithinTolerance() {
        let layout = ScrollbackMapLayout(height: 100, totalRows: 1000)
        let map = ScrollbackMap(totalRows: 1000, marks: [
            .init(row: 200, kind: .input, eventID: "a"), .init(row: 700, kind: .peer, eventID: "b"),
        ])
        #expect(layout.tapTarget(in: map, atY: 24)?.eventID == "a")
        #expect(layout.tapTarget(in: map, atY: 45) == nil, "A click between marks scrubs instead")
        #expect(layout.nearestMark(in: map, toY: 44)?.eventID == "a")
        #expect(layout.nearestMark(in: map, toY: 46)?.eventID == "b")
    }

    @Test func aMixedOrangeMarkPreviewsAndJumpsToTheInput() {
        let layout = ScrollbackMapLayout(height: 100, totalRows: 100)
        let input = ScrollbackMap.Mark(row: 40, kind: .input, eventID: "input")
        let reply = ScrollbackMap.Mark(row: 41, kind: .peer, eventID: "reply")
        let map = ScrollbackMap(totalRows: 100, marks: [input, reply])
        #expect(layout.previewTarget(in: map, atY: 41) == input)
        #expect(layout.tapTarget(in: map, atY: 41) == input)
    }

    @Test func aMixedPurpleMarkPreviewsTheIncomingMessage() {
        let layout = ScrollbackMapLayout(height: 100, totalRows: 100)
        let incoming = ScrollbackMap.Mark(row: 40, kind: .peer, eventID: "incoming")
        let response = ScrollbackMap.Mark(row: 41, kind: .peer, eventID: "response")
        let map = ScrollbackMap(totalRows: 100, marks: [incoming, response])
        #expect(layout.previewTarget(in: map, atY: 41, isIncoming: { $0 == incoming.eventID }) == incoming)
    }

    @Test func labelNamesTheSpeakerAndKeepsHumanInputVerbatim() throws {
        let timeline = sampleTimeline()
        let entries = ScrollbackMapEntry.entries(in: timeline)
        let input = try #require(entries[timeline.events[0].id])
        let peer = try #require(entries[timeline.events[1].id])
        #expect(input.kind == .input && input.text == "open a pr for the sidebar fix")
        #expect(input.heading().hasPrefix("You · "))
        #expect(peer.kind == .peer && peer.heading().hasPrefix("layout · "))
    }

    @Test func aGistThatFinishesAfterFocusMovesIsDropped() async {
        // Long enough that the provider must summarize instead of showing it verbatim.
        let text = String(repeating: "The layout agent checked another split view. ", count: 3)
        let entry = ScrollbackMapEntry(kind: .peer, text: text, timestamp: nil, sender: "layout")
        let gists = PeerMessageGistProvider { _ in
            try await Task.sleep(for: .milliseconds(100))
            return "Summary of the mark the pointer already left"
        }
        let load = Task { await ScrollbackMapOverlay.gist(for: entry, from: gists) }
        load.cancel()
        #expect(await load.value == nil, "A hover that moved on must not label the new mark with this gist")
        #expect(await ScrollbackMapOverlay.gist(for: entry, from: gists)?.isGenerated == true)
    }

    @Test func scrubbingScrollsTheModelsTerminal() async throws {
        let terminal = FakeScrollback(rows: sampleRows())
        let model = ScrollbackMapModel(terminal: terminal, debounce: .zero)
        model.scroll(toRow: 300)
        #expect(terminal.scrolled == [300])
    }

    @Test func rendersTheLiveLabel() throws {
        let timeline = sampleTimeline()
        let map = ScrollbackMap.locate(ScrollbackMap.messages(in: timeline), rows: sampleRows())
        let entries = ScrollbackMapEntry.entries(in: timeline)
        let viewport = ScrollbackViewport(offset: 270, length: 60, total: 600)
        let cardHeight: CGFloat = 210
        let layout = ScrollbackMapLayout(height: cardHeight - 12, map: map, viewport: viewport)
        let gists = PeerMessageGistProvider { _ in "Layout agent found no sidebar regressions" }
        for (name, row) in [("scrollback-map-scrub-input", 40), ("scrollback-map-scrub-peer", 300)] {
            try render(ScrollbackMapOverlay(map: map, viewport: viewport, entries: entries, gists: gists,
                                            availableHeight: cardHeight, availableWidth: 300,
                                            focusY: layout.y(forRow: row), scroll: { _ in })
                .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing),
                size: CGSize(width: 320, height: 240), named: name)
        }
    }
}

@MainActor
private final class MapWheelEvent: NSEvent {
    let point: NSPoint
    init(point: NSPoint) { self.point = point; super.init() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var locationInWindow: NSPoint { point }
    override var type: NSEvent.EventType { .scrollWheel }
}

private final class MapTerminalFixture: NSView {
    var clicks = 0
    var wheels = 0
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { clicks += 1 }
    override func scrollWheel(with event: NSEvent) { wheels += 1 }
}

private struct MapTerminalRepresentable: NSViewRepresentable {
    let view: MapTerminalFixture
    func makeNSView(context: Context) -> MapTerminalFixture { view }
    func updateNSView(_ nsView: MapTerminalFixture, context: Context) { }
}

@Suite("@spec CONTEXT-57.1: While the user hovers over, holds, or scrubs the scrollback map, the application shall group close user messages in shared cards beside their marks and connect each group to its span with a gradient. If all cards cannot fit, then the application shall prioritize the focused message and nearby cards.")
struct ScrollbackMapPreviewTests {
    @Test func previewsAllLocatedInputsAndOnlyTheFocusedAgentMessage() {
        let layout = ScrollbackMapLayout(height: 150, totalRows: 150)
        let first = ScrollbackMap.Mark(row: 20, kind: .input, eventID: "first")
        let merged = ScrollbackMap.Mark(row: 21, kind: .input, eventID: "merged")
        let peer = ScrollbackMap.Mark(row: 22, kind: .peer, eventID: "peer")
        let focused = ScrollbackMap.Mark(row: 55, kind: .peer, eventID: "focused")
        let last = ScrollbackMap.Mark(row: 110, kind: .input, eventID: "last")
        let map = ScrollbackMap(totalRows: 150, marks: [first, merged, peer, focused, last])
        let previews = layout.previewAnchors(in: map, focused: focused)
        #expect(previews.map(\.mark) == [first, merged, focused, last])
        #expect(zip(previews.map(\.y), [21, 21, 55, 110]).allSatisfy { abs($0 - $1) < 0.01 })
    }

    @Test func groupsNearbyInputsWithoutMergingTheFocusedAgentCard() {
        let previews = [30.0, 36, 52, 76, 100, 192].enumerated().map { index, y in
            ScrollbackMapPreview(id: String(index),
                entry: ScrollbackMapEntry(kind: index == 1 ? .peer : .input, text: "Message",
                                          timestamp: nil, sender: nil),
                y: y)
        }
        let groups = ScrollbackMapPreviewGroup.group(previews, maximumGap: 28, maximumSpan: 64)
        #expect(groups.map { $0.messages.map(\.id) } == [["1"], ["0", "2", "3"], ["4"], ["5"]])
        #expect(groups[1].startY == 30 && groups[1].endY == 76 && groups[1].y == 53)
    }

    @Test("@spec CONTEXT-57.12: While the user hovers over, touches, or scrubs the scrollback map over a group of close messages, the application shall list up to seven of the group's messages in rail order around the focused one, enlarge the focused message, shrink the others with their distance from it, and connect the focused message to its own mark.")
    func fisheyeListsTheGroupAroundTheFocusedMessage() throws {
        let messages = (0..<10).map { index in
            ScrollbackMapPreview(id: String(index),
                entry: ScrollbackMapEntry(kind: .input, text: "Message", timestamp: nil, sender: nil),
                y: Double(index) * 4)
        }
        let group = try #require(ScrollbackMapPreviewGroup.group(messages, maximumGap: 28, maximumSpan: 96).first)
        let focused = group.fisheye(focusedID: "1")
        #expect(focused.rows.map(\.preview.id) == ["0", "1", "2", "3", "4", "5", "6"])
        #expect(focused.rows.map(\.distance) == [1, 0, 1, 2, 3, 4, 5])
        #expect(focused.earlier == 0 && focused.later == 3)
        let middle = group.fisheye(focusedID: "6")
        #expect(middle.rows.map(\.preview.id) == ["3", "4", "5", "6", "7", "8", "9"])
        #expect(middle.earlier == 3 && middle.later == 0)
        let unfocused = group.fisheye(focusedID: nil)
        #expect(unfocused.rows.map(\.preview.id) == ["3", "4", "5", "6", "7", "8", "9"])
        #expect(unfocused.rows.allSatisfy { $0.distance == nil })
        #expect(ScrollbackMapFisheye.style(distance: 0).size > ScrollbackMapFisheye.style(distance: 1).size)
        #expect(ScrollbackMapFisheye.style(distance: 1).size > ScrollbackMapFisheye.style(distance: 2).size)
        #expect(ScrollbackMapFisheye.style(distance: 2) == ScrollbackMapFisheye.style(distance: 5))
        #expect(ScrollbackMapFisheye.style(distance: 0).lineLimit > 1)
    }

    @MainActor
    @Test func rendersTheFisheyeCard() throws {
        let texts = ["rerun the flaky port tests alone", "ok now bump the timeout? no — find why it hangs",
                     "also check the CI log for run 4077", "ship it once green"]
        let previews = texts.enumerated().map { index, text in
            ScrollbackMapPreview(id: String(index), entry: ScrollbackMapEntry(kind: .input, text: text,
                timestamp: Date.now.timeIntervalSinceReferenceDate - Double(9 - index * 2) * 60, sender: nil),
                y: 140 + Double(index) * 14)
        }
        let groups = ScrollbackMapPreviewGroup.group(previews, maximumGap: 36, maximumSpan: 64)
        try render(ScrollbackMapPreviews(groups: groups, height: 330, cardWidth: 180, gap: 48, railCenter: 18,
                                         focusY: 154, maximumShift: 16, focusedID: "1", responseGist: nil,
                                         onSelect: { _ in }),
                   size: CGSize(width: 300, height: 330), named: "scrollback-map-fisheye")
    }

    @MainActor
    @Test func rendersTheSharedFramesAndTheirRailSpans() throws {
        let items: [(row: Int, text: String, age: Double)] = [
            (28, "Check the migration logs", 87300),
            (43, "Look for the first failed statement", 18200),
            (62, "Run it against the copy first", 3620),
            (155, "Can we try the new layout?", 2800),
            (171, "Keep the current colors", 360),
            (241, "Did the simulator test pass?", 90),
        ]
        let viewport = ScrollbackViewport(offset: 220, length: 50, total: 300)
        let marks = items.map { ScrollbackMap.Mark(row: $0.row, kind: .input, eventID: String($0.row)) }
        let entries = Dictionary(uniqueKeysWithValues: items.map {
            (String($0.row), ScrollbackMapEntry(kind: .input, text: $0.text,
                timestamp: Date.now.timeIntervalSinceReferenceDate - $0.age, sender: nil))
        })
        try render(ScrollbackMapOverlay(map: ScrollbackMap(totalRows: 300, marks: marks), viewport: viewport,
                                        entries: entries, gists: .shared, availableHeight: 312, availableWidth: 360,
                                        focusY: 43, scroll: { _ in })
            .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing),
            size: CGSize(width: 380, height: 332), named: "scrollback-map-grouped")
    }

    @Test("@spec CONTEXT-57.14: When the previewed scrollback message changes, the application shall slide preview cards to their new positions and fade cards that no longer fit out where they stand, keeping unmeasured cards hidden, instead of moving or replacing them instantly. While Reduce Motion is on, the application shall change them without motion.")
    func hiddenCardsFadeWhereTheyStand() {
        let slots = ScrollbackPreviewStack.slots(anchors: [55, 67, 79, 130], heights: [36, 36, 36, nil],
                                                 height: 190, focusY: 67, maximumShift: 16)
        #expect(slots.map(\.visible) == [true, true, false, false])
        #expect(slots.map(\.top) == [22, 64, 61, 130])
        #expect(ScrollbackPreviewStack.animation(reduceMotion: true) == nil)
        #expect(ScrollbackPreviewStack.animation(reduceMotion: false) != nil)
        #expect(ScrollbackMapFisheye.animation(reduceMotion: true) == nil, "Grouped rows resize without motion too")
        #expect(ScrollbackMapFisheye.animation(reduceMotion: false) != nil)
    }

    @MainActor
    @Test func aHiddenCardLeavesThePointerToTheShownCard() async throws {
        func group(_ id: String, y: CGFloat) -> ScrollbackMapPreviewGroup {
            ScrollbackMapPreviewGroup(messages: [ScrollbackMapPreview(id: id,
                entry: ScrollbackMapEntry(kind: .input, text: "Message \(id)", timestamp: nil, sender: nil), y: y)])
        }
        var selected: [String] = []
        // The focused card fits; the next one cannot fit beside it and stays hidden, drawn over it.
        let window = try await settledWindow(showing: ScrollbackMapPreviews(
            groups: [group("shown", y: 70), group("hidden", y: 72)], height: 150, cardWidth: 180, gap: 48,
            railCenter: 18, focusY: 70, maximumShift: 16, focusedID: "shown", responseGist: nil,
            onSelect: { selected.append($0) }), size: CGSize(width: 228, height: 150))
        defer { window.close() }
        let host = try #require(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        // AppKit applies a native view's pointing-hand cursor rect even where SwiftUI shows nothing.
        #expect(descendants(host).filter { $0 is ScrollbackPreviewButtonInput.InputView }.count == 1,
                "Only the shown card may claim the pointer")
        let location = host.convert(NSPoint(x: 90, y: 70), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)))
        }
        await waitUntil { !selected.isEmpty }
        #expect(selected == ["shown"])
    }

    @MainActor
    @Test func aGroupCardThatCannotFitAnchorsNoFocusedConnector() async throws {
        let group = ScrollbackMapPreviewGroup(messages: (0..<4).map { index in
            ScrollbackMapPreview(id: String(index), entry: ScrollbackMapEntry(kind: .input,
                text: "Grouped message \(index)", timestamp: nil, sender: nil), y: 20 + CGFloat(index) * 6)
        })
        func anchorsFocusedRow(height: CGFloat) async throws -> Bool? {
            let probe = FocusedRowProbe()
            let window = try await settledWindow(showing: ScrollbackMapPreviews(groups: [group], height: height,
                    cardWidth: 180, gap: 48, railCenter: 18, focusY: 29, maximumShift: 16, focusedID: "1",
                    responseGist: nil, onSelect: { _ in })
                .backgroundPreferenceValue(FocusedRowBounds.self) { anchor in
                    let _ = probe.record(anchor != nil)
                    Color.clear
                }, size: CGSize(width: 228, height: height))
            window.close()
            return probe.anchorsFocusedRow
        }
        #expect(try await anchorsFocusedRow(height: 300) == true)
        #expect(try await anchorsFocusedRow(height: 40) == false, "A hidden card must not start the focused connector")
    }

    @Test func nudgesOnlyTheOverlappingPair() {
        let tops = ScrollbackPreviewStack.tops(anchors: [45, 136, 152, 260], heights: [30, 40, 32, 32],
                                               height: 310, focusY: 77, maximumShift: 24)
        #expect(tops == [30, 103, 149, 244])
    }

    @Test func fitsThePaneAndPrioritizesTheAreaBeingExplored() {
        let tops = ScrollbackPreviewStack.tops(anchors: [5, 75, 140, 148], heights: [35, 35, 50, 30],
                                               height: 138, focusY: 140, maximumShift: .infinity)
        #expect(tops == [nil, 11, 52, 108])
        #expect(ScrollbackPreviewStack.tops(anchors: [10], heights: [40], height: 20, focusY: 10, maximumShift: 16) == [nil])
    }

    @Test func omitsCardsThatWouldNeedLongConnectors() {
        let tops = ScrollbackPreviewStack.tops(anchors: [55, 67, 79, 130], heights: [36, 36, 36, 36],
                                               height: 190, focusY: 67, maximumShift: 16)
        #expect(tops == [22, 64, nil, 112])
    }

    @Test func theFocusedMessageWinsWhenSeveralInputsShareAMark() {
        let tops = ScrollbackPreviewStack.tops(anchors: [70, 70, 70, 70], heights: [36, 36, 36, 36],
                                               height: 150, focusY: 70, maximumShift: 16, focusedIndex: 2)
        #expect(tops == [nil, nil, 52, nil])
    }

    @Test("@spec CONTEXT-57.2: While a scrollback map preview has a message timestamp, the application shall show its elapsed age in whole minutes, hours from one hour, or days from twenty-four hours, and show now for messages less than a minute old.",
          arguments: [(-60.0, "now"), (59, "now"), (60, "1m"), (3599, "59m"), (3600, "1h"),
                      (86399, "23h"), (86400, "1d"), (259200, "3d")])
    func showsCompactRelativeAge(seconds: Double, age: String) {
        for kind in [ScrollbackMap.Kind.input, .peer] {
            let entry = ScrollbackMapEntry(kind: kind, text: "Message", timestamp: 0, sender: "Layout agent")
            let name = kind == .input ? "You" : "Layout agent"
            #expect(entry.heading(relativeTo: Date(timeIntervalSinceReferenceDate: seconds)) == "\(name) · \(age)")
        }
        let undated = ScrollbackMapEntry(kind: .input, text: "Message", timestamp: nil, sender: nil)
        #expect(undated.heading(relativeTo: Date(timeIntervalSinceReferenceDate: 60)) == "You")
    }
}

@Suite("@spec CONTEXT-36: While the Mac scrollback map is visible, the application shall place it in a fixed gutter beside the terminal text spanning the available pane height. While either map is visible, the application shall distinguish human input with orange rounded marks, incoming agent messages with purple square-ended marks, and local agent responses with cyan square-ended marks at rest and during interaction. While the Mac map is idle, the application shall show these marks and a viewport outline without a card background. While a message is in the preview, the application shall outline its mark.")
struct ScrollbackMapAppearanceTests {
    @MainActor
    @Test("@spec CONTEXT-57.13: While a scrollback map preview card is shown, the application shall draw it on a nearly opaque backing lighter than a dark terminal, so terminal text behind the card does not show through.")
    func previewCardsHideTheTerminalBehindThem() throws {
        let card = Color.clear.frame(height: 40)
            .modifier(ScrollbackMapPreviewFrame(width: 120))
            .padding(20)
            .background(Color(red: 1, green: 0, blue: 0))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let inside = try #require(bitmap.colorAt(x: 80, y: 40)?.usingColorSpace(.sRGB))
        #expect(inside.redComponent - inside.greenComponent < 0.1)
        #expect(inside.greenComponent > 0.18) // lighter than a #282c34 terminal
    }

    @Test func distantMarksRetainTheirColorAndThePreviewMatchesTheMessage() throws {
        let layout = ScrollbackMapLayout(height: 150, totalRows: 150)
        let input = ScrollbackMap.Mark(row: 38, kind: .input, eventID: "input")
        let peer = ScrollbackMap.Mark(row: 39, kind: .peer, eventID: "peer")
        let marks = [input, peer, .init(row: 48, kind: .input, eventID: "nearby"),
                                  .init(row: 119, kind: .input, eventID: "distant")]
        let idle = layout.presentedMarks(marks, width: 9, maximumWidth: 12, focusY: nil)
        let hovered = layout.presentedMarks(marks, width: 9, maximumWidth: 12, focusY: 39, previewedMark: peer)
        #expect(idle.allSatisfy { !$0.isPreviewed })
        #expect(hovered.filter(\.isPreviewed).count == 1)
        let palette = ScrollbackMapPalette(scheme: .dark)
        let environment = EnvironmentValues()
        let distant = try #require(hovered.last)
        #expect(palette.mark(distant.kind, muted: false).resolve(in: environment) == palette.input.resolve(in: environment))
        #expect(hovered.map { $0.frame.midY } == idle.map { $0.frame.midY })
        let selected = try #require(hovered.first)
        #expect(selected.kind == .peer, "A mixed group uses the color of the message in the preview")
        #expect(selected.isPreviewed)
        #expect(selected.cornerRadius == 0)
        #expect(distant.cornerRadius > 0)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func mobileMarksContrastWithTheirBackingInBothAppearances(scheme: ColorScheme) {
        let palette = ScrollbackMapPalette(scheme: scheme)
        let environment = EnvironmentValues()
        func luminance(_ color: Color) -> Double {
            let c = color.resolve(in: environment)
            return 0.2126 * Double(c.linearRed) + 0.7152 * Double(c.linearGreen) + 0.0722 * Double(c.linearBlue)
        }
        let backing = luminance(palette.backing)
        for color in [palette.input, palette.peer] {
            let mark = luminance(color)
            #expect((max(mark, backing) + 0.05) / (min(mark, backing) + 0.05) >= 4.5)
        }
    }
}

@Suite("@spec CONTEXT-57: While the user hovers over, touches, or scrubs the scrollback map, the application shall magnify nearby marks inward and along the strip without overlapping other marks or changing their vertical centers, the map height, or the navigation scale. If Reduce Motion is on, then the application shall expand and collapse the mobile map without animation.")
struct ScrollbackMapFixedPositionTests {
    @Test(arguments: [63.0, 138.0, 380.0])
    func drawingAndNavigationUseTheSameLinearScale(height: CGFloat) {
        let layout = ScrollbackMapLayout(height: height, totalRows: 1000)
        let target = ScrollbackMap.Mark(row: 700, kind: .input, eventID: "target")
        let y = height * 0.7
        #expect(layout.tapTarget(in: ScrollbackMap(totalRows: 1000, marks: [target]), atY: y) == target)
        #expect(layout.scrubTopRow(atY: y + 0.0001, viewportLength: 40) == 680)
        #expect(layout.row(forY: height) == 999)
    }

    @Test func magnificationFollowsThePointerWithoutMovingTargets() throws {
        let layout = ScrollbackMapLayout(height: 150, totalRows: 150)
        let marks = [20, 26, 43, 120].map { ScrollbackMap.Mark(row: $0, kind: .input, eventID: "\($0)") }
        func bars(near focus: CGFloat?) -> [CGRect] {
            layout.presentedMarks(marks, width: 9, maximumWidth: 26, focusY: focus).map(\.frame)
        }
        let idle = bars(near: nil)
        let early = bars(near: 20)
        let later = bars(near: 43)
        try #require(idle.count == 4 && early.count == 4 && later.count == 4)
        #expect(early.map(\.midY) == idle.map(\.midY))
        #expect(later.map(\.midY) == idle.map(\.midY))
        #expect(early[0].width > idle[0].width * 2 && early[0].height > idle[0].height)
        #expect(early[0].width > early[1].width)
        #expect(early[0].maxX <= 9 / 2, "Wide marks grow into the terminal side of the rail")
        #expect(later[2].height > idle[2].height * 2 && later[2].height > early[2].height)
        #expect(early[3] == idle[3] && later[3] == idle[3])
        #expect(layout.scrubTopRow(atY: early[0].midY, viewportLength: 10) == 15)
    }

    @Test func magnifiedMarksStayInsideTheStripAndApartInDenseRegions() {
        let layout = ScrollbackMapLayout(height: 42, totalRows: 42)
        let marks = stride(from: 0, through: 42, by: 3).map {
            ScrollbackMap.Mark(row: $0, kind: .peer, eventID: "\($0)")
        }
        for focus in [CGFloat(0), 21, 42] {
            let bars = layout.presentedMarks(marks, width: 8, maximumWidth: 8, focusY: focus).map(\.frame)
            #expect(bars.allSatisfy { $0.minY >= 0 && $0.maxY <= 42 && $0.width <= 8 })
            #expect(zip(bars, bars.dropFirst()).allSatisfy { $0.maxY <= $1.minY })
        }
    }

    @Test func reduceMotionDropsTheMobileExpansionAnimation() {
        #expect(ScrollbackMapLayout.interactionAnimation(reduceMotion: true) == nil)
        #expect(ScrollbackMapLayout.interactionAnimation(reduceMotion: false) != nil)
    }
}

@Test("@spec CONTEXT-37: While GrafttyMobile shows the scrollback map on the focused agent pane, the application shall place the card below the pane's floating top-right controls, including the Worktree context button, so the card and the controls never overlap.", arguments: [44.0, 96.0, 148.0])
func scrollbackMapClearsMobileControls(controlsHeight: Double) {
    let controlsTop: CGFloat = 12
    let controls = CGRect(x: 300, y: controlsTop, width: 44, height: controlsHeight)
    let top = ScrollbackMapLayout.topInset(belowControlsAt: controlsTop, controlsHeight: controlsHeight)
    let card = CGRect(x: 310, y: top, width: ScrollbackMapLayout.cardSize.width, height: ScrollbackMapLayout.cardSize.height)
    #expect(!card.intersects(controls))
    #expect(top - controls.maxY == 8)
}

@MainActor
@Suite("@spec CONTEXT-49: While the mobile scrollback map is idle, the application shall show an eight-point strip flush with the pane's right edge. While the map is visible, the application shall keep a 44-point-wide touch target and limit the map height to 150 points. While the map is held, dragged, or hovered, the application shall expand it inward. When the interaction ends or is cancelled, the application shall collapse the card.")
struct ScrollbackMapMobileCollapseTests {
    @Test func idleAndExpandedCardsKeepTheSameTouchWidth() throws {
        let timeline = sampleTimeline()
        let map = ScrollbackMap.locate(ScrollbackMap.messages(in: timeline), rows: sampleRows())
        let viewport = ScrollbackViewport(offset: 520, length: 60, total: 600)
        for active in [false, true] {
            let overlay = ScrollbackMapOverlay(map: map, viewport: viewport,
                entries: ScrollbackMapEntry.entries(in: timeline), gists: .shared,
                focusY: active ? 70 : nil, scroll: { _ in })
            let host = NSHostingView(rootView: overlay.mobileInputCard)
            #expect(host.fittingSize.width == 44)
            #expect(host.fittingSize.height == 150)
            try render(overlay.mobileInputCard.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing),
                       size: CGSize(width: 390, height: 240), named: active ? "scrollback-map-mobile-expanded" : "scrollback-map-mobile-collapsed")
        }
    }

    @Test func presentationExpandsOnlyInward() {
        let idle = ScrollbackMapLayout.mobileCardFrame(expansion: 0, height: 150)
        let active = ScrollbackMapLayout.mobileCardFrame(expansion: 1, height: 150)
        #expect(idle == CGRect(x: 36, y: 0, width: 8, height: 150))
        #expect(active == CGRect(x: 4, y: 0, width: 34, height: 150))
        #expect(idle.minY == active.minY)
        #expect(ScrollbackMapLayout.stripY(forCardY: 70) == 64)
    }
}

@MainActor
struct ScrollbackMapTileRailTests {
    @Test("@spec CONTEXT-57.15: While an agent is shown as a gallery tile, the application shall show its scrollback map on the tile's right edge, let its preview cards extend beyond the tile, and when a mark or card is activated, put that agent on stage scrolled to that message.")
    func tileRailJumpsThroughTheGallery() {
        let map = ScrollbackMap(totalRows: 1000, marks: [.init(row: 100, kind: .input, eventID: "early"),
                                                         .init(row: 900, kind: .input, eventID: "late")])
        let viewport = ScrollbackViewport(offset: 950, length: 50, total: 1000)
        let layout = ScrollbackMapLayout(height: 200, map: map, viewport: viewport)
        var jumped: [String] = []
        var scrolled: [Int] = []
        let tile = ScrollbackMapOverlay(map: map, viewport: viewport, entries: [:], availableHeight: 212,
                                        previewOverhang: 200, jump: { jumped.append($0) }, scroll: { scrolled.append($0) })
        let late = ScrollbackMapLayout.stripInset.top + layout.y(forRow: 900)
        tile.click(at: late, layout: layout)
        // A scrub only previews until it ends, then jumps to the previewed
        // message rather than to a row half a viewport above the finger.
        tile.finishDrag(at: late, layout: layout)
        #expect(jumped == ["late", "late"])
        #expect(scrolled.isEmpty)

        let stage = ScrollbackMapOverlay(map: map, viewport: viewport, entries: [:], availableHeight: 212,
                                         scroll: { scrolled.append($0) })
        stage.click(at: late, layout: layout)
        #expect(scrolled == [900])
        #expect(ScrollbackMapOverlay.previewFrame(railHeight: 80, overhang: 200) == .init(top: -200, height: 480))
        #expect(ScrollbackMapOverlay.previewFrame(railHeight: 80, overhang: 0) == .init(top: 0, height: 80))
    }

    /// A phone or iPad tile renders its own preview surface, so its rows
    /// mean nothing on the staged terminal; the jump carries the message
    /// and retries until the staged terminal has mounted and loaded it.
    @Test func aStagedJumpRetriesUntilTheMessageIsRevealed() async {
        var calls = 0
        let revealed = await StagedMessageReveal.reveal(attempts: 5, sleep: { _ in }) {
            calls += 1
            return calls == 3
        }
        #expect(revealed)
        #expect(calls == 3)

        calls = 0
        let gaveUp = await StagedMessageReveal.reveal(attempts: 4, sleep: { _ in }) { calls += 1; return false }
        #expect(!gaveUp)
        #expect(calls == 4)
    }

    @Test func aStagedJumpStopsWhenCancelled() async {
        var calls = 0
        let task = Task { @MainActor in
            await StagedMessageReveal.reveal(attempts: 50, sleep: { _ in withUnsafeCurrentTask { $0?.cancel() } }) {
                calls += 1
                return false
            }
        }
        #expect(await task.value == false)
        #expect(calls == 1)
    }

    @Test func aModelShownTwiceKeepsScanningUntilBothHide() async {
        let terminal = FakeScrollback(rows: sampleRows())
        let model = ScrollbackMapModel(terminal: terminal, debounce: .zero)
        model.update(timeline: sampleTimeline())
        model.setVisible(true, for: "stage")
        model.setVisible(true, for: "tile")
        model.setVisible(false, for: "stage")
        await waitUntil { model.map != nil }
        #expect(model.map?.marks.count == 3)
        model.setVisible(false, for: "tile")
        let reads = terminal.reads
        model.terminalHistoryDidChange()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(terminal.reads == reads)
    }

    /// A tile rail is shorter than its cards, which extend past it; the pointer
    /// must still reach those cards and activate them.
    @Test func tileRailCardsBeyondTheRailStayReachable() async throws {
        _ = NSApplication.shared
        let terminal = MapTerminalFixture()
        var history = WorktreeHistory()
        var rows = Array(repeating: "", count: 400)
        for index in 0..<5 {
            let prompt = "This is distinct message number \(index) in the group"
            rows[100 + index * 4] = "> " + prompt
            history.record(.init(text: prompt, at: start.addingTimeInterval(Double(index))))
        }
        let transcript = FakeScrollback(rows: rows)
        let model = ScrollbackMapModel(terminal: transcript, debounce: .zero)
        let rail = ScrollbackMapOverlayHost(model: model, timeline: .init(history: history, brief: nil),
                                            previewOverhang: 200, previewWidth: 420)
        let host = NSHostingView(rootView: MapTerminalRepresentable(view: terminal)
            .padding(.trailing, ScrollbackMapLayout.macGutterWidth)
            .overlay(alignment: .topTrailing) {
                rail.frame(width: ScrollbackMapLayout.macGutterWidth, height: 120).padding(.top, 240)
            })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 440, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await waitUntil { model.map?.marks.count == 5 }
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let pointer = try #require(descendants(host).compactMap { $0 as? ScrollbackMapPointerView }.first)
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: pointer.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
        }
        pointer.mouseMoved(with: try event(.mouseMoved, at: CGPoint(x: 7, y: pointer.bounds.midY)))
        await waitUntil { pointer.previewArea != nil }
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()
        let area = try #require(pointer.previewArea)
        let cardPoint = CGPoint(x: area.minX + 24, y: area.midY)
        pointer.mouseMoved(with: try event(.mouseMoved, at: cardPoint))
        let cardHit = host.hitTest(pointer.convert(cardPoint, to: host.superview))
        #expect(cardHit is ScrollbackPreviewButtonInput.InputView,
                "The pointer's preview area must be where the cards are drawn; it found \(cardHit.map { "\(type(of: $0))" } ?? "nil")")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try event(type, at: cardPoint))
        }
        await waitUntil { !transcript.scrolled.isEmpty }
        #expect(!transcript.scrolled.isEmpty, "Clicking a card beyond the rail jumps to its message")
        #expect(terminal.clicks == 0)
    }
}

@MainActor
@Suite("@spec CONTEXT-38: While the agent pane is visible, the application shall rebuild its scrollback map after about a second without timeline or scrollback size changes, ignore scroll-only viewport changes, rescan when a check every five seconds finds that the oldest scrollback row changed because output at the scrollback limit evicted rows, and not scan the scrollback while the pane is hidden.")
struct ScrollbackMapRebuildTests {
    @Test("@spec CONTEXT-57.10: When a quiet agent terminal becomes readable or installs same-sized history, the application shall locate its existing messages without waiting for another prompt.")
    func quietTerminalBecomesReadable() async throws {
        let terminal = FakeScrollback(rows: sampleRows())
        terminal.ready = false
        let model = ScrollbackMapModel(terminal: terminal, debounce: .zero, evictionCheckInterval: .milliseconds(10))
        model.update(timeline: sampleTimeline())
        model.setVisible(true)
        defer { model.setVisible(false) }
        await waitUntil { terminal.reads > 0 }
        terminal.ready = true
        await waitUntil { model.map?.marks.count == 3 }
        #expect(model.map?.marks.count == 3)
        terminal.rows.swapAt(40, 50)
        model.terminalHistoryDidChange()
        await waitUntil { model.map?.marks.first?.row == 50 }
        #expect(model.map?.marks.first?.row == 50)
    }

    @Test("@spec CONTEXT-57.9: When a paired Codex pane on iPhone has scanned its loaded rows without finding a message and older history is available, the application shall offer a control to load an earlier page and replace it with the rail when it finds a message.")
    func loadEarlierPageFromEmptyRail() async throws {
        let terminal = FakeScrollback(rows: ["• Reading the logs."])
        let model = ScrollbackMapModel(terminal: terminal, debounce: .zero)
        let timeline = WorktreeTimeline(history: nil, brief: nil)
        let agent = AgentSessionInfo(id: "agent", name: "agent", provider: "codex", status: "running", sessionName: "pane")
        let recovery = try #require(ScrollbackMapRecovery.pairedCodex(agent))
        let host = ScrollbackMapOverlayHost(model: model, timeline: timeline, recovery: recovery, loadEarlier: {
            terminal.rows.insert(contentsOf: ["› Please check", ""], at: 0)
            model.update(viewport: .init(offset: 2, length: 1, total: 3))
        })
        #expect(host.earlierHistoryAction == nil)
        model.update(timeline: timeline, recovery: recovery)
        model.setVisible(true)
        await waitUntil { model.map != nil }
        #expect(ScrollbackMapOverlayHost(model: model, timeline: timeline).earlierHistoryAction == nil)
        let load = try #require(host.earlierHistoryAction)
        load()
        await waitUntil { model.map?.marks.first?.row == 0 }
        #expect(model.map?.marks.count == 1)
        #expect(host.earlierHistoryAction == nil)
    }

    @Test("@spec CONTEXT-57.8: When a paired Codex pane shows a submitted user prompt missing from the host timeline, the application shall mark its loaded terminal row and show its text, excluding the editable composer and generated notices.")
    func pairedCodexRecoversSubmittedPrompts() async throws {
        let terminal = FakeScrollback(rows: [
            "› <graftty-forge-message provider=\"github\">", "  CI changed", "  </graftty-forge-message>", "", "• Checking CI.",
            "› install this on my iPhone", "", "• Installed.",
            "› the rail isn't appearing in this codex", "  session on iPhone", "", "• Checking the rail.",
            "› still typing", "", "  GPT-6 · context"
        ])
        let model = ScrollbackMapModel(terminal: terminal, debounce: .zero)
        let agent = AgentSessionInfo(id: "agent", name: "agent", provider: "codex", status: "running", sessionName: "codex-pane")
        let recovery = try #require(ScrollbackMapRecovery.pairedCodex(agent))
        model.update(timeline: WorktreeTimeline(history: nil, brief: nil),
                     recovery: recovery)
        model.setVisible(true)
        await waitUntil { model.map != nil }
        let marks = try #require(model.map?.marks)
        #expect(marks.map(\.row) == [5, 8])
        #expect(marks.compactMap { model.entries[$0.id]?.text } ==
                ["install this on my iPhone", "the rail isn't appearing in this codex session on iPhone"])
        #expect(marks.allSatisfy { model.entries[$0.id]?.timestamp == nil })

        var captured = WorktreeHistory()
        let input = WorktreeHistory.UserInput(text: "install this on my iPhone", at: start, runtime: "codex")
        captured.record(input)
        model.update(timeline: WorktreeTimeline(history: captured, brief: nil), recovery: recovery)
        await waitUntil { model.map?.row(for: input.id.uuidString) != nil }
        #expect(model.map?.marks.map(\.row) == [5, 8])
        #expect(model.entries[input.id.uuidString]?.timestamp == input.timestamp)
    }

    @Test("@spec CONTEXT-57.5: While a local Codex pane displays submitted prompts, the application shall mark matching prompts from its saved conversation even when captured agent replies already match, preserving captured marks and showing each prompt row once.", arguments: [false, true])
    func supplementsCapturedMarksWithSubmittedPrompts(hasCapturedInput: Bool) async {
        var rows = sampleRows()
        rows[40] = "› open a pr for the sidebar fix"
        rows[560] = "› keep going, this is not security related"
        rows[580] = "• The user said: keep going, this is not security related"
        let terminal = FakeScrollback(rows: rows)
        let model = ScrollbackMapModel(terminal: terminal, debounce: .zero)
        var captured = WorktreeHistory()
        if hasCapturedInput { captured.record(.init(text: "open a pr for the sidebar fix", at: start)) }
        captured.record(WorktreeHistory.AgentResponse(id: "reply", text: rows[300], at: start.addingTimeInterval(600), runtime: "codex"))
        model.update(timeline: WorktreeTimeline(history: captured, brief: nil),
                     recovery: .init(id: "local-codex", load: { sampleTimeline() }))
        model.setVisible(true)
        await waitUntil { model.map != nil }
        #expect(model.map?.marks.map(\.row) == [40, 300, 560])
        #expect(model.map?.marks.map(\.kind) == [.input, .peer, .input])
        #expect(model.map?.row(for: "reply") == 300)
        #expect(terminal.reads == 1)
    }

    @Test func hiddenPaneNeverScans() async {
        let terminal = FakeScrollback(rows: sampleRows())
        let model = ScrollbackMapModel(terminal: terminal, debounce: .milliseconds(20))
        model.update(timeline: sampleTimeline())
        model.update(viewport: ScrollbackViewport(offset: 0, length: 40, total: 600))
        try? await Task.sleep(for: .milliseconds(120))
        #expect(terminal.reads == 0)
        #expect(model.map == nil)
    }

    @Test func visiblePaneScansOnceAfterChangesSettle() async {
        let terminal = FakeScrollback(rows: sampleRows())
        let model = ScrollbackMapModel(terminal: terminal, debounce: .milliseconds(60))
        model.update(timeline: sampleTimeline())
        model.setVisible(true)
        for total in 600..<610 { model.update(viewport: ScrollbackViewport(offset: total - 40, length: 40, total: total)) }
        await waitUntil { model.map != nil }
        #expect(terminal.reads == 1, "A burst of scrollback growth scans once")
        #expect(model.map?.marks.count == 3)
        #expect(model.entries.count == 3)

        for offset in [0, 100, 200] { model.update(viewport: ScrollbackViewport(offset: offset, length: 40, total: 609)) }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(terminal.reads == 1, "Scrolling alone does not rescan")
        #expect(model.viewport.offset == 200)

        model.update(viewport: ScrollbackViewport(offset: 200, length: 40, total: 700))
        model.setVisible(false)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(terminal.reads == 1, "Hiding the pane cancels a pending scan")
    }

    @Test func evictionAtTheScrollbackLimitRescans() async {
        // Distinct filler rows, so the oldest row changes when output evicts rows.
        var rows = sampleRows().enumerated().map { $1 == "⏺ working…" ? "⏺ step \($0)" : $1 }
        let terminal = FakeScrollback(rows: rows)
        let model = ScrollbackMapModel(terminal: terminal, debounce: .milliseconds(10),
                                       evictionCheckInterval: .milliseconds(30))
        model.update(timeline: sampleTimeline())
        model.update(viewport: ScrollbackViewport(offset: 560, length: 40, total: 600))
        model.setVisible(true)
        await waitUntil { model.map != nil }
        #expect(model.map?.marks.map(\.row).sorted() == [40, 300, 560])

        // At the limit, 30 new rows evict the 30 oldest; the total and viewport stay put.
        rows = Array(rows.dropFirst(30)) + (0..<30).map { "⏺ new step \($0)" }
        terminal.rows = rows
        await waitUntil { model.map?.marks.map(\.row).sorted() == [10, 270, 530] }
        #expect(model.map?.marks.map(\.row).sorted() == [10, 270, 530], "Marks follow the evicted rows")
        #expect(terminal.reads == 2)

        model.setVisible(false)
        let checks = terminal.firstRowReads
        terminal.rows = Array(rows.dropFirst(30)) + (0..<30).map { "⏺ later step \($0)" }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(terminal.firstRowReads == checks, "A hidden pane stops checking")
        #expect(terminal.reads == 2)
    }

    @Test func timelineChangeRescans() async {
        let terminal = FakeScrollback(rows: sampleRows())
        let model = ScrollbackMapModel(terminal: terminal, debounce: .milliseconds(10))
        model.setVisible(true)
        model.update(timeline: WorktreeTimeline(history: nil, brief: nil))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(terminal.reads == 0, "A timeline without messages has nothing to locate")
        model.update(timeline: sampleTimeline())
        await waitUntil { model.map != nil }
        #expect(terminal.reads == 1)
    }
}

@Suite("@spec CONTEXT-39: The scrollback map shall be one adjustable accessibility element labeled Scrollback map, whose value names the current message and its position, and whose increment and decrement move to the next newer or older message and scroll the terminal there.")
struct ScrollbackMapAccessibilityTests {
    @Test func adjustingStepsThroughMarks() {
        let map = ScrollbackMap(totalRows: 1000, marks: [
            .init(row: 10, kind: .input, eventID: "a"), .init(row: 20, kind: .peer, eventID: "b"),
            .init(row: 30, kind: .input, eventID: "c"),
        ])
        #expect(ScrollbackMapLayout.adjacentMark(in: map, from: nil, forward: false)?.eventID == "c")
        #expect(ScrollbackMapLayout.adjacentMark(in: map, from: "c", forward: false)?.eventID == "b")
        #expect(ScrollbackMapLayout.adjacentMark(in: map, from: "b", forward: true)?.eventID == "c")
        #expect(ScrollbackMapLayout.adjacentMark(in: map, from: "a", forward: false)?.eventID == "a", "Stops at the oldest")
        #expect(ScrollbackMapLayout.adjacentMark(in: map, from: "c", forward: true)?.eventID == "c", "Stops at the newest")
    }
}
#endif
