import SwiftUI

/// A horizontally scrolling row of agent tabs that shrinks wide tabs to fit
/// the row before it resorts to scrolling.
public struct AgentTabStrip<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content
    @State private var width: CGFloat?

    public init(spacing: CGFloat = 2, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        // A horizontal scroll view proposes unlimited width to its content,
        // so the strip measures the visible row and passes that width in.
        ScrollView(.horizontal, showsIndicators: false) {
            AgentTabStripLayout(available: width, spacing: spacing) { content }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }
}

/// @spec LAYOUT-2.245
/// When agent tabs are wider than their row, the application shall shrink the widest tabs first to an equal width, no narrower than a minimum, truncating their titles in the middle, and scroll only the tabs that still do not fit.
public struct AgentTabStripLayout: Layout {
    public static let minimumTabWidth: CGFloat = 72

    var available: CGFloat?
    var spacing: CGFloat
    var minimum: CGFloat

    public init(available: CGFloat? = nil, spacing: CGFloat = 2, minimum: CGFloat = AgentTabStripLayout.minimumTabWidth) {
        self.available = available
        self.spacing = spacing
        self.minimum = minimum
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: subviews, proposal: proposal)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)), height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: subviews, proposal: proposal)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func widths(for subviews: Subviews, proposal: ProposedViewSize) -> [CGFloat] {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let isFixed = subviews.map { $0[AgentTabStripFixed.self] }
        let fixed = zip(ideals, isFixed).filter(\.1).reduce(0) { $0 + $1.0 + spacing }
        var tabs = AgentTabStripLayout.tabWidths(
            ideal: zip(ideals, isFixed).filter { !$0.1 }.map(\.0),
            available: available ?? proposal.width ?? .infinity, fixed: fixed, spacing: spacing, minimum: minimum
        ).makeIterator()
        return zip(ideals, isFixed).map { ideal, fixed in fixed ? ideal : tabs.next() ?? ideal }
    }

    /// Water-fills the tab budget: tabs narrower than an equal share keep their
    /// ideal width, and the rest share what remains equally. `fixed` covers the
    /// unshrinkable items together with their gaps.
    public static func tabWidths(ideal: [CGFloat], available: CGFloat, fixed: CGFloat, spacing: CGFloat,
                                 minimum: CGFloat = minimumTabWidth) -> [CGFloat] {
        var remaining = available - fixed - spacing * CGFloat(max(0, ideal.count - 1))
        guard ideal.reduce(0, +) > remaining else { return ideal }
        var unsettled = ideal.count
        for width in ideal.sorted() where width <= remaining / CGFloat(unsettled) {
            remaining -= width
            unsettled -= 1
        }
        let cap = max(minimum, remaining / CGFloat(max(1, unsettled)))
        return ideal.map { min($0, cap) }
    }
}

private enum AgentTabStripFixed: LayoutValueKey {
    static let defaultValue = false
}

public extension View {
    /// Keeps a control in an agent tab strip, such as the new-agent menu, at its ideal width.
    func agentTabStripFixed() -> some View {
        layoutValue(key: AgentTabStripFixed.self, value: true)
    }
}
