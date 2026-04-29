import SwiftUI
import AppKit
import GrafttyKit

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

            Text("#\(info.number)\(info.state == .merged ? " ✓ merged" : "")")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(info.state == .merged ? info.state.statusColor : theme.foreground)

            Text(info.title)
                .font(.caption)
                .foregroundColor(theme.foreground.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .leading)
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
        info.state == .merged
            ? Color(red: 0.64, green: 0.44, blue: 0.97, opacity: 0.15)
            : theme.foreground.opacity(0.08)
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

extension PRInfo.State {
    /// Color representing this PR's state. Green for open, purple for
    /// merged. Shared between the sidebar badge (foreground color of
    /// `#<number>`) and the breadcrumb pill (foreground color when
    /// merged). A future `.closed` case maps to red here.
    var statusColor: Color {
        switch self {
        case .open:   return Color(red: 0.25, green: 0.73, blue: 0.31)
        case .merged: return Color(red: 0.82, green: 0.66, blue: 1.0)
        }
    }
}

extension PRInfo.Checks {
    /// Color encoding the CI verdict. Reused by the breadcrumb PR
    /// button's dot and, per `PR-3.5`, the sidebar `#<number>` badge.
    /// The `.success` green intentionally matches `PRInfo.State.open`
    /// so an open PR with passing CI reads as a single signal.
    var statusColor: Color {
        switch self {
        case .success: return PRInfo.State.open.statusColor
        case .failure: return Color(red: 0.97, green: 0.32, blue: 0.29)
        case .pending: return Color(red: 0.82, green: 0.60, blue: 0.13)
        case .none:    return Color(red: 0.43, green: 0.46, blue: 0.51)
        }
    }
}

/// Subtle pulsing opacity for a pending CI indicator.
struct PulseIfPending: ViewModifier {
    let isPending: Bool
    @State private var phase = 0.0

    func body(content: Content) -> some View {
        content
            .opacity(isPending ? (0.5 + 0.5 * abs(cos(phase))) : 1.0)
            .task(id: isPending) {
                guard isPending else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    phase += .pi / 36
                }
            }
    }
}
