#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// The creation record uses the terminal's content region on both phone and
/// tablet. Opening a terminal after failure or interruption is an explicit act.
struct MobileCreationDetailView: View {
    let host: Host
    let worktree: WorktreePanes
    var theme: GhosttyThemeColors? = nil
    @Environment(\.remoteConnectionCoordinator) private var coordinator
    @State private var opening = false
    @State private var error: String?

    var body: some View {
        if let progress = worktree.creationProgress {
            WorktreeCreationDetailView(progress: progress,
                foreground: theme?.foreground ?? .primary,
                background: theme?.background ?? Color(uiColor: .systemBackground),
                onOpenTerminal: worktree.state == .closed ? openTerminal : nil)
                .disabled(opening)
                .alert("Could not open terminal", isPresented: Binding(
                    get: { error != nil }, set: { if !$0 { error = nil } }
                )) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        }
    }

    private func openTerminal() {
        guard !opening else { return }
        opening = true
        let provider = makeRemoteConnectionProvider(coordinator: coordinator, host: host,
            sessionName: "worktree-management")
        Task { @MainActor in
            defer { opening = false }
            do {
                let response = try await RelayedWorktreeManagementClient.send(.open(worktreeID: worktree.path), using: provider)
                if case .error(_, let message, _, _) = response { error = message }
                else if response != .ok { error = "The host returned an unexpected response." }
            } catch { self.error = error.localizedDescription }
        }
    }
}
#endif
