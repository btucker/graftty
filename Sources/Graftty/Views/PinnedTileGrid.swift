import SwiftUI
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

/// Pinned agents as a grid that grows with them. It never scrolls on its own,
/// so a tile that lights up can't be hidden.
struct PinnedTileGrid<Tile: View>: View {
    let rows: [MergedWorktreeRow]
    @ViewBuilder let tile: (MergedWorktreeRow) -> Tile

    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: PinnedTile.minimumWidth), spacing: 6)]
    }

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 6) {
            ForEach(rows) { tile($0) }
        }
    }
}

/// A tile accepts the same drops a pinned row does. Tiles sit side by side,
/// so a drop lands before or after a tile by which half it falls on.
struct PinnedTileDropTarget: ViewModifier {
    var isEnabled: Bool
    /// `after` is true for the trailing half. Returns whether the drop was used.
    let onDrop: (WorktreeRowDrop, Bool) -> Bool
    @State private var width: CGFloat = PinnedTile.minimumWidth
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .dropDestination(for: WorktreeRowDrop.self) { values, location in
                guard isEnabled, let value = values.first else { return false }
                return onDrop(value, location.x > width / 2)
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isEnabled && isTargeted {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.18))
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Hovering a tile names it and shows the line its row would show, so a
/// pinned agent's question can be read without opening it.
struct PinnedTileHoverCard: ViewModifier {
    let name: String
    let host: String?
    let status: SidebarRowStatus
    let secondary: Color
    @State private var isHovering = false
    @State private var isShowing = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering = $0 }
            .task(id: isHovering) {
                guard isHovering else { isShowing = false; return }
                try? await Task.sleep(for: .milliseconds(450))
                if !Task.isCancelled { isShowing = true }
            }
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(name).font(.system(size: 12, weight: .semibold))
                        if let host { Text(host).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    if status != .none {
                        SidebarStatusLine(status: status, secondary: secondary)
                    }
                }
                .padding(10)
                .frame(minWidth: 160, maxWidth: 280, alignment: .leading)
            }
    }
}
