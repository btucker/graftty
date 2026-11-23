#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

/// The regular-width workspace renders device-local tabs, splits, and a drawer.
/// Terminal attachments are retained by RootView across presentation changes.
struct MultiPaneDetailView: View {
    let host: Host
    let worktree: WorktreePanes
    let theme: GhosttyThemeColors
    let focusedPaneId: String?
    let pendingFocusRequests: Int
    let onFocusRequestsConsumed: () -> Void
    let ghosttyCommandContext: MobileGhosttyCommandContext
    let onSelectPane: (String) -> Void
    let onBackToWorktrees: () -> Void
    let workspaceStore: MobileWorkspaceStore
    var onNewTerminal: () -> Void = {}
    var attentionContext: SidebarWorktreeContext? = nil
    /// IPAD-1.31: each increment toggles the drawer from the iPad toolbar.
    var drawerToggleRequests = 0
    private var context: SidebarWorktreeContext { attentionContext ?? SidebarWorktreeContext(worktree: worktree) }

    @Environment(\.retainedMobilePanes) private var retainedPanes
    @State private var drawerResizeStart: Double?
    /// One Chat model per tab, so a draft survives a tab change.
    @State private var chatModels = AgentChatModelStore<String>()
    @State private var retentionOwner = UUID()
    /// The tree's only keyboard subscription; embedded panes read it from
    /// the environment (IPAD-2.10).
    @State private var keyboardFrame = KeyboardFrameObservation()

    var body: some View {
        HStack(spacing: 0) {
            stage
                .overlay(alignment: .topTrailing) {
                    if !showsGallery && !currentWorkspace.groups.isEmpty && !worktree.showsCreationProgress {
                        Button { mutate { $0.galleryVisible = true } } label: {
                            Label(galleryAgents.isEmpty || galleryAgents.count == 1 ? "Agents" : "Agents · \(galleryAgents.count)",
                                  systemImage: galleryAgents.count <= 1 ? "plus" : "rectangle.stack")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12).frame(minHeight: 36)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(theme.foreground)
                        .padding(.top, 6).padding(.trailing, 44)
                        .accessibilityIdentifier("workspace.gallery.open")
                    }
                }
            if showsGallery && !worktree.showsCreationProgress {
                MobileAgentGalleryColumn(host: host, worktree: worktree, context: context, agents: galleryAgents,
                    onStage: Set(currentWorkspace.gallerySessions.filter(currentWorkspace.isOnStage)), theme: theme,
                    onSelect: stageSession,
                    onJump: { session, row in stageSession(session) ; _ = row },
                    onNewAgent: onSelectPane,
                    onMove: { source, target, after in mutate { _ = $0.moveTile(source, relativeTo: target, after: after) } },
                    onCollapse: { mutate { $0.galleryVisible = false } })
                    .zIndex(1)
            }
        }
    }

    private var galleryAgents: [MobileGalleryAgent] {
        MobileGalleryAgent.agents(in: worktree, context: context, order: currentWorkspace.gallerySessions)
            .filter { currentWorkspace.sessions.contains($0.id) }
    }
    private var showsGallery: Bool { currentWorkspace.showsGallery(agentCount: galleryAgents.count) }

    private func stageSession(_ session: String) {
        mutate { $0.stage(session) }
        onSelectPane(session)
    }

    private var stage: some View {
        GeometryReader { geometry in
            if worktree.showsCreationProgress {
                MobileCreationDetailView(host: host, worktree: worktree, theme: theme)
            } else if worktree.layout != nil || currentWorkspace.root != nil {
                VStack(spacing: 0) {
                    if let visible = currentWorkspace.visiblePaneLayout(in: worktree.layout, retainedAgents: worktree.agents ?? []) {
                        render(visible, at: .root)
                    } else {
                        emptyWorkspace
                    }
                    if currentWorkspace.drawerVisible { drawerResizeHandle(available: geometry.size.height) }
                    // IPAD-1.31: the toolbar toggles the drawer; no bar while it's closed.
                    if currentWorkspace.drawerVisible { terminalDrawerHeader }
                    if currentWorkspace.drawerVisible, let session = currentWorkspace.selectedTerminal,
                       let leaf = worktree.layout?.leaves.first(where: { $0.sessionName == session }) {
                        render(.leaf(sessionName: session, title: leaf.title, attentionText: leaf.attentionText,
                            isBusy: leaf.isBusy, attentionSource: leaf.attentionSource, attentionTimestamp: leaf.attentionTimestamp), at: .root)
                            .frame(height: MobileWorkspaceStore.drawerHeight(currentWorkspace.drawerHeight, available: geometry.size.height))
                    } else if currentWorkspace.drawerVisible {
                        Button("New terminal") { onNewTerminal() }
                            .frame(maxWidth: .infinity)
                            .frame(height: MobileWorkspaceStore.drawerHeight(currentWorkspace.drawerHeight, available: geometry.size.height))
                    }
                }
            } else {
                emptyWorkspace
            }
        }
        .onAppear { reconcileWorkspace(revealFocused: true) }
        .onDisappear { retainedPanes?.retainWorkspace([], owner: retentionOwner) }
        .onChange(of: worktree) { _, _ in reconcileWorkspace(revealFocused: false) }
        .onChange(of: drawerToggleRequests) { _, _ in toggleDrawer() }
        .onChange(of: focusedPaneId) { _, selected in
            if let selected { mutate { $0.select(selected) } }
        }
        .environment(\.multiPaneKeyboardFrame, keyboardFrame)
        .padding(.bottom, keyboardFrame.bottomInset)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onKeyboardBottomInsetChange { inset in
            keyboardFrame = KeyboardFrameObservation(bottomInset: inset, sequence: keyboardFrame.sequence &+ 1)
        }
        .animation(.easeInOut(duration: 0.25), value: keyboardFrame.bottomInset)
    }

    private var emptyWorkspace: some View {
        ContentUnavailableView {
            Label("No active agents", systemImage: "terminal")
        } actions: {
            MobileNewAgentMenu(host: host, worktree: worktree.path, onSelect: onSelectPane)
        }
    }

    private func render(
        _ node: PaneLayoutNode,
        at path: IPadPaneTreePath
    ) -> AnyView {
        switch node {
        case let .leaf(sessionName, title, _, _, _, _):
            let isFocused = Self.isFocused(
                sessionName: sessionName,
                focusedPaneId: focusedPaneId
            )
            let isUnfocused = Self.isUnfocused(
                sessionName: sessionName,
                focusedPaneId: focusedPaneId
            )
            return AnyView(
                GeometryReader { geometry in
                    VStack(spacing: 0) {
                        if let agent = worktree.agents?.first(where: { $0.presentationSessionName == sessionName && $0.isCompleted }) {
                            if let group = currentWorkspace.group(containing: sessionName) { stagePaneHeader(group) }
                            MobileAgentConversationView(host: host, worktreePath: worktree.path, agent: agent)
                                .onTapGesture { onSelectPane(sessionName) }
                                .overlay(alignment: .top) {
                                    if currentWorkspace.group(containing: sessionName)?.id == inputRequestGroupID { inputRequestBanner }
                                }
                                .clipped()
                        } else {
                        MultiPaneLeafView(
                            host: host,
                            worktreePath: worktree.path,
                            sessionName: sessionName,
                            title: title.isEmpty ? sessionName : title,
                            theme: theme,
                            isFocused: isFocused,
                            isUnfocused: isUnfocused,
                            pendingFocusRequests: isFocused ? pendingFocusRequests : 0,
                            onFocusRequestsConsumed: onFocusRequestsConsumed,
                            ghosttyCommandContext: ghosttyCommandContext,
                            onSelect: {
                                guard focusedPaneId != sessionName else { return }
                                onSelectPane(sessionName)
                            },
                            onBackToWorktrees: onBackToWorktrees,
                            retainedPanes: retainedPanes,
                            paneHeader: currentWorkspace.group(containing: sessionName).flatMap { group in
                                currentWorkspace.groups.count > 1 || worktree.chatAgent(session: group.selected) != nil
                                    ? AnyView(stagePaneHeader(group)) : nil
                            },
                            paneBanner: currentWorkspace.group(containing: sessionName)?.id == inputRequestGroupID
                                ? AnyView(inputRequestBanner) : nil,
                            showsChat: showsChat(sessionName),
                            chatModel: showsChat(sessionName) ? chatModels.model(for: sessionName) : nil,
                            onShowTerminal: { setShowsChat(false, for: sessionName) }
                        )
                        .id(sessionName)
                        }
                    }
                    .dropDestination(for: WorkspaceTabDrag.self) { sessions, location in
                        guard let session = sessions.first?.session, currentWorkspace.sessions.contains(session),
                              let group = currentWorkspace.group(containing: sessionName) else { return false }
                        if let edge = WorkspaceLayout<String>.dropEdge(x: location.x, y: location.y,
                            width: geometry.size.width, height: geometry.size.height) {
                            mutate { $0.split(session, beside: group.id, edge: edge) }
                        } else { mutate { $0.move(session, to: group.id) } }
                        onSelectPane(session)
                        return true
                    }
                }
            )

        case let .split(direction, ratio, first, second):
            return AnyView(
                MultiPaneSplitNode(
                    direction: direction,
                    sourceRatio: ratio,
                    first: render(first, at: path.appending(.first)),
                    second: render(second, at: path.appending(.second)),
                    onRatioChange: { ratio in
                        workspaceStore.resize(hostID: host.id, worktree: worktree,
                            path: path, ratio: ratio)
                    }
                )
                .id(path)
            )
        }
    }

    /// LAYOUT-2.196: a live question shows at the top of the focused stage
    /// pane, whichever agent asks, so it can be answered without switching.
    private var inputRequestGroupID: UUID? {
        guard context.question != nil else { return nil }
        return focusedPaneId.flatMap { currentWorkspace.group(containing: $0)?.id } ?? currentWorkspace.focusedGroupID
    }

    private var inputRequestBanner: some View {
        WorkspaceInputRequest(context: context, selectedSession: focusedPaneId, onSelect: stageSession)
    }

    private var currentWorkspace: WorkspaceLayout<String> { workspaceStore.layout(hostID: host.id, worktree: worktree) }
    private func mutate(_ action: (inout WorkspaceLayout<String>) -> Void) {
        workspaceStore.update(hostID: host.id, worktree: worktree, action)
    }
    private func reconcileWorkspace(revealFocused: Bool) {
        let previous = Set(currentWorkspace.sessions)
        let live = Set(worktree.layout?.leaves.map(\.sessionName) ?? [])
        chatModels.prune(keeping: live)
        retainedPanes?.retainWorkspace(Set(live.map { .init(hostID: host.id, sessionName: $0) }), owner: retentionOwner)
        workspaceStore.synchronize(hostID: host.id, worktree: worktree, focused: focusedPaneId, revealFocused: revealFocused)
        if let selected = currentWorkspace.focusedSession, selected != focusedPaneId,
           worktree.agents?.contains(where: { $0.presentationSessionName == selected && $0.isCompleted }) == true {
            onSelectPane(selected)
        }
        for session in previous.subtracting(live) {
            retainedPanes?.remove(.init(hostID: host.id, sessionName: session))
        }
    }
    private func selectSession(_ session: String) {
        mutate { $0.select(session) }
        onSelectPane(session)
    }
    private func sessionTitle(_ session: String) -> String {
        worktree.workspaceSessionTitle(session)
    }
    private func showsChat(_ session: String) -> Bool {
        worktree.chatAgent(session: session) != nil && currentWorkspace.showsChat(session)
    }
    /// AGENT-6.187: only this device's saved layout changes. Nothing is sent to the host.
    private func setShowsChat(_ value: Bool, for session: String) {
        mutate { $0.setShowsChat(value, for: session) }
        onSelectPane(session)
    }

    /// A stage pane's slim header: in a split stage it names the pane and lets
    /// it leave the stage without closing its agent; an agent that offers Chat
    /// shows its Chat / Terminal switch here.
    @ViewBuilder private func stagePaneHeader(_ group: WorkspaceLayout<String>.Group) -> some View {
        let split = currentWorkspace.groups.count > 1
        let offersChat = worktree.chatAgent(session: group.selected) != nil
        if split || offersChat {
            HStack(spacing: 6) {
                if split {
                    AgentStatusDot(dot: galleryAgents.first { $0.id == group.selected }?.status.dot)
                    Text(sessionTitle(group.selected)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if offersChat {
                    AgentChatSwitch(showsChat: Binding(get: { showsChat(group.selected) },
                                                        set: { setShowsChat($0, for: group.selected) }))
                }
                if split {
                    Button {
                        mutate { _ = $0.removePane(group.id) }
                        if let next = currentWorkspace.focusedSession { onSelectPane(next) }
                    } label: { Image(systemName: "xmark").frame(width: 44, height: 36) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove from stage")
                }
            }
            .font(.footnote)
            .foregroundStyle(theme.foreground.opacity(focusedPaneId == group.selected ? 0.9 : 0.6))
            .padding(.leading, 12).frame(minHeight: 36)
            .background(theme.background)
            .overlay(alignment: .bottom) { theme.foreground.opacity(0.08).frame(height: 1) }
        }
    }
    private var terminalDrawerHeader: some View {
        HStack {
            // IPAD-1.31: a labeled drawer bar instead of a lone corner icon.
            Button(action: toggleDrawer) {
                HStack(spacing: 6) {
                    Label(currentWorkspace.terminals.isEmpty ? "Terminal" : "Terminal · \(currentWorkspace.terminals.count)",
                          systemImage: "apple.terminal")
                    Image(systemName: currentWorkspace.drawerVisible ? "chevron.down" : "chevron.up").font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.foreground.opacity(0.5))
                }
            }
            .accessibilityIdentifier("workspace.drawer.close")
            if currentWorkspace.drawerVisible {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(currentWorkspace.terminals, id: \.self) { session in
                            Button { selectSession(session) } label: {
                                Text(sessionTitle(session)).lineLimit(1).padding(.horizontal, 8).frame(minHeight: 44)
                                    .workspaceTabUnderline(selected: currentWorkspace.selectedTerminal == session, color: theme.foreground)
                            }.draggable(WorkspaceTabDrag(session))
                                .contextMenu {
                                    ForEach(currentWorkspace.groups) { group in
                                        Menu("Split beside \(sessionTitle(group.selected))") {
                                            ForEach(WorkspaceLayout<String>.Edge.allCases, id: \.rawValue) { edge in
                                                Button(edge.rawValue.capitalized) {
                                                    mutate { $0.split(session, beside: group.id, edge: edge) }; selectSession(session)
                                                }
                                            }
                                        }
                                    }
                                }
                        }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                onNewTerminal()
            } label: { Image(systemName: "plus").frame(width: 44, height: 44) }.accessibilityLabel("New terminal")
        }.buttonStyle(.plain).font(.callout).padding(.leading, 14).padding(.trailing, 4).frame(minHeight: 44)
            .foregroundStyle(theme.foreground).background(theme.background)
            .overlay(alignment: .top) { theme.foreground.opacity(0.08).frame(height: 1) }
            .terminalDrawerHitArea(onToggle: toggleDrawer)
    }

    private func toggleDrawer() {
        if currentWorkspace.drawerVisible {
            let previous = currentWorkspace.lastAgent
            mutate { _ = $0.hideDrawer() }
            if let previous { onSelectPane(previous) }
        } else {
            var needsTerminal = false
            mutate { needsTerminal = $0.openDrawer() }
            if needsTerminal { onNewTerminal() }
            else if let session = currentWorkspace.selectedTerminal { onSelectPane(session) }
        }
    }

    private func drawerResizeHandle(available: Double) -> some View {
        Rectangle().fill(theme.foreground.opacity(0.12)).frame(height: 8)
            .contentShape(Rectangle())
            .gesture(DragGesture().onChanged { value in
                if drawerResizeStart == nil {
                    drawerResizeStart = MobileWorkspaceStore.drawerHeight(currentWorkspace.drawerHeight, available: available)
                }
                mutate { $0.drawerHeight = MobileWorkspaceStore.drawerHeight(
                    (drawerResizeStart ?? 240) - value.translation.height, available: available) }
            }.onEnded { _ in drawerResizeStart = nil })
            .accessibilityLabel("Terminal drawer height")
            .accessibilityAdjustableAction { direction in
                mutate { $0.drawerHeight = MobileWorkspaceStore.drawerHeight(
                    MobileWorkspaceStore.drawerHeight($0.drawerHeight, available: available)
                        + (direction == .increment ? 40 : -40), available: available) }
            }
    }

    static func liveSessionNames(in layout: PaneLayoutNode?) -> [String] {
        layout?.leaves.map(\.sessionName) ?? []
    }

    static func isFocused(
        sessionName: String,
        focusedPaneId: String?
    ) -> Bool {
        sessionName == focusedPaneId
    }

    static func isUnfocused(
        sessionName: String,
        focusedPaneId: String?
    ) -> Bool {
        focusedPaneId != nil && sessionName != focusedPaneId
    }
}

private struct MultiPaneSplitNode: View {
    let direction: PaneLayoutNode.SplitAxis
    let sourceRatio: Double
    let first: AnyView
    let second: AnyView
    let onRatioChange: (Double) -> Void

    @State private var displayedRatio: Double

    init(
        direction: PaneLayoutNode.SplitAxis,
        sourceRatio: Double,
        first: AnyView,
        second: AnyView,
        onRatioChange: @escaping (Double) -> Void
    ) {
        self.direction = direction
        self.sourceRatio = sourceRatio
        self.first = first
        self.second = second
        self.onRatioChange = onRatioChange
        self._displayedRatio = State(
            initialValue: sourceRatio
        )
    }

    var body: some View {
        ProportionalSplitView(
            direction: direction,
            ratio: $displayedRatio,
            first: first,
            second: second,
            onDragEnd: onRatioChange
        )
        .onChange(of: sourceRatio) { _, newRatio in
            displayedRatio = newRatio
        }
    }
}

private struct MultiPaneLeafView: View {
    let host: Host
    let worktreePath: String
    let sessionName: String
    let title: String
    let theme: GhosttyThemeColors
    let isFocused: Bool
    let isUnfocused: Bool
    let pendingFocusRequests: Int
    let onFocusRequestsConsumed: () -> Void
    let ghosttyCommandContext: MobileGhosttyCommandContext
    let onSelect: () -> Void
    let onBackToWorktrees: () -> Void
    let retainedPanes: RetainedPaneClientPool<RetainedMobilePane>?
    var paneHeader: AnyView? = nil
    var paneBanner: AnyView? = nil
    var showsChat = false
    var chatModel: AgentChatModel? = nil
    var onShowTerminal: () -> Void = {}

    @State private var unusedNavigationPath = NavigationPath()

    var body: some View {
        SingleSessionView(
            step: SessionStep(
                host: host,
                worktreePath: worktreePath,
                sessionName: sessionName,
                title: title
            ),
            navigationPath: $unusedNavigationPath,
            isFullScreen: false,
            externalPendingFocusRequests: pendingFocusRequests,
            onExternalFocusRequestsConsumed: onFocusRequestsConsumed,
            ghosttyCommandContext: ghosttyCommandContext,
            isPaneFocused: isFocused,
            isEmbeddedPane: true,
            embeddedPaneHeader: paneHeader,
            embeddedPaneBanner: paneBanner,
            embeddedShowsChat: showsChat,
            onEmbeddedShowTerminal: onShowTerminal,
            embeddedChatModel: chatModel,
            onPaneInteraction: onSelect,
            onBackToWorktrees: onBackToWorktrees,
            retainedPanes: retainedPanes
        )
        .paneFocusDimming(
            fill: theme.unfocusedSplitFill,
            style: PaneFocusDimmingStyle(
                isUnfocused: isUnfocused,
                contentOpacity: theme.unfocusedSplitOpacity
            )
        )
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}
#endif
