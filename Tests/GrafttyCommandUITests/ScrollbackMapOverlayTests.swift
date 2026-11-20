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
@Suite("@spec CONTEXT-35: When the user hovers over, touches, or drags along the scrollback map, the application shall show the nearest mark's message to its left, with human input verbatim and a sparkle next to a generated peer gist. While the user drags, the application shall center the row under the pointer or finger. When the user clicks or taps a mark, the application shall scroll its row to the top of the terminal.")
struct ScrollbackMapScrubTests {
    @Test(arguments: [1.0, 7.0, 13.0])
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
        pointer.onClick?(ScrollbackMapLayout.stripInset.top + layout.y(forRow: 300))
        #expect(scrollback.scrolled.last == 300)
        pointer.mouseExited(with: moved)
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

@Suite("@spec CONTEXT-36: While the Mac scrollback map is visible, the application shall place it in a fixed gutter beside the terminal text spanning the available pane height. While either map is visible, the application shall distinguish human input with orange rounded marks and peer messages and agent responses with cyan square-ended marks at rest and during interaction. While the Mac map is idle, the application shall show these marks and a viewport outline without a card background. While a message is in the preview, the application shall outline its mark.")
struct ScrollbackMapAppearanceTests {
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
