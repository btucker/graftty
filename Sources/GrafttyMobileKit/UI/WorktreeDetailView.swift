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
        .task(id: host.id) {
            baseConfig = nil
            let text = await coordinator?
                .presentation(for: host)?
                .ghosttyConfig
            preferredStyle = GhosttyConfigFetcher.preferredInterfaceStyle(for: text)
            baseConfig = text ?? ""
        }
        // Re-keys on layout / scene-phase / gate transitions so we tear
        // the pool down on `.background` and rebuild on `.active +
        // unlocked`.
        .task(id: PoolKey(layout: worktree.layout, scene: scenePhase, gateUnlocked: gate.isUnlocked)) {
            await driveLifecycle()
        }
        .onDisappear {
            previews?.stopAll()
        }
    }

    private struct PoolKey: Hashable {
        let layout: PaneLayoutNode?
        let scene: ScenePhase
        let gateUnlocked: Bool
    }

    private func driveLifecycle() async {
        if LiveSessionReadiness.shouldTearDown(scene: scenePhase) {
            previews?.stopAll()
            // The negotiated `RemoteHostConnection` itself is torn down at
            // `RootView`'s `.background`-only `coordinator.invalidateAll()`,
            // not here — this branch also fires on `.inactive`, where the
            // shared connection must survive. The pool's own clients
            // re-resolve a fresh connection per dial (below) once
            // `invalidateAll()` has evicted it.
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
            // `stopAll()` above clears every preview client, and when
            // `update(layout:)` rebuilds them below, each fresh
            // `SessionClient` asks the coordinator fresh rather than
            // inheriting a connection captured back when the pool itself
            // was first built.
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
    }
}
#endif
