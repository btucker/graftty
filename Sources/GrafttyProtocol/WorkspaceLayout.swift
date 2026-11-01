import Foundation

/// Device-local presentation. Session references never own or stop processes.
public struct WorkspaceLayout<Session: Hashable & Codable & Sendable>: Codable, Sendable, Equatable {
    public enum Edge: String, Codable, Sendable, CaseIterable { case left, right, top, bottom }
    public struct Group: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public var sessions: [Session]
        public var selected: Session
        public init(id: UUID = UUID(), sessions: [Session], selected: Session) {
            self.id = id; self.sessions = sessions; self.selected = selected
        }
    }
    public indirect enum Node: Codable, Sendable, Equatable {
        case group(UUID)
        case split(vertical: Bool, ratio: Double, first: Node, second: Node)

        public func replacing(_ id: UUID, with replacement: Node?) -> Node? {
            switch self {
            case .group(let current): return current == id ? replacement : self
            case .split(let vertical, let ratio, let first, let second):
                let a = first.replacing(id, with: replacement)
                let b = second.replacing(id, with: replacement)
                if let a, let b { return .split(vertical: vertical, ratio: ratio, first: a, second: b) }
                return a ?? b
            }
        }

        public var groupIDs: [UUID] {
            switch self {
            case .group(let id): [id]
            case .split(_, _, let first, let second): first.groupIDs + second.groupIDs
            }
        }
    }

    public let version: Int
    public var root: Node?
    public private(set) var groups: [Group]
    public private(set) var terminals: [Session]
    public private(set) var selectedTerminal: Session?
    public private(set) var lastAgent: Session?
    /// The active presentation may be retained content with no live terminal.
    public private(set) var focusedSession: Session?
    public var drawerVisible: Bool
    public var drawerHeight: Double
    public var sessions: [Session] { groups.flatMap(\.sessions) + terminals }

    public init(root: Node? = nil, groups: [Group] = []) {
        version = 1
        self.root = root
        self.groups = groups
        terminals = []
        drawerVisible = false
        drawerHeight = 240
        lastAgent = groups.first?.selected
    }

    public static func clampedDrawerHeight(_ requested: Double, available: Double) -> Double {
        let maximum = available.isFinite ? max(0, available * 0.7) : 0
        return min(max(min(120, maximum), requested.isFinite ? requested : 240), maximum)
    }

    public static func resizedDrawerHeight(_ requested: Double, by delta: Double, available: Double) -> Double {
        clampedDrawerHeight(clampedDrawerHeight(requested, available: available) + delta, available: available)
    }

    public static func dropEdge(x: Double, y: Double, width: Double, height: Double) -> Edge? {
        if x < width * 0.2 { return .left }
        if x > width * 0.8 { return .right }
        if y < height * 0.2 { return .top }
        if y > height * 0.8 { return .bottom }
        return nil
    }

    public func group(containing session: Session) -> Group? { groups.first { $0.sessions.contains(session) } }

    public mutating func addAgent(_ session: Session) {
        guard !sessions.contains(session) else { select(session); return }
        if let index = lastAgent.flatMap({ group(containing: $0)?.id }).flatMap({ id in groups.firstIndex { $0.id == id } })
            ?? groups.indices.first {
            groups[index].sessions.append(session)
            groups[index].selected = session
        } else {
            let group = Group(sessions: [session], selected: session)
            groups.append(group)
            root = .group(group.id)
        }
        lastAgent = session
    }

    public mutating func addTerminal(_ session: Session) {
        guard !sessions.contains(session) else { select(session); return }
        terminals.append(session)
        selectedTerminal = session
        drawerVisible = true
    }

    public mutating func select(_ session: Session) {
        guard sessions.contains(session) else { return }
        focusedSession = session
        if terminals.contains(session) {
            selectedTerminal = session
            drawerVisible = true
        } else if let index = groups.firstIndex(where: { $0.sessions.contains(session) }) {
            groups[index].selected = session
            lastAgent = session
        }
    }

    /// Returns whether opening the drawer requires its first terminal.
    @discardableResult
    public mutating func openDrawer() -> Bool {
        let needsTerminal = !drawerVisible && terminals.isEmpty
        drawerVisible = true
        return needsTerminal
    }

    @discardableResult
    public mutating func hideDrawer() -> Session? {
        drawerVisible = false
        if let lastAgent { select(lastAgent) }
        return lastAgent
    }

    public mutating func remove(_ session: Session) {
        terminals.removeAll { $0 == session }
        if selectedTerminal == session { selectedTerminal = terminals.first }
        for i in groups.indices {
            groups[i].sessions.removeAll { $0 == session }
            if groups[i].selected == session, let replacement = groups[i].sessions.first { groups[i].selected = replacement }
        }
        for group in groups where group.sessions.isEmpty { root = root?.replacing(group.id, with: nil) }
        groups.removeAll { $0.sessions.isEmpty }
        if lastAgent == session { lastAgent = groups.first?.selected }
        if focusedSession == session { focusedSession = lastAgent ?? selectedTerminal }
    }

    public mutating func move(_ session: Session, to target: UUID) {
        guard sessions.contains(session), groups.contains(where: { $0.id == target }) else { return }
        if group(containing: session)?.id == target { select(session); return }
        remove(session)
        guard let index = groups.firstIndex(where: { $0.id == target }) else { return }
        groups[index].sessions.append(session)
        groups[index].selected = session
        lastAgent = session
    }

    public mutating func moveToDrawer(_ session: Session) {
        guard sessions.contains(session) else { return }
        remove(session)
        addTerminal(session)
    }

    public mutating func split(_ session: Session, beside target: UUID, edge: Edge) {
        guard sessions.contains(session), let destination = groups.first(where: { $0.id == target }),
              !(destination.sessions == [session]) else { return }
        remove(session)
        let group = Group(sessions: [session], selected: session)
        groups.append(group)
        let before = edge == .left || edge == .top
        root = root?.replacing(target, with: .split(vertical: edge == .top || edge == .bottom,
            ratio: 0.5, first: .group(before ? group.id : target), second: .group(before ? target : group.id)))
        lastAgent = session
    }

    public mutating func merge(_ source: UUID, into target: UUID) {
        guard source != target, let sourceGroup = groups.first(where: { $0.id == source }) else { return }
        for session in sourceGroup.sessions { move(session, to: target) }
    }

    public mutating func reconcile(live: [Session], agents: Set<Session>, retained: Set<Session> = [], completed: Set<Session> = [], preservingSelection: Bool = false) {
        let previous = self
        let liveSet = Set(live).union(retained)
        for session in sessions where !liveSet.contains(session) { remove(session) }
        for session in live where !sessions.contains(session) && !completed.contains(session) {
            if agents.contains(session) { addAgent(session) }
            else { addTerminal(session) }
        }
        if preservingSelection {
            for group in previous.groups { select(group.selected) }
            if let lastAgent = previous.lastAgent { select(lastAgent) }
            if let terminal = previous.selectedTerminal { select(terminal) }
            focusedSession = previous.focusedSession.flatMap { sessions.contains($0) ? $0 : nil }
            drawerVisible = previous.drawerVisible
        }
    }
}
