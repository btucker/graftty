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
    @State private var archive: ManagedAgent?
    @State private var archivePreview: String?
    @State private var lastFocused: PaneSlotID?
    @State private var lastFocusedAgentID: String?
    @State private var failure: String?
    @State private var launching = false
    @State private var resizeStart: Double?
    @State private var dropTarget: UUID?

    private var layout: WorkspaceLayout<PaneSlotID> { worktree.workspaceLayout ?? .preserving(worktree.splitTree) }
    private var theme: GhosttyTheme { terminalManager.theme }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let archive {
                    VStack(spacing: 0) {
                        HStack {
                            AgentProviderIcon(provider: archive.provider.rawValue)
                            Text(archive.name)
                            Text("Closed").foregroundStyle(.secondary)
                            Spacer()
                            Button("Back to agents") {
                                self.archive = nil
                                if let slot = layout.lastAgent { focus(slot) }
                            }
                        }.padding(10)
                        Divider()
                        ScrollView {
                            Text(archivePreview ?? "Loading transcript…")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if layout.root != nil {
                    TerminalContentView(terminalManager: terminalManager,
                        splitTree: Binding(get: {
                            worktree.canvasTree
                        }, set: { tree in mutate { $0.updateGeometry(from: tree) } }),
                        focusedPaneSlotID: worktree.focusedPaneSlotID, theme: theme, onFocusTerminal: focus,
                        previewWorktreePath: worktree.path, agentScrollbackMap: agentScrollbackMap,
                        paneHeader: { slot in AnyView(groupHeader(for: slot)) },
                        paneDropTarget: { slot, content in AnyView(dropDestination(slot, content: content)) })
                } else {
                    VStack(spacing: 12) {
                        Text("No active agents").font(.headline)
                        newAgentMenu
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if layout.drawerVisible {
                    Rectangle().fill(theme.foreground.opacity(0.12)).frame(height: 4)
                        .contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            if resizeStart == nil { resizeStart = WorkspaceLayout<PaneSlotID>.clampedDrawerHeight(layout.drawerHeight, available: geometry.size.height) }
                            mutate { $0.drawerHeight = WorkspaceLayout<PaneSlotID>.resizedDrawerHeight(resizeStart ?? 240,
                                by: -value.translation.height, available: geometry.size.height) }
                        }.onEnded { _ in resizeStart = nil })
                        .accessibilityLabel("Terminal drawer height")
                        .accessibilityAdjustableAction { direction in
                            mutate { $0.drawerHeight = WorkspaceLayout<PaneSlotID>.resizedDrawerHeight($0.drawerHeight,
                                by: direction == .increment ? 40 : -40, available: geometry.size.height) }
                        }
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
        .onAppear {
            synchronize(); lastFocused = worktree.focusedPaneSlotID
            lastFocusedAgentID = worktree.agents.first { $0.paneSlotID == lastFocused && $0.status != .closed }?.id
        }
        .task(id: archive?.id) {
            archivePreview = nil
            guard let archive else { return }
            do {
                let preview = try await OffMainIO.run { try AgentArchiveStore().preview(archive) }
                guard !Task.isCancelled else { return }
                archivePreview = preview ?? archive.completion?.result ?? "No transcript was available when this session closed."
            } catch {
                guard !Task.isCancelled else { return }
                archivePreview = "Could not read transcript: \(error.localizedDescription)"
            }
        }
        .onChange(of: worktree.path) { _, _ in
            archive = nil; lastFocused = worktree.focusedPaneSlotID
            lastFocusedAgentID = worktree.agents.first { $0.paneSlotID == lastFocused && $0.status != .closed }?.id
        }
        .onChange(of: worktree.agents) { previous, _ in
            // Teardown clears the slot before the final closed transition is persisted.
            if let focused = previous.first(where: { $0.paneSlotID != nil && $0.paneSlotID == lastFocused }) {
                lastFocusedAgentID = focused.id
            }
            if let closed = worktree.newlyClosedAgent(viewedAgentID: lastFocusedAgentID, previousAgents: previous) {
                archive = closed
            }
        }
        .onChange(of: worktree.splitTree.allLeaves) { _, _ in synchronize() }
        .onChange(of: worktree.agents.compactMap(\.paneSlotID)) { _, _ in synchronize() }
        .onChange(of: worktree.focusedPaneSlotID) { old, slot in
            if let slot {
                if worktree.splitTree.zoomed != slot { worktree.splitTree = worktree.splitTree.withZoom(nil) }
                mutate { $0.select(slot) }
                if old == nil || old.map(worktree.splitTree.containsLeaf) == true {
                    lastFocused = slot; lastFocusedAgentID = agent(slot)?.id; archive = nil
                }
            }
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
                                    if let agent = agent(tab) {
                                        AgentStatusBadge(status: agent.status.rawValue,
                                            needsInput: worktree.paneAttention[tab]?.source == .agentStop,
                                            failure: agent.failure, disconnected: terminalManager.attachmentFailures[tab] != nil,
                                            processObservation: agent.processObservation)
                                    } else if worktree.paneAttention[tab] != nil {
                                        Image(systemName: "circle.fill").font(.system(size: 5)).accessibilityLabel("Needs attention")
                                    }
                                }.padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(group?.selected == tab ? theme.foreground.opacity(0.10) : .clear)
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(group?.selected == tab ? .isSelected : [])
                                .draggable(tab.id.uuidString)
                                .contextMenu { tabMenu(tab, group: group?.id) }
                        }
                    }
                }
                newAgentMenu
            }.font(.system(size: 12))
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
                    guard worktree.splitTree.containsLeaf(session) else { return false }
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
        } else if let agent = agent(slot), let completion = agent.completion, agent.requiresAcknowledgment {
            Button(completion.outcome == .interrupted || completion.outcome == .failed ? "Acknowledge and close agent" : "Close completed agent") { perform(.init(action: .close, callerWorktree: worktree.path, agentID: agent.id, completionID: completion.id)) }
        }
    }

    private var drawerHeader: some View {
        HStack(spacing: 10) {
            Button {
                if layout.drawerVisible {
                    var next = layout
                    let previous = next.hideDrawer()
                    worktree.workspaceLayout = next
                    if let previous { onFocusTerminal(previous) }
                } else {
                    mutate { $0.drawerVisible = true }
                    if let slot = layout.selectedTerminal { focus(slot) }
                }
            } label: {
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
            .padding(.horizontal, 8)
    }

    private func launch(_ provider: TeamHookRuntime) {
        perform(.init(action: .add, callerWorktree: worktree.path, name: "\(provider.displayName) \(worktree.agents.count + 1)",
            worktree: worktree.path, provider: provider, operationID: UUID().uuidString))
    }
    private func perform(_ operation: AgentControlRequest) {
        guard let request else { failure = "Agent controls are not ready."; return }
        launching = true
        Task { @MainActor in
            defer { launching = false }
            let response = await request(operation)
            if case .error(let message) = response { failure = message }
        }
    }
    private func agent(_ slot: PaneSlotID) -> ManagedAgent? { worktree.agents.first { $0.paneSlotID == slot && $0.status != .closed } }
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
        archive = nil; lastFocused = slot; lastFocusedAgentID = agent(slot)?.id
        if worktree.splitTree.zoomed != slot { worktree.splitTree = worktree.splitTree.withZoom(nil) }
        mutate { $0.select(slot) }; onFocusTerminal(slot)
    }
    private func synchronize() {
        worktree.ensureWorkspaceLayout()
        if let focused = worktree.focusedPaneSlotID { mutate { $0.select(focused) } }
    }
    private func receive(_ providers: [NSItemProvider], action: @escaping @MainActor (PaneSlotID) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let value = object as? String, let id = UUID(uuidString: value) else { return }
            Task { @MainActor in
                let slot = PaneSlotID(id: id)
                guard worktree.splitTree.containsLeaf(slot) else { return }
                action(slot)
            }
        }
        return true
    }
}
