import SwiftUI
import GrafttyKit
import GrafttyProtocol

struct WakeFlow {
    enum Phase: Equatable { case waking, failed(message: String) }
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
                Text("Connecting to \(flow.remoteMac.label)…")
            case .failed(let message):
                Text("\(flow.remoteMac.label) didn't respond.")
                Text(message)
                    .font(.caption).foregroundColor(theme.foreground.opacity(0.6))
                Button("Try Again", action: onTryAgain)
            }
        }
        .foregroundColor(theme.foreground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
