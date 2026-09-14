import SwiftUI
import GrafttyProtocol

/// Shares folder disclosure and sibling-only move gestures across remote clients.
public struct SidebarWorktreeRows<Row: View>: View {
    public var worktrees: [WorktreePanes]
    public var allowsReordering: Bool
    public var onMove: (WorktreePanes, WorktreePanes, Bool) -> Void
    public var row: (WorktreePanes) -> Row
    @State private var collapsed: Set<String> = []

    public init(worktrees: [WorktreePanes], allowsReordering: Bool = false,
                onMove: @escaping (WorktreePanes, WorktreePanes, Bool) -> Void = { _, _, _ in },
                @ViewBuilder row: @escaping (WorktreePanes) -> Row) {
        self.worktrees = worktrees; self.allowsReordering = allowsReordering
        self.onMove = onMove; self.row = row
    }

    public var body: some View { rows(SidebarWorktreeTree.nodes(worktrees)) }

    private func rows(_ nodes: [SidebarWorktreeTree]) -> AnyView {
        AnyView(ForEach(nodes) { node in
            if let worktree = node.worktree {
                row(worktree)
                    .moveDisabled(!allowsReordering || worktree.isMainCheckout || worktree.state.isInFlight)
            } else if let children = node.children {
                DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(node.id) }, set: {
                    if $0 { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
                })) {
                    rows(children)
                } label: { Label(node.name, systemImage: "folder").font(.callout) }
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
