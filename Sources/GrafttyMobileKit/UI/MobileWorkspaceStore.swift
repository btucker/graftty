import Foundation
import GrafttyProtocol
import Observation

/// Device-local workspace state shared by the detail and keyboard command router.
@Observable
@MainActor
final class MobileWorkspaceStore {
    private var layouts: [String: WorkspaceLayout<String>] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(hostID: UUID, path: String) -> String { "workspace.ipad.\(hostID).\(path)" }

    func layout(hostID: UUID, worktree: WorktreePanes) -> WorkspaceLayout<String> {
        layouts[key(hostID: hostID, path: worktree.path)] ?? .initial(for: worktree)
    }

    func synchronize(hostID: UUID, worktree: WorktreePanes, focused: String?, revealFocused: Bool = true) {
        let key = key(hostID: hostID, path: worktree.path)
        var next = layouts[key] ?? defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode(WorkspaceLayout<String>.self, from: $0)
        } ?? .initial(for: worktree)
        next.reconcile(live: worktree.layout?.leaves.map(\.sessionName) ?? [],
            agents: Set(worktree.agents?.compactMap(\.sessionName) ?? []),
            retained: Set(worktree.agents?.compactMap(\.presentationSessionName) ?? []),
            completed: Set(worktree.agents?.filter(\.isCompleted).compactMap(\.presentationSessionName) ?? []),
            preservingSelection: !revealFocused && layouts[key] != nil)
        let restoringCompleted = layouts[key] == nil && next.focusedSession.map { selected in
            worktree.agents?.contains(where: { $0.presentationSessionName == selected && $0.isCompleted }) == true
        } == true
        if !restoringCompleted, let focused, revealFocused || layouts[key] == nil { next.select(focused) }
        save(next, key: key)
    }

    func update(hostID: UUID, worktree: WorktreePanes, _ action: (inout WorkspaceLayout<String>) -> Void) {
        var next = layout(hostID: hostID, worktree: worktree)
        action(&next)
        save(next, key: key(hostID: hostID, path: worktree.path))
    }

    private func save(_ layout: WorkspaceLayout<String>, key: String) {
        guard layouts[key] != layout else { return }
        layouts[key] = layout
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: key) }
    }

    func navigationLayout(hostID: UUID, worktree: WorktreePanes) -> PaneLayoutNode? {
        let workspace = layout(hostID: hostID, worktree: worktree)
        let canvas = workspace.visiblePaneLayout(in: worktree.layout, retainedAgents: worktree.agents ?? [])
        guard workspace.drawerVisible, let selected = workspace.selectedTerminal,
              let terminal = worktree.layout?.leaves.first(where: { $0.sessionName == selected }) else { return canvas }
        let drawer = PaneLayoutNode.leaf(sessionName: selected, title: terminal.title,
            attentionText: terminal.attentionText, isBusy: terminal.isBusy,
            attentionSource: terminal.attentionSource, attentionTimestamp: terminal.attentionTimestamp)
        return canvas.map { .split(direction: .vertical, ratio: 0.7, left: $0, right: drawer) } ?? drawer
    }

    func resize(hostID: UUID, worktree: WorktreePanes, path: IPadPaneTreePath, ratio: Double) {
        guard ratio.isFinite else { return }
        func resized(_ node: WorkspaceLayout<String>.Node, at path: ArraySlice<IPadPaneTreePath.Branch>) -> WorkspaceLayout<String>.Node {
            guard case .split(let vertical, let current, let first, let second) = node else { return node }
            guard let branch = path.first else {
                return .split(vertical: vertical, ratio: min(0.9, max(0.1, ratio)), first: first, second: second)
            }
            return .split(vertical: vertical, ratio: current,
                first: branch == .first ? resized(first, at: path.dropFirst()) : first,
                second: branch == .second ? resized(second, at: path.dropFirst()) : second)
        }
        update(hostID: hostID, worktree: worktree) { layout in
            layout.root = layout.root.map { resized($0, at: path.branches[...]) }
        }
    }

    static func previousAgent(_ previous: String?, in worktree: WorktreePanes) -> String? {
        let live = Set(worktree.layout?.leaves.map(\.sessionName) ?? [])
        let agents = worktree.agents?.filter { $0.status != "closed" }.compactMap(\.sessionName).filter(live.contains) ?? []
        return previous.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first
    }

    static func drawerHeight(_ height: Double, available: Double) -> Double {
        WorkspaceLayout<String>.clampedDrawerHeight(height, available: available)
    }
}

struct IPadPaneTreePath: Hashable {
    enum Branch: Hashable { case first, second }
    static let root = IPadPaneTreePath(branches: [])
    let branches: [Branch]

    func appending(_ branch: Branch) -> IPadPaneTreePath {
        IPadPaneTreePath(branches: branches + [branch])
    }
}

