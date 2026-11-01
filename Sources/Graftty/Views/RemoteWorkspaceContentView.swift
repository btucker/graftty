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
    var attentionContext: SidebarWorktreeContext?
    var requestedAgent: String? = nil
    var consumeAgentRequest: () -> Void = {}
    var conversationRequest: @MainActor (String, AgentConversationAction) async throws -> WorktreeManagementResponse = { _, _ in
        .error(code: "unavailable", message: "The host connection is unavailable.", forceAllowed: false, shortStatus: nil)
    }
    @State private var zoomed: PaneSlotID?
    @State private var workspace: WorkspaceLayout<String>?
    @State private var drawerResizeStart: Double?

    private var layout: WorkspaceLayout<String> { workspace ?? .initial(for: worktree) }
    private var key: String { "remote.workspace.\(identity).\(worktree.path)" }
    private func slot(_ session: String) -> PaneSlotID? {
        viewer.existingTerminalID(identity: identity, worktreePath: worktree.path, sessionName: session)
            ?? worktree.agents?.first(where: { $0.presentationSessionName == session })?.retainedSlotID
                .flatMap(UUID.init(uuidString:)).map { PaneSlotID(id: $0) }
    }
    private func title(_ session: String) -> String {
        worktree.workspaceSessionTitle(session)
    }
    private func select(_ session: String) {
        zoomed = nil
        workspace?.select(session)
        if worktree.agents?.contains(where: { $0.presentationSessionName == session && $0.isCompleted }) == true {
            terminalManager.clearFocus()
        } else if let id = slot(session) { onFocus(id) }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                WorkspaceInputRequest(context: attentionContext, selectedSession: layout.focusedSession, onSelect: select)
                if let visible = layout.visiblePaneLayout(in: worktree.layout, retainedAgents: worktree.agents ?? []) {
                    surface(visible, headers: true)
                } else {
                    Text("No active agents").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if layout.drawerVisible {
                    HorizontalResizeDivider(label: "Terminal drawer height", onResize: { translation in
                        if drawerResizeStart == nil { drawerResizeStart = drawerHeight(layout.drawerHeight, available: geometry.size.height) }
                        workspace?.drawerHeight = drawerHeight((drawerResizeStart ?? 240) - translation, available: geometry.size.height)
                    }, onResizeEnd: { drawerResizeStart = nil })
                }
                HStack {
                    Button(action: toggleDrawer) { Label("Terminal", systemImage: "terminal").labelStyle(.iconOnly) }
                        .help(layout.drawerVisible ? "Hide terminal" : "Show terminal")
                    if layout.drawerVisible {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(layout.terminals, id: \.self) { session in
                                    Button { select(session) } label: {
                                        Text(title(session)).lineLimit(1).padding(.horizontal, 8).frame(height: 30)
                                            .workspaceTabUnderline(selected: layout.selectedTerminal == session, color: terminalManager.theme.foreground)
                                    }.draggable(WorkspaceTabDrag(session))
                                        .contextMenu {
                                            ForEach(layout.groups) { group in
                                                Button("Move to \(title(group.selected)) tabs") { workspace?.move(session, to: group.id); select(session) }
                                                Button("Split beside \(title(group.selected))") { workspace?.split(session, beside: group.id, edge: .right); select(session) }
                                            }
                                        }
                                }
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button(action: newTerminal) { Image(systemName: "plus") }.help("New terminal")
                }.buttonStyle(.plain).font(.caption).padding(.horizontal, 12).frame(height: 30)
                    .terminalDrawerHitArea(onToggle: toggleDrawer)
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
            showRequestedAgent()
            revealFocused()
            publishVisibility()
            viewer.workspaceCommandHandler = handleCommand
        }
        .onDisappear {
            viewer.workspaceCommandHandler = nil
            viewer.clearWorkspaceVisibility(identity: identity, worktreePath: worktree.path)
        }
        .onChange(of: requestedAgent) { _, _ in showRequestedAgent() }
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

    private func showRequestedAgent() {
        guard let requestedAgent, let agent = worktree.agents?.first(where: { $0.id == requestedAgent }),
              let session = agent.presentationSessionName else { return }
        if !layout.sessions.contains(session) { workspace?.addAgent(session) }
        select(session)
        consumeAgentRequest()
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
        if let selected = layout.focusedSession,
           worktree.agents?.contains(where: { $0.presentationSessionName == selected && $0.isCompleted }) == true {
            terminalManager.clearFocus()
            zoomed = nil
            return
        }
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
            onFocusTerminal: { id in
                if let session = layout.sessions.first(where: { slot($0) == id }) { select(session) }
            }, agentScrollbackMap: agentScrollbackMap,
            paneHeader: headers ? { id in AnyView(header(id)) } : nil,
            paneContent: { id in
                guard let agent = worktree.agents?.first(where: { $0.presentationSessionName.flatMap(slot) == id && $0.isCompleted }) else { return nil }
                return AnyView(AgentConversationView(agent: agent) { action in try await conversationRequest(agent.id, action) })
            },
            paneDropTarget: headers ? { id, content in AnyView(dropTarget(id, content: content)) } : nil,
            leadingContentInset: WorkspaceContentView.leadingContentInset)
    }

    private func updateGeometry(_ tree: SplitTree) {
        func update(_ old: WorkspaceLayout<String>.Node, _ new: SplitTree.Node) -> WorkspaceLayout<String>.Node {
            guard case .split(let vertical, _, let first, let second) = old, case .split(let split) = new else { return old }
            return .split(vertical: vertical, ratio: split.ratio, first: update(first, split.left), second: update(second, split.right))
        }
        if let old = workspace?.root, let new = tree.root { workspace?.root = update(old, new) }
    }

    private func handleCommand(_ command: HostManagedPaneCommand, _ source: PaneSlotID) -> Bool {
        let canvas = SplitTree(root: layout.visiblePaneLayout(in: worktree.layout, retainedAgents: worktree.agents ?? []).flatMap(availableNode))
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
            content.dropDestination(for: WorkspaceTabDrag.self) { sessions, location in
                guard let session = sessions.first?.session, layout.sessions.contains(session),
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
                                AgentProviderIcon(provider: worktree.agents?.first { $0.presentationSessionName == session }?.provider)
                                Text(title(session)).lineLimit(1)
                                    .fontWeight(group.selected == session ? .medium : .regular)
                                if let agent = worktree.agents?.first(where: { $0.presentationSessionName == session }) {
                                    AgentStatusBadge(status: agent.status,
                                        needsInput: (attentionContext ?? SidebarWorktreeContext(worktree: worktree)).needsInput(session: session),
                                        failure: agent.failure,
                                        disconnected: slot(session).map { terminalManager.attachmentFailures[$0] != nil } ?? false,
                                        processObservation: agent.processObservation)
                                }
                            }.padding(.horizontal, 12).padding(.vertical, 9)
                                .foregroundStyle(terminalManager.theme.foreground.opacity(worktree.agents?.contains(where: { $0.presentationSessionName == session && $0.isCompleted }) == true ? 0.4 : group.selected == session ? 1 : 0.65))
                                .overlay(alignment: .bottom) {
                                    Rectangle().fill(group.selected == session ? terminalManager.theme.foreground.opacity(0.55) : .clear)
                                        .frame(height: 2)
                                }
                        }.buttonStyle(.plain).draggable(WorkspaceTabDrag(session))
                            .modifier(WorkspaceTabDropTarget { source, after in
                                let sameGroup = layout.group(containing: source)?.id == group.id
                                if workspace?.moveTab(source, relativeTo: session, after: after) == true && !sameGroup { select(source) }
                            })
                            .contextMenu {
                                ForEach(WorkspaceLayout<String>.Edge.allCases, id: \.rawValue) { edge in
                                    Button("Split \(edge.rawValue)") { workspace?.split(session, beside: group.id, edge: edge); select(session) }
                                        .disabled(group.sessions.count < 2)
                                }
                                ForEach(layout.groups.filter { $0.id != group.id }) { destination in
                                    Button("Move to \(title(destination.selected)) tabs") { workspace?.move(session, to: destination.id); select(session) }
                                    Button("Merge into \(title(destination.selected)) tabs") { workspace?.merge(group.id, into: destination.id); select(session) }
                                }
                                if worktree.agents?.contains(where: { $0.presentationSessionName == session && $0.isCompleted }) == true {
                                    Button("Close tab") {
                                        workspace?.remove(session)
                                        if let next = layout.focusedSession { select(next) }
                                        else { terminalManager.clearFocus() }
                                    }
                                }
                                if worktree.agents?.contains(where: { $0.presentationSessionName == session }) != true {
                                    Button("Move to terminal drawer") { workspace?.moveToDrawer(session); select(session) }
                                }
                            }
                    }
                }
            }.font(.system(size: 13))
                .background { terminalManager.theme.background.worktreeHeaderWash() }
                .dropDestination(for: WorkspaceTabDrag.self) { sessions, _ in
                    guard let session = sessions.first?.session, layout.sessions.contains(session) else { return false }
                    workspace?.move(session, to: group.id); select(session); return true
                }
        }
    }
    private func toggleDrawer() {
        var next = layout
        if next.drawerVisible {
            let previous = next.hideDrawer()
            workspace = next
            if let previous { select(previous) }
        } else {
            let needsTerminal = next.openDrawer()
            workspace = next
            if needsTerminal { newTerminal() }
            else if let selected = next.selectedTerminal { select(selected) }
        }
    }

    private func newTerminal() {
        viewer.createDrawerTerminal()
    }

    private func reconcile() {
        workspace?.reconcile(live: worktree.layout?.leaves.map(\.sessionName) ?? [],
            agents: Set(worktree.agents?.compactMap(\.sessionName) ?? []),
            retained: Set(worktree.agents?.compactMap(\.presentationSessionName) ?? []),
            completed: Set(worktree.agents?.filter(\.isCompleted).compactMap(\.presentationSessionName) ?? []), preservingSelection: true)
        reconcileZoom()
        if let selected = layout.focusedSession, worktree.agents?.contains(where: { $0.presentationSessionName == selected && $0.isCompleted }) == true { terminalManager.clearFocus() }
    }
}
