#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

/// One agent as a mobile gallery tile shows it.
struct MobileGalleryAgent: Identifiable, Equatable {
    /// The agent's terminal session.
    let id: String
    let title: String
    let status: AgentTileStatus

    /// Agents with a terminal or a retained result, in the given order.
    static func agents(in worktree: WorktreePanes, context: SidebarWorktreeContext, order: [String]? = nil) -> [MobileGalleryAgent] {
        let all: [MobileGalleryAgent] = (worktree.agents ?? []).compactMap { agent in
            guard let session = agent.presentationSessionName else { return nil }
            let needsInput = context.needsInput(session: session)
            return MobileGalleryAgent(id: session, title: worktree.workspaceSessionTitle(session),
                status: AgentTileStatus(needsInput: needsInput,
                    isBusy: worktree.layout?.leaves.first { $0.sessionName == session }?.isBusy == true,
                    isCompleted: agent.isCompleted, isCached: false, question: context.question(session: session),
                    result: agent.result, statusLabel: AgentAssignmentStatus(agent: agent, needsInput: needsInput).label))
        }
        guard let order else { return all }
        return order.compactMap { session in all.first { $0.id == session } }
            + all.filter { !order.contains($0.id) }
    }
}

/// Owns the watch-only preview clients and the host's terminal config for
/// the tiles on screen. Tiles attach in the preview role, so they never
/// resize a terminal or take display ownership.
@MainActor @Observable
final class MobileGalleryPreviews {
    private(set) var baseConfig: String?
    private(set) var preferredStyle: UIUserInterfaceStyle = .unspecified
    private var pool: PanePreviewClientPool<SessionClient>?
    private var hostID: UUID?

    func client(for session: String) -> SessionClient? { pool?.clients[session] }

    func loadConfig(host: Host, coordinator: RemoteConnectionCoordinator?) async {
        guard baseConfig == nil || hostID != host.id else { return }
        let text = await coordinator?.presentation(for: host)?.ghosttyConfig
        guard !Task.isCancelled else { return }
        preferredStyle = GhosttyConfigFetcher.preferredInterfaceStyle(for: text)
        baseConfig = text ?? ""
    }

    func keepLive(_ sessions: [String], host: Host, coordinator: RemoteConnectionCoordinator?) {
        if hostID != host.id {
            pool?.stopAll()
            pool = nil
            hostID = host.id
        }
        if pool == nil {
            // Resolve the connection on every dial, as the worktree detail's previews do.
            pool = PanePreviewClientPool { sessionName in
                SessionClient.live(sessionName: sessionName, role: .preview,
                    remoteConnectionProvider: makeRemoteConnectionProvider(coordinator: coordinator, host: host, sessionName: sessionName))
            }
        }
        pool?.update(sessions: sessions)
        pool?.resumeAll()
    }

    func suspend() { pool?.suspendAll() }
    func stop() { pool?.stopAll(); pool = nil }
}

/// One mobile gallery tile: a live preview when it has a client, otherwise
/// its caption alone, with the agent's scroll rail on the right edge.
struct MobileGalleryTile: View {
    let agent: MobileGalleryAgent
    let isOnStage: Bool
    let client: SessionClient?
    let previews: MobileGalleryPreviews
    let timeline: WorktreeTimeline?
    let theme: GhosttyThemeColors
    let onJump: (Int) -> Void
    @State private var container: TerminalInputContainerView?

    var body: some View {
        AgentGalleryTile(title: agent.title, status: agent.status, isOnStage: isOnStage,
                         foreground: theme.foreground, background: theme.background) {
            if let client {
                MobileTerminalPreview(client: client, baseConfig: previews.baseConfig,
                                      preferredInterfaceStyle: previews.preferredStyle,
                                      onContainer: { captured in if container !== captured { container = captured } })
            } else {
                Text(agent.status.caption).font(.caption2).foregroundStyle(theme.foreground.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(8)
            }
        } rail: {
            if client != nil, let container, let timeline {
                ScrollbackMapOverlayHost(model: container.scrollbackMapModel, timeline: timeline,
                                         previewOverhang: 200, previewWidth: 240, onJump: onJump)
            }
        }
    }
}

/// The tiles and the empty new-agent tile, laid out in a grid. Shared by the
/// iPad's gallery column and the phone's gallery screen.
struct MobileAgentGalleryGrid: View {
    let host: Host
    let worktree: WorktreePanes
    let context: SidebarWorktreeContext
    let agents: [MobileGalleryAgent]
    let onStage: Set<String>
    let columns: Int
    let tileSize: CGSize
    let theme: GhosttyThemeColors
    /// At most this many tiles show a live terminal at once (IOS-13.33).
    var liveLimit = 4
    let onSelect: (String) -> Void
    let onJump: (String, Int) -> Void
    let onNewAgent: (String) -> Void
    /// Dragging a tile before or after another reorders the gallery, where supported.
    var onMove: ((String, String, Bool) -> Void)? = nil

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate
    @Environment(\.remoteConnectionCoordinator) private var coordinator
    @State private var previews = MobileGalleryPreviews()
    @State private var visible: Set<String> = []

    private var isReady: Bool { LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) }
    private var liveSessions: [String] {
        let live = agents.filter { !$0.status.isDimmed }.map(\.id)
        return AgentGalleryPreviewBudget.live(sessions: live, visible: visible, limit: liveLimit)
    }

    var body: some View {
        let grid = Array(repeating: GridItem(.fixed(tileSize.width), spacing: 10), count: columns)
        LazyVGrid(columns: grid, spacing: 10) {
            ForEach(agents) { agent in
                Button { onSelect(agent.id) } label: {
                    MobileGalleryTile(agent: agent, isOnStage: onStage.contains(agent.id),
                        client: liveSessions.contains(agent.id) ? previews.client(for: agent.id) : nil,
                        previews: previews,
                        timeline: context.scrollbackPaneIDs.contains(agent.id) ? WorktreeTimeline(context) : nil,
                        theme: theme, onJump: { onJump(agent.id, $0) })
                }
                .buttonStyle(.plain)
                .frame(width: tileSize.width, height: tileSize.height)
                .accessibilityIdentifier("workspace.gallery.tile.\(agent.id)")
                .modifier(MobileGalleryReorder(session: agent.id, onMove: onMove))
                .onAppear { visible.insert(agent.id) }
                .onDisappear { visible.remove(agent.id) }
            }
            MobileNewAgentMenu(host: host, worktree: worktree.path, onSelect: onNewAgent,
                               label: AnyView(AgentGalleryEmptyTile(foreground: theme.foreground)
                                   .frame(width: tileSize.width, height: tileSize.height)))
                .frame(width: tileSize.width, height: tileSize.height)
                .accessibilityIdentifier("workspace.gallery.newAgent")
        }
        .task(id: host.id) { await previews.loadConfig(host: host, coordinator: coordinator) }
        .task(id: LiveKey(sessions: liveSessions, isReady: isReady, suspended: LiveSessionReadiness.shouldSuspendTransport(scene: scenePhase))) {
            if LiveSessionReadiness.shouldSuspendTransport(scene: scenePhase) { previews.suspend(); return }
            guard isReady else { return }
            previews.keepLive(liveSessions, host: host, coordinator: coordinator)
        }
        .onDisappear { previews.stop() }
    }

    private struct LiveKey: Hashable { let sessions: [String]; let isReady: Bool; let suspended: Bool }
}

private struct MobileGalleryReorder: ViewModifier {
    let session: String
    let onMove: ((String, String, Bool) -> Void)?

    func body(content: Content) -> some View {
        if let onMove {
            content.draggable(WorkspaceTabDrag(session))
                .modifier(WorkspaceTabDropTarget(vertical: true) { source, after in onMove(source, session, after) })
        } else {
            content
        }
    }
}

/// The iPad's gallery: one column on the right of the worktree.
struct MobileAgentGalleryColumn: View {
    static let width: CGFloat = 240
    let host: Host
    let worktree: WorktreePanes
    let context: SidebarWorktreeContext
    let agents: [MobileGalleryAgent]
    let onStage: Set<String>
    let theme: GhosttyThemeColors
    let onSelect: (String) -> Void
    let onJump: (String, Int) -> Void
    let onNewAgent: (String) -> Void
    let onMove: (String, String, Bool) -> Void
    let onCollapse: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agents").font(.footnote.weight(.semibold)).foregroundStyle(theme.foreground.opacity(0.55))
                Spacer()
                Button(action: onCollapse) { Image(systemName: "sidebar.trailing").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(theme.foreground.opacity(0.6))
                    .accessibilityLabel("Hide agents")
            }
            .padding(.leading, 12)
            ScrollView(.vertical) {
                MobileAgentGalleryGrid(host: host, worktree: worktree, context: context, agents: agents, onStage: onStage,
                    columns: 1, tileSize: CGSize(width: Self.width - 20, height: 150), theme: theme,
                    onSelect: onSelect, onJump: onJump, onNewAgent: onNewAgent, onMove: onMove)
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
            .scrollClipDisabled()
        }
        .frame(width: Self.width)
        .background(theme.foreground.opacity(0.03))
        .overlay(alignment: .leading) { theme.foreground.opacity(0.08).frame(width: 1) }
    }
}

/// The phone's gallery: every agent, two by two or two stacked, filling the
/// screen (IOS-13.32). Typing happens only on the stage, so tiles are watch-only.
struct MobileAgentGalleryScreen: View {
    let host: Host
    let worktree: WorktreePanes
    let context: SidebarWorktreeContext
    let stagedSession: String
    let theme: GhosttyThemeColors
    let onSelect: (String) -> Void
    let onNewAgent: (String) -> Void
    var onOpenTerminal: (() -> Void)? = nil
    let onClose: () -> Void
    @Environment(\.openWorktreeContext) private var openContext

    @AppStorage("workspace.iphone.gallery.density") private var densityValue = AgentGalleryDensity.four.rawValue
    private var density: AgentGalleryDensity { AgentGalleryDensity(rawValue: densityValue) ?? .four }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onClose) { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                    .accessibilityLabel("Back to the terminal")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Agents").font(.headline)
                    Text(CompactAgentBar.location(worktree: worktree, hostLabel: host.label))
                        .font(.caption2).foregroundStyle(theme.foreground.opacity(0.65)).lineLimit(1)
                }
                Spacer()
                if let onOpenTerminal {
                    Button(action: onOpenTerminal) { Image(systemName: "apple.terminal").frame(width: 44, height: 44) }
                        .accessibilityLabel("Terminal").accessibilityIdentifier("workspace.terminal.open")
                }
                if let openContext {
                    Button { onClose(); openContext() } label: { Image(systemName: "info.circle").frame(width: 44, height: 44) }
                        .accessibilityLabel("About this worktree").accessibilityIdentifier("workspace.about.open")
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            GeometryReader { geometry in
                let size = density.tileSize(in: CGSize(width: geometry.size.width - 24, height: geometry.size.height - 12),
                                            spacing: 10)
                ScrollView(.vertical) {
                    MobileAgentGalleryGrid(host: host, worktree: worktree, context: context,
                        agents: MobileGalleryAgent.agents(in: worktree, context: context), onStage: [stagedSession],
                        columns: density.columns, tileSize: size, theme: theme,
                        onSelect: onSelect, onJump: { session, _ in onSelect(session) }, onNewAgent: onNewAgent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .animation(.snappy, value: densityValue)
                }
                .scrollClipDisabled()
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    densityValue = density.after(pinchScale: value.magnification).rawValue
                })
            }
        }
        .foregroundStyle(theme.foreground)
        .background(theme.background.ignoresSafeArea())
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}
#endif
