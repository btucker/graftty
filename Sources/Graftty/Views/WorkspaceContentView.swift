import SwiftUI
import UniformTypeIdentifiers
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

private struct AgentWorkspaceRequestKey: EnvironmentKey {
    static let defaultValue: (@MainActor (AgentControlRequest) async -> ResponseMessage)? = nil
}
extension EnvironmentValues {
    var agentWorkspaceRequest: (@MainActor (AgentControlRequest) async -> ResponseMessage)? {
        get { self[AgentWorkspaceRequestKey.self] }
        set { self[AgentWorkspaceRequestKey.self] = newValue }
    }
}

private struct AgentChatServiceKey: EnvironmentKey {
    static let defaultValue: AgentChatService? = nil
}
extension EnvironmentValues {
    /// Chat for agent tabs hosted on this Mac.
    var agentChatService: AgentChatService? {
        get { self[AgentChatServiceKey.self] }
        set { self[AgentChatServiceKey.self] = newValue }
    }
}

private struct LocalAttentionAnswerKey: EnvironmentKey {
    static let defaultValue: (@MainActor (AttentionAnswer) async -> WorktreeManagementResponse)? = nil
}
extension EnvironmentValues {
    /// Types a Context answer into an agent pane on this Mac (AGENT-3.50).
    var localAttentionAnswer: (@MainActor (AttentionAnswer) async -> WorktreeManagementResponse)? {
        get { self[LocalAttentionAnswerKey.self] }
        set { self[LocalAttentionAnswerKey.self] = newValue }
    }
}

struct WorkspaceContentView: View {
    @ObservedObject var terminalManager: TerminalManager
    @Binding var worktree: WorktreeEntry
    let onFocusTerminal: (PaneSlotID) -> Void
    let onNewTerminal: () -> Void
    let onCloseTerminal: (PaneSlotID) -> Void
    /// AGENT-2.7: hook-reported turn activity distinguishes working and idle agents.
    var agentLiveness: ClaudeSessionRegistry? = nil
    /// LAYOUT-2.190: explicit tab selection hands keyboard focus to the
    /// terminal. Clicks inside a terminal already make it first responder.
    var onActivateTerminal: (PaneSlotID) -> Void = { _ in }
    var onClearFocus: (() -> Void)?
    /// A hair of breathing room so terminal text doesn't slam into the
    /// sidebar divider, while tab rows stay flush with the window edge.
    static let leadingContentInset: CGFloat = 6
    var agentScrollbackMaps: [PaneSlotID: AgentScrollbackMap] = [:]
    var attentionContext: SidebarWorktreeContext?
    /// Context, shown beneath the gallery in one right-hand column (LAYOUT-2.253).
    var contextPanel: AnyView? = nil
    @Environment(\.agentWorkspaceRequest) private var request
    @Environment(\.agentChatService) private var chatService
    @State private var chatModels = AgentChatModelStore<PaneSlotID>()
    @State private var failure: String?
    @State private var launching = false
    @State private var resizeStart: Double?
    @State private var dropTarget: UUID?

    private var layout: WorkspaceLayout<PaneSlotID> { worktree.workspaceLayout ?? .preserving(worktree.splitTree) }
    private var theme: GhosttyTheme { terminalManager.theme }

    var body: some View {
        HStack(spacing: 0) {
            stage
                .overlay(alignment: .topTrailing) {
                    if !showsGallery && layout.root != nil {
                        WorkspaceGalleryOpener(agentCount: galleryAgents.count,
                            askingCount: galleryAgents.count { needsInput($0) }, theme: theme) {
                            mutate { $0.galleryVisible = true }
                        }
                        .padding(.top, 6).padding(.trailing, 22)
                    }
                }
            if let width = WorkspaceGalleryColumn.width(showsGallery: showsGallery, showsContext: contextPanel != nil) {
                VStack(spacing: 0) {
                    if showsGallery {
                        gallery.frame(maxHeight: contextPanel == nil ? .infinity : 320)
                    }
                    if let contextPanel {
                        if showsGallery { theme.foreground.opacity(0.08).frame(height: 1) }
                        contextPanel.frame(maxHeight: .infinity)
                    }
                }
                .frame(width: width)
                // Above the stage, so tile rail cards can spill over it.
                .zIndex(1)
            }
        }
        .background(theme.background)
        .onAppear { synchronize(initial: true) }
        .onChange(of: worktree.path) { _, _ in synchronize(initial: true) }
        .onChange(of: worktree.splitTree.allLeaves) { _, _ in synchronize() }
        .onChange(of: worktree.agents) { _, _ in synchronize() }
        .onChange(of: worktree.focusedPaneSlotID) { old, slot in
            // Teardown's fallback focus must not replace a selected completed agent.
            guard old == nil || old.map(worktree.splitTree.containsLeaf) == true, let slot else { return }
            if worktree.splitTree.zoomed != slot { worktree.splitTree = worktree.splitTree.withZoom(nil) }
            worktree.ensureWorkspaceLayout()
            mutate { $0.select(slot) }
        }
        .alert("Agent operation failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    /// Agents with a tile: every agent in the layout, on stage or off.
    private var galleryAgents: [PaneSlotID] { layout.gallerySessions.filter { agent($0) != nil } }

    var showsGallery: Bool { layout.showsGallery(agentCount: galleryAgents.count) }

    private var gallery: some View {
        WorkspaceGallery(tiles: galleryAgents.map(tileModel), theme: theme,
            onStage: { id in slot(id).map(stageAgent) },
            onJump: { id, row in
                guard let slot = slot(id) else { return }
                stageAgent(slot)
                // Scroll once the staged surface is mounted.
                DispatchQueue.main.async { terminalManager.handle(for: slot)?.scrollbackMapModel.scroll(toRow: row) }
            },
            onMove: { source, target, after in
                guard let source = slot(source), let target = slot(target) else { return }
                mutate { _ = $0.moveTile(source, relativeTo: target, after: after) }
            },
            onCollapse: { mutate { $0.galleryVisible = false } },
            newAgent: {
                newAgentMenu(label: AnyView(AgentGalleryEmptyTile(foreground: theme.foreground)))
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
            },
            tileMenu: { id in if let slot = slot(id) { tileMenu(slot) } })
    }

    private func slot(_ id: String) -> PaneSlotID? {
        UUID(uuidString: id).map(PaneSlotID.init(id:)).flatMap { layout.sessions.contains($0) ? $0 : nil }
    }

    private func tileModel(_ slot: PaneSlotID) -> WorkspaceGalleryTileModel {
        let agent = agent(slot)
        let asking = needsInput(slot)
        let question = asking ? (worktree.paneSessions[slot].flatMap { attentionContext?.question(session: ZmxLauncher.sessionName(for: $0)) }
            ?? worktree.paneAttention[slot]?.text) : nil
        return WorkspaceGalleryTileModel(id: slot.id.uuidString,
            handle: hasCompletedContentOrClosed(agent) ? nil : terminalManager.handle(for: slot),
            title: title(slot),
            status: AgentTileStatus(needsInput: asking, isBusy: isBusy(slot) ?? (agent?.status == .running),
                isCompleted: hasCompletedContentOrClosed(agent), isCached: false, question: question,
                result: agent?.completion?.result, statusLabel: agent.map(Self.statusLabel) ?? "Terminal"),
            isOnStage: layout.isOnStage(slot), scrollback: agentScrollbackMaps[slot])
    }

    private func hasCompletedContentOrClosed(_ agent: ManagedAgent?) -> Bool {
        agent?.completion != nil || agent?.status == .closed
    }

    static func statusLabel(_ agent: ManagedAgent) -> String {
        switch agent.status {
        case .starting: "Starting"
        case .running: "Running"
        case .waiting: "Waiting"
        case .awaitingCleanup: "Finished"
        case .closing: "Closing"
        case .closed: "Closed"
        case .failed: "Failed"
        case .interrupted: "Interrupted"
        }
    }

    private var stage: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if layout.root != nil {
                    TerminalContentView(terminalManager: terminalManager,
                        splitTree: Binding(get: {
                            worktree.canvasTree
                        }, set: { tree in mutate { $0.updateGeometry(from: tree) } }),
                        focusedPaneSlotID: worktree.presentationPane, theme: theme, onFocusTerminal: focus,
                        previewWorktreePath: worktree.path, agentScrollbackMaps: agentScrollbackMaps,
                        paneHeader: { slot in AnyView(stagePaneHeader(for: slot)) },
                        paneBanner: { slot in
                            guard attentionContext?.question != nil,
                                  let group = layout.group(containing: slot), group.id == stageBannerGroupID else { return nil }
                            return AnyView(inputRequestBanner)
                        },
                        paneContent: { slot in
                            if let chat = chatContent(slot) { return chat }
                            guard let agent = agent(slot), agent.completion != nil || agent.status == .closed else { return nil }
                            return AnyView(CompletedAgentContent(agent: agent, launching: launching,
                                onResume: { perform(.init(action: .resume, callerWorktree: worktree.path, agentID: agent.id)) }))
                        },
                        paneDropTarget: { slot, content in AnyView(dropDestination(slot, content: content)) },
                        leadingContentInset: Self.leadingContentInset)
                } else {
                    VStack(spacing: 12) {
                        Text("No active agents").font(.headline)
                        newAgentMenu().controlSize(.large)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if layout.drawerVisible {
                    HorizontalResizeDivider(label: "Terminal drawer height", onResize: { translation in
                        if resizeStart == nil { resizeStart = WorkspaceLayout<PaneSlotID>.clampedDrawerHeight(layout.drawerHeight, available: geometry.size.height) }
                        mutate { $0.drawerHeight = WorkspaceLayout<PaneSlotID>.resizedDrawerHeight(resizeStart ?? 240,
                            by: -translation, available: geometry.size.height) }
                    }, onResizeEnd: { resizeStart = nil })
                }
                drawerHeader
                if layout.drawerVisible {
                    Group {
                        if let slot = layout.selectedTerminal {
                            TerminalContentView(terminalManager: terminalManager, splitTree: .constant(SplitTree(root: .leaf(slot))),
                                focusedPaneSlotID: worktree.focusedPaneSlotID, theme: theme,
                                onFocusTerminal: focus, previewWorktreePath: worktree.path,
                                leadingContentInset: Self.leadingContentInset)
                        } else {
                            Button("New terminal", action: onNewTerminal)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.frame(height: WorkspaceLayout<PaneSlotID>.clampedDrawerHeight(layout.drawerHeight, available: geometry.size.height))
                }
            }
            .background(theme.background)
            .foregroundStyle(theme.foreground)
        }
    }

    /// A stage pane's slim header: in a split stage it names the pane and
    /// lets it leave the stage without closing its agent; an agent that offers
    /// Chat shows its Chat / Terminal switch here. Otherwise there is none.
    @ViewBuilder private func stagePaneHeader(for slot: PaneSlotID) -> some View {
        let offersChat = chatService != nil && agent(slot).map(AgentChatHost.offers) == true
        if let group = layout.group(containing: slot), layout.groups.count > 1 || offersChat {
            HStack(spacing: 6) {
                if layout.groups.count > 1 {
                    if agent(slot) != nil { AgentStatusDot(dot: tileModel(slot).status.dot) }
                    WorkspaceTerminalTitle(terminalManager: terminalManager, invalidations: terminalManager.paneTitleInvalidations,
                        slot: slot, agentName: agent(slot)?.name, provider: agent(slot)?.provider.rawValue)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if offersChat {
                    AgentChatSwitch(showsChat: Binding(get: { showsChat(slot) }, set: { setView(slot, chat: $0) }))
                        .controlSize(.small)
                }
                if layout.groups.count > 1 {
                    Button {
                        mutate { _ = $0.removePane(group.id) }
                        if let next = layout.focusedSession { focus(next) }
                    } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help("Remove from stage")
                        .accessibilityLabel("Remove from stage")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(theme.foreground.opacity(layout.focusedGroupID == group.id ? 0.85 : 0.55))
            .padding(.horizontal, 10).frame(minHeight: 24)
            .background { theme.background.worktreeHeaderWash() }
            .overlay(alignment: .bottom) { theme.foreground.opacity(0.08).frame(height: 1) }
        }
    }

    /// A live question shows at the top of the focused stage pane, whichever
    /// agent asks, so the user can answer without switching (LAYOUT-2.196).
    var stageBannerGroupID: UUID? { layout.focusedGroupID }

    private var inputRequestBanner: some View {
        WorkspaceInputRequest(context: attentionContext, selectedSession: worktree.presentationPane.flatMap { worktree.paneSessions[$0] }.map(ZmxLauncher.sessionName(for:))) { session in
            if let slot = worktree.paneSessions.first(where: { ZmxLauncher.sessionName(for: $0.value) == session })?.key { stageAgent(slot) }
        }
    }

    private func dropDestination(_ slot: PaneSlotID, content: AnyView) -> some View {
        GeometryReader { geometry in
            content
                .overlay {
                    if let group = layout.group(containing: slot), dropTarget == group.id {
                        ZStack {
                            Rectangle().strokeBorder(theme.foreground.opacity(0.5), lineWidth: 2)
                            Text("Drop at an edge to split · Drop in the center to replace")
                                .font(.caption).padding(8).background(.regularMaterial)
                        }.allowsHitTesting(false)
                    }
                }
                .dropDestination(for: WorkspaceTabDrag.self) { items, location in
                    defer { dropTarget = nil }
                    guard let item = items.first?.session, let uuid = UUID(uuidString: item),
                          let group = layout.group(containing: slot) else { return false }
                    let session = PaneSlotID(id: uuid)
                    guard layout.sessions.contains(session) else { return false }
                    let edge: WorkspaceLayout<PaneSlotID>.Edge?
                    if location.x < geometry.size.width * 0.2 { edge = .left }
                    else if location.x > geometry.size.width * 0.8 { edge = .right }
                    else if location.y < geometry.size.height * 0.2 { edge = .top }
                    else if location.y > geometry.size.height * 0.8 { edge = .bottom }
                    else { edge = nil }
                    mutate { next in
                        if let edge { next.split(session, beside: group.id, edge: edge) }
                        else { next.move(session, to: group.id) }
                    }
                    focus(session)
                    return true
                } isTargeted: { targeted in
                    if targeted { dropTarget = layout.group(containing: slot)?.id }
                    else if dropTarget == layout.group(containing: slot)?.id { dropTarget = nil }
                }
        }
    }

    @ViewBuilder private func tileMenu(_ slot: PaneSlotID) -> some View {
        if !layout.isOnStage(slot), let target = layout.focusedGroupID {
            Button("Put on stage") { stageAgent(slot) }
            Button("Show beside the stage") { mutate { $0.split(slot, beside: target, edge: .right) }; focus(slot, activate: true) }
        } else if let group = layout.group(containing: slot), layout.groups.count > 1 {
            Button("Remove from stage") {
                mutate { _ = $0.removePane(group.id) }
                if let next = layout.focusedSession { focus(next) }
            }
        }
        if agent(slot) == nil {
            Button("Move to terminal drawer") { mutate { $0.moveToDrawer(slot) }; focus(slot) }
            Button("Close terminal", role: .destructive) { onCloseTerminal(slot) }
        } else if let agent = agent(slot), agent.status == .closed {
            Button("Dismiss") {
                mutate { $0.remove(slot) }
                if let next = layout.focusedSession { focus(next) }
                else { clearFocus() }
            }
        } else if let agent = agent(slot), let completion = agent.completion {
            Button(completion.outcome == .interrupted || completion.outcome == .failed ? "Acknowledge and close agent" : "Close completed agent") { perform(.init(action: .close, callerWorktree: worktree.path, agentID: agent.id, completionID: completion.id)) }
        }
    }

    private var drawerHeader: some View {
        HStack(spacing: 10) {
            Button(action: toggleDrawer) {
                Label("Terminal", systemImage: "terminal").labelStyle(.iconOnly)
            }.buttonStyle(.plain).help(layout.drawerVisible ? "Hide terminal" : "Show terminal")
            if layout.drawerVisible {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                ForEach(layout.terminals, id: \.self) { slot in
                    Button { selectTerminalTab(slot) } label: {
                        WorkspaceTerminalTitle(terminalManager: terminalManager, invalidations: terminalManager.paneTitleInvalidations, slot: slot, agentName: agent(slot)?.name, provider: agent(slot)?.provider.rawValue).lineLimit(1).padding(.horizontal, 8).frame(height: 30)
                            .workspaceTabUnderline(selected: layout.selectedTerminal == slot, color: theme.foreground)
                    }.buttonStyle(.plain)
                        .fontWeight(layout.selectedTerminal == slot ? .semibold : .regular)
                        .draggable(WorkspaceTabDrag(slot.id.uuidString))
                        .contextMenu {
                            ForEach(layout.groups) { group in
                                Button("Split beside \(title(group.selected))") { mutate { $0.split(slot, beside: group.id, edge: .right) }; focus(slot) }
                            }
                            Button("Close terminal", role: .destructive) { onCloseTerminal(slot) }
                        }
                }
                    }
                }.fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onNewTerminal) { Image(systemName: "plus") }.buttonStyle(.plain).help("New terminal")
            if layout.drawerVisible {
                Button {
                    var next = layout; let previous = next.hideDrawer(); worktree.workspaceLayout = next
                    if let previous { onFocusTerminal(previous) }
                } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).help("Hide terminal")
            }
        }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 30)
            .background(theme.foreground.opacity(0.04))
            .terminalDrawerHitArea(onToggle: toggleDrawer)
    }

    func toggleDrawer() {
        var next = layout
        if next.drawerVisible {
            let previous = next.hideDrawer()
            worktree.workspaceLayout = next
            if let previous { onFocusTerminal(previous) }
        } else {
            let needsTerminal = next.openDrawer()
            worktree.workspaceLayout = next
            if needsTerminal { onNewTerminal() }
            if let slot = layout.selectedTerminal { selectTerminalTab(slot) }
        }
    }

    private func newAgentMenu(label: AnyView? = nil) -> some View {
        NewAgentMenu(label: label) { provider, operationID in
            guard let request else { throw AgentLaunchError("Agent controls are not ready.") }
            let response = await request(.init(action: .add, callerWorktree: worktree.path,
                name: "Agent \(worktree.agents.count + 1)", worktree: worktree.path,
                provider: provider.flatMap(TeamHookRuntime.init(rawValue:)),
                operationID: operationID.uuidString, selectTab: true, launchOrigin: .userInterface))
            if case .error(let message) = response { throw AgentLaunchError(message) }
        }
            .fixedSize().disabled(launching)
            .foregroundStyle(theme.foreground.opacity(0.7))
            .padding(.horizontal, 8)
    }
    private func perform(_ operation: AgentControlRequest) {
        guard let request else { failure = "Agent controls are not ready."; return }
        launching = true
        Task { @MainActor in
            defer { launching = false }
            let response = await request(operation)
            if case .error(let message) = response { failure = message }
            if operation.action == .resume, case .agents(let records) = response,
               let slot = records.first?.agent.presentationSlotID { focus(slot) }
        }
    }
    private func needsInput(_ slot: PaneSlotID) -> Bool {
        if let attentionContext, let session = worktree.paneSessions[slot] { return attentionContext.needsInput(session: ZmxLauncher.sessionName(for: session)) }
        return worktree.paneAttention[slot]?.source == .agentStop
    }
    func isBusy(_ slot: PaneSlotID) -> Bool? {
        guard let agentLiveness, let session = worktree.paneSessions[slot] else { return nil }
        return AgentLivenessMerge.isPaneBusy(sessionName: ZmxLauncher.sessionName(for: session),
            liveness: agentLiveness.livenessBySession)
    }
    private func agent(_ slot: PaneSlotID) -> ManagedAgent? { worktree.agents.first { $0.presentationSlotID == slot } }
    func showsChat(_ slot: PaneSlotID) -> Bool { chatService != nil && worktree.showsChat(in: slot) }
    /// AGENT-6.183: a view change keeps the terminal mounted in its manager and sends the agent nothing.
    func setView(_ slot: PaneSlotID, chat: Bool) {
        var entry = worktree
        WorkspaceChatSwitch.setView(chat: chat, slot: slot, in: &entry)
        worktree = entry
        if showsChat(slot) {
            clearFocus()
        } else if worktree.splitTree.containsLeaf(slot) {
            onFocusTerminal(slot)
            onActivateTerminal(slot)
        }
    }
    private func chatContent(_ slot: PaneSlotID) -> AnyView? {
        guard showsChat(slot), let chatService, let agent = agent(slot) else { return nil }
        return AnyView(AgentChatView(
            model: chatModels.model(for: slot),
            tabID: "\(agent.id)/\(agent.providerSessionID ?? "")", agentName: agent.name,
            connection: chatService.connection(worktreePath: worktree.path, agentID: agent.id, viewer: .host),
            showTerminal: { setView(slot, chat: false) }
        ).foregroundStyle(theme.foreground).tint(theme.foreground).background(theme.background))
    }
    private func title(_ slot: PaneSlotID) -> String {
        WorkspaceTerminalTitle.text(terminalManager: terminalManager, slot: slot,
                                    agentName: agent(slot)?.name, provider: agent(slot)?.provider.rawValue)
    }
    private func mutate(_ action: (inout WorkspaceLayout<PaneSlotID>) -> Void) {
        var next = layout; action(&next); worktree.workspaceLayout = next
        if let zoomed = worktree.splitTree.zoomed, !next.visibleSplitTree.containsLeaf(zoomed) {
            worktree.splitTree = worktree.splitTree.withZoom(nil)
        }
    }
    /// A gallery tile's action. Tiles are drag sources, so tests call this
    /// directly; a synthetic press would enter AppKit's drag tracking loop.
    func stageAgent(_ slot: PaneSlotID) {
        if worktree.splitTree.zoomed != slot { worktree.splitTree = worktree.splitTree.withZoom(nil) }
        mutate { $0.stage(slot) }
        focus(slot, activate: true)
    }
    func selectTerminalTab(_ slot: PaneSlotID) { focus(slot, activate: true) }
    private func focus(_ slot: PaneSlotID) { focus(slot, activate: false) }
    private func focus(_ slot: PaneSlotID, activate: Bool) {
        if worktree.splitTree.zoomed != slot { worktree.splitTree = worktree.splitTree.withZoom(nil) }
        mutate { $0.select(slot) }
        if worktree.showsNonTerminalContent(in: slot) {
            clearFocus()
        } else if worktree.splitTree.containsLeaf(slot) {
            onFocusTerminal(slot)
            if activate { onActivateTerminal(slot) }
        }
    }
    private func clearFocus() {
        if let onClearFocus { onClearFocus() }
        else { terminalManager.clearFocus() }
    }
    private func synchronize(initial: Bool = false) {
        let hadLayout = worktree.workspaceLayout != nil
        worktree.ensureWorkspaceLayout()
        if initial && !hadLayout, let focused = worktree.focusedPaneSlotID { mutate { $0.select(focused) } }
        if let slot = worktree.presentationPane, worktree.showsNonTerminalContent(in: slot) { clearFocus() }
        chatModels.prune(keeping: Set(worktree.agents.compactMap(\.presentationSlotID)))
    }
    private func receive(_ providers: [NSItemProvider], action: @escaping @MainActor (PaneSlotID) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadTransferable(type: WorkspaceTabDrag.self) { result in
            guard case .success(let payload) = result, let id = UUID(uuidString: payload.session) else { return }
            Task { @MainActor in
                let slot = PaneSlotID(id: id)
                guard layout.sessions.contains(slot) else { return }
                action(slot)
            }
        }
        return true
    }
}

struct CompletedAgentContent: View {
    let agent: ManagedAgent
    let launching: Bool
    let onResume: () -> Void
    var loadTranscript: @MainActor (ManagedAgent) async throws -> String? = { agent in
        try await OffMainIO.run { try AgentArchiveStore().preview(agent) }
    }
    @State private var transcript: String?
    @State private var failure: String?

    private var canResume: Bool {
        agent.providerSessionID?.isEmpty == false && agent.completion != nil && agent.status != .closing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(agent.status == .closed ? "Session closed" : agent.completion?.outcome == .interrupted ? "Assignment interrupted" : agent.completion?.outcome == .failed ? "Assignment failed" : "Assignment finished")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Resume session", action: onResume).disabled(launching || !canResume)
            }.padding(12)
            if !canResume {
                Text(agent.providerSessionID?.isEmpty != false ? "This session has no saved conversation ID to resume." : "Session cleanup is in progress.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let result = agent.completion?.result { Text(result).textSelection(.enabled) }
                    if let transcript { Text(transcript).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    if let failure = failure ?? agent.failure { Text(failure).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: agent.transcriptArchive?.id ?? agent.assignmentID.uuidString) {
                transcript = nil; failure = nil
                do {
                    let preview = try await loadTranscript(agent)
                    guard !Task.isCancelled else { return }
                    transcript = preview
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = "Could not read transcript: \(error.localizedDescription)"
                }
            }
    }
}

/// Observe title changes inside the label, without invalidating terminal content.
private struct WorkspaceTerminalTitle: View {
    let terminalManager: TerminalManager
    @ObservedObject var invalidations: PaneTitleInvalidationSource
    let slot: PaneSlotID
    /// Only the fields the title reads, so tab diffs never compare whole agent records.
    let agentName: String?
    let provider: String?

    static func text(terminalManager: TerminalManager, slot: PaneSlotID, agentName: String?, provider: String?) -> String {
        SidebarAgentTitle.display(terminalTitle: terminalManager.displayTitle(for: slot),
                                  agentName: agentName ?? "Terminal", tabProvider: provider)
    }

    var body: some View {
        let _ = invalidations.generation
        let title = Self.text(terminalManager: terminalManager, slot: slot, agentName: agentName, provider: provider)
        Text(title).help(title)
    }
}
