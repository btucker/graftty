#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// The worktree's identity at the top of the phone screen, on the same emoji
/// wash the Mac draws behind its header.
struct MobileWorktreeIdentityHeader: View {
    let worktree: WorktreePanes
    let purpose: String?
    let theme: GhosttyThemeColors

    private var project: SidebarProject? { SidebarProjection.projects([worktree]).first }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(worktree.repoDisplayName).font(.caption).foregroundStyle(theme.foreground.opacity(0.65))
            HStack(spacing: 8) {
                if let project {
                    WorktreeIdentityView(identity: worktree.iconIdentity, project: project, size: 22)
                }
                Text(worktree.displayName).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            }
            if let badge = worktree.prBadge {
                SidebarPRBadge(badge: badge).padding(.top, 2)
            }
            if let purpose {
                Text(purpose).font(.subheadline).foregroundStyle(theme.foreground.opacity(0.82))
                    .lineLimit(2).padding(.top, 4)
            }
        }
        .foregroundStyle(theme.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }
}

/// The emoji wash pinned behind the top of the screen, under the status and
/// navigation bars, dissolving into the screen background.
struct MobileWorktreeHeaderWash: View {
    let worktree: WorktreePanes
    let theme: GhosttyThemeColors

    var body: some View {
        if let wash = WorktreeHeaderWash(identity: worktree.iconIdentity, project: SidebarProjection.projects([worktree]).first,
                                         iconData: nil, background: theme.background, isDark: theme.isDark) {
            WorktreeHeaderWashView(wash: wash, fadesToBackground: true)
                .frame(height: 300)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// IOS-4.55: agents as cards ordered by who needs the user, then shells.
struct MobileWorktreeOverviewView: View {
    let host: Host
    let overview: MobileWorktreeOverview
    let theme: GhosttyThemeColors
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Agents")
            ForEach(overview.agents) { agent in
                MobileAgentCard(host: host, agent: agent, theme: theme) { onSelect(agent.session) }
            }
            if !overview.terminals.isEmpty {
                sectionLabel("Terminals").padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(Array(overview.terminals.enumerated()), id: \.element.id) { index, terminal in
                        if index > 0 { Divider().overlay(theme.foreground.opacity(0.08)) }
                        Button { onSelect(terminal.session) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "apple.terminal").font(.footnote)
                                    .frame(width: 24, height: 24)
                                    .background(theme.foreground.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                Text(terminal.title).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(theme.foreground.opacity(0.4))
                            }
                            .padding(.horizontal, 13).frame(minHeight: 48).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(theme.foreground.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 12)
        .padding(.bottom, 24)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).textCase(.uppercase)
            .foregroundStyle(theme.foreground.opacity(0.5)).padding(.horizontal, 6)
    }
}

private struct MobileAgentCard: View {
    let host: Host
    let agent: MobileWorktreeOverview.Agent
    let theme: GhosttyThemeColors
    let onOpen: () -> Void

    private var isWaiting: Bool { agent.state == .needsInput }
    private var isFinished: Bool { agent.state == .finished || agent.state == .failed }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    AgentProviderIcon(provider: agent.provider)
                    Text(agent.title).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    MobileAgentStatusBadge(agent: agent.info, hostID: host.id, needsInput: isWaiting)
                    Text(isWaiting ? "Your turn" : agent.status.label).font(.caption)
                        .foregroundStyle(theme.foreground.opacity(0.6)).lineLimit(1)
                }
                if let message = agent.message {
                    Text(message).font(.subheadline).foregroundStyle(theme.foreground.opacity(0.82))
                        .lineLimit(isWaiting ? 4 : 2).multilineTextAlignment(.leading)
                }
                if isWaiting {
                    Text("Open").font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 16).frame(height: 32)
                        .background(theme.foreground, in: Capsule())
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.foreground.opacity(isWaiting ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.foreground.opacity(isWaiting ? 0.16 : 0.06)))
            .opacity(isFinished ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this agent's terminal")
    }
}
#endif
