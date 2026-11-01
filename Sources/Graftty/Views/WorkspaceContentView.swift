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

struct WorkspaceContentView: View {
    @ObservedObject var terminalManager: TerminalManager
    @Binding var worktree: WorktreeEntry
    let onFocusTerminal: (PaneSlotID) -> Void
    let onNewTerminal: () -> Void
    let onCloseTerminal: (PaneSlotID) -> Void
    var agentScrollbackMap: AgentScrollbackMap?
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
                        paneContent: { slot in
                            guard let agent = agent(slot), agent.completion != nil || agent.status == .closed else { return nil }
                            return AnyView(CompletedAgentContent(agent: agent, launching: launching,
                                onResume: { perform(.init(action: .resume, callerWorktree: worktree.path, agentID: agent.id)) }))
                        },
                        paneDropTarget: { slot, content in AnyView(dropDestination(slot, content: content)) })
                } else {
                    VStack(spacing: 12) {
                        Text("No active agents").font(.headline)
                        newAgentMenu
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
                                onFocusTerminal: focus, previewWorktreePath: worktree.path)
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
                            Button { focus(tab) } label: {
                                HStack(spacing: 6) {
                                    AgentProviderIcon(provider: agent(tab)?.provider.rawValue)
                                    Text(title(tab)).lineLimit(1)
                                        .fontWeight(group?.selected == tab ? .medium : .regular)
                                    if let agent = agent(tab) {
                                        AgentStatusBadge(status: agent.status.rawValue,
                                            needsInput: worktree.paneAttention[tab]?.source == .agentStop,
                                            failure: agent.failure, disconnected: terminalManager.attachmentFailures[tab] != nil,
                                            processObservation: agent.processObservation)
                                    } else if worktree.paneAttention[tab] != nil {
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
                                .draggable(tab.id.uuidString)
                                .contextMenu { tabMenu(tab, group: group?.id) }
                        }
                        newAgentMenu
                    }
                }
            }.font(.system(size: 13))
                .overlay(alignment: .bottom) { theme.foreground.opacity(0.08).frame(height: 1) }
                .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                    receive(providers) { session in if let id = group?.id { mutate { $0.move(session, to: id) }; focus(session) } }
                }

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
                .dropDestination(for: String.self) { items, location in
                    defer { dropTarget = nil }
                    guard let item = items.first, let uuid = UUID(uuidString: item),
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
        } else if let agent = agent(slot), let completion = agent.completion, agent.requiresAcknowledgment {
            Button(completion.outcome == .interrupted || completion.outcome == .failed ? "Acknowledge and close agent" : "Close completed agent") { perform(.init(action: .close, callerWorktree: worktree.path, agentID: agent.id, completionID: completion.id)) }
        }
    }

    private var drawerHeader: some View {
        HStack(spacing: 10) {
            Button(action: toggleDrawer) {
                Label(layout.terminals.isEmpty ? "Terminal" : "Terminal · \(layout.terminals.count)", systemImage: "terminal")
            }.buttonStyle(.plain).help(layout.drawerVisible ? "Hide terminal" : "Show terminal")
            if layout.drawerVisible {
                ForEach(layout.terminals, id: \.self) { slot in
                    Button(title(slot)) { focus(slot) }.buttonStyle(.plain)
                        .fontWeight(layout.selectedTerminal == slot ? .semibold : .regular)
                        .draggable(slot.id.uuidString)
                        .contextMenu {
                            ForEach(layout.groups) { group in
                                Button("Move to \(title(group.selected)) tabs") { mutate { $0.move(slot, to: group.id) }; focus(slot) }
                                Button("Split beside \(title(group.selected))") { mutate { $0.split(slot, beside: group.id, edge: .right) }; focus(slot) }
                            }
                            Button("Close terminal", role: .destructive) { onCloseTerminal(slot) }
                        }
                }
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

    private func toggleDrawer() {
        var next = layout
        if next.drawerVisible {
            let previous = next.hideDrawer()
            worktree.workspaceLayout = next
            if let previous { onFocusTerminal(previous) }
        } else {
            let needsTerminal = next.openDrawer()
            worktree.workspaceLayout = next
            if needsTerminal { onNewTerminal() }
            else if let slot = next.selectedTerminal { focus(slot) }
        }
    }

    private var newAgentMenu: some View {
        Menu {
            if let preferred = AgentPreference.provider() {
                Button("New \(preferred.displayName) agent (default)") { launch(preferred) }
                Divider()
            }
            ForEach(TeamHookRuntime.allCases, id: \.rawValue) { provider in
                Button { launch(provider) } label: {
                    Label { Text("New \(provider.displayName) agent") } icon: { AgentProviderIcon(provider: provider.rawValue) }
                }
            }
        } label: { Label("New agent", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize().disabled(launching)
            .foregroundStyle(theme.foreground.opacity(0.7))
            .padding(.horizontal, 8)
    }

    private func launch(_ provider: TeamHookRuntime) {
        perform(.init(action: .add, callerWorktree: worktree.path, name: "\(provider.displayName) \(worktree.agents.count + 1)",
            worktree: worktree.path, provider: provider, operationID: UUID().uuidString, selectTab: true))
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
    private func agent(_ slot: PaneSlotID) -> ManagedAgent? { worktree.agents.first { $0.presentationSlotID == slot } }
    private func title(_ slot: PaneSlotID) -> String {
        agent(slot)?.name ?? GrafttyApp.paneTitle(for: slot, terminalManager: terminalManager) ?? "Terminal"
    }
    private func mutate(_ action: (inout WorkspaceLayout<PaneSlotID>) -> Void) {
        var next = layout; action(&next); worktree.workspaceLayout = next
        if let zoomed = worktree.splitTree.zoomed, !next.visibleSplitTree.containsLeaf(zoomed) {
            worktree.splitTree = worktree.splitTree.withZoom(nil)
        }
    }
    private func focus(_ slot: PaneSlotID) {
        if worktree.splitTree.zoomed != slot { worktree.splitTree = worktree.splitTree.withZoom(nil) }
        mutate { $0.select(slot) }
        if worktree.hasCompletedContent(in: slot) {
            terminalManager.clearFocus()
        } else if worktree.splitTree.containsLeaf(slot) { onFocusTerminal(slot) }
    }
    private func synchronize(initial: Bool = false) {
        let hadLayout = worktree.workspaceLayout != nil
        worktree.ensureWorkspaceLayout()
        if initial && !hadLayout, let focused = worktree.focusedPaneSlotID { mutate { $0.select(focused) } }
        if let slot = worktree.presentationPane, worktree.hasCompletedContent(in: slot) { terminalManager.clearFocus() }
    }
    private func receive(_ providers: [NSItemProvider], action: @escaping @MainActor (PaneSlotID) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String, let id = UUID(uuidString: value) else { return }
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
