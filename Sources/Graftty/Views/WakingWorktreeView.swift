import SwiftUI
import GrafttyKit
import GrafttyProtocol

struct WakeFlow: Identifiable {
    enum Phase { case waking, failed }
    let id = UUID()
    let remoteMac: RemoteMac
    let worktreePath: String
    let phase: Phase
}

/// Shown in place of the terminal while a sleeping host wakes.
struct WakingWorktreeView: View {
    let flow: WakeFlow
    let theme: GhosttyTheme
    let onTryAgain: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            switch flow.phase {
            case .waking:
                ProgressView().controlSize(.small)
                Text("Waking \(flow.remoteMac.label)…")
            case .failed:
                Text("\(flow.remoteMac.label) didn't respond.")
                Text("Waking only works on its local network.")
                    .font(.caption).foregroundColor(theme.foreground.opacity(0.6))
                Button("Try Again", action: onTryAgain)
            }
        }
        .foregroundColor(theme.foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
