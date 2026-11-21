import GrafttyProtocol
import OSLog
import SwiftUI

private let scrollbackLog = Logger(subsystem: "com.graftty.app", category: "scrollback-map")

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
    /// Presentation provenance; the stored map classifies local responses as peers too.
    let isIncomingPeer: Bool

    init(kind: ScrollbackMap.Kind, text: String, timestamp: Double?, sender: String?, isIncomingPeer: Bool = false) {
        self.kind = kind; self.text = text; self.timestamp = timestamp; self.sender = sender
        self.isIncomingPeer = isIncomingPeer
    }

    /// The human input and peer messages of a timeline, by event id.
    public static func entries(in timeline: WorktreeTimeline) -> [String: ScrollbackMapEntry] {
        var entries: [String: ScrollbackMapEntry] = [:]
        for event in timeline.events {
            switch event.kind {
            case .user:
                entries[event.id] = ScrollbackMapEntry(kind: .input, text: event.completed, timestamp: event.timestamp, sender: nil)
            case .agentMessage, .agentResponse:
                entries[event.id] = ScrollbackMapEntry(kind: .peer, text: event.completed, timestamp: event.timestamp,
                                                       sender: event.sourceWorktreeName ?? (event.kind == .agentResponse ? event.title : nil),
                                                       isIncomingPeer: event.kind == .agentMessage)
            case .creation, .checkpoint, .system: break
            }
        }
        return entries
    }

    var speaker: String { kind == .input ? "You" : (sender ?? "Peer agent") }

    func relativeAge(at now: Date) -> String? {
        guard let timestamp else { return nil }
        let elapsed = now.timeIntervalSinceReferenceDate - timestamp
        guard elapsed.isFinite, elapsed < Double(Int.max) else { return nil }
        switch elapsed {
        case ..<60: return "now"
        case ..<3600: return "\(Int(elapsed / 60))m"
        case ..<86400: return "\(Int(elapsed / 3600))h"
        default: return "\(Int(elapsed / 86400))d"
        }
    }

    func heading(relativeTo now: Date = .now) -> String {
        relativeAge(at: now).map { "\(speaker) · \($0)" } ?? speaker
    }
}

/// The scrollback map's geometry: a strip `height` points tall covering `totalRows`
/// rows, where marks closer than `mergeDistance` points draw as one.
public struct ScrollbackMapLayout: Equatable {
    public static let cardSize = CGSize(width: 34, height: 150)
    static let mobileTouchWidth: CGFloat = 44
    static let mobileCollapsedWidth: CGFloat = 8
    static let macGutterWidth: CGFloat = 14
    static let macLensWidth: CGFloat = 26
    private static let focusRadius: CGFloat = 48
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
        var centerY: CGFloat { y + height / 2 }
        /// Human input wins so a merged input never disappears.
        public var kind: ScrollbackMap.Kind { marks.contains { $0.kind == .input } ? .input : .peer }
    }

    struct PresentedMark: Identifiable {
        let cluster: Cluster
        let frame: CGRect
        let kind: ScrollbackMap.Kind
        let isPreviewed: Bool
        var id: String { cluster.id }
        var cornerRadius: CGFloat { kind == .input ? frame.height / 2 : 0 }
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

    /// Grow bars inward and stop vertical growth at the midpoint to either neighbor.
    /// The clusters and row mapping stay independent of pointer position.
    func presentedMarks(_ marks: [ScrollbackMap.Mark], width: CGFloat, maximumWidth: CGFloat,
                        focusY: CGFloat?, previewedMark: ScrollbackMap.Mark? = nil,
                        muted: Bool = false) -> [PresentedMark] {
        let clusters = clusters(marks)
        return clusters.indices.map { index in
            let cluster = clusters[index]
            let selectedMark = previewedMark.flatMap { cluster.marks.contains($0) ? $0 : nil }
            let previewed = selectedMark != nil
            let center = cluster.centerY
            let influence = focusY.map { max(0, 1 - abs($0 - center) / Self.focusRadius) } ?? 0
            let strength = previewed ? 1 : influence * influence
            let top = index > 0 ? (clusters[index - 1].centerY + center) / 2 : 0
            let bottom = index + 1 < clusters.count ? (center + clusters[index + 1].centerY) / 2 : height
            let baseHeight = muted ? min(2, cluster.height) : cluster.height
            let halfHeight = min(baseHeight * (1 + 1.8 * strength) / 2, center - top, bottom - center)
            let kind = selectedMark?.kind ?? cluster.kind
            let baseWidth = width * (kind == .input ? 0.85 : 0.55)
            let peakWidth = maximumWidth * (kind == .input ? 1 : 0.7)
            let barWidth = baseWidth + (peakWidth - baseWidth) * strength
            let x = min(-barWidth / 2, width / 2 - barWidth)
            let frame = CGRect(x: x, y: center - halfHeight, width: barWidth, height: halfHeight * 2)
            return PresentedMark(cluster: cluster, frame: frame, kind: kind, isPreviewed: previewed)
        }
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

    /// Preview and jump using the kind the cluster actually displays.
    func previewTarget(in map: ScrollbackMap, atY y: CGFloat, isIncoming: (String) -> Bool = { _ in false })
        -> ScrollbackMap.Mark? {
        target(in: map, atY: y, tolerance: .infinity, isIncoming: isIncoming)
    }

    public func tapTarget(in map: ScrollbackMap, atY y: CGFloat, isIncoming: (String) -> Bool = { _ in false })
        -> ScrollbackMap.Mark? {
        target(in: map, atY: y, tolerance: Self.tapTolerance, isIncoming: isIncoming)
    }

    private func target(in map: ScrollbackMap, atY y: CGFloat, tolerance: CGFloat, isIncoming: (String) -> Bool)
        -> ScrollbackMap.Mark? {
        guard let cluster = clusters(map.marks).min(by: { abs($0.centerY - y) < abs($1.centerY - y) }),
              abs(cluster.centerY - y) <= tolerance else { return nil }
        let incoming = cluster.kind == .peer && cluster.marks.contains { isIncoming($0.eventID) }
        return cluster.marks.filter {
            $0.kind == cluster.kind && (!incoming || isIncoming($0.eventID))
        }.min { abs(self.y(forRow: $0.row) - y) < abs(self.y(forRow: $1.row) - y) }
    }

    /// The viewport top that centers the row under the pointer or finger.
    public func scrubTopRow(atY y: CGFloat, viewportLength: Int) -> Int {
        max(0, row(forY: y) - max(0, viewportLength) / 2)
    }

    /// Several inputs can share the orange bar of a merged cluster.
    func previewAnchors(in map: ScrollbackMap, focused: ScrollbackMap.Mark?) -> [(mark: ScrollbackMap.Mark, y: CGFloat)] {
        clusters(map.marks).flatMap { cluster in
            cluster.marks.compactMap { mark in
                guard mark.kind == .input || mark == focused else { return nil }
                return (mark, cluster.centerY)
            }
        }
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
    let incomingPeer: Color
    let viewport: Color

    init(scheme: ColorScheme) {
        let dark = scheme == .dark
        backing = Color(white: dark ? 0.12 : 0.96)
        input = dark ? Color(red: 1, green: 0.67, blue: 0.31) : Color(red: 0.52, green: 0.25, blue: 0)
        peer = dark ? Color(red: 0.38, green: 0.89, blue: 0.99) : Color(red: 0.02, green: 0.34, blue: 0.42)
        incomingPeer = PeerMessageStyle.color(in: scheme)
        viewport = dark ? .white : .black
    }

    func mark(_ kind: ScrollbackMap.Kind, incoming: Bool = false, muted: Bool = false) -> Color {
        (kind == .input ? input : (incoming ? incomingPeer : peer)).opacity(muted ? 0.82 : 1)
    }
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
    private let availableWidth: CGFloat
    @State private var hover: CGFloat?
    #if os(macOS)
    @State private var previewArea: CGRect?
    #else
    @State private var previewReleasedAt: Date?
    #endif
    @State private var scrub: CGFloat?
    // GestureState clears on cancellation, so an interrupted touch cannot leave the map expanded.
    @GestureState private var touch: CGFloat?
    @State private var accessibilityMark: String?
    @State private var responseGist: (entry: ScrollbackMapEntry, gist: PeerMessageGist)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    public init(map: ScrollbackMap, viewport: ScrollbackViewport, entries: [String: ScrollbackMapEntry],
                gists: PeerMessageGistProvider = .shared, availableHeight: CGFloat = ScrollbackMapLayout.cardSize.height,
                availableWidth: CGFloat = 360,
                scroll: @escaping (Int) -> Void) {
        self.init(map: map, viewport: viewport, entries: entries, gists: gists, availableHeight: availableHeight,
                  availableWidth: availableWidth, focusY: nil, scroll: scroll)
    }

    /// `focusY` starts the overlay mid-scrub, for rendering tests.
    init(map: ScrollbackMap, viewport: ScrollbackViewport, entries: [String: ScrollbackMapEntry],
         gists: PeerMessageGistProvider, availableHeight: CGFloat = ScrollbackMapLayout.cardSize.height,
         availableWidth: CGFloat = 360, focusY: CGFloat?, scroll: @escaping (Int) -> Void) {
        self.map = map; self.viewport = viewport; self.entries = entries; self.gists = gists; self.scroll = scroll
        self.availableHeight = availableHeight
        self.availableWidth = availableWidth
        _scrub = State(initialValue: focusY.map { $0 + ScrollbackMapLayout.stripInset.top })
    }

    private var interactionY: CGFloat? { touch ?? scrub ?? hover }
    private var isActive: Bool { interactionY != nil }

    private func focusedMark(in layout: ScrollbackMapLayout) -> ScrollbackMap.Mark? {
        guard let interactionY else { return nil }
        let y = ScrollbackMapLayout.stripY(forCardY: interactionY, height: layout.height)
        return layout.previewTarget(in: map, atY: y) { entries[$0]?.isIncomingPeer == true }
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
            let response = mark.flatMap { entries[$0.eventID] }.flatMap { $0.kind == .peer ? $0 : nil }
            inputCard(layout: layout, previewedMark: mark)
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
                .overlay(alignment: .topTrailing) {
                    if let interactionY {
                        previews(layout: layout, focused: mark, focusY: interactionY)
                    }
                }
                #if os(macOS)
                .onPreferenceChange(ScrollbackPreviewArea.self) { previewArea = $0 }
                #endif
                .task(id: response) {
                    responseGist = nil
                    if let response, let gist = await Self.gist(for: response, from: gists) {
                        responseGist = (response, gist)
                    }
                }
        }
    }

    @ViewBuilder
    private func previews(layout: ScrollbackMapLayout, focused: ScrollbackMap.Mark?, focusY: CGFloat) -> some View {
        #if os(macOS)
        let railCenter = ScrollbackMapLayout.macGutterWidth / 2
        let gap = railCenter + ScrollbackMapLayout.macLensWidth + 5
        let preferredWidth = ScrollbackMapLabel.defaultWidth
        let maximumShift: CGFloat = 24
        let maximumGap: CGFloat = 28
        let maximumSpan: CGFloat = 96
        #else
        let frame = ScrollbackMapLayout.mobileCardFrame(expansion: 1, height: layout.cardHeight)
        let railCenter = ScrollbackMapLayout.mobileTouchWidth - frame.midX
        let gap = ScrollbackMapLayout.mobileTouchWidth + 4
        let preferredWidth: CGFloat = 154
        let maximumShift: CGFloat = 16
        let maximumGap: CGFloat = 36
        let maximumSpan: CGFloat = 64
        #endif
        let cardWidth = min(preferredWidth, availableWidth - gap)
        if cardWidth > 24 {
            let previews = layout.previewAnchors(in: map, focused: focused).compactMap { mark, y in
                entries[mark.eventID].map {
                    ScrollbackMapPreview(id: mark.eventID, entry: $0, y: y + ScrollbackMapLayout.stripInset.top)
                }
            }
            let groups = ScrollbackMapPreviewGroup.group(previews, maximumGap: maximumGap, maximumSpan: maximumSpan)
            ScrollbackMapPreviews(groups: groups, height: availableHeight, cardWidth: cardWidth,
                                  gap: gap, railCenter: railCenter, focusY: focusY, maximumShift: maximumShift,
                                  focusedID: focused?.eventID, responseGist: responseGist) { firstID in
                if let row = map.row(for: firstID) { scroll(row) }
                #if !os(macOS)
                scrub = nil
                previewReleasedAt = nil
                #endif
            }
        }
    }

    private func inputCard(layout: ScrollbackMapLayout, previewedMark: ScrollbackMap.Mark?) -> some View {
        #if os(macOS)
        let content = strip(layout: layout, width: 9, maximumMarkWidth: ScrollbackMapLayout.macLensWidth,
                            muted: !isActive, growsInward: true, previewedMark: previewedMark)
            .frame(width: ScrollbackMapLayout.macGutterWidth)
        return ScrollbackMapPointerInput(content: AnyView(content), terminalOnLeft: layoutDirection == .leftToRight,
            previewArea: previewArea,
            onHover: { hover = $0 },
            onScrub: { scrub = $0 },
            onDrag: { drag(at: $0, layout: layout) },
            onClick: { click(at: $0, layout: layout) }
        )
        .frame(width: ScrollbackMapLayout.macGutterWidth, height: layout.cardHeight)
        #else
        return mobileInputCard(layout: layout, previewedMark: previewedMark)
        #endif
    }

    /// Kept available on Mac for rendering and layout regression tests of the mobile presentation.
    var mobileInputCard: some View {
        let layout = mobileLayout
        return mobileInputCard(layout: layout, previewedMark: focusedMark(in: layout))
    }

    private func mobileInputCard(layout: ScrollbackMapLayout, previewedMark: ScrollbackMap.Mark?) -> some View {
        ScrollbackMapExpansion(amount: isActive ? 1 : 0) { expansion in
            let frame = ScrollbackMapLayout.mobileCardFrame(expansion: expansion, height: layout.cardHeight)
            let inset = ScrollbackMapLayout.stripInset.leading * expansion
            let shape = RoundedRectangle(cornerRadius: 3 + 6 * expansion)
            let width = frame.width - inset * 2
            return strip(layout: layout, width: width, maximumMarkWidth: max(width, frame.width - 2),
                         muted: false, previewedMark: previewedMark)
                .frame(width: frame.width, height: frame.height)
                .background(ScrollbackMapPalette(scheme: colorScheme).backing, in: shape)
                .offset(x: frame.minX)
                .frame(width: ScrollbackMapLayout.mobileTouchWidth, height: frame.height, alignment: .topLeading)
        }
        .animation(ScrollbackMapLayout.interactionAnimation(reduceMotion: reduceMotion), value: isActive)
        .contentShape(Rectangle())
        .gesture(scrubGesture(layout: layout))
        #if !os(macOS)
        .task(id: previewReleasedAt) {
            guard previewReleasedAt != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            scrub = nil
        }
        #endif
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover = point.y
            case .ended: hover = nil
            }
        }
    }

    private func strip(layout: ScrollbackMapLayout, width: CGFloat, maximumMarkWidth: CGFloat,
                       muted: Bool, growsInward: Bool = false, previewedMark: ScrollbackMap.Mark?) -> some View {
        let palette = ScrollbackMapPalette(scheme: colorScheme)
        let box = layout.viewportBox(viewport)
        let focusY = interactionY.map { ScrollbackMapLayout.stripY(forCardY: $0, height: layout.height) }
        let marks = layout.presentedMarks(map.marks, width: width, maximumWidth: maximumMarkWidth,
                                         focusY: focusY, previewedMark: previewedMark, muted: muted)
        return ZStack(alignment: .top) {
            if !muted {
                Rectangle().fill(palette.viewport.opacity(focusY == nil ? 0.18 : 0.08)).frame(width: 1)
            }
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(palette.viewport.opacity(muted ? 0.65 : 0.9), lineWidth: 1)
                .frame(width: width, height: box.height)
                .offset(y: box.y)
            ForEach(marks) { mark in
                let shape = RoundedRectangle(cornerRadius: mark.cornerRadius)
                let incoming = if mark.isPreviewed, let previewedMark {
                    entries[previewedMark.eventID]?.isIncomingPeer == true
                } else {
                    mark.cluster.marks.contains { entries[$0.eventID]?.isIncomingPeer == true }
                }
                shape.fill(palette.mark(mark.kind, incoming: incoming, muted: muted))
                    .overlay {
                        if mark.isPreviewed {
                            shape.strokeBorder(palette.viewport.opacity(0.9), lineWidth: 0.75)
                        }
                    }
                    .frame(width: mark.frame.width, height: mark.frame.height)
                    .offset(x: growsInward ? mark.frame.midX * (layoutDirection == .leftToRight ? 1 : -1) : 0,
                            y: mark.frame.minY)
            }
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
                #if !os(macOS)
                if let y = gestures.first?.location.y ?? gestures.second?.location.y {
                    scrub = y
                    previewReleasedAt = .now
                }
                #endif
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
        let target = layout.tapTarget(in: map, atY: y) { entries[$0]?.isIncomingPeer == true }
        scroll(target?.row ?? layout.scrubTopRow(atY: y, viewportLength: viewport.length))
    }

    private var accessibilityValue: String {
        let mark = accessibilityMark.flatMap { id in map.marks.first { $0.eventID == id } }
            ?? map.nearestMark(toRow: viewport.offset)
        guard let mark, let index = map.marks.firstIndex(of: mark), let entry = entries[mark.eventID] else {
            return "\(map.marks.count) messages"
        }
        let text = entry.kind == .peer ? PeerMessageGist.immediate(entry.text).text : entry.text
        return "\(index + 1) of \(map.marks.count), \(entry.heading()): \(text)"
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
    static let defaultWidth: CGFloat = 200
    let entry: ScrollbackMapEntry
    /// Nil for human input, which is never summarized.
    let gist: PeerMessageGist?
    var width = ScrollbackMapLabel.defaultWidth
    var now = Date.now
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(entry.speaker).lineLimit(1)
                if let age = entry.relativeAge(at: now) {
                    Text("· \(age)").monospacedDigit().fixedSize().foregroundStyle(Color.secondary)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(ScrollbackMapPalette(scheme: colorScheme).mark(entry.kind, incoming: entry.isIncomingPeer))
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
        .modifier(ScrollbackMapPreviewFrame(width: width))
    }
}

struct ScrollbackMapPreviewFrame: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

public struct ScrollbackMapRecovery: Sendable {
    public let id: String
    let load: @Sendable () -> WorktreeTimeline?

    public init(id: String, load: @escaping @Sendable () -> WorktreeTimeline?) {
        self.id = id
        self.load = load
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
    private var capturedEntries: [String: ScrollbackMapEntry] = [:]
    private var recovery: ScrollbackMapRecovery?
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

    public func update(timeline: WorktreeTimeline, recovery: ScrollbackMapRecovery? = nil) {
        let messages = ScrollbackMap.messages(in: timeline)
        guard messages != self.messages || recovery?.id != self.recovery?.id else { return }
        self.messages = messages
        capturedEntries = ScrollbackMapEntry.entries(in: timeline)
        if self.recovery?.id != recovery?.id { self.recovery = recovery }
        if messages.isEmpty, recovery == nil { map = nil; entries = [:]; stopEvictionCheck() }
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
        guard isVisible, !messages.isEmpty || recovery != nil, terminal != nil else { return }
        let debounce = debounce
        pending = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self, let terminal = self.terminal else { return }
            let firstRow = terminal.firstRowText()
            let snapshot = terminal.scrollbackRows(limit: ScrollbackMap.readLimit)
            let messages = self.messages, recovery = self.recovery, capturedEntries = self.capturedEntries
            let (map, entries) = await Task.detached(priority: .userInitiated) { () -> (ScrollbackMap?, [String: ScrollbackMapEntry]) in
                guard let snapshot else { return (nil, [:]) }
                let captured = ScrollbackMap.locate(messages, in: snapshot)
                guard let timeline = recovery?.load() else { return (captured, capturedEntries) }
                let saved = ScrollbackMap.messages(in: timeline)
                let entries = capturedEntries.merging(ScrollbackMapEntry.entries(in: timeline)) { captured, _ in captured }
                let base = captured.marks.isEmpty ? ScrollbackMap.locate(saved, in: snapshot) : captured
                let savedInputs = ScrollbackMap.codexInputMarks(saved, in: snapshot)
                let capturedInputs = ScrollbackMap.codexInputMarks(messages, in: snapshot)
                let savedIDs = Set(savedInputs.map(\.eventID))
                let confirmed = savedInputs + capturedInputs.filter { !savedIDs.contains($0.eventID) }
                let confirmedTexts = Set(confirmed.compactMap { entries[$0.eventID]?.text })
                var marksByRow: [Int: ScrollbackMap.Mark] = [:]
                for mark in base.marks {
                    if mark.kind == .input, let text = entries[mark.eventID]?.text, confirmedTexts.contains(text) { continue }
                    marksByRow[mark.row] = mark
                }
                // Keep the captured event ID when both sources describe the same prompt row.
                for mark in confirmed { marksByRow[mark.row] = mark }
                return (ScrollbackMap(totalRows: snapshot.totalRows, marks: Array(marksByRow.values)), entries)
            }.value
            guard !Task.isCancelled else { return }
            let userCount = map?.marks.count { $0.kind == .input } ?? 0
            scrollbackLog.debug("Scan read \(snapshot?.rows.count ?? 0) rows and found \(userCount) user marks among \(map?.marks.count ?? 0) total.")
            self.entries = entries
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
    let recovery: ScrollbackMapRecovery?
    var gists: PeerMessageGistProvider = .shared
    /// Derived once per parent update, not on every viewport report that redraws this body.
    private let messages: [ScrollbackMap.Message]

    public init(model: ScrollbackMapModel, timeline: WorktreeTimeline, isVisible: Bool = true,
                recovery: ScrollbackMapRecovery? = nil,
                gists: PeerMessageGistProvider = .shared) {
        self.model = model; self.timeline = timeline; self.isVisible = isVisible; self.gists = gists
        self.recovery = recovery
        self.messages = ScrollbackMap.messages(in: timeline)
    }

    public var body: some View {
        GeometryReader { geometry in
            if let map = model.map, !map.marks.isEmpty {
                ScrollbackMapOverlay(map: map, viewport: model.viewport, entries: model.entries, gists: gists,
                                     availableHeight: geometry.size.height, availableWidth: geometry.size.width,
                                     scroll: { [model] in model.scroll(toRow: $0) })
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onAppear {
                        let userCount = map.marks.count { $0.kind == .input }
                        scrollbackLog.debug("Showing rail with \(userCount) user marks among \(map.marks.count) total. Local Codex session: \(recovery != nil).")
                    }
            }
        }
        .onAppear {
            model.update(timeline: timeline, recovery: recovery)
            model.setVisible(isVisible)
        }
        .onDisappear { model.setVisible(false) }
        .onChange(of: messages) { _, _ in model.update(timeline: timeline, recovery: recovery) }
        .onChange(of: recovery?.id) { _, _ in model.update(timeline: timeline, recovery: recovery) }
        .onChange(of: isVisible) { _, visible in model.setVisible(visible) }
    }
}

#if os(macOS)
public extension View {
    /// Keep the gutter outside the terminal grid even before the first scrollback scan finishes.
    @MainActor
    func macScrollbackMapGutter(timeline: WorktreeTimeline?, model: ScrollbackMapModel,
                                background: Color, topInset: CGFloat, recovery: ScrollbackMapRecovery? = nil) -> some View {
        padding(.trailing, timeline == nil ? 0 : ScrollbackMapLayout.macGutterWidth)
            .background(alignment: .trailing) {
                if timeline != nil {
                    background.frame(width: ScrollbackMapLayout.macGutterWidth).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let timeline {
                    ScrollbackMapOverlayHost(model: model, timeline: timeline, recovery: recovery)
                        .padding(.vertical, ScrollbackMapLayout.stripInset.top)
                        .padding(.top, topInset)
                }
            }
    }
}
#endif
