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
            // LAYOUT-2.232: tiles are keyed by their row, which names the host.
            // A tile must not set its own `.id` from its path: two hosts can
            // keep a checkout at the same path, and the clash blanks a cell.
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
/// pinned agent's question can be read without opening it (LAYOUT-2.228).
struct PinnedTileHoverCard: ViewModifier {
    let name: String
    let host: String?
    let status: SidebarRowStatus

    func body(content: Content) -> some View {
        content.help(PinnedTile.hoverText(name: name, host: host, status: status))
    }
}
