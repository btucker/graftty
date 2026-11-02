import Foundation
import GrafttyProtocol

public extension WorktreeEntry {
    /// Canvas zoom must never mount a drawer or a hidden tab a second time.
    var canvasTree: SplitTree {
        guard let layout = workspaceLayout else { return splitTree }
        let tree = layout.visibleSplitTree
        return tree.withZoom(splitTree.zoomed.flatMap {
            tree.containsLeaf($0) && (focusedPaneSlotID == nil || focusedPaneSlotID == $0) ? $0 : nil
        })
    }

    func newlyClosedAgent(viewedAgentID: String?, previousAgents: [ManagedAgent]) -> ManagedAgent? {
        guard let viewedAgentID else { return nil }
        return agents.first { agent in
            guard agent.id == viewedAgentID, agent.status == .closed,
                  let previous = previousAgents.first(where: { $0.id == agent.id }) else { return false }
            return previous.status != .closed
        }
    }

    /// Commands target the visible presentation, which may have no live process.
    var presentationPane: PaneSlotID? {
        if let layout = workspaceLayout, let focused = layout.focusedSession,
           layout.visibleSplitTree.containsLeaf(focused) || (layout.drawerVisible && layout.selectedTerminal == focused) {
            return focused
        }
        if let focusedPaneSlotID {
            if let group = workspaceLayout?.group(containing: focusedPaneSlotID) { return group.selected }
            if splitTree.containsLeaf(focusedPaneSlotID) { return focusedPaneSlotID }
        }
        return workspaceLayout?.lastAgent ?? splitTree.allLeaves.first
    }

    func hasCompletedContent(in slot: PaneSlotID) -> Bool {
        agents.contains { $0.presentationSlotID == slot && ($0.completion != nil || $0.status == .closed) }
    }

    @discardableResult
    mutating func showAgentTab(_ id: String) -> PaneSlotID? {
        guard let slot = agents.first(where: { $0.id == id })?.presentationSlotID else { return nil }
        ensureWorkspaceLayout()
        if workspaceLayout?.sessions.contains(slot) != true { workspaceLayout?.addAgent(slot) }
        workspaceLayout?.select(slot)
        return slot
    }

    @discardableResult
    mutating func dismissCompletedTab(_ slot: PaneSlotID) -> Bool {
        guard workspaceLayout?.sessions.contains(slot) == true, hasCompletedContent(in: slot) else { return false }
        workspaceLayout?.remove(slot)
        return true
    }

    var visiblePaneSlots: Set<PaneSlotID> {
        let canvas = canvasTree
        var slots = Set(canvas.zoomed.map { [$0] } ?? canvas.allLeaves)
        if let layout = workspaceLayout, layout.drawerVisible, let terminal = layout.selectedTerminal {
            slots.insert(terminal)
        }
        return slots
    }

    func ownsManagedAgent(in slot: PaneSlotID) -> Bool {
        agents.contains { $0.paneSlotID == slot && $0.status != .closed }
    }

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
        workspaceLayout?.reconcile(live: splitTree.allLeaves, agents: Set(agents.compactMap(\.paneSlotID)),
            retained: Set(agents.compactMap(\.presentationSlotID)),
            completed: Set(agents.filter { $0.completion != nil || $0.status == .closed }.compactMap(\.presentationSlotID)), preservingSelection: true)
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
