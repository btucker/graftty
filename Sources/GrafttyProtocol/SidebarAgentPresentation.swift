import Foundation

public enum SidebarAgentTitle {
    public static func display(terminalTitle: String, agentName: String?) -> String {
        terminalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? agentName ?? "" : terminalTitle
    }
}

public extension WorktreePanes {
    var sidebarAgentLeaves: [PaneLayoutNode.Leaf] {
        guard state == .running, !showsCreationProgress else { return [] }
        let sessions = Set((agents ?? []).filter { $0.status != "closed" }.compactMap(\.sessionName))
        return layout?.leaves.filter { sessions.contains($0.sessionName) } ?? []
    }
}
