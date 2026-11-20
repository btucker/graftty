import GrafttyProtocol
import SwiftUI

/// The terminal rows on screen, as the terminal's scrollbar reports them.
public struct ScrollbackViewport: Sendable, Equatable {
    public let offset: Int
    public let length: Int
    public let total: Int
    public init(offset: Int, length: Int, total: Int) {
        self.offset = offset; self.length = length; self.total = total
    }
    public static let empty = ScrollbackViewport(offset: 0, length: 0, total: 0)
}

/// What the scrubber label says about one mark's message.
public struct ScrollbackMapEntry: Sendable, Equatable {
    public let kind: ScrollbackMap.Kind
    public let text: String
    public let timestamp: Double?
    public let sender: String?

    /// The human input and peer messages of a timeline, by event id.
    public static func entries(in timeline: WorktreeTimeline) -> [String: ScrollbackMapEntry] {
        var entries: [String: ScrollbackMapEntry] = [:]
        for event in timeline.events {
            switch event.kind {
            case .user:
                entries[event.id] = ScrollbackMapEntry(kind: .input, text: event.completed, timestamp: event.timestamp, sender: nil)
            case .agentMessage, .agentResponse:
                entries[event.id] = ScrollbackMapEntry(kind: .peer, text: event.completed, timestamp: event.timestamp,
                                                       sender: event.sourceWorktreeName ?? (event.kind == .agentResponse ? event.title : nil))
            case .creation, .checkpoint, .system: break
            }
        }
        return entries
    }

    /// You for human input, else the sending worktree, then the time.
    var heading: String {
        let who = kind == .input ? "You" : (sender ?? "Peer agent")
        guard let timestamp else { return who }
        let date = Date(timeIntervalSinceReferenceDate: timestamp)
        return "\(who) · \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// The scrollback map's geometry: a strip `height` points tall covering `totalRows`
/// rows, where marks closer than `mergeDistance` points draw as one.
public struct ScrollbackMapLayout: Equatable {
    public static let cardSize = CGSize(width: 34, height: 150)
    static let mobileTouchWidth: CGFloat = 44
    static let mobileCollapsedWidth: CGFloat = 8
    static let macGutterWidth: CGFloat = 14
    public static let stripInset = EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7)
    public static let mergeDistance: CGFloat = 3
    public static let markHeight: CGFloat = 3
    public static let minimumViewportHeight: CGFloat = 4
    /// How close a click must land to a mark to jump to it rather than scrub.
    public static let tapTolerance: CGFloat = 6

    public static var stripHeight: CGFloat { cardSize.height - stripInset.top - stripInset.bottom }

    /// The mobile drawing expands inside a fixed touch width at the pane's right edge.
    static func mobileCardFrame(expansion: CGFloat, height: CGFloat) -> CGRect {
        let width = mobileCollapsedWidth + (cardSize.width - mobileCollapsedWidth) * expansion
        let trailing: CGFloat = 6 * expansion
        return CGRect(x: mobileTouchWidth - width - trailing, y: 0, width: width, height: height)
    }

    /// Input covers the whole card; drawing coordinates begin inside its padding.
    public static func stripY(forCardY y: CGFloat, height: CGFloat = stripHeight) -> CGFloat {
        min(height, max(0, y - stripInset.top))
    }

    public struct Cluster: Equatable, Identifiable {
        public var id: String { marks[0].eventID }
        public let marks: [ScrollbackMap.Mark]
        /// The top of the drawn mark, kept inside the strip.
        public let y: CGFloat
        let height: CGFloat
        /// Orange wins over blue so a merged human input never disappears.
        public var kind: ScrollbackMap.Kind { marks.contains { $0.kind == .input } ? .input : .peer }
    }

    public let height: CGFloat
    public let totalRows: Int
    var cardHeight: CGFloat { height + Self.stripInset.top + Self.stripInset.bottom }

    public init(height: CGFloat = ScrollbackMapLayout.stripHeight, totalRows: Int) {
        self.height = height
        self.totalRows = max(1, totalRows)
    }

    /// Rows can grow past the last scan, so the live viewport total wins when larger.
    public init(height: CGFloat = ScrollbackMapLayout.stripHeight, map: ScrollbackMap, viewport: ScrollbackViewport) {
        self.init(height: height, totalRows: max(map.totalRows, viewport.total))
    }

    public func y(forRow row: Int) -> CGFloat {
        CGFloat(min(max(row, 0), totalRows)) / CGFloat(totalRows) * height
    }

    public func row(forY y: CGFloat) -> Int {
        guard height > 0 else { return 0 }
        var lower = 0
        var upper = totalRows
        while upper - lower > 1 {
            let middle = lower + (upper - lower) / 2
            if self.y(forRow: middle) <= y { lower = middle } else { upper = middle }
        }
        return lower
    }

    public func clusters(_ marks: [ScrollbackMap.Mark]) -> [Cluster] {
        var groups: [[(mark: ScrollbackMap.Mark, y: CGFloat)]] = []
        for mark in marks.sorted(by: { $0.row < $1.row }) {
            let y = y(forRow: mark.row)
            // Group by the first center before resolving rendered overlaps below.
            if let first = groups.last?.first, y - first.y < Self.mergeDistance {
                groups[groups.count - 1].append((mark, y))
            } else {
                groups.append([(mark, y)])
            }
        }
        let initialClusters = groups.map { group in
            let mean = group.map(\.y).reduce(0, +) / CGFloat(group.count)
            return cluster(group.map(\.mark), centeredAt: mean)
        }
        var clusters: [Cluster] = []
        for var next in initialClusters {
            while let previous = clusters.last, previous.y + previous.height > next.y {
                clusters.removeLast()
                let count = previous.marks.count + next.marks.count
                let center = ((previous.y + previous.height / 2) * CGFloat(previous.marks.count)
                    + (next.y + next.height / 2) * CGFloat(next.marks.count)) / CGFloat(count)
                next = cluster(previous.marks + next.marks, centeredAt: center)
            }
            clusters.append(next)
        }
        return clusters
    }

    private func cluster(_ marks: [ScrollbackMap.Mark], centeredAt center: CGFloat) -> Cluster {
        let size = min(height, Self.markHeight)
        return Cluster(marks: marks, y: min(max(0, center - size / 2), height - size), height: size)
    }

    /// The viewport box's top and height, at least `minimumViewportHeight` and inside the strip.
    public func viewportBox(_ viewport: ScrollbackViewport) -> (y: CGFloat, height: CGFloat) {
        let offset = min(totalRows, max(0, viewport.offset))
        let end = offset + min(totalRows - offset, max(0, viewport.length))
        let top = y(forRow: offset)
        let boxHeight = min(height, max(Self.minimumViewportHeight, y(forRow: end) - top))
        return (min(top, height - boxHeight), boxHeight)
    }

    public func nearestMark(in map: ScrollbackMap, toY y: CGFloat) -> ScrollbackMap.Mark? {
        map.marks.min { abs(self.y(forRow: $0.row) - y) < abs(self.y(forRow: $1.row) - y) }
    }

    /// The mark a click at `y` lands on, if any.
    public func tapTarget(in map: ScrollbackMap, atY y: CGFloat) -> ScrollbackMap.Mark? {
        nearestMark(in: map, toY: y).flatMap { abs(self.y(forRow: $0.row) - y) <= Self.tapTolerance ? $0 : nil }
    }

    /// The viewport top that centers the row under the pointer or finger.
    public func scrubTopRow(atY y: CGFloat, viewportLength: Int) -> Int {
        max(0, row(forY: y) - max(0, viewportLength) / 2)
    }

    /// The label's top, beside the mark it describes and inside the card's height.
    public func labelTop(forMarkAt row: Int, labelHeight: CGFloat) -> CGFloat {
        min(max(0, y(forRow: row) - labelHeight / 2), max(0, height - labelHeight))
    }

    /// The next newer (`forward`) or older mark from `current`; the newest when nothing is current.
    public static func adjacentMark(in map: ScrollbackMap, from current: String?, forward: Bool) -> ScrollbackMap.Mark? {
        guard let index = current.flatMap({ id in map.marks.firstIndex { $0.eventID == id } }) else {
            return map.marks.last
        }
        let next = index + (forward ? 1 : -1)
        return map.marks.indices.contains(next) ? map.marks[next] : map.marks[index]
    }

    public static func interactionAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    /// On mobile the card's top sits this far below the top of the pane's floating
    /// top-right controls (Worktree context and resource buttons), so the two never overlap.
    public static func topInset(belowControlsAt controlsTop: CGFloat, controlsHeight: CGFloat, spacing: CGFloat = 8) -> CGFloat {
        controlsTop + max(0, controlsHeight) + spacing
    }
}

/// Opaque, appearance-aware colors keep the marks legible against terminal output.
struct ScrollbackMapPalette {
    let backing: Color
    let input: Color
    let peer: Color
    let viewport: Color

    init(scheme: ColorScheme) {
        let dark = scheme == .dark
        backing = Color(white: dark ? 0.12 : 0.96)
        input = dark ? Color(red: 1, green: 0.82, blue: 0.57) : Color(red: 0.53, green: 0.26, blue: 0)
        peer = dark ? Color(red: 0.66, green: 0.84, blue: 1) : Color(red: 0.07, green: 0.36, blue: 0.59)
        viewport = dark ? .white : .black
    }

    func mark(_ kind: ScrollbackMap.Kind) -> Color { kind == .input ? input : peer }
}

/// Animates only the mobile card's horizontal expansion.
private struct ScrollbackMapExpansion<Content: View>: View, Animatable {
    var amount: CGFloat
    var content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    var body: some View {
        content(amount).transaction { $0.animation = nil }
    }
}

/// @spec CONTEXT-34
/// While an agent pane contains located messages, the application shall show a map of the entire scrollback with marks for human inputs, peer messages, and agent responses, merge marks closer than three points or whose bars overlap, and outline the visible rows. If no message is located, then the application shall hide the map.
public struct ScrollbackMapOverlay: View {
    let map: ScrollbackMap
    let viewport: ScrollbackViewport
    let entries: [String: ScrollbackMapEntry]
    let gists: PeerMessageGistProvider
    let scroll: (Int) -> Void
    private let availableHeight: CGFloat
    @State private var hover: CGFloat?
    @State private var scrub: CGFloat?
    // GestureState clears on cancellation, so an interrupted touch cannot leave the map expanded.
    @GestureState private var touch: CGFloat?
    @State private var accessibilityMark: String?
    @State private var gist: PeerMessageGist?
    @State private var labelHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    public init(map: ScrollbackMap, viewport: ScrollbackViewport, entries: [String: ScrollbackMapEntry],
                gists: PeerMessageGistProvider = .shared, availableHeight: CGFloat = ScrollbackMapLayout.cardSize.height,
                scroll: @escaping (Int) -> Void) {
        self.init(map: map, viewport: viewport, entries: entries, gists: gists, availableHeight: availableHeight,
                  focusY: nil, scroll: scroll)
    }

    /// `focusY` starts the overlay mid-scrub, for rendering tests.
    init(map: ScrollbackMap, viewport: ScrollbackViewport, entries: [String: ScrollbackMapEntry],
         gists: PeerMessageGistProvider, availableHeight: CGFloat = ScrollbackMapLayout.cardSize.height,
         focusY: CGFloat?, scroll: @escaping (Int) -> Void) {
        self.map = map; self.viewport = viewport; self.entries = entries; self.gists = gists; self.scroll = scroll
        self.availableHeight = availableHeight
        _scrub = State(initialValue: focusY.map { $0 + ScrollbackMapLayout.stripInset.top })
    }

    private var interactionY: CGFloat? { touch ?? scrub ?? hover }
    private var isActive: Bool { interactionY != nil }

    private func focusedMark(in layout: ScrollbackMapLayout) -> ScrollbackMap.Mark? {
        guard let interactionY else { return nil }
        return layout.nearestMark(in: map, toY: ScrollbackMapLayout.stripY(forCardY: interactionY, height: layout.height))
    }

    private func layout(cardHeight: CGFloat) -> ScrollbackMapLayout {
        let inset = ScrollbackMapLayout.stripInset
        return ScrollbackMapLayout(height: max(0, cardHeight - inset.top - inset.bottom), map: map, viewport: viewport)
    }

    private var mobileLayout: ScrollbackMapLayout {
        layout(cardHeight: min(availableHeight, ScrollbackMapLayout.cardSize.height))
    }

    public var body: some View {
        #if os(macOS)
        let layout = layout(cardHeight: availableHeight)
        #else
        let layout = mobileLayout
        #endif
        if !map.marks.isEmpty, layout.height >= ScrollbackMapLayout.markHeight {
            let mark = focusedMark(in: layout)
            inputCard(layout: layout)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Scrollback map")
                .accessibilityValue(accessibilityValue)
                .accessibilityHint("Swipe up or down to move between messages in the terminal")
                .accessibilityAdjustableAction { direction in
                    let forward = direction == .increment
                    guard let mark = ScrollbackMapLayout.adjacentMark(in: map, from: accessibilityMark, forward: forward) else { return }
                    accessibilityMark = mark.eventID
                    scroll(mark.row)
                }
                .accessibilityIdentifier("terminal.scrollbackMap")
                .task(id: mark?.eventID) { await loadGist(for: mark) }
        }
    }

    private func inputCard(layout: ScrollbackMapLayout) -> some View {
        #if os(macOS)
        let content = strip(layout: layout, width: 9, muted: !isActive)
            .frame(width: ScrollbackMapLayout.macGutterWidth)
        return ScrollbackMapPointerInput(content: AnyView(content), terminalOnLeft: layoutDirection == .leftToRight,
            onHover: { hover = $0 },
            onScrub: { scrub = $0 },
            onDrag: { drag(at: $0, layout: layout) },
            onClick: { click(at: $0, layout: layout) }
        )
        .frame(width: ScrollbackMapLayout.macGutterWidth, height: layout.cardHeight)
        .overlay(alignment: .topLeading) { label(layout: layout) }
        #else
        return mobileInputCard(layout: layout)
        #endif
    }

    /// Kept available on Mac for rendering and layout regression tests of the mobile presentation.
    var mobileInputCard: some View { mobileInputCard(layout: mobileLayout) }

    private func mobileInputCard(layout: ScrollbackMapLayout) -> some View {
        ScrollbackMapExpansion(amount: isActive ? 1 : 0) { expansion in
            let frame = ScrollbackMapLayout.mobileCardFrame(expansion: expansion, height: layout.cardHeight)
            let inset = ScrollbackMapLayout.stripInset.leading * expansion
            let shape = RoundedRectangle(cornerRadius: 3 + 6 * expansion)
            return strip(layout: layout, width: frame.width - inset * 2, muted: false)
                .frame(width: frame.width, height: frame.height)
                .background(ScrollbackMapPalette(scheme: colorScheme).backing, in: shape)
                .overlay(alignment: .topLeading) { label(layout: layout, fixedVertically: true) }
                .offset(x: frame.minX)
                .frame(width: ScrollbackMapLayout.mobileTouchWidth, height: frame.height, alignment: .topLeading)
        }
        .animation(ScrollbackMapLayout.interactionAnimation(reduceMotion: reduceMotion), value: isActive)
        .contentShape(Rectangle())
        .gesture(scrubGesture(layout: layout))
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover = point.y
            case .ended: hover = nil
            }
        }
    }

    private func strip(layout: ScrollbackMapLayout, width: CGFloat, muted: Bool) -> some View {
        let palette = ScrollbackMapPalette(scheme: colorScheme)
        let box = layout.viewportBox(viewport)
        return ZStack(alignment: .top) {
            if !muted {
                Rectangle().fill(palette.viewport.opacity(0.18)).frame(width: 1)
            }
            ForEach(layout.clusters(map.marks)) { cluster in
                let height = muted ? min(2, cluster.height) : cluster.height
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(muted ? Color.primary.opacity(cluster.kind == .input ? 0.46 : 0.34) : palette.mark(cluster.kind))
                    .frame(width: width * (cluster.kind == .input ? 0.85 : 0.55), height: height)
                    .offset(y: cluster.y + (cluster.height - height) / 2)
            }
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(palette.viewport.opacity(muted ? 0.65 : 0.9), lineWidth: 1)
                .frame(height: box.height)
                .offset(y: box.y)
        }
        .frame(width: width, height: layout.height, alignment: .top)
        .padding(.vertical, ScrollbackMapLayout.stripInset.top)
    }

    private func scrubGesture(layout: ScrollbackMapLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .simultaneously(with: SpatialTapGesture())
            .updating($touch) { gestures, touch, _ in
                touch = gestures.first?.location.y
            }
            .onChanged { gestures in
                if let value = gestures.first, hasMoved(value) { drag(at: value.location.y, layout: layout) }
            }
            .onEnded { gestures in
                if let value = gestures.first, hasMoved(value) {
                    drag(at: value.location.y, layout: layout)
                } else if let y = gestures.second?.location.y {
                    click(at: y, layout: layout)
                }
            }
    }

    private func hasMoved(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.height) >= 2 || abs(value.translation.width) >= 2
    }

    private func drag(at cardY: CGFloat, layout: ScrollbackMapLayout) {
        let y = ScrollbackMapLayout.stripY(forCardY: cardY, height: layout.height)
        scroll(layout.scrubTopRow(atY: y, viewportLength: viewport.length))
    }

    private func click(at cardY: CGFloat, layout: ScrollbackMapLayout) {
        let y = ScrollbackMapLayout.stripY(forCardY: cardY, height: layout.height)
        scroll(layout.tapTarget(in: map, atY: y)?.row
            ?? layout.scrubTopRow(atY: y, viewportLength: viewport.length))
    }

    @ViewBuilder
    private func label(layout: ScrollbackMapLayout, fixedVertically: Bool = false) -> some View {
        if let mark = focusedMark(in: layout), let entry = entries[mark.eventID] {
            ScrollbackMapLabel(entry: entry, gist: entry.kind == .peer ? (gist ?? .immediate(entry.text)) : nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { labelHeight = $0 }
                .offset(x: -(ScrollbackMapLabel.width + 6),
                        y: ScrollbackMapLayout.stripInset.top + (fixedVertically ? 0 :
                            layout.labelTop(forMarkAt: mark.row, labelHeight: labelHeight)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var accessibilityValue: String {
        let mark = accessibilityMark.flatMap { id in map.marks.first { $0.eventID == id } }
            ?? map.nearestMark(toRow: viewport.offset)
        guard let mark, let index = map.marks.firstIndex(of: mark), let entry = entries[mark.eventID] else {
            return "\(map.marks.count) messages"
        }
        let text = entry.kind == .peer ? PeerMessageGist.immediate(entry.text).text : entry.text
        return "\(index + 1) of \(map.marks.count), \(entry.heading): \(text)"
    }

    private func loadGist(for mark: ScrollbackMap.Mark?) async {
        gist = nil
        if let loaded = await Self.gist(for: mark.flatMap { entries[$0.eventID] }, from: gists) { gist = loaded }
    }

    /// A peer entry's gist; nil for human input, or once the label's task was
    /// cancelled because focus moved to another mark while it generated.
    static func gist(for entry: ScrollbackMapEntry?, from gists: PeerMessageGistProvider) async -> PeerMessageGist? {
        guard let entry, entry.kind == .peer else { return nil }
        let gist = await gists.gist(for: entry.text)
        return Task.isCancelled ? nil : gist
    }
}

/// The scrubber's label: the human input verbatim, or the peer gist with its sparkle.
struct ScrollbackMapLabel: View {
    static let width: CGFloat = 200
    let entry: ScrollbackMapEntry
    /// Nil for human input, which is never summarized.
    let gist: PeerMessageGist?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.heading)
                .font(.caption2.weight(.medium))
                .foregroundStyle(entry.kind == .input ? Color.orange : Color.accentColor)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if gist?.isGenerated == true {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(.secondary)
                }
                Text(gist?.text ?? entry.text)
                    .font(.caption)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(width: Self.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

/// @spec CONTEXT-38
/// One terminal pane's scrollback map: rebuilt from the timeline and the pane's
/// scrollback after a quiet second, only while the pane is visible. At the scrollback
/// limit new output evicts old rows without changing the total, so a cheap periodic
/// check of the oldest row triggers a rescan.
@MainActor
public final class ScrollbackMapModel: ObservableObject {
    @Published public private(set) var map: ScrollbackMap?
    @Published public private(set) var viewport = ScrollbackViewport.empty
    public private(set) var entries: [String: ScrollbackMapEntry] = [:]
    private weak var terminal: (any TerminalScrollback)?
    private var messages: [ScrollbackMap.Message] = []
    private var isVisible = false
    private var pending: Task<Void, Never>?
    private var evictionCheck: Task<Void, Never>?
    /// The oldest row when the current map was scanned.
    private var scannedFirstRow: String?
    private let debounce: Duration
    private let evictionCheckInterval: Duration

    public init(terminal: any TerminalScrollback, debounce: Duration = .seconds(1),
                evictionCheckInterval: Duration = .seconds(5)) {
        self.terminal = terminal
        self.debounce = debounce
        self.evictionCheckInterval = evictionCheckInterval
    }

    deinit {
        pending?.cancel()
        evictionCheck?.cancel()
    }

    public func update(timeline: WorktreeTimeline) {
        let messages = ScrollbackMap.messages(in: timeline)
        guard messages != self.messages else { return }
        self.messages = messages
        entries = ScrollbackMapEntry.entries(in: timeline)
        if messages.isEmpty { map = nil; stopEvictionCheck() }
        scheduleRebuild()
    }

    /// Scrollbar reports arrive for every scroll; only a size change rescans.
    public func update(viewport: ScrollbackViewport) {
        guard viewport != self.viewport else { return }
        let resized = viewport.total != self.viewport.total
        self.viewport = viewport
        if resized { scheduleRebuild() }
    }

    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { scheduleRebuild() } else { pending?.cancel(); pending = nil; stopEvictionCheck() }
    }

    public func scroll(toRow row: Int) {
        terminal?.scroll(toRow: row)
    }

    /// Each change restarts the wait, so streaming output scans once it settles.
    private func scheduleRebuild() {
        pending?.cancel()
        pending = nil
        guard isVisible, !messages.isEmpty, terminal != nil else { return }
        let debounce = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self, let terminal = self.terminal else { return }
            let firstRow = terminal.firstRowText()
            let map = await terminal.scrollbackMap(for: self.messages)
            guard !Task.isCancelled else { return }
            self.map = map
            self.scannedFirstRow = firstRow
            self.pending = nil
            if map == nil { self.stopEvictionCheck() } else { self.startEvictionCheck() }
        }
    }

    /// Reads one row per interval, never the full scan, and rescans when it moved.
    private func startEvictionCheck() {
        guard evictionCheck == nil else { return }
        let interval = evictionCheckInterval
        evictionCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                // A pending scan records the row itself; hiding the pane cancels this loop.
                guard self.pending == nil, let terminal = self.terminal else { continue }
                if terminal.firstRowText() != self.scannedFirstRow { self.scheduleRebuild() }
            }
        }
    }

    private func stopEvictionCheck() {
        evictionCheck?.cancel()
        evictionCheck = nil
    }
}

/// Keeps a pane's map current and shows the overlay once it has marks.
public struct ScrollbackMapOverlayHost: View {
    @ObservedObject var model: ScrollbackMapModel
    let timeline: WorktreeTimeline
    let isVisible: Bool
    var gists: PeerMessageGistProvider = .shared
    /// Derived once per parent update, not on every viewport report that redraws this body.
    private let messages: [ScrollbackMap.Message]

    public init(model: ScrollbackMapModel, timeline: WorktreeTimeline, isVisible: Bool = true,
                gists: PeerMessageGistProvider = .shared) {
        self.model = model; self.timeline = timeline; self.isVisible = isVisible; self.gists = gists
        self.messages = ScrollbackMap.messages(in: timeline)
    }

    public var body: some View {
        GeometryReader { geometry in
            if let map = model.map {
                ScrollbackMapOverlay(map: map, viewport: model.viewport, entries: model.entries, gists: gists,
                                     availableHeight: geometry.size.height,
                                     scroll: { [model] in model.scroll(toRow: $0) })
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onAppear {
            model.update(timeline: timeline)
            model.setVisible(isVisible)
        }
        .onDisappear { model.setVisible(false) }
        .onChange(of: messages) { _, _ in model.update(timeline: timeline) }
        .onChange(of: isVisible) { _, visible in model.setVisible(visible) }
    }
}

#if os(macOS)
public extension View {
    /// Keep the gutter outside the terminal grid even before the first scrollback scan finishes.
    @MainActor
    func macScrollbackMapGutter(timeline: WorktreeTimeline?, model: ScrollbackMapModel,
                                background: Color, topInset: CGFloat) -> some View {
        padding(.trailing, timeline == nil ? 0 : ScrollbackMapLayout.macGutterWidth)
            .background(alignment: .trailing) {
                if timeline != nil {
                    background.frame(width: ScrollbackMapLayout.macGutterWidth).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let timeline {
                    ScrollbackMapOverlayHost(model: model, timeline: timeline)
                        .padding(.vertical, ScrollbackMapLayout.stripInset.top)
                        .padding(.top, topInset)
                        .frame(width: ScrollbackMapLayout.macGutterWidth)
                }
            }
    }
}
#endif
