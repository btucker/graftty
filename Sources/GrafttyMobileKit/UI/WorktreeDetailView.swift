#if canImport(UIKit)
import GhosttyTerminal
import GrafttyProtocol
import SwiftUI

private let maxLivePanePreviews = 2

/// Second "inside a host" screen — shows the split-faithful tree of
/// panes for the selected worktree. Tapping a pane tile pushes a
/// `SessionStep` onto the navigation stack which opens that pane's
/// terminal fullscreen.
public struct WorktreeDetailView: View {
    public let host: Host
    public let worktree: WorktreePanes
    public let onSelectPane: (_ sessionName: String) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate

    @State private var controller: TerminalController?
    @State private var previews: PanePreviewClientPool<SessionClient>?

    public init(
        host: Host,
        worktree: WorktreePanes,
        onSelectPane: @escaping (_ sessionName: String) -> Void
    ) {
        self.host = host
        self.worktree = worktree
        self.onSelectPane = onSelectPane
    }

    public var body: some View {
        Group {
            if let layout = worktree.layout {
                PaneLayoutView(
                    layout: layout,
                    controller: controller,
                    previewClient: { previews?.clients[$0] }
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
            if controller == nil {
                let text = await GhosttyConfigFetcher.fetch(baseURL: host.baseURL)
                controller = TerminalController(
                    configSource: text.map { .generated($0) } ?? .none
                )
            }
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
        if scenePhase == .background {
            previews?.stopAll()
            return
        }
        guard LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked) else { return }
        guard let layout = worktree.layout else { return }
        if previews == nil {
            previews = PanePreviewClientPool { sessionName in
                SessionClient.live(baseURL: host.baseURL, sessionName: sessionName)
            }
        }
        previews?.update(layout: layout, maxLivePreviews: maxLivePanePreviews)
    }
}
#endif
