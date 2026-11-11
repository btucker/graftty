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
    static let mobileCollapsedWidth: CGFloat = 4
    public static let stripInset = EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7)
    public static let mergeDistance: CGFloat = 3
    public static let markHeight: CGFloat = 3
    static let maximumGrowth: CGFloat = 52
    private static let magnificationRadius: CGFloat = 48
    public static let minimumViewportHeight: CGFloat = 4
    /// How close a click must land to a mark to jump to it rather than scrub.
    public static let tapTolerance: CGFloat = 6

    public static var stripHeight: CGFloat { cardSize.height - stripInset.top - stripInset.bottom }

    /// The mobile drawing expands inside a fixed touch width at the pane's right edge.
    static func mobileCardFrame(magnification: CGFloat, height: CGFloat) -> CGRect {
        let width = mobileCollapsedWidth + (cardSize.width - mobileCollapsedWidth) * magnification
        let trailing: CGFloat = 6 * magnification
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
        let widthScale: CGFloat
        /// Orange wins over blue so a merged human input never disappears.
        public var kind: ScrollbackMap.Kind { marks.contains { $0.kind == .input } ? .input : .peer }
    }

    public let height: CGFloat
    public let totalRows: Int
    var cardHeight: CGFloat { height + Self.stripInset.top + Self.stripInset.bottom }
    private let restingHeight: CGFloat
    private let entryY: CGFloat
    private let tailScale: CGFloat
    private let focusY: CGFloat?
    private let magnification: CGFloat

    public init(height: CGFloat = ScrollbackMapLayout.stripHeight, totalRows: Int) {
        self.init(height: height, totalRows: totalRows, focusY: nil, entryY: nil)
    }

    init(height: CGFloat, totalRows: Int, focusY: CGFloat?, entryY: CGFloat?,
         magnification: CGFloat = 1,
         availableGrowth: CGFloat = ScrollbackMapLayout.maximumGrowth) {
        let magnification = min(1, max(0, magnification))
        let anchor = min(height, max(0, entryY ?? focusY ?? 0))
        let tail = height - anchor
        let growth = focusY == nil ? 0 : min(availableGrowth, Self.maximumGrowth, tail) * magnification
        self.height = height + growth
        self.totalRows = max(1, totalRows)
        restingHeight = height
        self.entryY = anchor
        tailScale = tail > 0 ? growth / tail : 0
        self.focusY = focusY.map { min(height + growth, max(0, $0)) }
        self.magnification = magnification
    }

    /// Rows can grow past the last scan, so the live viewport total wins when larger.
    public init(height: CGFloat = ScrollbackMapLayout.stripHeight, map: ScrollbackMap, viewport: ScrollbackViewport) {
        self.init(height: height, totalRows: max(map.totalRows, viewport.total))
    }

    public func y(forRow row: Int) -> CGFloat {
        let restingY = CGFloat(min(max(row, 0), totalRows)) / CGFloat(totalRows) * restingHeight
        // Extend below the entry point so opening the card keeps the row there under the pointer.
        let y = restingY + max(0, restingY - entryY) * tailScale
        guard let focusY else { return y }
        let delta = y - focusY
        let radius = min(Self.magnificationRadius, delta < 0 ? focusY : height - focusY)
        guard radius > 0 else { return y }
        let influence = max(0, 1 - abs(delta) / radius)
        // This curve fixes the focus and both ends of the strip, and preserves row order.
        return y + 2.4 * magnification * delta * influence * influence
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
        let influence = focusY.map { max(0, 1 - abs(center - $0) / Self.magnificationRadius) } ?? 0
        let strength = magnification * influence * influence
        let size = min(height, Self.markHeight * (1 + 0.9 * strength))
        return Cluster(marks: marks, y: min(max(0, center - size / 2), height - size),
                       height: size, widthScale: 1 + 0.5 * strength)
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

    /// The card draws at 40 percent opacity while idle and fully opaque while hovered or scrubbed.
    public static func opacity(isActive: Bool) -> Double { isActive ? 1 : 0.4 }

    public static func interactionAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    /// On mobile the card's top sits this far below the top of the pane's floating
    /// top-right controls (Worktree context and resource buttons), so the two never overlap.
    public static func topInset(belowControlsAt controlsTop: CGFloat, controlsHeight: CGFloat, spacing: CGFloat = 8) -> CGFloat {
        controlsTop + max(0, controlsHeight) + spacing
    }
}

/// Supplies each animation frame's geometry to both drawing and native input.
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
/// While a worktree's agent pane is shown on Mac or mobile and its scrollback holds located human inputs or peer messages, the application shall float a small translucent scrollback map card at the pane's top-right whose strip spans the whole scrollback, with orange marks for human inputs, accent-blue marks for peer messages and agent responses, marks merged when their displayed centers are closer than 3 points or their bars overlap, and a box showing the current viewport, and shall hide the card while no message is located.
public struct ScrollbackMapOverlay: View {
    private struct Interaction {
        let cardY: CGFloat
        let entryCardY: CGFloat
    }

    private struct Touch {
        let interaction: Interaction
        let initialLayout: ScrollbackMapLayout
    }

    let map: ScrollbackMap
    let viewport: ScrollbackViewport
    let entries: [String: ScrollbackMapEntry]
    let gists: PeerMessageGistProvider
    let scroll: (Int) -> Void
    private let availableHeight: CGFloat
    @State private var hover: Interaction?
    @State private var scrub: Interaction?
    @State private var lastInteraction: Interaction?
    @State private var touchStartLayout: ScrollbackMapLayout?
    // GestureState also clears on cancellation, so an interrupted touch cannot leave the map expanded.
    @GestureState private var touch: Touch?
    @State private var accessibilityMark: String?
    @State private var gist: PeerMessageGist?
    @State private var labelHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(map: ScrollbackMap, viewport: ScrollbackViewport, entries: [String: ScrollbackMapEntry],
                gists: PeerMessageGistProvider = .shared, availableHeight: CGFloat = .infinity, scroll: @escaping (Int) -> Void) {
        self.init(map: map, viewport: viewport, entries: entries, gists: gists, availableHeight: availableHeight,
                  focusY: nil, scroll: scroll)
    }

    /// `focusY` starts the overlay mid-scrub, for rendering tests.
    init(map: ScrollbackMap, viewport: ScrollbackViewport, entries: [String: ScrollbackMapEntry],
         gists: PeerMessageGistProvider, availableHeight: CGFloat = .infinity, focusY: CGFloat?, scroll: @escaping (Int) -> Void) {
        self.map = map; self.viewport = viewport; self.entries = entries; self.gists = gists; self.scroll = scroll
        self.availableHeight = availableHeight
        _scrub = State(initialValue: focusY.map {
            let cardY = $0 + ScrollbackMapLayout.stripInset.top
            return Interaction(cardY: cardY, entryCardY: cardY)
        })
    }

    private var interaction: Interaction? { touch?.interaction ?? scrub ?? hover }
    private var isActive: Bool { interaction != nil }
    private var restingHeight: CGFloat { min(availableHeight, ScrollbackMapLayout.cardSize.height) }
    private func focusedMark(in layout: ScrollbackMapLayout) -> ScrollbackMap.Mark? {
        guard let interaction else { return nil }
        return layout.nearestMark(in: map, toY: ScrollbackMapLayout.stripY(forCardY: interaction.cardY, height: layout.height))
    }

    private func layout(for interaction: Interaction?, magnification: CGFloat) -> ScrollbackMapLayout {
        let inset = ScrollbackMapLayout.stripInset
        return ScrollbackMapLayout(height: max(0, restingHeight - inset.top - inset.bottom),
                                   totalRows: max(map.totalRows, viewport.total),
                                   focusY: interaction.map { $0.cardY - inset.top },
                                   entryY: interaction.map { $0.entryCardY - inset.top },
                                   magnification: magnification,
                                   availableGrowth: max(0, availableHeight - restingHeight))
    }

    public var body: some View {
        if !map.marks.isEmpty, layout(for: nil, magnification: 0).height >= ScrollbackMapLayout.markHeight {
            animatedCard { layout, amount in
                let focusedMark = focusedMark(in: layout)
                inputCard(layout: layout, magnification: amount)
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
                .task(id: focusedMark?.eventID) { await loadGist(for: focusedMark) }
            }
        }
    }

    private func animatedCard<Content: View>(
        @ViewBuilder content: @escaping (ScrollbackMapLayout, CGFloat) -> Content
    ) -> some View {
        ScrollbackMapExpansion(amount: isActive ? 1 : 0) { amount in
            content(layout(for: interaction ?? lastInteraction, magnification: amount), amount)
        }
        .animation(ScrollbackMapLayout.interactionAnimation(reduceMotion: reduceMotion), value: isActive)
    }

    private func inputCard(layout: ScrollbackMapLayout, magnification: CGFloat) -> some View {
        #if os(macOS)
        let content = visualCard(layout: layout, magnification: magnification)
            .frame(maxHeight: .infinity, alignment: .top)
        return ScrollbackMapPointerInput(content: AnyView(content),
            onHover: { updateHover($0, magnification: magnification) },
            onScrub: { updateScrub($0, magnification: magnification) },
            onDrag: { drag(pointerInteraction(at: $0, magnification: magnification), magnification: magnification) },
            onClick: { click(at: $0, layout: layout) }
        )
        .frame(width: ScrollbackMapLayout.cardSize.width, height: layout.cardHeight)
        #else
        return mobileInputCard(layout: layout, magnification: magnification)
        #endif
    }

    /// Kept available on Mac for rendering and layout regression tests of the mobile presentation.
    var mobileInputCard: some View {
        animatedCard { layout, amount in mobileInputCard(layout: layout, magnification: amount) }
    }

    private func mobileInputCard(layout: ScrollbackMapLayout, magnification: CGFloat) -> some View {
        let frame = ScrollbackMapLayout.mobileCardFrame(magnification: magnification, height: layout.cardHeight)
        return visualCard(layout: layout, magnification: magnification, isMobile: true)
            .offset(x: frame.minX)
            .frame(width: ScrollbackMapLayout.mobileTouchWidth, height: frame.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(scrubGesture(layout: layout, magnification: magnification))
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): updateHover(point.y, magnification: magnification)
                case .ended: updateHover(nil, magnification: magnification)
                }
            }
    }

    private func visualCard(layout: ScrollbackMapLayout, magnification: CGFloat, isMobile: Bool = false) -> some View {
        let box = layout.viewportBox(viewport)
        let expansion: CGFloat = isMobile ? magnification : 1
        let width = ScrollbackMapLayout.mobileCardFrame(magnification: expansion, height: layout.cardHeight).width
        let horizontalInset = ScrollbackMapLayout.stripInset.leading * expansion
        let stripWidth = width - horizontalInset * 2
        let cornerRadius: CGFloat = 2 + 7 * expansion
        let idleOpacity = ScrollbackMapLayout.opacity(isActive: false)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.12))
                .frame(width: 2).frame(maxWidth: .infinity)
            ForEach(layout.clusters(map.marks)) { cluster in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(cluster.kind == .input ? Color.orange : Color.accentColor)
                    .frame(width: stripWidth * cluster.widthScale, height: cluster.height)
                    .frame(maxWidth: .infinity)
                    .offset(y: cluster.y)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.08))
                .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
                .frame(height: box.height)
                .padding(.horizontal, -3 * expansion)
                .offset(y: box.y)
        }
        .frame(width: stripWidth, height: layout.height, alignment: .top)
        .padding(.vertical, ScrollbackMapLayout.stripInset.top)
        .padding(.horizontal, horizontalInset)
        .frame(width: width, height: layout.cardHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25 * expansion), radius: 8, y: 3)
        .overlay(alignment: .topLeading) { label(layout: layout) }
        .opacity(idleOpacity + (1 - idleOpacity) * Double(magnification))
    }

    private func scrubGesture(layout: ScrollbackMapLayout, magnification: CGFloat) -> some Gesture {
        return DragGesture(minimumDistance: 0)
            .simultaneously(with: SpatialTapGesture())
            .updating($touch) { gestures, touch, _ in
                if let drag = gestures.first {
                    touch = Touch(interaction: touchInteraction(drag, magnification: magnification),
                                  initialLayout: touch?.initialLayout ?? layout)
                }
            }
            .onChanged { gestures in
                guard let value = gestures.first else { return }
                touchStartLayout = touch?.initialLayout ?? layout
                let interaction = touchInteraction(value, magnification: magnification)
                lastInteraction = interaction
                if hasMoved(value) { drag(interaction, magnification: magnification) }
            }
            .onEnded { gestures in
                let tapLayout = gestures.first == nil ? layout : (touchStartLayout ?? layout)
                touchStartLayout = nil
                if let drag = gestures.first, hasMoved(drag) { return }
                guard let y = gestures.second?.location.y else { return }
                // A tap aims at the map as it looked before the finger touched it.
                click(at: y, layout: tapLayout)
            }
    }

    private func hasMoved(_ value: DragGesture.Value) -> Bool {
        abs(value.translation.height) >= 2 || abs(value.translation.width) >= 2
    }

    private func updateHover(_ y: CGFloat?, magnification: CGFloat) {
        hover = y.map { pointerInteraction(at: $0, magnification: magnification) }
        if let hover { lastInteraction = hover }
    }

    private func updateScrub(_ y: CGFloat?, magnification: CGFloat) {
        scrub = y.map { pointerInteraction(at: $0, magnification: magnification) }
        if let scrub { lastInteraction = scrub }
    }

    private func pointerInteraction(at y: CGFloat, magnification: CGFloat) -> Interaction {
        let entry = interaction?.entryCardY ?? (magnification > 0 ? lastInteraction?.entryCardY : nil) ?? y
        return Interaction(cardY: y, entryCardY: entry)
    }

    private func touchInteraction(_ value: DragGesture.Value, magnification: CGFloat) -> Interaction {
        let entry = touch?.interaction.entryCardY ?? hover?.entryCardY
            ?? (magnification > 0 ? lastInteraction?.entryCardY : nil) ?? value.startLocation.y
        return Interaction(cardY: value.location.y, entryCardY: entry)
    }

    private func drag(_ interaction: Interaction, magnification: CGFloat) {
        let layout = layout(for: interaction, magnification: magnification)
        let y = ScrollbackMapLayout.stripY(forCardY: interaction.cardY, height: layout.height)
        scroll(layout.scrubTopRow(atY: y, viewportLength: viewport.length))
    }

    private func click(at cardY: CGFloat, layout: ScrollbackMapLayout) {
        let y = ScrollbackMapLayout.stripY(forCardY: cardY, height: layout.height)
        scroll(layout.tapTarget(in: map, atY: y)?.row
            ?? layout.scrubTopRow(atY: y, viewportLength: viewport.length))
    }

    @ViewBuilder
    private func label(layout: ScrollbackMapLayout) -> some View {
        if let mark = focusedMark(in: layout), let entry = entries[mark.eventID] {
            ScrollbackMapLabel(entry: entry, gist: entry.kind == .peer ? (gist ?? .immediate(entry.text)) : nil)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { labelHeight = $0 }
                .offset(x: -(ScrollbackMapLabel.width + 6),
                        y: ScrollbackMapLayout.stripInset.top + layout.labelTop(forMarkAt: mark.row, labelHeight: labelHeight))
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
