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
    public let coordinator: RemoteConnectionCoordinator?
    public let onSelect: (WorktreePanes) -> Void
    public let onSelectPane: (PaneLayoutNode.Leaf) -> Void

    public init(
        host: Host,
        theme: GhosttyThemeColors? = nil,
        coordinator: RemoteConnectionCoordinator? = nil,
        onSelect: @escaping (WorktreePanes) -> Void,
        onSelectPane: @escaping (PaneLayoutNode.Leaf) -> Void
    ) {
        self.host = host
        self.theme = theme
        self.coordinator = coordinator
        self.onSelect = onSelect
        self.onSelectPane = onSelectPane
    }

    public var body: some View {
        WorktreeListContent(
            host: host,
            theme: theme,
            includeRemoteWorktrees: coordinator?.isPaired(host) == true,
            remoteConnectionProvider: makeRemoteConnectionProvider(
                coordinator: coordinator,
                host: host,
                sessionName: "worktree-management"
            ),
            onSelect: onSelect,
            onSelectPane: onSelectPane
        )
        // Set on this iPhone-compact wrapper rather than inside
        // WorktreeListContent: the iPad sidebar uses `HostMenu` (in the
        // sidebar nav bar's `.topBarLeading` slot) as its sole host
        // indicator and a system nav-bar title there would duplicate
        // the host label as a second row above it (IPAD-1.2).
        .navigationTitle(host.label)
    }
}
#endif
