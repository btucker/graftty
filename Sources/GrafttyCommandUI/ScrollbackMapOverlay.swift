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
            case .agentMessage:
                entries[event.id] = ScrollbackMapEntry(kind: .peer, text: event.completed, timestamp: event.timestamp,
                                                       sender: event.sourceWorktreeName)
            case .creation, .checkpoint: break
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
    public static let stripInset = EdgeInsets(top: 6, leading: 7, bottom: 6, trailing: 7)
    public static let mergeDistance: CGFloat = 3
    public static let markHeight: CGFloat = 3
    public static let minimumViewportHeight: CGFloat = 4
    /// How close a click must land to a mark to jump to it rather than scrub.
    public static let tapTolerance: CGFloat = 6

    public static var stripHeight: CGFloat { cardSize.height - stripInset.top - stripInset.bottom }

    public struct Cluster: Equatable, Identifiable {
        public var id: String { marks[0].eventID }
        public let marks: [ScrollbackMap.Mark]
        /// The top of the drawn mark, kept inside the strip.
        public let y: CGFloat
        /// Orange wins over blue so a merged human input never disappears.
        public var kind: ScrollbackMap.Kind { marks.contains { $0.kind == .input } ? .input : .peer }
    }

    public let height: CGFloat
    public let totalRows: Int

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
        return min(totalRows - 1, max(0, Int((min(max(y, 0), height) / height * CGFloat(totalRows)).rounded(.down))))
    }

    public func clusters(_ marks: [ScrollbackMap.Mark]) -> [Cluster] {
        var groups: [[(mark: ScrollbackMap.Mark, y: CGFloat)]] = []
        for mark in marks.sorted(by: { $0.row < $1.row }) {
            let y = y(forRow: mark.row)
            if let last = groups.last?.last, y - last.y < Self.mergeDistance {
                groups[groups.count - 1].append((mark, y))
            } else {
                groups.append([(mark, y)])
            }
        }
        return groups.map { group in
            let mean = group.map(\.y).reduce(0, +) / CGFloat(group.count)
            return Cluster(marks: group.map(\.mark), y: min(max(0, mean - Self.markHeight / 2), height - Self.markHeight))
        }
    }

    /// The viewport box's top and height, at least `minimumViewportHeight` and inside the strip.
    public func viewportBox(_ viewport: ScrollbackViewport) -> (y: CGFloat, height: CGFloat) {
        let boxHeight = min(height, max(Self.minimumViewportHeight, y(forRow: viewport.length)))
        return (min(max(0, y(forRow: viewport.offset)), height - boxHeight), boxHeight)
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

    public static func fadeAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    /// On mobile the card's top sits this far below the top of the pane's floating
    /// top-right controls (Worktree context and resource buttons), so the two never overlap.
    public static func topInset(belowControlsAt controlsTop: CGFloat, controlsHeight: CGFloat, spacing: CGFloat = 8) -> CGFloat {
        controlsTop + max(0, controlsHeight) + spacing
    }
}

/// @spec CONTEXT-34
/// A small floating card at a terminal pane's top-right that maps where human input
/// and peer messages sit in the whole scrollback, with the current viewport boxed.
public struct ScrollbackMapOverlay: View {
    let map: ScrollbackMap
    let viewport: ScrollbackViewport
    let entries: [String: ScrollbackMapEntry]
    let gists: PeerMessageGistProvider
    let scroll: (Int) -> Void
    @State private var hoverY: CGFloat?
    @State private var scrubY: CGFloat?
    @State private var dragStartY: CGFloat?
    @State private var accessibilityMark: String?
    @State private var gist: PeerMessageGist?
    @State private var labelHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(map: ScrollbackMap, viewport: ScrollbackViewport, entries: [String: ScrollbackMapEntry],
                gists: PeerMessageGistProvider = .shared, scroll: @escaping (Int) -> Void) {
        self.init(map: map, viewport: viewport, entries: entries, gists: gists, focusY: nil, scroll: scroll)
    }

    /// `focusY` starts the overlay mid-scrub, for rendering tests.
    init(map: ScrollbackMap, viewport: ScrollbackViewport, entries: [String: ScrollbackMapEntry],
         gists: PeerMessageGistProvider, focusY: CGFloat?, scroll: @escaping (Int) -> Void) {
        self.map = map; self.viewport = viewport; self.entries = entries; self.gists = gists; self.scroll = scroll
        _scrubY = State(initialValue: focusY)
    }

    private var layout: ScrollbackMapLayout { ScrollbackMapLayout(map: map, viewport: viewport) }
    private var focusY: CGFloat? { scrubY ?? hoverY }
    private var isActive: Bool { focusY != nil }
    private var focusedMark: ScrollbackMap.Mark? { focusY.flatMap { layout.nearestMark(in: map, toY: $0) } }

    public var body: some View {
        if !map.marks.isEmpty {
            card
                .overlay(alignment: .topLeading) { label }
                .opacity(ScrollbackMapLayout.opacity(isActive: isActive))
                .animation(ScrollbackMapLayout.fadeAnimation(reduceMotion: reduceMotion), value: isActive)
                .task(id: focusedMark?.eventID) { await loadGist() }
        }
    }

    private var card: some View {
        let layout = layout
        let box = layout.viewportBox(viewport)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.12))
                .frame(width: 2).frame(maxWidth: .infinity)
            ForEach(layout.clusters(map.marks)) { cluster in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(cluster.kind == .input ? Color.orange : Color.accentColor)
                    .frame(height: cluster.marks.contains { $0.eventID == focusedMark?.eventID } ? 4 : ScrollbackMapLayout.markHeight)
                    .offset(y: cluster.y)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.08))
                .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
                .frame(height: box.height)
                .padding(.horizontal, -3)
                .offset(y: box.y)
        }
        .frame(width: ScrollbackMapLayout.cardSize.width - ScrollbackMapLayout.stripInset.leading - ScrollbackMapLayout.stripInset.trailing,
               height: layout.height, alignment: .top)
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        #if os(macOS)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hoverY = point.y
            case .ended: hoverY = nil
            }
        }
        #endif
        .padding(ScrollbackMapLayout.stripInset)
        .frame(width: ScrollbackMapLayout.cardSize.width, height: ScrollbackMapLayout.cardSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
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
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStartY == nil { dragStartY = value.startLocation.y }
                scrubY = value.location.y
                // A press that has not moved yet may be a click on a mark.
                guard abs(value.translation.height) >= 2 || abs(value.translation.width) >= 2 else { return }
                scroll(layout.scrubTopRow(atY: value.location.y, viewportLength: viewport.length))
            }
            .onEnded { value in
                defer { scrubY = nil; dragStartY = nil }
                guard abs(value.translation.height) < 2, abs(value.translation.width) < 2 else { return }
                if let mark = layout.tapTarget(in: map, atY: value.location.y) {
                    scroll(mark.row)
                } else {
                    scroll(layout.scrubTopRow(atY: value.location.y, viewportLength: viewport.length))
                }
            }
    }

    @ViewBuilder
    private var label: some View {
        if let mark = focusedMark, let entry = entries[mark.eventID] {
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

    private func loadGist() async {
        gist = nil
        guard let mark = focusedMark, let entry = entries[mark.eventID], entry.kind == .peer else { return }
        gist = await gists.gist(for: entry.text)
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
/// scrollback after a quiet second, only while the pane is visible.
@MainActor
public final class ScrollbackMapModel: ObservableObject {
    @Published public private(set) var map: ScrollbackMap?
    @Published public private(set) var viewport = ScrollbackViewport.empty
    public private(set) var entries: [String: ScrollbackMapEntry] = [:]
    private weak var terminal: (any TerminalScrollback)?
    private var messages: [ScrollbackMap.Message] = []
    private var isVisible = false
    private var pending: Task<Void, Never>?
    private let debounce: Duration

    public init(terminal: any TerminalScrollback, debounce: Duration = .seconds(1)) {
        self.terminal = terminal
        self.debounce = debounce
    }

    public func update(timeline: WorktreeTimeline) {
        let messages = ScrollbackMap.messages(in: timeline)
        guard messages != self.messages else { return }
        self.messages = messages
        entries = ScrollbackMapEntry.entries(in: timeline)
        if messages.isEmpty { map = nil }
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
        if visible { scheduleRebuild() } else { pending?.cancel(); pending = nil }
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
            let map = await terminal.scrollbackMap(for: self.messages)
            guard !Task.isCancelled else { return }
            self.map = map
            self.pending = nil
        }
    }
}

/// Keeps a pane's map current and shows the overlay once it has marks.
public struct ScrollbackMapOverlayHost: View {
    @ObservedObject var model: ScrollbackMapModel
    let timeline: WorktreeTimeline
    let isVisible: Bool
    var gists: PeerMessageGistProvider = .shared

    public init(model: ScrollbackMapModel, timeline: WorktreeTimeline, isVisible: Bool = true,
                gists: PeerMessageGistProvider = .shared) {
        self.model = model; self.timeline = timeline; self.isVisible = isVisible; self.gists = gists
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            // Mounted even without marks, so appearance tracks the pane's visibility.
            Color.clear.frame(width: 0, height: 0)
            if let map = model.map {
                ScrollbackMapOverlay(map: map, viewport: model.viewport, entries: model.entries, gists: gists,
                                     scroll: { [model] in model.scroll(toRow: $0) })
            }
        }
        .onAppear {
            model.update(timeline: timeline)
            model.setVisible(isVisible)
        }
        .onDisappear { model.setVisible(false) }
        .onChange(of: ScrollbackMap.messages(in: timeline)) { _, _ in model.update(timeline: timeline) }
        .onChange(of: isVisible) { _, visible in model.setVisible(visible) }
    }
}
