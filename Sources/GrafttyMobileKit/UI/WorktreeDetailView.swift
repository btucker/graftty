#if canImport(UIKit)
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
    /// Resolves the per-host `RemoteHostConnection` for the preview pool
    /// so pane previews ride SSH-over-WebRTC when `host` is paired,
    /// failing closed when no authenticated channel is available. `nil` in
    /// contexts that construct this view directly (previews / focused tests).
    public let coordinator: RemoteConnectionCoordinator?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate

    @State private var baseConfig: String?
    @State private var baseConfigHostID: UUID?
    @State private var preferredStyle: UIUserInterfaceStyle = .unspecified
    @State private var previews: PanePreviewClientPool<SessionClient>?

    public init(
        host: Host,
        worktree: WorktreePanes,
        coordinator: RemoteConnectionCoordinator? = nil,
        onSelectPane: @escaping (_ sessionName: String) -> Void
    ) {
        self.host = host
        self.worktree = worktree
        self.coordinator = coordinator
        self.onSelectPane = onSelectPane
    }

    public var body: some View {
        Group {
            if let layout = worktree.layout {
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
        .navigationTitle(worktree.displayName)
        .navigationBarTitleDisplayMode(.inline)
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
        .task(id: PoolKey(layout: worktree.layout, scene: scenePhase, gateUnlocked: gate.isUnlocked)) {
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

    private struct PoolKey: Hashable {
        let layout: PaneLayoutNode?
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
        guard let layout = worktree.layout else { return }
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
                    baseURL: host.baseURL,
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
