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
    @State private var zoomed: PaneSlotID?
    @State private var workspace: WorkspaceLayout<String>?
    @State private var drawerResizeStart: Double?

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
        zoomed = nil
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
                if layout.drawerVisible {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 4)
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if drawerResizeStart == nil { drawerResizeStart = drawerHeight(layout.drawerHeight, available: geometry.size.height) }
                            workspace?.drawerHeight = drawerHeight((drawerResizeStart ?? 240) - value.translation.height, available: geometry.size.height)
                        }.onEnded { _ in drawerResizeStart = nil })
                        .accessibilityLabel("Terminal drawer height")
                        .accessibilityAdjustableAction { direction in
                            workspace?.drawerHeight = WorkspaceLayout<String>.resizedDrawerHeight(layout.drawerHeight,
                                by: direction == .increment ? 40 : -40, available: geometry.size.height)
                        }
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
                                Menu(title(session)) {
                                    Button("Select") { select(session) }
                                    ForEach(layout.groups) { group in
                                        Button("Move to \(title(group.selected)) tabs") { workspace?.move(session, to: group.id); select(session) }
                                        Button("Split beside \(title(group.selected))") { workspace?.split(session, beside: group.id, edge: .right); select(session) }
                                    }
                                }
                            }
                        }.menuStyle(.borderlessButton).fixedSize().draggable(layout.selectedTerminal ?? "")
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
                        .frame(height: drawerHeight(layout.drawerHeight, available: geometry.size.height))
                }
            }
        }
        .onAppear {
            workspace = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(WorkspaceLayout<String>.self, from: $0) }
                ?? .initial(for: worktree)
            reconcile()
            revealFocused()
            publishVisibility()
            viewer.workspaceCommandHandler = handleCommand
        }
        .onDisappear {
            viewer.workspaceCommandHandler = nil
            viewer.clearWorkspaceVisibility(identity: identity, worktreePath: worktree.path)
        }
        .onChange(of: worktree) { _, _ in reconcile(); viewer.workspaceCommandHandler = handleCommand }
        .onChange(of: focused) { _, id in
            revealFocused()
        }
        .onChange(of: workspace) { _, value in
            reconcileZoom()
            publishVisibility()
            if let value, let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
        }
        .onChange(of: zoomed) { _, _ in publishVisibility() }
    }

    private func drawerHeight(_ requested: Double, available: Double) -> Double {
        WorkspaceLayout<String>.clampedDrawerHeight(requested, available: available)
    }

    private var canvasZoom: PaneSlotID? {
        guard let zoomed, focused == nil || focused == zoomed,
              layout.groups.contains(where: { slot($0.selected) == zoomed }) else { return nil }
        return zoomed
    }

    private func revealFocused() {
        if zoomed != focused { zoomed = nil }
        if let focused, let session = layout.sessions.first(where: { slot($0) == focused }) { workspace?.select(session) }
        reconcileZoom()
    }

    private func reconcileZoom() {
        zoomed = canvasZoom
    }

    private func publishVisibility() {
        let canvas = layout.groups.map(\.selected)
        var sessions = Set(canvasZoom.flatMap { id in canvas.first { slot($0) == id } }.map { [$0] } ?? canvas)
        if layout.drawerVisible, let terminal = layout.selectedTerminal { sessions.insert(terminal) }
        viewer.setWorkspaceVisibleSessions(sessions, identity: identity, worktreePath: worktree.path)
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
                let tree = SplitTree(root: availableNode(node))
                return tree.withZoom(headers ? canvasZoom.flatMap { tree.containsLeaf($0) ? $0 : nil } : nil)
            }, set: { tree in
                guard headers else { return }
                updateGeometry(tree)
            }), focusedPaneSlotID: focused, theme: terminalManager.theme,
            onFocusTerminal: onFocus, agentScrollbackMap: agentScrollbackMap,
            paneHeader: headers ? { id in AnyView(header(id)) } : nil,
            paneDropTarget: headers ? { id, content in AnyView(dropTarget(id, content: content)) } : nil)
    }

    private func updateGeometry(_ tree: SplitTree) {
        func update(_ old: WorkspaceLayout<String>.Node, _ new: SplitTree.Node) -> WorkspaceLayout<String>.Node {
            guard case .split(let vertical, _, let first, let second) = old, case .split(let split) = new else { return old }
            return .split(vertical: vertical, ratio: split.ratio, first: update(first, split.left), second: update(second, split.right))
        }
        if let old = workspace?.root, let new = tree.root { workspace?.root = update(old, new) }
    }

    private func handleCommand(_ command: HostManagedPaneCommand, _ source: PaneSlotID) -> Bool {
        let canvas = SplitTree(root: layout.visiblePaneLayout(in: worktree.layout).flatMap(availableNode))
        var navigation = canvas
        if layout.drawerVisible, let terminal = layout.selectedTerminal.flatMap(slot) {
            navigation = SplitTree(root: canvas.root.map { .split(.init(direction: .vertical, ratio: 0.7, left: $0, right: .leaf(terminal))) } ?? .leaf(terminal))
        }
        func focus(_ id: PaneSlotID?) {
            guard let id, let session = layout.sessions.first(where: { slot($0) == id }) else { return }
            let preserve = zoomed != nil && terminalManager.splitPreserveZoomOnNavigation
            select(session)
            if preserve, layout.group(containing: session) != nil { zoomed = id }
        }
        switch command {
        case .focus(let direction): focus(navigation.spatialNeighbor(of: source, direction: direction.asSpatial))
        case .focusOrder(let forward):
            let sessions = layout.sessions
            if let index = sessions.firstIndex(where: { slot($0) == source }), !sessions.isEmpty {
                focus(slot(sessions[(index + (forward ? 1 : sessions.count - 1)) % sessions.count]))
            }
        case .toggleZoom: zoomed = canvas.containsLeaf(source) && zoomed != source ? source : nil
        case .equalize: updateGeometry(canvas.equalizing()); zoomed = nil
        case .resize(let direction, let amount):
            if let tree = try? canvas.resizing(target: source, direction: direction, pixels: amount,
                ancestorBounds: NSApp.keyWindow?.contentView?.bounds ?? CGRect(x: 0, y: 0, width: 1200, height: 800)) { updateGeometry(tree); zoomed = nil }
        case .split, .close, .surfaceClosed: return false
        }
        return true
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
                                if let agent = worktree.agents?.first(where: { $0.sessionName == session }) {
                                    AgentStatusBadge(status: agent.status,
                                        needsInput: worktree.layout?.leaves.first { $0.sessionName == session }?.attentionSource == .agentStop,
                                        failure: agent.failure,
                                        disconnected: slot(session).map { terminalManager.attachmentFailures[$0] != nil } ?? false,
                                        processObservation: agent.processObservation)
                                }
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
            agents: Set(worktree.agents?.compactMap(\.sessionName) ?? []), preservingSelection: true)
        reconcileZoom()
    }
}
