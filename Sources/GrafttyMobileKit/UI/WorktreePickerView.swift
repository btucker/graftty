#if canImport(UIKit)
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI

/// Thin wrapper around `WorktreeListContent` for the compact (iPhone) path.
/// Owns no extra state — the navigation push is the caller's concern via
/// the `onSelect` / `onSelectPane` callbacks. The iPad path uses
/// `WorktreeListContent` directly with different callbacks.
public struct WorktreePickerView: View {
    public var navigation: SidebarNavigationState? = nil
    public let feed: MultiHostFeed
    let project: SidebarProject?
    public let theme: GhosttyThemeColors?
    public let onSelect: (Host, WorktreePanes) -> Void
    public let onSelectPane: (Host, WorktreePanes, PaneLayoutNode.Leaf) -> Void
    private let onSelectWorktreeDetail: ((Host, WorktreePanes) -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate

    public init(
        feed: MultiHostFeed,
        theme: GhosttyThemeColors? = nil,
        onSelect: @escaping (Host, WorktreePanes) -> Void,
        onSelectPane: @escaping (Host, WorktreePanes, PaneLayoutNode.Leaf) -> Void,
        navigation: SidebarNavigationState? = nil,
        project: SidebarProject? = nil,
        onSelectWorktreeDetail: ((Host, WorktreePanes) -> Void)? = nil
    ) {
        self.navigation = navigation
        self.feed = feed
        self.project = project
        self.theme = theme
        self.onSelect = onSelect
        self.onSelectPane = onSelectPane
        self.onSelectWorktreeDetail = onSelectWorktreeDetail
    }

    public var body: some View {
        WorktreeListContent(
            feed: feed,
            theme: theme,
            isReadyToLoad: LiveSessionReadiness.isActive(
                scene: scenePhase,
                gateUnlocked: gate.isUnlocked
            ),
            onSelect: onSelect,
            onSelectPane: onSelectPane,
            navigation: navigation,
            project: project,
            onSelectWorktreeDetail: onSelectWorktreeDetail
        )
        .navigationTitle(project?.name ?? "Projects")
        .navigationBarTitleDisplayMode(project == nil ? .large : .inline)
    }
}
#endif
