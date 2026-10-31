import Foundation

public extension WorkspaceLayout where Session == String {
    static func initial(for worktree: WorktreePanes) -> Self {
        guard let inventory = worktree.layout else { return Self() }
        guard let agents = worktree.agents else {
            var groups: [Group] = []
            func convert(_ node: PaneLayoutNode) -> Node {
                switch node {
                case .leaf(let session, _, _, _, _, _):
                    let group = Group(sessions: [session], selected: session)
                    groups.append(group)
                    return .group(group.id)
                case .split(let direction, let ratio, let first, let second):
                    return .split(vertical: direction == .vertical, ratio: ratio, first: convert(first), second: convert(second))
                }
            }
            let root = convert(inventory)
            return Self(root: root, groups: groups)
        }
        var layout = Self()
        layout.reconcile(live: inventory.leaves.map(\.sessionName), agents: Set(agents.compactMap(\.sessionName)))
        layout.drawerVisible = layout.groups.isEmpty
        return layout
    }

    func visiblePaneLayout(in inventory: PaneLayoutNode?) -> PaneLayoutNode? {
        guard let inventory else { return nil }
        let leaves = inventory.leaves
        func render(_ node: Node) -> PaneLayoutNode? {
            switch node {
            case .group(let id):
                guard let selected = groups.first(where: { $0.id == id })?.selected,
                      let leaf = leaves.first(where: { $0.sessionName == selected }) else { return nil }
                return .leaf(sessionName: leaf.sessionName, title: leaf.title, attentionText: leaf.attentionText,
                    isBusy: leaf.isBusy, attentionSource: leaf.attentionSource, attentionTimestamp: leaf.attentionTimestamp)
            case .split(let vertical, let ratio, let first, let second):
                let a = render(first), b = render(second)
                if let a, let b { return .split(direction: vertical ? .vertical : .horizontal, ratio: ratio, left: a, right: b) }
                return a ?? b
            }
        }
        return root.flatMap(render)
    }
}
