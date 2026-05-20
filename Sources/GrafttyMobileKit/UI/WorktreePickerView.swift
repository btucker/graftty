#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// Thin wrapper around `WorktreeListContent` for the compact (iPhone) path.
/// Owns no extra state — the navigation push is the caller's concern via
/// the `onSelect` / `onSelectPane` callbacks. The iPad path uses
/// `WorktreeListContent` directly with different callbacks.
public struct WorktreePickerView: View {
    public let host: Host
    public let theme: GhosttyThemeColors?
    public let onSelect: (WorktreePanes) -> Void
    public let onSelectPane: (PaneLayoutNode.Leaf) -> Void

    public init(
        host: Host,
        theme: GhosttyThemeColors? = nil,
        onSelect: @escaping (WorktreePanes) -> Void,
        onSelectPane: @escaping (PaneLayoutNode.Leaf) -> Void
    ) {
        self.host = host
        self.theme = theme
        self.onSelect = onSelect
        self.onSelectPane = onSelectPane
    }

    public var body: some View {
        WorktreeListContent(
            host: host,
            theme: theme,
            onSelect: onSelect,
            onSelectPane: onSelectPane
        )
    }
}
#endif
