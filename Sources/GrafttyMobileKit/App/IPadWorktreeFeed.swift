#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// @spec IPAD-1.24: While the iPad layout displays a paired host, the application shall apply the host's pushed panes-state frames to the shared worktree state from outside the split view's columns, so the collapsed-sidebar attention indicator (IPAD-1.11) stays current without the sidebar list on screen.
struct IPadWorktreeFeed: ViewModifier {
    let host: Host?
    let updates: (@MainActor () -> AsyncStream<RemoteWorktreeUpdate>?)?
    let appState: IPadAppState
    /// Runs after each applied frame, for the layout's pending pane mutations.
    let didApply: @MainActor ([WorktreePanes]) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.biometricGate) private var gate

    private var isReady: Bool {
        LiveSessionReadiness.isActive(scene: scenePhase, gateUnlocked: gate.isUnlocked)
    }

    func body(content: Content) -> some View {
        content.task(id: Key(hostID: host?.id, isReady: isReady, hasUpdates: updates != nil)) {
            await observe()
        }
    }

    private func observe() async {
        guard isReady, let host, let updates = updates?() else { return }
        // Compare with what this observation applied, not with
        // `latestWorktrees`: RootView seeds that from activation fetches
        // without recomputing what derives from it (IPAD-1.25).
        var applied: [WorktreePanes]?
        for await update in updates {
            guard !Task.isCancelled, appState.selectedHostId == host.id else { return }
            guard case let .frame(.snapshot(list, _)) = update else {
                // Keep the last rows while the host is unreachable.
                continue
            }
            // A sidebar-only frame repeats the rows (IOS-4.31).
            guard list != applied else { continue }
            applied = list
            IPadRootLayout.onWorktreeListChanged(appState: appState, list: list)
            didApply(list)
        }
    }

    private struct Key: Hashable {
        let hostID: UUID?
        let isReady: Bool
        let hasUpdates: Bool
    }
}
#endif
