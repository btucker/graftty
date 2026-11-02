import SwiftUI
import AppKit
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI

struct PRButton: View {
    let info: PRInfo
    let theme: GhosttyTheme
    let onRefresh: () -> Void
    var compact = false

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

            Text("#\(info.number)\(compact ? "" : terminalSuffix)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(info.state.isTerminal ? info.state.statusColor : theme.foreground)

            if !compact {
            Text(info.title)
                .font(.caption)
                .foregroundColor(theme.foreground.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .leading)

            }
            if compact && hasConflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(PRInfo.Mergeable.conflicting.statusColor)
            }
            if !compact && hasConflict {
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
        .padding(.horizontal, compact ? 2 : 8)
        .padding(.vertical, 2)
        .background(compact ? .clear : background)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.foreground.opacity(0.12), lineWidth: compact ? 0 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("#\(info.number) · \(info.title)\n\(accessibilityChecks)\(terminalSuffix)\(conflictDescription)")
        .accessibilityLabel(
            "Pull request \(info.number), \(accessibilityChecks)\(terminalSuffix)\(conflictDescription), \(info.title). Click to open in browser."
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

    var hasConflict: Bool { info.state == .open && info.mergeable == .conflicting }
    private var conflictDescription: String { hasConflict ? ", merge conflict" : "" }

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
