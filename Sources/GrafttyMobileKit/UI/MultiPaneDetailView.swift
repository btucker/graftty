#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

/// The regular-width iPad terminal surface. It renders the Mac-provided pane
/// tree directly and mounts one real, ownership-aware terminal session in
/// every leaf. The selected leaf is the sole UIKit keyboard owner, but all
/// sibling panes remain connected, live, and interactive for scrolling.
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

    @State private var workspace: WorkspaceLayout<String>?
    @State private var ratioOverrides = IPadPaneRatioOverrides()
    /// The tree's only keyboard subscription; embedded panes read it from
    /// the environment (IPAD-2.10).
    @State private var keyboardFrame = KeyboardFrameObservation()

    var body: some View {
        GeometryReader { geometry in
        Group {
            if worktree.showsCreationProgress {
                MobileCreationDetailView(host: host, worktree: worktree, theme: theme)
            } else if let inventory = worktree.layout {
                VStack(spacing: 0) {
                    if let visible = currentWorkspace.visiblePaneLayout(in: inventory) {
                        render(visible, at: .root)
                    } else {
                        Text("No active agents").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    terminalDrawerHeader
                    if currentWorkspace.drawerVisible, let session = currentWorkspace.selectedTerminal,
                       let leaf = inventory.leaves.first(where: { $0.sessionName == session }) {
                        render(.leaf(sessionName: session, title: leaf.title, attentionText: leaf.attentionText,
                            isBusy: leaf.isBusy, attentionSource: leaf.attentionSource, attentionTimestamp: leaf.attentionTimestamp), at: .root)
                            .frame(height: min(CGFloat(currentWorkspace.drawerHeight), geometry.size.height * 0.45))
                    }
                }
            } else {
                ContentUnavailableView(
                    "No panes running",
                    systemImage: "terminal"
                )
            }
        }
        }
        .onAppear {
            if workspace == nil {
                workspace = UserDefaults.standard.data(forKey: workspaceKey).flatMap {
                    try? JSONDecoder().decode(WorkspaceLayout<String>.self, from: $0)
                } ?? .initial(for: worktree)
            }
            reconcileWorkspace()
        }
        .onChange(of: worktree) { _, _ in reconcileWorkspace() }
        .onChange(of: focusedPaneId) { _, selected in
            if let selected { workspace?.select(selected) }
        }
        .onChange(of: workspace) { _, value in
            if let value, let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: workspaceKey) }
        }
        .environment(\.multiPaneKeyboardFrame, keyboardFrame)
        .padding(.bottom, keyboardFrame.bottomInset)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onKeyboardBottomInsetChange { inset in
            keyboardFrame = KeyboardFrameObservation(bottomInset: inset, sequence: keyboardFrame.sequence &+ 1)
        }
        .animation(.easeInOut(duration: 0.25), value: keyboardFrame.bottomInset)
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
                if let group = currentWorkspace.group(containing: sessionName) { tabHeader(group) }
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
                    onBackToWorktrees: onBackToWorktrees
                )
                .id(sessionName)
                }
                .dropDestination(for: String.self) { sessions, location in
                    guard let session = sessions.first, currentWorkspace.sessions.contains(session),
                          let group = currentWorkspace.group(containing: sessionName) else { return false }
                    if let edge = WorkspaceLayout<String>.dropEdge(x: location.x, y: location.y,
                        width: geometry.size.width, height: geometry.size.height) {
                        workspace?.split(session, beside: group.id, edge: edge)
                    } else { workspace?.move(session, to: group.id) }
                    onSelectPane(session)
                    return true
                }
                }
            )

        case let .split(direction, ratio, first, second):
            let identity = IPadPaneSplitIdentity(
                path: path,
                direction: direction,
                firstAnchor: first.leaves.first?.sessionName,
                secondAnchor: second.leaves.first?.sessionName
            )
            let ratioOverride = Binding<Double?>(
                get: { ratioOverrides[identity] },
                set: { value in
                    ratioOverrides[identity] = value
                }
            )
            return AnyView(
                MultiPaneSplitNode(
                    direction: direction,
                    sourceRatio: ratio,
                    ratioOverride: ratioOverride,
                    first: render(first, at: path.appending(.first)),
                    second: render(second, at: path.appending(.second))
                )
                .id(identity.renderIdentity)
            )
        }
    }

    private var workspaceKey: String { "workspace.ipad.\(host.id).\(worktree.path)" }
    private var currentWorkspace: WorkspaceLayout<String> { workspace ?? .initial(for: worktree) }
    private func reconcileWorkspace() {
        var next = currentWorkspace
        next.reconcile(live: worktree.layout?.leaves.map(\.sessionName) ?? [], agents: Set(worktree.agents?.compactMap(\.sessionName) ?? []))
        workspace = next
    }
    private func selectSession(_ session: String) {
        workspace?.select(session)
        onSelectPane(session)
    }
    private func sessionTitle(_ session: String) -> String {
        worktree.agents?.first { $0.sessionName == session }?.name ?? worktree.layout?.title(for: session) ?? "Terminal"
    }
    private func tabHeader(_ group: WorkspaceLayout<String>.Group) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(group.sessions, id: \.self) { session in
                    Button { selectSession(session) } label: {
                        HStack(spacing: 6) {
                            AgentProviderIcon(provider: worktree.agents?.first { $0.sessionName == session }?.provider)
                            Text(sessionTitle(session)).lineLimit(1)
                        }.padding(.horizontal, 10).frame(minHeight: 44)
                            .background(group.selected == session ? theme.foreground.opacity(0.10) : .clear)
                    }.buttonStyle(.plain)
                        .draggable(session)
                        .contextMenu {
                            Menu("Split into pane") {
                                ForEach(WorkspaceLayout<String>.Edge.allCases, id: \.rawValue) { edge in
                                    Button(edge.rawValue.capitalized) { workspace?.split(session, beside: group.id, edge: edge); onSelectPane(session) }
                                        .disabled(group.sessions.count < 2)
                                }
                            }
                            ForEach(currentWorkspace.groups.filter { $0.id != group.id }) { target in
                                Button("Move to \(sessionTitle(target.selected)) tab group") {
                                    workspace?.move(session, to: target.id); onSelectPane(session)
                                }
                                Button("Merge into \(sessionTitle(target.selected)) tab group") {
                                    workspace?.merge(group.id, into: target.id); onSelectPane(session)
                                }
                            }
                        }
                }
            }
        }.font(.caption).foregroundStyle(theme.foreground)
            .dropDestination(for: String.self) { sessions, _ in
                guard let session = sessions.first, currentWorkspace.sessions.contains(session) else { return false }
                workspace?.move(session, to: group.id); onSelectPane(session); return true
            }
    }
    private var terminalDrawerHeader: some View {
        HStack {
            Button {
                if currentWorkspace.drawerVisible {
                    if let previous = workspace?.hideDrawer() { onSelectPane(previous) }
                } else {
                    workspace?.drawerVisible = true
                    if let session = currentWorkspace.selectedTerminal { onSelectPane(session) }
                }
            } label: { Label("Terminal", systemImage: "terminal") }
            if currentWorkspace.drawerVisible {
                Menu {
                    ForEach(currentWorkspace.terminals, id: \.self) { session in
                        Button(sessionTitle(session)) { selectSession(session) }
                    }
                } label: { Text(currentWorkspace.selectedTerminal.map(sessionTitle) ?? "No terminals") }
            }
            Spacer()
            Button {
                ghosttyCommandContext.perform(.ghostty(.newSplitDown))
            } label: { Image(systemName: "plus") }.accessibilityLabel("New terminal").disabled(!ghosttyCommandContext.isEnabled(.newSplitDown))
        }.buttonStyle(.plain).font(.callout).padding(.horizontal, 12).frame(minHeight: 44)
            .foregroundStyle(theme.foreground).background(theme.background)
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

struct IPadPaneSplitIdentity: Hashable {
    let path: IPadPaneTreePath
    let direction: PaneLayoutNode.SplitAxis
    let firstAnchor: String?
    let secondAnchor: String?

    /// SwiftUI node identity stays path-stable so topology edits preserve
    /// surviving terminal views. The full identity remains the ratio-cache key.
    var renderIdentity: IPadPaneTreePath { path }
}

struct IPadPaneTreePath: Hashable {
    enum Branch: Hashable {
        case first
        case second
    }

    static let root = IPadPaneTreePath(branches: [])

    let branches: [Branch]

    func appending(_ branch: Branch) -> IPadPaneTreePath {
        IPadPaneTreePath(branches: branches + [branch])
    }
}

struct IPadPaneRatioOverrides {
    private var values: [IPadPaneSplitIdentity: Double] = [:]

    subscript(identity: IPadPaneSplitIdentity) -> Double? {
        get { values[identity] }
        set { values[identity] = newValue }
    }

    func ratio(
        at identity: IPadPaneSplitIdentity,
        sourceRatio: Double
    ) -> Double {
        values[identity] ?? sourceRatio
    }
}

private struct MultiPaneSplitNode: View {
    let direction: PaneLayoutNode.SplitAxis
    let sourceRatio: Double
    @Binding var ratioOverride: Double?
    let first: AnyView
    let second: AnyView

    @State private var displayedRatio: Double

    init(
        direction: PaneLayoutNode.SplitAxis,
        sourceRatio: Double,
        ratioOverride: Binding<Double?>,
        first: AnyView,
        second: AnyView
    ) {
        self.direction = direction
        self.sourceRatio = sourceRatio
        self._ratioOverride = ratioOverride
        self.first = first
        self.second = second
        self._displayedRatio = State(
            initialValue: ratioOverride.wrappedValue ?? sourceRatio
        )
    }

    var body: some View {
        ProportionalSplitView(
            direction: direction,
            ratio: $displayedRatio,
            first: first,
            second: second,
            onDragEnd: { ratioOverride = $0 }
        )
        .onChange(of: sourceRatio) { _, newRatio in
            guard ratioOverride == nil else { return }
            displayedRatio = newRatio
        }
        .onChange(of: ratioOverride) { _, override in
            displayedRatio = override ?? sourceRatio
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
            onPaneInteraction: onSelect,
            onBackToWorktrees: onBackToWorktrees
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
