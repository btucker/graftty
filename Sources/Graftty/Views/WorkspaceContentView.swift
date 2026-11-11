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
    /// AGENT-2.7: hook-reported turn activity, so stopped turns stop spinning.
    var agentLiveness: ClaudeSessionRegistry? = nil
    /// LAYOUT-2.190: explicit tab selection hands keyboard focus to the
    /// terminal. Clicks inside a terminal already make it first responder.
    var onActivateTerminal: (PaneSlotID) -> Void = { _ in }
    /// A hair of breathing room so terminal text doesn't slam into the
    /// sidebar divider, while tab rows stay flush with the window edge.
    static let leadingContentInset: CGFloat = 6
    var agentScrollbackMap: AgentScrollbackMap?
    var attentionContext: SidebarWorktreeContext?
    @Environment(\.agentWorkspaceRequest) private var request
    @State private var failure: String?
    @State private var launching = false
    @State private var resizeStart: Double?
    @State private var dropTarget: UUID?

    private var layout: WorkspaceLayout<PaneSlotID> { worktree.workspaceLayout ?? .preserving(worktree.splitTree) }
    private var theme: GhosttyTheme { terminalManager.theme }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if layout.root != nil {
                    TerminalContentView(terminalManager: terminalManager,
                        splitTree: Binding(get: {
                            worktree.canvasTree
                        }, set: { tree in mutate { $0.updateGeometry(from: tree) } }),
                        focusedPaneSlotID: worktree.presentationPane, theme: theme, onFocusTerminal: focus,
                        previewWorktreePath: worktree.path, agentScrollbackMap: agentScrollbackMap,
                        paneHeader: { slot in AnyView(groupHeader(for: slot)) },
                        paneBanner: { slot in
                            guard let group = layout.group(containing: slot), group.id == inputRequestGroupID else { return nil }
                            return AnyView(inputRequestBanner)
                        },
                        paneContent: { slot in
                            guard let agent = agent(slot), agent.completion != nil || agent.status == .closed else { return nil }
                            return AnyView(CompletedAgentContent(agent: agent, launching: launching,
                                onResume: { perform(.init(action: .resume, callerWorktree: worktree.path, agentID: agent.id)) }))
                        },
                        paneDropTarget: { slot, content in AnyView(dropDestination(slot, content: content)) },
                        leadingContentInset: Self.leadingContentInset)
                } else {
                    VStack(spacing: 12) {
                        Text("No active agents").font(.headline)
                        newAgentMenu.controlSize(.large)
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
        .onAppear { synchronize(initial: true) }
        .onChange(of: worktree.path) { _, _ in synchronize(initial: true) }
        .onChange(of: worktree.splitTree.allLeaves) { _, _ in synchronize() }
        .onChange(of: worktree.agents) { _, _ in synchronize() }
        .onChange(of: worktree.focusedPaneSlotID) { old, slot in
            // Teardown's fallback focus must not replace a selected completed tab.
            guard old == nil || old.map(worktree.splitTree.containsLeaf) == true, let slot else { return }
            if worktree.splitTree.zoomed != slot { worktree.splitTree = worktree.splitTree.withZoom(nil) }
            worktree.ensureWorkspaceLayout()
            mutate { $0.select(slot) }
        }
        .alert("Agent operation failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func groupHeader(for slot: PaneSlotID) -> some View {
        let group = layout.group(containing: slot)
        return VStack(spacing: 0) {
            HStack(spacing: 2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(group?.sessions ?? [], id: \.self) { tab in
                            Button { selectTab(tab) } label: {
                                HStack(spacing: 6) {
                                    if let agent = agent(tab) {
                                        AgentStatusBadge(status: agent.status.rawValue,
                                            needsInput: needsInput(tab),
                                            failure: agent.failure, disconnected: terminalManager.attachmentFailures[tab] != nil,
                                            processObservation: agent.processObservation, isBusy: isBusy(tab))
                                    } else {
                                        Image(systemName: "terminal")
                                    }
                                    WorkspaceTerminalTitle(terminalManager: terminalManager, invalidations: terminalManager.paneTitleInvalidations, slot: tab, fallback: agent(tab)?.name ?? "Terminal").lineLimit(1)
                                        .fontWeight(group?.selected == tab ? .medium : .regular)
                                    if agent(tab) == nil, worktree.paneAttention[tab] != nil {
                                        Image(systemName: "circle.fill").font(.system(size: 5)).accessibilityLabel("Needs attention")
                                    }
                                }.padding(.horizontal, 12).padding(.vertical, 9)
                                    .foregroundStyle(theme.foreground.opacity(agent(tab)?.completion != nil || agent(tab)?.status == .closed ? 0.4 : group?.selected == tab ? 1 : 0.65))
                                    .overlay(alignment: .bottom) {
                                        Rectangle().fill(group?.selected == tab ? theme.foreground.opacity(0.55) : .clear)
                                            .frame(height: 2)
                                    }
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(group?.selected == tab ? .isSelected : [])
                                .workspaceTabDragSource(tab.id.uuidString, onSelect: { selectTab(tab) })
                                .modifier(WorkspaceTabDropTarget { value, after in
                                    guard let id = UUID(uuidString: value) else { return }
                                    let source = PaneSlotID(id: id)
                                    let sameGroup = layout.group(containing: source)?.id == group?.id
                                    var moved = false
                                    mutate { moved = $0.moveTab(source, relativeTo: tab, after: after) }
                                    if moved && !sameGroup { focus(source) }
                                })
                                .contextMenu { tabMenu(tab, group: group?.id) }
                        }
                        newAgentMenu.menuStyle(.borderlessButton)
                    }
                }
            }.font(.system(size: 13))
                .background { theme.background.worktreeHeaderWash() }
                .overlay(alignment: .bottom) { theme.foreground.opacity(0.08).frame(height: 1) }
                .onDrop(of: [WorkspaceTabDrag.contentType], isTargeted: nil) { providers in
                    receive(providers) { session in if let id = group?.id { mutate { $0.move(session, to: id) }; focus(session) } }
                }
        }
    }

    /// The tab group under which a live input request shows: the asking
    /// agent's group, else the focused one.
    private var inputRequestGroupID: UUID? {
        guard attentionContext?.question != nil else { return nil }
        let asking = attentionContext?.questionPaneID.flatMap { session in
            worktree.paneSessions.first { ZmxLauncher.sessionName(for: $0.value) == session }?.key
        }
        return (asking ?? worktree.presentationPane).flatMap { layout.group(containing: $0)?.id } ?? layout.groups.first?.id
    }

    private var inputRequestBanner: some View {
        WorkspaceInputRequest(context: attentionContext, selectedSession: worktree.presentationPane.flatMap { worktree.paneSessions[$0] }.map(ZmxLauncher.sessionName(for:))) { session in
            if let slot = worktree.paneSessions.first(where: { ZmxLauncher.sessionName(for: $0.value) == session })?.key { selectTab(slot) }
        }
    }

    private func dropDestination(_ slot: PaneSlotID, content: AnyView) -> some View {
        GeometryReader { geometry in
            content
                .overlay {
                    if let group = layout.group(containing: slot), dropTarget == group.id {
                        ZStack {
                            Rectangle().strokeBorder(theme.foreground.opacity(0.5), lineWidth: 2)
                            Text("Drop at an edge to split · Drop in the center for a tab")
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

    @ViewBuilder private func tabMenu(_ slot: PaneSlotID, group: UUID?) -> some View {
        if let group {
            Menu("Split into pane") {
                ForEach(WorkspaceLayout<PaneSlotID>.Edge.allCases, id: \.rawValue) { edge in
                    Button(edge.rawValue.capitalized) { mutate { $0.split(slot, beside: group, edge: edge) }; focus(slot) }
                        .disabled(layout.group(containing: slot)?.sessions.count == 1)
                }
            }
            Menu("Move to tab group") {
                ForEach(layout.groups.filter { $0.id != group }) { destination in
                    Button(title(destination.selected)) { mutate { $0.move(slot, to: destination.id) }; focus(slot) }
                }
            }.disabled(layout.groups.count < 2)
            Menu("Merge group into") {
                ForEach(layout.groups.filter { $0.id != group }) { destination in
                    Button(title(destination.selected)) { mutate { $0.merge(group, into: destination.id) }; focus(slot) }
                }
            }.disabled(layout.groups.count < 2)
        }
        if agent(slot) == nil {
            Button("Move to terminal drawer") { mutate { $0.moveToDrawer(slot) }; focus(slot) }
            Button("Close terminal", role: .destructive) { onCloseTerminal(slot) }
        } else if let agent = agent(slot), agent.status == .closed {
            Button("Close tab") {
                mutate { $0.remove(slot) }
                if let next = layout.focusedSession { focus(next) }
                else { terminalManager.clearFocus() }
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
                        WorkspaceTerminalTitle(terminalManager: terminalManager, invalidations: terminalManager.paneTitleInvalidations, slot: slot, fallback: agent(slot)?.name ?? "Terminal").lineLimit(1).padding(.horizontal, 8).frame(height: 30)
                            .workspaceTabUnderline(selected: layout.selectedTerminal == slot, color: theme.foreground)
                    }.buttonStyle(.plain)
                        .fontWeight(layout.selectedTerminal == slot ? .semibold : .regular)
                        .draggable(WorkspaceTabDrag(slot.id.uuidString))
                        .contextMenu {
                            ForEach(layout.groups) { group in
                                Button("Move to \(title(group.selected)) tabs") { mutate { $0.move(slot, to: group.id) }; focus(slot) }
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

    private var newAgentMenu: some View {
        NewAgentMenu { provider, operationID in
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
    private func title(_ slot: PaneSlotID) -> String {
        SidebarAgentTitle.display(terminalTitle: terminalManager.displayTitle(for: slot), agentName: agent(slot)?.name ?? "Terminal")
    }
    private func mutate(_ action: (inout WorkspaceLayout<PaneSlotID>) -> Void) {
        var next = layout; action(&next); worktree.workspaceLayout = next
        if let zoomed = worktree.splitTree.zoomed, !next.visibleSplitTree.containsLeaf(zoomed) {
            worktree.splitTree = worktree.splitTree.withZoom(nil)
        }
    }
    /// The tab strip's action. Tabs are drag sources, so tests call this
    /// directly; a synthetic press would enter AppKit's drag tracking loop.
    func selectTab(_ slot: PaneSlotID) { focus(slot, activate: true) }
    func selectTerminalTab(_ slot: PaneSlotID) { selectTab(slot) }
    private func focus(_ slot: PaneSlotID) { focus(slot, activate: false) }
    private func focus(_ slot: PaneSlotID, activate: Bool) {
        if worktree.splitTree.zoomed != slot { worktree.splitTree = worktree.splitTree.withZoom(nil) }
        mutate { $0.select(slot) }
        if worktree.hasCompletedContent(in: slot) {
            terminalManager.clearFocus()
        } else if worktree.splitTree.containsLeaf(slot) {
            onFocusTerminal(slot)
            if activate { onActivateTerminal(slot) }
        }
    }
    private func synchronize(initial: Bool = false) {
        let hadLayout = worktree.workspaceLayout != nil
        worktree.ensureWorkspaceLayout()
        if initial && !hadLayout, let focused = worktree.focusedPaneSlotID { mutate { $0.select(focused) } }
        if let slot = worktree.presentationPane, worktree.hasCompletedContent(in: slot) { terminalManager.clearFocus() }
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
    let fallback: String

    var body: some View {
        let _ = invalidations.generation
        Text(SidebarAgentTitle.display(terminalTitle: terminalManager.displayTitle(for: slot), agentName: fallback))
    }
}
