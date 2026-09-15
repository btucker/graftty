import SwiftUI
import GrafttyProtocol

/// Shared PR/MR badge for worktree rows and Attention cards.
public struct SidebarPRBadge: View {
    public let badge: PRBadge
    @Environment(\.openURL) private var openURL

    public init(badge: PRBadge) { self.badge = badge }

    public var body: some View {
        let tone = PRBadgeStyle.tone(
            state: badge.state,
            checks: badge.checks,
            mergeable: badge.mergeable
        )
        Button {
            openURL(badge.url)
        } label: {
            Text(verbatim: badge.referenceText)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(color(for: tone))
                .padding(.horizontal, 3)
                .overlay {
                    if tone == .conflicting {
                        // Outline ring on conflict — pairs with the
                        // breadcrumb's "merge conflict" pill so both
                        // surfaces share the same visual language.
                        // PR-8.20.
                        Capsule()
                            .strokeBorder(color(for: tone), lineWidth: 1)
                    }
                }
                .modifier(PulseIfPending(isPending: tone.pulses))
        }
        .buttonStyle(.plain)
        .help(Self.badgeTooltip(for: badge))
        .accessibilityLabel(Self.badgeAccessibilityLabel(for: badge, tone: tone))
    }

    private func color(for tone: PRBadgeStyle.Tone) -> Color {
        switch tone {
        case .open:        return PRInfo.State.open.statusColor
        case .merged:      return PRInfo.State.merged.statusColor
        case .closed:      return PRInfo.State.closed.statusColor
        case .ciFailure:   return PRInfo.Checks.failure.statusColor
        case .ciPending:   return PRInfo.Checks.pending.statusColor
        case .conflicting: return PRInfo.Mergeable.conflicting.statusColor
        }
    }

    public static func badgeTooltip(for badge: PRBadge) -> String {
        "Open \(badge.referenceText) on \(badge.url.host ?? "")"
    }

    public static func badgeAccessibilityLabel(
        for badge: PRBadge,
        tone: PRBadgeStyle.Tone
    ) -> String {
        let stateWord: String
        switch badge.state {
        case .open:   stateWord = "open"
        case .merged: stateWord = "merged"
        case .closed: stateWord = "closed"
        }
        let suffix: String
        switch tone {
        case .ciFailure:   suffix = ", CI failing"
        case .ciPending:   suffix = ", CI running"
        case .conflicting: suffix = ", merge conflict"
        case .open, .merged, .closed: suffix = ""
        }
        return "Pull request \(badge.number), \(stateWord)\(suffix). Click to open in browser."
    }

}
