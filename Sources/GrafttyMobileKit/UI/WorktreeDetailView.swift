#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

/// Second "inside a host" screen — shows the split-faithful tree of
/// panes for the selected worktree. Tapping a pane tile pushes a
/// `SessionStep` onto the navigation stack which opens that pane's
/// terminal fullscreen.
public struct WorktreeDetailView: View {
    public let host: Host
    public let worktree: WorktreePanes
    public let onSelectPane: (_ sessionName: String) -> Void
    let sidebarNavigation: SidebarNavigationState?
    private var context: SidebarWorktreeContext {
        sidebarNavigation?.worktreeContext(currentWorktree) ?? SidebarWorktreeContext(worktree: currentWorktree)
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate
    /// Resolves the per-host `RemoteHostConnection` for the preview pool
    /// so pane previews ride SSH-over-WebRTC when `host` is paired,
    /// failing closed when no authenticated channel is available.
    @Environment(\.remoteConnectionCoordinator) private var coordinator

    @Environment(\.remoteWorktreeUpdates) private var worktreeUpdates
    @State private var liveCreation: CreationSnapshot?
    private var creationIdentity: CreationIdentity {
        .init(hostID: host.id, path: worktree.path, operationID: worktree.creationProgress?.operationID)
    }
    private var currentWorktree: WorktreePanes {
        if let liveCreation, liveCreation.identity == creationIdentity { return liveCreation.worktree }
        return worktree
    }

    @State private var baseConfig: String?
    @State private var baseConfigHostID: UUID?
    @State private var preferredStyle: UIUserInterfaceStyle = .unspecified
    @State private var previews: PanePreviewClientPool<SessionClient>?

    public init(
        host: Host,
        worktree: WorktreePanes,
        sidebarNavigation: SidebarNavigationState? = nil,
        onSelectPane: @escaping (_ sessionName: String) -> Void
    ) {
        self.host = host
        self.worktree = worktree
        self.sidebarNavigation = sidebarNavigation
        self.onSelectPane = onSelectPane
    }

    private var theme: GhosttyThemeColors { GhosttyThemeColors(parsingConfigText: baseConfig ?? "") }
    /// IOS-4.55: worktrees with agents get agent cards instead of pane tiles.
    private var overview: MobileWorktreeOverview? {
        guard !currentWorktree.showsCreationProgress,
              CompactTerminalPresentation.agentWorkspace(path: currentWorktree.path, rows: [currentWorktree], fallback: nil) != nil
        else { return nil }
        return MobileWorktreeOverview(worktree: currentWorktree, context: context)
    }

    public var body: some View {
        content
        .toolbar { ToolbarItem(placement: .topBarTrailing) { WorktreePreviewMenu(host: host, worktree: worktree.path) } }
        .navigationTitle(currentWorktree.showsCreationProgress ? currentWorktree.displayName : "")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: CreationKey(identity: creationIdentity,
            isReady: LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked))) {
            await observeCreation()
        }
        .task(id: ConfigurationKey(
            hostID: host.id,
            isReady: LiveSessionReadiness.isActive(
                scene: scenePhase,
                gateUnlocked: gate.isUnlocked
            )
        )) {
            guard LiveSessionReadiness.isActive(
                scene: scenePhase,
                gateUnlocked: gate.isUnlocked
            ) else { return }
            if baseConfigHostID != host.id {
                baseConfigHostID = host.id
                baseConfig = nil
            }
            // Preserve an already-loaded config across lifecycle rekeys. A
            // nil value means an earlier fetch was canceled before it could
            // safely publish, so foregrounding should try again.
            guard baseConfig == nil else { return }
            let text = await coordinator?
                .presentation(for: host)?
                .ghosttyConfig
            guard !Task.isCancelled,
                  LiveSessionReadiness.isActive(
                      scene: scenePhase,
                      gateUnlocked: gate.isUnlocked
                  )
            else { return }
            preferredStyle = GhosttyConfigFetcher.preferredInterfaceStyle(for: text)
            baseConfig = text ?? ""
        }
        // Re-keys on layout / scene-phase / gate transitions. Transient
        // `.inactive` phases preserve live transport; `.background` suspends
        // transport without releasing preview surfaces, and `.active +
        // unlocked` resumes those same clients.
        .task(id: PoolKey(layout: currentWorktree.layout, showsCreationProgress: currentWorktree.showsCreationProgress, usesOverview: overview != nil,
                         scene: scenePhase, gateUnlocked: gate.isUnlocked)) {
            await driveLifecycle()
        }
        .onDisappear {
            // A compact NavigationStack push temporarily removes this view
            // from the window. Preserve the preview clients so returning does
            // not manufacture four fresh Ghostty surfaces at once; the pool
            // dies with this view when it is actually popped.
            previews?.suspendAll()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let overview {
            ScrollView {
                VStack(spacing: 0) {
                    MobileWorktreeIdentityHeader(worktree: currentWorktree, purpose: overview.purpose, theme: theme)
                    MobileWorktreeOverviewView(host: host, overview: overview, theme: theme, onSelect: onSelectPane)
                }
            }
            .background(alignment: .top) { MobileWorktreeHeaderWash(worktree: currentWorktree, theme: theme) }
            .background(theme.background.ignoresSafeArea())
            .environment(\.colorScheme, theme.isDark ? .dark : .light)
            .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            VStack(spacing: 0) {
                if !currentWorktree.showsCreationProgress {
                    MobileWorktreeIdentityHeader(worktree: currentWorktree,
                        purpose: MobileWorktreeOverview(worktree: currentWorktree, context: context).purpose, theme: theme)
                }
                paneContent
            }
            .background(alignment: .top) {
                if !currentWorktree.showsCreationProgress { MobileWorktreeHeaderWash(worktree: currentWorktree, theme: theme) }
            }
        }
    }


    @ViewBuilder
    private var paneContent: some View {
        Group {
            if currentWorktree.showsCreationProgress {
                MobileCreationDetailView(host: host, worktree: currentWorktree)
            } else if let layout = currentWorktree.layout {
                PaneLayoutView(
                    layout: layout,
                    baseConfig: baseConfig,
                    previewClient: { previews?.clients[$0] },
                    preferredInterfaceStyle: preferredStyle
                ) { sessionName in
                    onSelectPane(sessionName)
                }
            } else {
                ContentUnavailableView(
                    "No panes running",
                    systemImage: "terminal",
                    description: Text("Start a pane in Graftty on the Mac to see it here.")
                )
            }
        }

    }

    private struct CreationIdentity: Hashable {
        let hostID: UUID
        let path: String
        let operationID: String?
    }

    private struct CreationSnapshot {
        let identity: CreationIdentity
        let worktree: WorktreePanes
    }

    private struct CreationKey: Hashable {
        let identity: CreationIdentity
        let isReady: Bool
    }

    /// The compact picker leaves the screen while diagnostics are selected.
    /// Keep observing the shared push feed here, rather than freezing the
    /// navigation destination's initial snapshot or opening a terminal early.
    private func observeCreation() async {
        guard LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked),
              let updates = worktreeUpdates?(host) else { return }
        let observesCreation = currentWorktree.showsCreationProgress
        for await update in updates {
            guard !Task.isCancelled else { return }
            guard case .frame(.snapshot(let rows, _)) = update,
                  let row = rows.first(where: { $0.path == worktree.path }) else { continue }
            // IOS-4.55: agent cards follow live status after creation too.
            guard observesCreation else {
                liveCreation = CreationSnapshot(identity: creationIdentity, worktree: row)
                continue
            }
            guard row.creationProgress?.operationID == worktree.creationProgress?.operationID else { continue }
            // Publish readiness before navigating. A lifecycle restart or
            // return to this destination must not consume a replay twice.
            liveCreation = CreationSnapshot(identity: creationIdentity, worktree: row)
            if !row.showsCreationProgress, row.state == .running,
               row.layout?.isLeaf == true, let pane = row.layout?.leaves.first {
                onSelectPane(pane.sessionName)
                return
            }
        }
    }

    private struct PoolKey: Hashable {
        let layout: PaneLayoutNode?
        let showsCreationProgress: Bool
        let usesOverview: Bool
        let scene: ScenePhase
        let gateUnlocked: Bool
    }

    private struct ConfigurationKey: Hashable {
        let hostID: UUID
        let isReady: Bool
    }

    private func driveLifecycle() async {
        guard !Task.isCancelled else { return }
        if LiveSessionReadiness.shouldSuspendTransport(scene: scenePhase) {
            previews?.suspendAll()
            // RootView's coordinator access gate tears down the negotiated
            // connection on the same `.background` transition. Each preserved
            // client re-resolves a fresh connection when resumed.
            return
        }
        guard LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) else { return }
        guard !currentWorktree.showsCreationProgress, let layout = currentWorktree.layout else { return }
        // IOS-4.55: agent cards render from metadata, not live pane previews.
        guard overview == nil else {
            previews?.stopAll()
            previews = nil
            return
        }
        // IOS-4.14: skip the preview terminal pool for single-pane worktrees.
        guard !layout.isLeaf else {
            previews?.stopAll()
            previews = nil
            return
        }
        if previews == nil {
            // The factory below re-resolves `coordinator.connection(for:)`
            // on EVERY dial (not once at pool-construction time) — the
            // same per-dial provider `SessionClient.live` uses for the
            // fullscreen path. That's what keeps a background→foreground
            // cycle from reusing a stale, already-invalidated connection:
            // each resumed `SessionClient` asks the coordinator fresh rather
            // than retaining the previous authenticated connection.
            previews = PanePreviewClientPool { [coordinator, host] sessionName in
                SessionClient.live(
                    sessionName: sessionName,
                    role: .preview,
                    remoteConnectionProvider: makeRemoteConnectionProvider(coordinator: coordinator, host: host, sessionName: sessionName)
                )
            }
        }
        previews?.update(layout: layout)
        previews?.resumeAll()
    }
}
#endif
