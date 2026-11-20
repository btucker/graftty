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

    func excerpts(focusedID: String?) -> ArraySlice<ScrollbackMapPreview> {
        let count = min(messages.count, 3)
        let start = messages.firstIndex { $0.id == focusedID }.map {
            min(messages.count - count, max(0, $0 - 1))
        } ?? messages.count - count
        return messages[start ..< start + count]
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
    let responseGist: (entry: ScrollbackMapEntry, gist: PeerMessageGist)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        TimelineView(.everyMinute) { _ in
            let now = Date.now
            let focusedIndex = groups.firstIndex { $0.messages.contains { $0.id == focusedID } }
            ScrollbackPreviewStack(width: cardWidth, height: height, gap: gap, focusY: focusY,
                                   maximumShift: maximumShift, focusedIndex: focusedIndex) {
                ForEach(groups) { group in
                    card(for: group, now: now)
                        .layoutValue(key: PreviewY.self, value: group.y)
                        .anchorPreference(key: PreviewBounds.self, value: .bounds) { [group.id: $0] }
                }
            }
            .backgroundPreferenceValue(PreviewBounds.self, connectors)
            .clipped()
        }
    }

    @ViewBuilder private func card(for group: ScrollbackMapPreviewGroup, now: Date) -> some View {
        let entry = group.messages[0].entry
        if group.messages.count == 1 {
            ScrollbackMapLabel(entry: entry, gist: gist(for: entry), width: cardWidth, now: now)
        } else {
            let excerpts = group.excerpts(focusedID: focusedID)
            let hiddenCount = group.messages.count - excerpts.count
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.speaker)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ScrollbackMapPalette(scheme: colorScheme).input)
                ForEach(excerpts) { message in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(message.entry.text)
                            .font(.caption)
                            .lineLimit(message.id == focusedID ? 3 : 1)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let age = message.entry.relativeAge(at: now) {
                            Text(age).font(.caption2).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                        }
                    }
                }
                if hiddenCount > 0 {
                    Text("+\(hiddenCount) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .modifier(ScrollbackMapPreviewFrame(width: cardWidth))
        }
    }

    private func gist(for entry: ScrollbackMapEntry) -> PeerMessageGist? {
        guard entry.kind == .peer else { return nil }
        return responseGist?.entry == entry ? responseGist?.gist : .immediate(entry.text)
    }

    private func connectors(for bounds: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            let visible = groups.compactMap { group -> (ScrollbackMapPreviewGroup, CGRect)? in
                guard let anchor = bounds[group.id] else { return nil }
                let rect = geometry[anchor]
                return rect.midY < height ? (group, rect) : nil
            }
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

private enum PreviewY: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

private enum PreviewBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct ScrollbackPreviewStack: Layout {
    let width: CGFloat
    let height: CGFloat
    let gap: CGFloat
    let focusY: CGFloat
    let maximumShift: CGFloat
    let focusedIndex: Int?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width + gap, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cardProposal = ProposedViewSize(width: width, height: nil)
        let heights = subviews.map { $0.sizeThatFits(cardProposal).height }
        let anchors = subviews.map { $0[PreviewY.self] }
        let tops = Self.tops(anchors: anchors, heights: heights, height: bounds.height, focusY: focusY,
                             maximumShift: maximumShift, focusedIndex: focusedIndex)
        for (subview, top) in zip(subviews, tops) {
            // Unplaced cards would default to the center, so place surplus cards past the clip edge.
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + (top ?? bounds.height)),
                          anchor: .topLeading, proposal: cardProposal)
        }
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
                let preferred = min(height - cardHeight, max(0, anchors[index] - cardHeight / 2))
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
