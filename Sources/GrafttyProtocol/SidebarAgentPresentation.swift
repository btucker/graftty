import Foundation

public extension WorktreePanes {
    var sidebarAgentLeaves: [PaneLayoutNode.Leaf] {
        guard state == .running, !showsCreationProgress else { return [] }
        let sessions = Set((agents ?? []).filter { $0.status != "closed" }.compactMap(\.sessionName))
        return layout?.leaves.filter { sessions.contains($0.sessionName) } ?? []
    }
}
