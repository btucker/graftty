import SwiftUI

struct ScrollbackMapPreview: Identifiable {
    let id: String
    let entry: ScrollbackMapEntry
    let y: CGFloat
}

struct ScrollbackMapPreviewGroup: Identifiable {
    let messages: [ScrollbackMapPreview]

    var id: String { messages[0].id }
    var startY: CGFloat { messages[0].y }
    var endY: CGFloat { messages[messages.count - 1].y }
    var y: CGFloat { (startY + endY) / 2 }

    static func group(_ previews: [ScrollbackMapPreview], maximumGap: CGFloat, maximumSpan: CGFloat) -> [Self] {
        var runs: [[ScrollbackMapPreview]] = []
        // The focused agent reply comes and goes without changing how the user messages group.
        for message in previews where message.entry.kind == .input {
            if let first = runs.last?.first, let last = runs.last?.last,
               message.y - last.y <= maximumGap && message.y - first.y <= maximumSpan {
                runs[runs.count - 1].append(message)
            } else {
                runs.append([message])
            }
        }
        let replies = previews.filter { $0.entry.kind == .peer }.map { [$0] }
        return (runs + replies).map(Self.init(messages:)).sorted { $0.y < $1.y }
    }

    /// The rows of a grouped card: a window of up to `limit` messages around
    /// the focused one, each with its distance from it, or the latest messages when
    /// no message in the group is focused.
    ///
    /// `windowID` keeps the window where the rail put it while the pointer moves
    /// the focus between the rows shown, so rows never slide under the pointer.
    func fisheye(focusedID: String?, windowID: String? = nil, limit: Int = 7)
        -> (rows: [(preview: ScrollbackMapPreview, distance: Int?)], earlier: Int, later: Int) {
        let count = min(messages.count, limit)
        let focus = messages.firstIndex { $0.id == focusedID }
        let center = messages.firstIndex { $0.id == windowID } ?? focus
        let start = center.map { min(messages.count - count, max(0, $0 - count / 2)) } ?? messages.count - count
        let rows = (start ..< start + count).map { index in
            (preview: messages[index], distance: focus.map { abs(index - $0) })
        }
        return (rows, start, messages.count - start - count)
    }
}

/// @spec CONTEXT-57.12
/// While the user hovers over, touches, or scrubs the scrollback map over a group of close messages, the application shall list up to seven of the group's messages in rail order around the focused one, enlarge the focused message, shrink the others with their distance from it, and connect the focused message to its own mark.
enum ScrollbackMapFisheye {
    struct Style: Equatable {
        let size: CGFloat
        let opacity: Double
        let lineLimit: Int
    }

    /// Text size falls off with distance from the focused mark, like the rail lens.
    static func style(distance: Int?) -> Style {
        switch distance {
        case nil: Style(size: 12, opacity: 0.85, lineLimit: 1)
        case 0: Style(size: 15, opacity: 1, lineLimit: 3)
        case 1: Style(size: 12, opacity: 0.7, lineLimit: 1)
        default: Style(size: 10.5, opacity: 0.45, lineLimit: 1)
        }
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.18)
    }
}

enum FocusedRowBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct ScrollbackMapPreviews: View {
    let groups: [ScrollbackMapPreviewGroup]
    let height: CGFloat
    let cardWidth: CGFloat
    let gap: CGFloat
    let railCenter: CGFloat
    let focusY: CGFloat
    let maximumShift: CGFloat
    let focusedID: String?
    /// The message the rail points at, which fixes each card's window of rows.
    var windowID: String? = nil
    /// The message whose row the pointer is over, if any.
    var hoveredID: String? = nil
    /// Scroll-wheel travel over a card: the delta and whether it is precise.
    var onWheel: (CGFloat, Bool) -> Void = { _, _ in }
    let responseGist: (entry: ScrollbackMapEntry, gist: PeerMessageGist)?
    let onSelect: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Measured card heights; a card stays hidden until it has been measured.
    @State private var heights: [String: CGFloat] = [:]

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let now = Date.now
            let slots = ScrollbackPreviewStack.slots(
                anchors: groups.map(\.y), heights: groups.map { heights[$0.id] }, height: height, focusY: focusY,
                maximumShift: maximumShift,
                focusedIndex: groups.firstIndex { $0.messages.contains { $0.id == focusedID } })
            ZStack(alignment: .topLeading) {
                ForEach(Array(zip(groups, slots)), id: \.0.id) { group, slot in
                    Button { onSelect(target(in: group)) } label: {
                        card(for: group, now: now).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    #if os(macOS)
                    .overlay {
                        // AppKit keeps a transparent native view's pointing-hand cursor rect.
                        if slot.visible {
                            ScrollbackPreviewButtonInput(wheel: onWheel) { onSelect(target(in: group)) }
                                .accessibilityHidden(true)
                        }
                    }
                    #endif
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cardHeight in
                        // A first measurement reveals the card in place: sliding it in would
                        // also move the hover area the pointer crosses on its way to the card.
                        var transaction = Transaction()
                        transaction.disablesAnimations = heights[group.id] == nil
                        withTransaction(transaction) { heights[group.id] = cardHeight }
                    }
                    .opacity(slot.visible ? 1 : 0)
                    .allowsHitTesting(slot.visible)
                    .accessibilityHidden(!slot.visible)
                    .anchorPreference(key: PreviewBounds.self, value: .bounds) { slot.visible ? [group.id: $0] : [:] }
                    .transformPreference(FocusedRowBounds.self) { if !slot.visible { $0 = nil } }
                    .transformPreference(PreviewRowBounds.self) { if !slot.visible { $0 = [:] } }
                    // Padding, unlike an offset, moves the anchors that place connectors and the Mac hover area.
                    .padding(.top, slot.top)
                }
            }
            .frame(width: cardWidth + gap, height: height, alignment: .topLeading)
            .animation(ScrollbackPreviewStack.animation(reduceMotion: reduceMotion), value: slots)
            .backgroundPreferenceValue(PreviewBounds.self) { connectors(for: $0).allowsHitTesting(false) }
            #if os(macOS)
            .backgroundPreferenceValue(PreviewRowBounds.self) { rows in
                GeometryReader { geometry in
                    // In the rail's coordinates, like the hover area: its origin is the gutter's leading edge.
                    let shift = layoutDirection == .leftToRight ? ScrollbackMapLayout.macGutterWidth - geometry.size.width : 0
                    Color.clear.preference(key: ScrollbackPreviewRows.self,
                                           value: rows.mapValues { geometry[$0].offsetBy(dx: shift, dy: 0) })
                }
            }
            #endif
            .overlayPreferenceValue(FocusedRowBounds.self) { focusedConnector(for: $0).allowsHitTesting(false) }
            .clipped()
        }
    }

    /// Activating a card goes to the message focused inside it, else its first (CONTEXT-57.7).
    private func target(in group: ScrollbackMapPreviewGroup) -> String {
        group.messages.first { $0.id == hoveredID }?.id ?? group.id
    }

    @ViewBuilder private func card(for group: ScrollbackMapPreviewGroup, now: Date) -> some View {
        let entry = group.messages[0].entry
        if group.messages.count == 1 {
            ScrollbackMapLabel(entry: entry, gist: gist(for: entry), width: cardWidth, now: now)
        } else {
            fisheyeCard(for: group, now: now)
        }
    }

    private func fisheyeCard(for group: ScrollbackMapPreviewGroup, now: Date) -> some View {
        let window = group.fisheye(focusedID: focusedID, windowID: windowID)
        let palette = ScrollbackMapPalette(scheme: colorScheme)
        return VStack(alignment: .leading, spacing: 3) {
            Text(group.messages[0].entry.speaker)
                .font(.caption2.weight(.medium))
                .foregroundStyle(palette.input)
            if window.earlier > 0 {
                Text("+\(window.earlier) earlier").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(window.rows, id: \.preview.id) { row in
                let style = ScrollbackMapFisheye.style(distance: row.distance)
                let isFocused = row.distance == 0
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.preview.entry.text)
                        .font(.system(size: style.size, weight: isFocused ? .medium : .regular))
                        .lineLimit(style.lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let age = row.preview.entry.relativeAge(at: now) {
                        Text(age).font(.system(size: 10)).monospacedDigit().fixedSize()
                            .foregroundStyle(isFocused ? AnyShapeStyle(palette.input) : AnyShapeStyle(.secondary))
                    }
                }
                .opacity(style.opacity)
                .padding(.vertical, isFocused ? 3 : 0)
                .anchorPreference(key: FocusedRowBounds.self, value: .bounds) { isFocused ? $0 : nil }
                .anchorPreference(key: PreviewRowBounds.self, value: .bounds) { [row.preview.id: $0] }
            }
            if window.later > 0 {
                Text("+\(window.later) later").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .animation(ScrollbackMapFisheye.animation(reduceMotion: reduceMotion), value: focusedID)
        .modifier(ScrollbackMapPreviewFrame(width: cardWidth))
    }

    /// A solid line from the focused fisheye row to its own mark on the rail.
    private func focusedConnector(for anchor: Anchor<CGRect>?) -> some View {
        GeometryReader { geometry in
            if let anchor, let y = groups.lazy.flatMap(\.messages).first(where: { $0.id == focusedID })?.y {
                let rect = geometry[anchor]
                let leadingOnLeft = layoutDirection == .leftToRight
                let railX = leadingOnLeft ? geometry.size.width - railCenter : railCenter
                // The row sits inside the card's padding; start the line at the card edge.
                let edgeX = leadingOnLeft ? rect.maxX + 9 : rect.minX - 9
                Path { path in
                    path.move(to: CGPoint(x: edgeX, y: rect.midY))
                    path.addLine(to: CGPoint(x: railX, y: y))
                }
                .stroke(ScrollbackMapPalette(scheme: colorScheme).input, lineWidth: 1.5)
            }
        }
    }

    private func gist(for entry: ScrollbackMapEntry) -> PeerMessageGist? {
        guard entry.kind == .peer else { return nil }
        return responseGist?.entry == entry ? responseGist?.gist : .immediate(entry.text)
    }

    private func connectors(for bounds: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            let visible = groups.compactMap { group in bounds[group.id].map { (group, geometry[$0]) } }
            let palette = ScrollbackMapPalette(scheme: colorScheme)
            let leadingOnLeft = layoutDirection == .leftToRight
            let railX = leadingOnLeft ? geometry.size.width - railCenter : railCenter
            Canvas { context, _ in
                for (group, rect) in visible {
                    let edgeX = leadingOnLeft ? rect.maxX : rect.minX
                    let entry = group.messages[0].entry
                    let color = palette.mark(entry.kind, incoming: entry.isIncomingPeer)
                    if group.messages.count == 1 {
                        let line = Path { path in
                            path.move(to: CGPoint(x: edgeX, y: rect.midY))
                            path.addLine(to: CGPoint(x: railX, y: group.y))
                        }
                        context.stroke(line, with: .color(color.opacity(0.65)), lineWidth: 1)
                    } else {
                        let bandEnd = railX + (leadingOnLeft ? -6 : 6)
                        let top = group.startY - 2
                        let bottom = group.endY + 2
                        let band = Path { path in
                            path.move(to: CGPoint(x: edgeX, y: rect.minY + 4))
                            path.addLine(to: CGPoint(x: bandEnd, y: top))
                            path.addLine(to: CGPoint(x: bandEnd, y: bottom))
                            path.addLine(to: CGPoint(x: edgeX, y: rect.maxY - 4))
                            path.closeSubpath()
                        }
                        context.fill(band, with: .linearGradient(Gradient(colors: [color.opacity(0.04), color.opacity(0.32)]),
                            startPoint: CGPoint(x: edgeX, y: 0), endPoint: CGPoint(x: bandEnd, y: 0)))
                        let bracket = Path { path in
                            path.move(to: CGPoint(x: bandEnd, y: top))
                            path.addLine(to: CGPoint(x: bandEnd, y: bottom))
                        }
                        context.stroke(bracket, with: .color(color.opacity(0.55)), lineWidth: 1)
                    }
                }
            }
            #if os(macOS)
            .preference(key: ScrollbackPreviewArea.self, value: previewArea(visible.map { $0.1 }, width: geometry.size.width))
            #endif
        }
    }

    #if os(macOS)
    private func previewArea(_ frames: [CGRect], width: CGFloat) -> CGRect? {
        guard let first = frames.first else { return nil }
        let cards = frames.dropFirst().reduce(first) { $0.union($1) }
        let gutter = ScrollbackMapLayout.macGutterWidth
        let left = layoutDirection == .leftToRight ? cards.minX + gutter - width : 0
        let right = layoutDirection == .leftToRight ? gutter : cards.maxX
        let top = min(cards.minY, max(0, focusY))
        let bottom = max(cards.maxY, min(height, focusY))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
    #endif
}

#if os(macOS)
enum ScrollbackPreviewArea: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = value?.union(next) ?? next }
    }
}
#endif

/// Each fisheye row's bounds, so the pointer can focus the row it is over (CONTEXT-57.17).
private enum PreviewRowBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

#if os(macOS)
enum ScrollbackPreviewRows: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }

    /// The row at `point`: rows span their card's width, so only `y` picks among them.
    static func row(at point: CGPoint, in rows: [String: CGRect]) -> String? {
        rows.first { $0.value.insetBy(dx: -12, dy: -2).contains(point) }?.key
    }
}
#endif

private enum PreviewBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

/// @spec CONTEXT-57.14
/// When the previewed scrollback message changes, the application shall slide preview cards to their new positions and fade cards that no longer fit out where they stand, keeping unmeasured cards hidden, instead of moving or replacing them instantly. While Reduce Motion is on, the application shall change them without motion.
enum ScrollbackPreviewStack {
    struct Slot: Equatable {
        let top: CGFloat
        let visible: Bool
    }

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.18)
    }

    /// Every card keeps a position, so a card that no longer fits fades beside its
    /// mark instead of jumping off the edge; unmeasured cards stay hidden at their mark.
    static func slots(anchors: [CGFloat], heights: [CGFloat?], height: CGFloat, focusY: CGFloat,
                      maximumShift: CGFloat, focusedIndex: Int? = nil) -> [Slot] {
        let tops = tops(anchors: anchors, heights: heights.map { $0 ?? .infinity }, height: height,
                        focusY: focusY, maximumShift: maximumShift, focusedIndex: focusedIndex)
        return zip(anchors, zip(heights, tops)).map { anchor, measured in
            let (cardHeight, top) = measured
            if let top { return Slot(top: top, visible: true) }
            guard let cardHeight else { return Slot(top: min(height, anchor), visible: false) }
            return Slot(top: preferredTop(anchor: anchor, cardHeight: cardHeight, height: height), visible: false)
        }
    }

    /// A card centered on its mark, kept inside the pane where it fits.
    private static func preferredTop(anchor: CGFloat, cardHeight: CGFloat, height: CGFloat) -> CGFloat {
        min(max(0, height - cardHeight), max(0, anchor - cardHeight / 2))
    }

    static func tops(anchors: [CGFloat], heights: [CGFloat], height: CGFloat, focusY: CGFloat,
                     maximumShift: CGFloat, focusedIndex: Int? = nil) -> [CGFloat?] {
        func placements(for indices: [Int]) -> [CGFloat?]? {
            let spacing: CGFloat = 6
            var offsets: [CGFloat] = []
            var groups: [PreviewGroup] = []
            var nextOffset: CGFloat = 0
            var earliest = -CGFloat.infinity
            for (position, index) in indices.enumerated() {
                let cardHeight = heights[index]
                guard cardHeight <= height else { return nil }
                let preferred = preferredTop(anchor: anchors[index], cardHeight: cardHeight, height: height)
                let lower = max(0, preferred - maximumShift) - nextOffset
                let upper = min(height - cardHeight, preferred + maximumShift) - nextOffset
                earliest = max(earliest, lower)
                guard earliest <= upper else { return nil }

                // Subtract cumulative heights and gaps so overlap becomes a
                // reversal of order. Pool adjacent reversals toward their mean.
                offsets.append(nextOffset)
                var group = PreviewGroup(first: position, count: 1, sum: preferred - nextOffset,
                                         lower: lower, upper: upper)
                while let previous = groups.last, previous.top > group.top {
                    groups.removeLast()
                    group = PreviewGroup(first: previous.first, count: previous.count + group.count,
                                         sum: previous.sum + group.sum, lower: max(previous.lower, group.lower),
                                         upper: min(previous.upper, group.upper))
                }
                groups.append(group)
                nextOffset += cardHeight + spacing
            }

            var tops = [CGFloat?](repeating: nil, count: anchors.count)
            for group in groups {
                for position in group.first ..< group.first + group.count {
                    tops[indices[position]] = group.top + offsets[position]
                }
            }
            return tops
        }

        if let all = placements(for: Array(anchors.indices)) { return all }
        var accepted: [Int] = []
        var tops = [CGFloat?](repeating: nil, count: anchors.count)
        func priority(_ index: Int) -> (Int, CGFloat, Int) {
            (index == focusedIndex ? 0 : 1, abs(anchors[index] - focusY), index)
        }
        let indices = anchors.indices.sorted { priority($0) < priority($1) }
        for index in indices {
            let candidate = (accepted + [index]).sorted()
            if let placed = placements(for: candidate) {
                accepted = candidate
                tops = placed
            }
        }
        return tops
    }

    private struct PreviewGroup {
        let first: Int
        let count: Int
        let sum: CGFloat
        let lower: CGFloat
        let upper: CGFloat
        var top: CGFloat { min(upper, max(lower, sum / CGFloat(count))) }
    }
}
