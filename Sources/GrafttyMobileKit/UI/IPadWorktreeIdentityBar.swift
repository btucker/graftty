#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// IPAD-1.31: the iPad workspace leads with the worktree's identity on its
/// emoji wash. The name opens the agent cards the phone shows.
struct IPadWorktreeIdentityBar: View {
    let host: Host
    let worktree: WorktreePanes
    let context: SidebarWorktreeContext
    let theme: GhosttyThemeColors
    let onSelect: (String) -> Void
    @State private var showsAgents = false

    private var overview: MobileWorktreeOverview { MobileWorktreeOverview(worktree: worktree, context: context) }
    private var project: SidebarProject? { SidebarProjection.projects([worktree]).first }

    var body: some View {
        let overview = overview
        VStack(alignment: .leading, spacing: 3) {
            Button { showsAgents = true } label: {
                HStack(spacing: 8) {
                    if let project {
                        WorktreeIdentityView(identity: worktree.iconIdentity, project: project, size: 20)
                    }
                    Text(worktree.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.foreground.opacity(0.55))
                    if let badge = worktree.prBadge { SidebarPRBadge(badge: badge) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(overview.agents.isEmpty && overview.terminals.isEmpty)
            .accessibilityIdentifier("workspace.identity")
            .accessibilityHint("Shows this worktree's agents")
            .popover(isPresented: $showsAgents) {
                ScrollView {
                    MobileWorktreeOverviewView(host: host, overview: overview, theme: theme) { session in
                        showsAgents = false
                        onSelect(session)
                    }
                    .padding(.top, 14)
                }
                .frame(minWidth: 360, idealWidth: 380, minHeight: 320, idealHeight: 480)
                .background(theme.background)
                .environment(\.colorScheme, theme.isDark ? .dark : .light)
            }
            if let purpose = overview.purpose {
                Text(purpose).font(.subheadline).foregroundStyle(theme.foreground.opacity(0.78)).lineLimit(1)
            }
        }
        .foregroundStyle(theme.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
#endif
