#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
private final class FakeScrollback: TerminalScrollback {
    var rows: [String]
    var reads = 0
    var scrolled: [Int] = []
    var firstRowReads = 0
    init(rows: [String]) { self.rows = rows }
    func firstRowText() -> String? {
        firstRowReads += 1
        return rows.first
    }
    func scrollbackRows(limit: Int) -> ScrollbackRows? {
        reads += 1
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
@Suite("@spec CONTEXT-34: While a worktree's agent pane is shown on Mac or mobile and its scrollback holds located human inputs or peer messages, the application shall float a small translucent scrollback map card at the pane's top-right whose strip spans the whole scrollback, with orange marks for human inputs, accent-blue marks for peer messages and agent responses, marks closer than 3 points in the displayed strip merged into one, and a box showing the current viewport, and shall hide the card while no message is located.")
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

    @Test func cardHasTheDefaultSizeAndHidesWithoutMarks() throws {
        let timeline = sampleTimeline()
        let map = ScrollbackMap.locate(ScrollbackMap.messages(in: timeline), rows: sampleRows())
        #expect(map.marks.map(\.kind) == [.input, .peer, .input])
        let entries = ScrollbackMapEntry.entries(in: timeline)
        let viewport = ScrollbackViewport(offset: 520, length: 60, total: 600)
        let shown = NSHostingView(rootView: ScrollbackMapOverlay(map: map, viewport: viewport, entries: entries, scroll: { _ in }))
        #expect(abs(shown.fittingSize.width - ScrollbackMapLayout.cardSize.width) < 1)
        #expect(abs(shown.fittingSize.height - ScrollbackMapLayout.cardSize.height) < 1)
        let empty = NSHostingView(rootView: ScrollbackMapOverlay(map: ScrollbackMap(totalRows: 600, marks: []), viewport: viewport,
                                                                 entries: entries, scroll: { _ in }))
        #expect(empty.fittingSize == .zero)
        try render(ScrollbackMapOverlay(map: map, viewport: viewport, entries: entries, scroll: { _ in })
            .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing),
            size: CGSize(width: 320, height: 200), named: "scrollback-map-idle")
    }
}

@MainActor
@Suite("@spec CONTEXT-35: When the user hovers over the scrollback map card including its padding on Mac or with a pointer on mobile, or drags along it on Mac or mobile, the application shall show a label to the left of the strip with the nearest mark's message, the human input verbatim or the peer message's gist with a sparkle when generated, and while dragging shall scroll the terminal live to center the row under the pointer or finger; when the user clicks or taps a mark, the application shall scroll that mark's row to the top of the terminal.")
struct ScrollbackMapScrubTests {
    @Test(arguments: [2.0, 17.0, 32.0])
    func clickingTheWholeCardAboveANativeTerminalScrolls(x: Double) async throws {
        _ = NSApplication.shared
        let terminal = MapTerminalFixture()
        let timeline = sampleTimeline()
        let map = ScrollbackMap.locate(ScrollbackMap.messages(in: timeline), rows: sampleRows())
        let viewport = ScrollbackViewport(offset: 520, length: 60, total: 600)
        let scrollback = FakeScrollback(rows: sampleRows())
        let model = ScrollbackMapModel(terminal: scrollback, debounce: .zero)
        model.update(viewport: viewport)
        let content = MapTerminalRepresentable(view: terminal)
            .overlay(alignment: .topTrailing) {
                ScrollbackMapOverlayHost(model: model, timeline: timeline)
                    .padding(10)
            }
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
        let markY = ScrollbackMapLayout(map: map, viewport: viewport).y(forRow: 40)
        let point = pointer.convert(NSPoint(x: x, y: ScrollbackMapLayout.stripInset.top + markY), to: nil)
        let hit = host.hitTest(host.superview?.convert(point, from: nil) ?? point)
        #expect(hit === pointer, "The map must own hit testing above the represented terminal")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(scrollback.scrolled == [40], "The full visible card must receive clicks above the native terminal, including its padding")
        #expect(terminal.clicks == 0, "Map clicks must not reach the terminal")

        pointer.scrollWheel(with: MapWheelEvent(point: point))
        #expect(terminal.wheels == 1, "Wheel scrolling over the map must reach the terminal behind it")

        var hovers: [CGFloat?] = []
        let onHover = pointer.onHover
        pointer.onHover = { hovers.append($0); onHover?($0) }
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        pointer.mouseMoved(with: moved)
        await waitUntil { pointer.bounds.height > ScrollbackMapLayout.cardSize.height }
        let expandedPoint = pointer.convert(NSPoint(x: x, y: 175), to: nil)
        #expect(host.hitTest(host.superview?.convert(expandedPoint, from: nil) ?? expandedPoint) === pointer)
        pointer.mouseExited(with: moved)
        #expect(hovers.count == 2 && hovers[0] != nil && hovers[1] == nil, "Hovering anywhere on the card shows and clears its label")
        await waitUntil { pointer.bounds.height == ScrollbackMapLayout.cardSize.height }
        #expect(host.hitTest(host.superview?.convert(expandedPoint, from: nil) ?? expandedPoint) !== pointer)

        let dragY: CGFloat = 169
        let active = ScrollbackMapLayout(height: ScrollbackMapLayout.stripHeight, totalRows: 600, focusY: dragY, entryY: markY)
        for (type, y) in [(NSEvent.EventType.leftMouseDown, markY), (.leftMouseDragged, dragY), (.leftMouseUp, dragY)] {
            let y = ScrollbackMapLayout.stripInset.top + y
            let location = pointer.convert(NSPoint(x: x, y: y), to: nil)
            let event = try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
        }
        #expect(scrollback.scrolled.last == active.scrubTopRow(atY: dragY, viewportLength: viewport.length))
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

    @Test func labelSitsBesideItsMarkInsideTheCard() {
        let layout = ScrollbackMapLayout(height: 100, totalRows: 1000)
        #expect(layout.labelTop(forMarkAt: 500, labelHeight: 40) == 30)
        #expect(layout.labelTop(forMarkAt: 0, labelHeight: 40) == 0)
        #expect(layout.labelTop(forMarkAt: 1000, labelHeight: 40) == 60)
    }

    @Test func labelNamesTheSpeakerAndKeepsHumanInputVerbatim() throws {
        let timeline = sampleTimeline()
        let entries = ScrollbackMapEntry.entries(in: timeline)
        let input = try #require(entries[timeline.events[0].id])
        let peer = try #require(entries[timeline.events[1].id])
        #expect(input.kind == .input && input.text == "open a pr for the sidebar fix")
        #expect(input.heading.hasPrefix("You · "))
        #expect(peer.kind == .peer && peer.heading.hasPrefix("layout · "))
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
        let layout = ScrollbackMapLayout(map: map, viewport: viewport)
        let gists = PeerMessageGistProvider { _ in "Layout agent found no sidebar regressions" }
        for (name, row) in [("scrollback-map-scrub-input", 40), ("scrollback-map-scrub-peer", 300)] {
            try render(ScrollbackMapOverlay(map: map, viewport: viewport, entries: entries, gists: gists,
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

@Suite("@spec CONTEXT-36: While the pointer is not over the scrollback map and no drag is in progress, the application shall draw the card at 40 percent opacity, and shall draw it fully opaque while it is hovered, dragged, or touched, changing without animation when Reduce Motion is on.")
struct ScrollbackMapFadeTests {
    @Test func idleCardFades() {
        #expect(ScrollbackMapLayout.opacity(isActive: false) == 0.4)
        #expect(ScrollbackMapLayout.opacity(isActive: true) == 1)
    }

    @Test func reduceMotionDropsTheFadeAnimation() {
        #expect(ScrollbackMapLayout.interactionAnimation(reduceMotion: true) == nil)
        #expect(ScrollbackMapLayout.interactionAnimation(reduceMotion: false) != nil)
    }
}

@Suite("@spec CONTEXT-57: While the scrollback map is hovered or dragged on Mac or mobile, the application shall animate the card's downward expansion as space allows, enlarge and spread marks near the pointer or finger, keep the initial row under it as the card opens, and use the magnified geometry for navigation. When the interaction ends, the application shall animate the card back to its idle size. If Reduce Motion is on, then the application shall apply both transitions without animation.")
struct ScrollbackMapMagnificationTests {
    @Test func expansionKeepsTheEntryRowUnderThePointer() {
        let idle = ScrollbackMapLayout(height: 100, totalRows: 1000)
        let active = ScrollbackMapLayout(height: 100, totalRows: 1000, focusY: 50, entryY: 50)
        #expect(active.height > idle.height)
        #expect(active.y(forRow: 500) == idle.y(forRow: 500))
        #expect(active.row(forY: 50) == 500)
        #expect(active.y(forRow: 0) == 0)
        #expect(active.y(forRow: 1000) == active.height)
    }

    @Test func theLensSeparatesNearbyMarksAndMovesWithThePointer() throws {
        let map = ScrollbackMap(totalRows: 1000, marks: [
            .init(row: 50, kind: .input, eventID: "far"),
            .init(row: 480, kind: .peer, eventID: "near"),
            .init(row: 500, kind: .input, eventID: "focus"),
        ])
        let idle = ScrollbackMapLayout(height: 100, totalRows: 1000)
        let active = ScrollbackMapLayout(height: 100, totalRows: 1000, focusY: 50, entryY: 50)
        #expect(idle.clusters(map.marks).count == 2)
        let clusters = active.clusters(map.marks)
        #expect(clusters.map(\.id) == ["far", "near", "focus"])
        let focused = try #require(clusters.last)
        let far = try #require(clusters.first)
        #expect(focused.height > far.height)
        #expect(focused.widthScale > far.widthScale)

        let moved = ScrollbackMapLayout(height: 100, totalRows: 1000, focusY: 5, entryY: 50)
        #expect(moved.clusters(map.marks).first?.height == focused.height)
        #expect(moved.height == active.height)
    }

    @Test(arguments: [0.0, 5.0, 50.0, 95.0, 100.0])
    func drawnRowsStayOrderedAndNavigationUsesTheirPositions(entryY: CGFloat) {
        let active = ScrollbackMapLayout(height: 100, totalRows: 1000, focusY: entryY, entryY: entryY)
        let positions = (0...1000).map(active.y(forRow:))
        #expect(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })
        let y = (positions[700] + positions[701]) / 2
        let map = ScrollbackMap(totalRows: 1000, marks: [.init(row: 700, kind: .input, eventID: "target")])
        #expect(active.tapTarget(in: map, atY: y)?.row == 700)
        #expect(active.scrubTopRow(atY: y, viewportLength: 40) == 680)
        let box = active.viewportBox(ScrollbackViewport(offset: 700, length: 40, total: 1000))
        #expect(abs(box.y - positions[700]) < 1)
        #expect(abs(box.y + box.height - positions[740]) < ScrollbackMapLayout.minimumViewportHeight)
    }

    @Test func growthFitsTheAvailableSpace() {
        let active = ScrollbackMapLayout(height: 100, totalRows: 1000, focusY: 20, entryY: 20, availableGrowth: 12)
        #expect(active.height == 112)
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
@Suite("@spec CONTEXT-49: While the mobile scrollback map is idle, the application shall show a four-point strip flush with the pane's right edge. While the map is visible, the application shall retain a 44-point-wide touch target. While the map is held, dragged, or hovered, the application shall expand it inward. When the interaction ends or is cancelled, the application shall collapse the card.")
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
            #expect(host.fittingSize.height == (active ? 202 : 150))
            try render(overlay.mobileInputCard.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing),
                       size: CGSize(width: 390, height: 240), named: active ? "scrollback-map-mobile-expanded" : "scrollback-map-mobile-collapsed")
        }
    }

    @Test func presentationExpandsInwardAndDownwardFromTheSameOrigin() {
        let idle = ScrollbackMapLayout.mobileCardFrame(isActive: false, height: 150)
        let active = ScrollbackMapLayout.mobileCardFrame(isActive: true, height: 202)
        #expect(idle == CGRect(x: 40, y: 0, width: 4, height: 150))
        #expect(active == CGRect(x: 4, y: 0, width: 34, height: 202))
        #expect(idle.minY == active.minY)
        #expect(ScrollbackMapLayout.stripY(forCardY: 70) == 64)
    }
}

@MainActor
@Suite("@spec CONTEXT-38: While the agent pane is visible, the application shall rebuild its scrollback map after about a second without timeline or scrollback size changes, ignore scroll-only viewport changes, rescan when a check every five seconds finds that the oldest scrollback row changed because output at the scrollback limit evicted rows, and not scan the scrollback while the pane is hidden.")
struct ScrollbackMapRebuildTests {
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
