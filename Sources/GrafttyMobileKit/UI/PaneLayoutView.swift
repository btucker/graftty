#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// Renders a `PaneLayoutNode` tree as nested rectangles that mirror the
/// Mac sidebar's split layout. Leaves become tappable tiles labelled
/// with the pane's current title. Each split respects its ratio: a
/// horizontal split divides width by `ratio` (left takes that fraction);
/// a vertical split divides height. Works recursively for any depth.
public struct PaneLayoutView: View {
    public let layout: PaneLayoutNode
    public let onSelect: (_ sessionName: String) -> Void

    public init(
        layout: PaneLayoutNode,
        onSelect: @escaping (_ sessionName: String) -> Void
    ) {
        self.layout = layout
        self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { geo in
            render(layout, in: geo.size)
        }
        .padding(8)
    }

    /// Recursive, so has to return `AnyView` — Swift can't infer an
    /// opaque `some View` that references itself.
    private func render(_ node: PaneLayoutNode, in size: CGSize) -> AnyView {
        switch node {
        case let .leaf(sessionName, title):
            return AnyView(PaneTile(title: title.isEmpty ? sessionName : title) {
                onSelect(sessionName)
            })

        case let .split(direction, ratio, left, right):
            switch direction {
            case .horizontal:
                let leftWidth = max(0, size.width * CGFloat(ratio) - 2)
                let rightWidth = max(0, size.width * CGFloat(1 - ratio) - 2)
                return AnyView(HStack(spacing: 4) {
                    render(left, in: CGSize(width: leftWidth, height: size.height))
                        .frame(width: leftWidth)
                    render(right, in: CGSize(width: rightWidth, height: size.height))
                        .frame(width: rightWidth)
                })
            case .vertical:
                let topHeight = max(0, size.height * CGFloat(ratio) - 2)
                let bottomHeight = max(0, size.height * CGFloat(1 - ratio) - 2)
                return AnyView(VStack(spacing: 4) {
                    render(left, in: CGSize(width: size.width, height: topHeight))
                        .frame(height: topHeight)
                    render(right, in: CGSize(width: size.width, height: bottomHeight))
                        .frame(height: bottomHeight)
                })
            }
        }
    }
}

/// Leaf in the split tree — a tappable rounded rect with the pane title.
/// Title uses `.lineLimit(3)` + `.minimumScaleFactor` so small panes
/// still render something readable.
private struct PaneTile: View {
    let title: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            RoundedRectangle(cornerRadius: 10)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                )
                .overlay(
                    Text(title)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .padding(6)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
#endif
