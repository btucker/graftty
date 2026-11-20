import SwiftUI

struct ScrollbackMapPreview: Identifiable {
    let id: String
    let entry: ScrollbackMapEntry
    let y: CGFloat
}

struct ScrollbackMapPreviews: View {
    let previews: [ScrollbackMapPreview]
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
        TimelineView(.everyMinute) { context in
            ScrollbackPreviewStack(width: cardWidth, height: height, gap: gap, focusY: focusY,
                                   maximumShift: maximumShift, focusedIndex: previews.firstIndex { $0.id == focusedID }) {
                ForEach(previews) { preview in
                    ScrollbackMapLabel(entry: preview.entry, gist: gist(for: preview.entry),
                                       width: cardWidth, now: context.date)
                        .layoutValue(key: PreviewY.self, value: preview.y)
                        .anchorPreference(key: PreviewBounds.self, value: .bounds) { [preview.id: $0] }
                }
            }
            .backgroundPreferenceValue(PreviewBounds.self) { bounds in
                connectors(for: bounds)
            }
            .clipped()
        }
    }

    private func gist(for entry: ScrollbackMapEntry) -> PeerMessageGist? {
        guard entry.kind == .peer else { return nil }
        return responseGist?.entry == entry ? responseGist?.gist : .immediate(entry.text)
    }

    private func connectors(for bounds: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            let palette = ScrollbackMapPalette(scheme: colorScheme)
            let leadingOnLeft = layoutDirection == .leftToRight
            let railX = leadingOnLeft ? geometry.size.width - railCenter : railCenter
            Canvas { context, _ in
                for preview in previews {
                    guard let anchor = bounds[preview.id] else { continue }
                    let rect = geometry[anchor]
                    guard rect.midY < height else { continue }
                    let start = CGPoint(x: leadingOnLeft ? rect.maxX : rect.minX, y: rect.midY)
                    let end = CGPoint(x: railX, y: preview.y)
                    let line = Path { path in
                        path.move(to: start)
                        path.addLine(to: end)
                    }
                    let color = palette.mark(preview.entry.kind, incoming: preview.entry.isIncomingPeer)
                    context.stroke(line, with: .color(color.opacity(0.65)), lineWidth: 1)
                }
            }
        }
    }
}

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
