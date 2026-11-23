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
    let onFocus: (PaneSlotID?) -> Void
    let onPaneCommandTargetChange: (PaneSlotID?) -> Void
    var agentScrollbackMaps: [PaneSlotID: AgentScrollbackMap] = [:]
    var attentionContext: SidebarWorktreeContext?
    /// Context, shown beneath the gallery in one right-hand column (LAYOUT-2.252).
    var contextPanel: AnyView? = nil
    var requestedAgent: String? = nil
    var consumeAgentRequest: () -> Void = {}
    var launchAgent: @MainActor (String?, UUID) async throws -> String = { _, _ in
        throw AgentLaunchError("The host connection is unavailable.")
    }
    var conversationRequest: @MainActor (String, AgentConversationAction) async throws -> WorktreeManagementResponse = { _, _ in
        .error(code: "unavailable", message: "The host connection is unavailable.", forceAllowed: false, shortStatus: nil)
    }
    /// Chat for one of this worktree's agents, through the host connection.
    var chatConnection: @MainActor (String) -> AgentChatConnection? = { _ in nil }
    @State private var chatModels = AgentChatModelStore<String>()
    @State private var zoomed: PaneSlotID?
    @State private var workspace: WorkspaceLayout<String>?
    @State private var drawerResizeStart: Double?
    @State private var pendingAgentSession: String?

    private var layout: WorkspaceLayout<String> { workspace ?? .initial(for: worktree) }
    private var paneCommandTarget: PaneSlotID? {
        guard let session = layout.focusedSession, !showsNonTerminalContent(session) else { return nil }
        return slot(session)
    }
    private func slot(_ session: String) -> PaneSlotID? {
        viewer.existingTerminalID(identity: identity, worktreePath: worktree.path, sessionName: session)
            ?? worktree.agents?.first(where: { $0.presentationSessionName == session })?.retainedSlotID
                .flatMap(UUID.init(uuidString:)).map { PaneSlotID(id: $0) }
    }
    private func title(_ session: String) -> String {
        worktree.workspaceSessionTitle(session)
    }
    /// The agent whose conversation the host can show in Chat for this tab.
    private func chatAgent(_ session: String) -> AgentSessionInfo? {
        worktree.chatAgent(session: session)
    }
    private func showsChat(_ session: String) -> Bool { chatAgent(session) != nil && layout.showsChat(session) }
    private func showsNonTerminalContent(_ session: String) -> Bool {
        showsChat(session) || worktree.agents?.contains(where: { $0.presentationSessionName == session && $0.isCompleted }) == true
    }
    /// AGENT-6.187: only this viewer's saved layout changes. Nothing is sent to the host.
    private func setView(_ session: String, chat: Bool) {
        workspace?.setShowsChat(chat, for: session)
        select(session)
    }
    private func chatContent(_ session: String) -> AnyView? {
        guard showsChat(session), let agent = chatAgent(session), let connection = chatConnection(agent.id) else { return nil }
        return AnyView(AgentChatView(model: chatModels.model(for: session), tabID: "\(agent.id)/\(agent.assignmentID ?? "")", agentName: agent.name,
                                     connection: connection, showTerminal: { setView(session, chat: false) })
            .foregroundStyle(terminalManager.theme.foreground).tint(terminalManager.theme.foreground).background(terminalManager.theme.background))
    }
    private func select(_ session: String) {
        zoomed = nil
        workspace?.select(session)
        if showsNonTerminalContent(session) {
            onFocus(nil)
        } else if let id = slot(session) { onFocus(id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            stage
                .overlay(alignment: .topTrailing) {
                    if !showsGallery && !layout.groups.isEmpty {
                        WorkspaceGalleryOpener(agentCount: galleryAgents.count,
                            askingCount: galleryAgents.count { context.needsInput(session: $0) },
                            theme: terminalManager.theme) { workspace?.galleryVisible = true }
                            .padding(.top, 6).padding(.trailing, 22)
                    }
                }
            if let width = WorkspaceGalleryColumn.width(showsGallery: showsGallery, showsContext: contextPanel != nil) {
                VStack(spacing: 0) {
                    if showsGallery { gallery.frame(maxHeight: contextPanel == nil ? .infinity : 320) }
                    if let contextPanel {
                        if showsGallery { terminalManager.theme.foreground.opacity(0.08).frame(height: 1) }
                        contextPanel.frame(maxHeight: .infinity)
                    }
                }
                .frame(width: width)
                .zIndex(1)
            }
        }
        .onAppear {
            workspace = viewer.workspaceLayout(identity: identity, worktree: worktree)
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
        .onChange(of: paneCommandTarget, initial: true) { _, pane in
            onPaneCommandTargetChange(pane)
        }
        .onChange(of: worktree) { _, _ in reconcile(); showNewAgent(); viewer.workspaceCommandHandler = handleCommand }
        .onChange(of: focused) { _, id in
            revealFocused()
        }
        .onChange(of: workspace) { _, value in
            reconcileZoom()
            publishVisibility()
            if let value { viewer.saveWorkspaceLayout(value, identity: identity, worktreePath: worktree.path) }
        }
        .onChange(of: zoomed) { _, _ in publishVisibility() }
    }

    private var context: SidebarWorktreeContext { attentionContext ?? SidebarWorktreeContext(worktree: worktree) }
    private func agent(_ session: String) -> AgentSessionInfo? {
        worktree.agents?.first { $0.presentationSessionName == session }
    }
    private var galleryAgents: [String] { layout.gallerySessions.filter { agent($0) != nil } }
    private var showsGallery: Bool { layout.showsGallery(agentCount: galleryAgents.count) }

    private var gallery: some View {
        WorkspaceGallery(tiles: galleryAgents.map(tileModel), theme: terminalManager.theme,
            onStage: stage,
            onJump: { session, row in
                stage(session)
                DispatchQueue.main.async { slot(session).flatMap(terminalManager.handle(for:))?.scrollbackMapModel.scroll(toRow: row) }
            },
            onMove: { source, target, after in _ = workspace?.moveTile(source, relativeTo: target, after: after) },
            onCollapse: { workspace?.galleryVisible = false },
            newAgent: {
                newAgentMenu(label: AnyView(AgentGalleryEmptyTile(foreground: terminalManager.theme.foreground)))
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
            },
            tileMenu: { session in tileMenu(session) })
    }

    private func tileModel(_ session: String) -> WorkspaceGalleryTileModel {
        let info = agent(session)
        let asking = context.needsInput(session: session)
        let completed = info?.isCompleted == true
        let status = info.map { AgentAssignmentStatus(agent: $0, needsInput: asking).label } ?? "Terminal"
        return WorkspaceGalleryTileModel(id: session,
            handle: completed ? nil : slot(session).flatMap(terminalManager.handle(for:)),
            title: title(session),
            status: AgentTileStatus(needsInput: asking,
                isBusy: worktree.layout?.leaves.first { $0.sessionName == session }?.isBusy == true,
                isCompleted: completed, isCached: false, question: context.question(session: session),
                result: info?.result, statusLabel: status),
            isOnStage: layout.isOnStage(session), scrollback: slot(session).flatMap { agentScrollbackMaps[$0] })
    }

    private func stage(_ session: String) {
        workspace?.stage(session)
        select(session)
    }

    @ViewBuilder private func tileMenu(_ session: String) -> some View {
        if !layout.isOnStage(session), let target = layout.focusedGroupID {
            Button("Put on stage") { stage(session) }
            Button("Show beside the stage") { workspace?.split(session, beside: target, edge: .right); select(session) }
        } else if let group = layout.group(containing: session), layout.groups.count > 1 {
            Button("Remove from stage") { removePane(group.id) }
        }
        if agent(session)?.isCompleted == true {
            Button("Dismiss") {
                workspace?.remove(session)
                if let next = layout.focusedSession { select(next) } else { terminalManager.clearFocus() }
            }
        }
    }

    private func removePane(_ id: UUID) {
        _ = workspace?.removePane(id)
        if let next = layout.focusedSession { select(next) }
    }

    private var stage: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let visible = layout.visiblePaneLayout(in: worktree.layout, retainedAgents: worktree.agents ?? []) {
                    surface(visible, headers: true)
                } else {
                    VStack(spacing: 12) {
                        Text("No active agents").font(.headline)
                        newAgentMenu().controlSize(.large)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
    }

    private func newAgentMenu(label: AnyView? = nil) -> some View {
        NewAgentMenu(label: label) { provider, operationID in
            let session = try await launchAgent(provider, operationID)
            try Task.checkCancellation()
            pendingAgentSession = session
            showNewAgent()
        }
    }

    private func showNewAgent() {
        guard viewer.selectedRemoteIdentity == identity, viewer.selectedRemoteWorktreePath == worktree.path else {
            pendingAgentSession = nil
            return
        }
        guard let session = pendingAgentSession,
              worktree.layout?.leaves.contains(where: { $0.sessionName == session }) == true else { return }
        workspace?.addAgent(session)
        select(session)
        pendingAgentSession = nil
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
            onFocus(nil)
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
            }, agentScrollbackMaps: agentScrollbackMaps,
            paneHeader: headers ? { id in AnyView(header(id)) } : nil,
            paneBanner: headers ? { id in
                guard let group = layout.groups.first(where: { slot($0.selected) == id }), attentionContext?.question != nil, group.id == layout.focusedGroupID else { return nil }
                return AnyView(WorkspaceInputRequest(context: attentionContext, selectedSession: layout.focusedSession, onSelect: stage))
            } : nil,
            paneContent: { id in
                if let session = layout.sessions.first(where: { slot($0) == id }), let chat = chatContent(session) {
                    return chat
                }
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

    /// A stage pane's slim header: names a split pane and removes it from the
    /// stage, and holds the Chat / Terminal switch for an agent that offers Chat.
    @ViewBuilder private func header(_ id: PaneSlotID) -> some View {
        let offersChat = chatAgent(layout.groups.first(where: { slot($0.selected) == id })?.selected ?? "") != nil
        if let group = layout.groups.first(where: { slot($0.selected) == id }), layout.groups.count > 1 || offersChat {
            HStack(spacing: 6) {
                if layout.groups.count > 1 {
                    AgentStatusDot(dot: tileModel(group.selected).status.dot)
                    Text(title(group.selected)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if offersChat {
                    AgentChatSwitch(showsChat: Binding(get: { showsChat(group.selected) },
                                                       set: { setView(group.selected, chat: $0) }))
                        .controlSize(.small)
                }
                if layout.groups.count > 1 {
                    Button { removePane(group.id) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Remove from stage").accessibilityLabel("Remove from stage")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(terminalManager.theme.foreground.opacity(layout.focusedGroupID == group.id ? 0.85 : 0.55))
            .padding(.horizontal, 10).frame(minHeight: 24)
            .background { terminalManager.theme.background.worktreeHeaderWash() }
            .overlay(alignment: .bottom) { terminalManager.theme.foreground.opacity(0.08).frame(height: 1) }
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
        workspace?.reconcile(with: worktree, preservingSelection: true)
        chatModels.prune(keeping: Set(layout.sessions))
        reconcileZoom()
        if let selected = layout.focusedSession, showsNonTerminalContent(selected) { onFocus(nil) }
    }
}
