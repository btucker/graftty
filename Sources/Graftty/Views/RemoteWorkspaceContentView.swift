import SwiftUI
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

/// Remote layout is saved on the viewing Mac. Host session ownership is unchanged.
struct RemoteWorkspaceContentView: View {
    @ObservedObject var viewer: RemoteWorktreeViewerController
    @ObservedObject var terminalManager: TerminalManager
    let worktree: WorktreePanes
    let identity: RemoteMacIdentity
    let focused: PaneSlotID?
    let onFocus: (PaneSlotID) -> Void
    var agentScrollbackMap: AgentScrollbackMap?
    @State private var workspace: WorkspaceLayout<String>?

    private var layout: WorkspaceLayout<String> { workspace ?? .initial(for: worktree) }
    private var key: String { "remote.workspace.\(identity).\(worktree.path)" }
    private func slot(_ session: String) -> PaneSlotID? {
        viewer.existingTerminalID(identity: identity, worktreePath: worktree.path, sessionName: session)
    }
    private func title(_ session: String) -> String {
        worktree.agents?.first { $0.sessionName == session }?.name
            ?? worktree.layout?.leaves.first { $0.sessionName == session }?.displayTitle ?? "Terminal"
    }
    private func select(_ session: String) {
        workspace?.select(session)
        if let id = slot(session) { onFocus(id) }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let visible = layout.visiblePaneLayout(in: worktree.layout) {
                    surface(visible, headers: true)
                } else {
                    Text("No active agents").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack {
                    Button {
                        if layout.drawerVisible {
                            if let previous = workspace?.hideDrawer() { select(previous) }
                        } else {
                            workspace?.drawerVisible = true
                            if let selected = layout.selectedTerminal { select(selected) }
                        }
                    } label: { Label("Terminal", systemImage: "terminal") }
                    if layout.drawerVisible {
                        Menu(layout.selectedTerminal.map(title) ?? "No terminals") {
                            ForEach(layout.terminals, id: \.self) { session in
                                Button(title(session)) { select(session) }
                            }
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer()
                    Button {
                        if let target = focused ?? viewer.splitTree.allLeaves.first {
                            viewer.performWorkspaceCommand(.split(.down), on: target)
                        }
                    } label: { Image(systemName: "plus") }.help("New terminal")
                }.buttonStyle(.plain).font(.caption).padding(.horizontal, 12).frame(height: 30)
                if layout.drawerVisible, let session = layout.selectedTerminal,
                   let leaf = worktree.layout?.leaves.first(where: { $0.sessionName == session }) {
                    surface(.leaf(sessionName: session, title: leaf.title, attentionText: leaf.attentionText,
                        isBusy: leaf.isBusy, attentionSource: leaf.attentionSource, attentionTimestamp: leaf.attentionTimestamp), headers: false)
                        .frame(height: min(layout.drawerHeight, geometry.size.height * 0.45))
                }
            }
        }
        .onAppear {
            workspace = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(WorkspaceLayout<String>.self, from: $0) }
                ?? .initial(for: worktree)
            reconcile()
        }
        .onChange(of: worktree) { _, _ in reconcile() }
        .onChange(of: focused) { _, id in
            if let session = worktree.layout?.leaves.first(where: { slot($0.sessionName) == id })?.sessionName {
                workspace?.select(session)
            }
        }
        .onChange(of: workspace) { _, value in
            if let value, let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    private func availableNode(_ node: PaneLayoutNode) -> SplitTree.Node? {
        switch node {
        case .leaf(let session, _, _, _, _, _): return slot(session).map { .leaf($0) }
        case .split(let axis, let ratio, let first, let second):
            let a = availableNode(first), b = availableNode(second)
            if let a, let b { return .split(.init(direction: axis == .vertical ? .vertical : .horizontal, ratio: ratio, left: a, right: b)) }
            return a ?? b
        }
    }

    private func surface(_ node: PaneLayoutNode, headers: Bool) -> some View {
        TerminalContentView(terminalManager: terminalManager,
            splitTree: Binding(get: {
                SplitTree(root: availableNode(node))
            }, set: { tree in
                guard headers else { return }
                func update(_ old: WorkspaceLayout<String>.Node, _ new: SplitTree.Node) -> WorkspaceLayout<String>.Node {
                    guard case .split(let vertical, _, let first, let second) = old, case .split(let split) = new else { return old }
                    return .split(vertical: vertical, ratio: split.ratio, first: update(first, split.left), second: update(second, split.right))
                }
                if let old = workspace?.root, let new = tree.root { workspace?.root = update(old, new) }
            }), focusedPaneSlotID: focused, theme: terminalManager.theme,
            onFocusTerminal: onFocus, agentScrollbackMap: agentScrollbackMap,
            paneHeader: headers ? { id in AnyView(header(id)) } : nil,
            paneDropTarget: headers ? { id, content in AnyView(dropTarget(id, content: content)) } : nil)
    }

    private func dropTarget(_ id: PaneSlotID, content: AnyView) -> some View {
        GeometryReader { geometry in
            content.dropDestination(for: String.self) { sessions, location in
                guard let session = sessions.first, layout.sessions.contains(session),
                      let group = layout.groups.first(where: { slot($0.selected) == id }) else { return false }
                if let edge = WorkspaceLayout<String>.dropEdge(x: location.x, y: location.y,
                    width: geometry.size.width, height: geometry.size.height) {
                    workspace?.split(session, beside: group.id, edge: edge)
                } else { workspace?.move(session, to: group.id) }
                select(session)
                return true
            }
        }
    }

    @ViewBuilder private func header(_ id: PaneSlotID) -> some View {
        if let group = layout.groups.first(where: { slot($0.selected) == id }) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(group.sessions, id: \.self) { session in
                        Button { select(session) } label: {
                            HStack(spacing: 6) {
                                AgentProviderIcon(provider: worktree.agents?.first { $0.sessionName == session }?.provider)
                                Text(title(session)).lineLimit(1)
                            }.padding(8).background(group.selected == session ? Color.primary.opacity(0.1) : .clear)
                        }.buttonStyle(.plain).draggable(session)
                            .contextMenu {
                                ForEach(WorkspaceLayout<String>.Edge.allCases, id: \.rawValue) { edge in
                                    Button("Split \(edge.rawValue)") { workspace?.split(session, beside: group.id, edge: edge); select(session) }
                                        .disabled(group.sessions.count < 2)
                                }
                                ForEach(layout.groups.filter { $0.id != group.id }) { destination in
                                    Button("Move to \(title(destination.selected)) tabs") { workspace?.move(session, to: destination.id); select(session) }
                                    Button("Merge into \(title(destination.selected)) tabs") { workspace?.merge(group.id, into: destination.id); select(session) }
                                }
                                if worktree.agents?.contains(where: { $0.sessionName == session }) != true {
                                    Button("Move to terminal drawer") { workspace?.moveToDrawer(session); select(session) }
                                }
                            }
                    }
                }
            }.font(.caption)
                .dropDestination(for: String.self) { sessions, _ in
                    guard let session = sessions.first, layout.sessions.contains(session) else { return false }
                    workspace?.move(session, to: group.id); select(session); return true
                }
        }
    }
    private func reconcile() {
        workspace?.reconcile(live: worktree.layout?.leaves.map(\.sessionName) ?? [],
            agents: Set(worktree.agents?.compactMap(\.sessionName) ?? []))
    }
}
