import Foundation
import GrafttyProtocol

public extension WorktreeEntry {
    var navigationTree: SplitTree {
        guard let layout = workspaceLayout, !layout.sessions.isEmpty else { return splitTree }
        let canvas = layout.visibleSplitTree
        guard layout.drawerVisible, let terminal = layout.selectedTerminal else { return canvas }
        guard let root = canvas.root else { return SplitTree(root: .leaf(terminal)) }
        return SplitTree(root: .split(.init(direction: .vertical, ratio: 0.7, left: root, right: .leaf(terminal))))
    }

    mutating func ensureWorkspaceLayout() {
        if workspaceLayout == nil { workspaceLayout = .preserving(splitTree) }
        for slot in agents.filter({ $0.launchOperationID != nil && $0.status != .closed }).compactMap(\.paneSlotID) where workspaceLayout?.terminals.contains(slot) == true {
            workspaceLayout?.remove(slot)
            workspaceLayout?.addAgent(slot)
        }
        workspaceLayout?.reconcile(live: splitTree.allLeaves, agents: Set(agents.compactMap(\.paneSlotID)))
    }
}

public extension WorkspaceLayout where Session == PaneSlotID {
    static func preserving(_ tree: SplitTree) -> Self {
        let groups = tree.allLeaves.map { Group(id: $0.id, sessions: [$0], selected: $0) }
        return Self(root: tree.root.map { presentationNode($0) { $0.id } }, groups: groups)
    }

    var visibleSplitTree: SplitTree {
        func render(_ node: Node) -> SplitTree.Node? {
            switch node {
            case .group(let id): return groups.first(where: { $0.id == id }).map { .leaf($0.selected) }
            case .split(let vertical, let ratio, let first, let second):
                let a = render(first), b = render(second)
                if let a, let b { return .split(.init(direction: vertical ? .vertical : .horizontal,
                    ratio: ratio, left: a, right: b)) }
                return a ?? b
            }
        }
        return SplitTree(root: root.flatMap(render))
    }

    mutating func updateGeometry(from tree: SplitTree) {
        guard Set(tree.allLeaves) == Set(groups.map(\.selected)) else { return }
        let groupIDs = Dictionary(uniqueKeysWithValues: groups.map { ($0.selected, $0.id) })
        root = tree.root.map { Self.presentationNode($0) { groupIDs[$0]! } }
    }

    private static func presentationNode(_ node: SplitTree.Node, groupID: (PaneSlotID) -> UUID) -> Node {
        switch node {
        case .leaf(let slot): .group(groupID(slot))
        case .split(let split): .split(vertical: split.direction == .vertical, ratio: split.ratio,
            first: presentationNode(split.left, groupID: groupID), second: presentationNode(split.right, groupID: groupID))
        }
    }
}
