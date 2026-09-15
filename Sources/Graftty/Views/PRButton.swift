import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

struct PRButton: View {
    let info: PRInfo
    let theme: GhosttyTheme
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(dotColor.opacity(0.5), lineWidth: info.checks == .pending ? 2 : 0)
                )
                .modifier(PulseIfPending(isPending: info.checks == .pending))

            Text("#\(info.number)\(terminalSuffix)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(info.state.isTerminal ? info.state.statusColor : theme.foreground)

            Text(info.title)
                .font(.caption)
                .foregroundColor(theme.foreground.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .leading)

            if info.state == .open && info.mergeable == .conflicting {
                Text("merge conflict")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundColor(PRInfo.Mergeable.conflicting.statusColor)
                    .background(
                        Capsule().fill(PRInfo.Mergeable.conflicting.statusColor.opacity(0.18))
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.foreground.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("Open #\(info.number) on \(info.url.host ?? "")")
        .accessibilityLabel(
            "Pull request \(info.number), \(accessibilityChecks), \(info.title). Click to open in browser."
        )
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(info.url) }
        .contextMenu {
            Button("Refresh now") { onRefresh() }
            Button("Copy URL") { Pasteboard.copy(info.url.absoluteString) }
        }
    }

    private var background: Color {
        switch info.state {
        case .merged: return Color(red: 0.64, green: 0.44, blue: 0.97, opacity: 0.15)
        case .closed: return PRInfo.State.closed.statusColor.opacity(0.15)
        case .open:   return theme.foreground.opacity(0.08)
        }
    }

    private var terminalSuffix: String {
        switch info.state {
        case .merged: return " ✓ merged"
        case .closed: return " ✕ closed"
        case .open:   return ""
        }
    }

    private var dotColor: Color { info.checks.statusColor }

    private var accessibilityChecks: String {
        switch info.checks {
        case .success: return "CI passing"
        case .failure: return "CI failing"
        case .pending: return "CI running"
        case .none:    return "no CI checks"
        }
    }
}
