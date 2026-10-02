import SwiftUI
import GrafttyProtocol

/// Shares folder disclosure and sibling-only move gestures across remote clients.
public struct SidebarWorktreeRows<Row: View>: View {
    public var worktrees: [WorktreePanes]
    public var allowsReordering: Bool
    public var onMove: (WorktreePanes, WorktreePanes, Bool) -> Void
    public var row: (WorktreePanes) -> Row
    public var rowInsets: EdgeInsets?
    public var folderIndent: CGFloat
    public var showsSections: Bool
    @State private var collapsed: Set<String> = []
    @AppStorage private var isPinnedCollapsed: Bool

    public init(worktrees: [WorktreePanes], allowsReordering: Bool = false,
                onMove: @escaping (WorktreePanes, WorktreePanes, Bool) -> Void = { _, _, _ in },
                rowInsets: EdgeInsets? = nil,
                folderIndent: CGFloat = 0,
                showsSections: Bool = true,
                @ViewBuilder row: @escaping (WorktreePanes) -> Row) {
        self.worktrees = worktrees; self.allowsReordering = allowsReordering
        self.onMove = onMove; self.row = row
        self.rowInsets = rowInsets
        self.folderIndent = folderIndent
        self.showsSections = showsSections
        let projectID = worktrees.first.map(SidebarProjection.projectID) ?? "empty"
        self._isPinnedCollapsed = AppStorage(wrappedValue: false, "sidebar.pinned.collapsed.\(projectID)")
    }

    @ViewBuilder public var body: some View {
        let sections = SidebarWorktreeSections(worktrees)
        if showsSections && sections.hasPinMetadata {
            rows(SidebarWorktreeTree.nodes(sections.tasks), section: "tasks:")
            SidebarWorktreeSectionHeader("Pinned Agents", isCollapsed: $isPinnedCollapsed)
            if !isPinnedCollapsed {
                rows(SidebarWorktreeTree.nodes(sections.pinned), section: "pinned:")
            }
        } else {
            rows(SidebarWorktreeTree.nodes(worktrees))
        }
    }

    private func rows(_ nodes: [SidebarWorktreeTree], section: String = "") -> AnyView {
        AnyView(ForEach(nodes) { node in
            if let worktree = node.worktree {
                row(worktree)
                    .moveDisabled(!allowsReordering || worktree.isMainCheckout || worktree.state.isInFlight)
            } else if let children = node.children {
                DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(section + node.id) }, set: {
                    if $0 { collapsed.remove(section + node.id) } else { collapsed.insert(section + node.id) }
                })) {
                    rows(children, section: section)
                        .padding(.leading, folderIndent)
                } label: { Label(node.name, systemImage: "folder").font(.callout) }
                .listRowInsets(rowInsets)
                .moveDisabled(true)
            }
        }.onMove { offsets, destination in
            guard allowsReordering, let source = offsets.first, source != destination, source + 1 != destination else { return }
            let target = destination > source ? destination - 1 : destination
            guard nodes.indices.contains(target), let moving = nodes[source].worktree,
                  let relativeTo = nodes[target].worktree else { return }
            onMove(moving, relativeTo, destination > source)
        })
    }
}
