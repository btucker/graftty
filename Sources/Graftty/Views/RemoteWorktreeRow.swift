import SwiftUI
import GrafttyKit
import GrafttyProtocol

/// @spec SYNC-5.1 (rendering; inventory spec in SyncTodo.swift)
/// A teammate's worktree, rendered read-only and ambient: dim person icon,
/// dimmed branch text, italic running hint, owner badge at the trailing
/// edge. Deliberately quieter than local rows.
struct RemoteWorktreeRow: View {
    let presence: RemoteWorktreePresence
    let theme: GhosttyTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "person")
                .font(.caption)
                .foregroundColor(theme.sidebarDimIcon)
            Text(presence.branch)
                .foregroundColor(theme.sidebarSecondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            if presence.state == .running {
                Text("running")
                    .font(.caption)
                    .italic()
                    .foregroundColor(theme.sidebarSecondaryText)
            }
            Spacer()
            Text(presence.ownerName)
                .font(.caption)
                .foregroundColor(theme.sidebarSecondaryText)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(presence.ownerName) worktree \(presence.branch)" + (presence.state == .running ? ", running" : ""))
    }
}
