import SwiftUI
import GrafttyKit

/// 4×3 routing matrix UI (TEAM-1.8). Each cell binds to one bit of the
/// corresponding `RecipientSet` field on `TeamEventRoutingPreferences`.
struct ChannelRoutingMatrixView: View {
    @Binding var prefs: TeamEventRoutingPreferences

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            // Header
            GridRow {
                Text("")
                Text("Root agent")
                    .font(.caption.weight(.semibold))
                    .gridColumnAlignment(.center)
                Text("Worktree agent")
                    .font(.caption.weight(.semibold))
                    .gridColumnAlignment(.center)
                Text("Other worktree agents")
                    .font(.caption.weight(.semibold))
                    .gridColumnAlignment(.center)
            }
            Divider().gridCellColumns(4)

            row("PR/MR state changed",     keyPath: \.prStateChanged)
            row("PR/MR merged",            keyPath: \.prMerged)
            row("CI conclusion changed",   keyPath: \.ciConclusionChanged)
            row("Mergability changed",     keyPath: \.mergabilityChanged)
        }
    }

    @ViewBuilder
    private func row(
        _ label: String,
        keyPath: WritableKeyPath<TeamEventRoutingPreferences, RecipientSet>
    ) -> some View {
        GridRow {
            Text(label)
            cellToggle(keyPath: keyPath, recipient: .root)
            cellToggle(keyPath: keyPath, recipient: .worktree)
            cellToggle(keyPath: keyPath, recipient: .otherWorktrees)
        }
    }

    private func cellToggle(
        keyPath: WritableKeyPath<TeamEventRoutingPreferences, RecipientSet>,
        recipient: RecipientSet
    ) -> some View {
        Toggle("", isOn: Binding<Bool>(
            get: { prefs[keyPath: keyPath].contains(recipient) },
            set: { newValue in
                if newValue { prefs[keyPath: keyPath].insert(recipient) }
                else        { prefs[keyPath: keyPath].remove(recipient) }
            }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .gridColumnAlignment(.center)
    }
}
