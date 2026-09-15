import SwiftUI
import GrafttyProtocol

extension PRInfo.State {
    /// Color representing this PR's state. Green for open, purple for
    /// merged, red for closed-without-merging. Shared between the
    /// sidebar reference badge and the
    /// breadcrumb pill (foreground color when merged/closed).
    public var statusColor: Color {
        switch self {
        case .open:   return Color(red: 0.25, green: 0.73, blue: 0.31)
        case .merged: return Color(red: 0.82, green: 0.66, blue: 1.0)
        case .closed: return Color(red: 0.83, green: 0.33, blue: 0.31)
        }
    }
}

extension PRInfo.Checks {
    /// Color encoding the CI verdict. Reused by the breadcrumb PR
    /// button's dot and, per `PR-3.5`, the sidebar reference badge.
    /// The `.success` green intentionally matches `PRInfo.State.open`
    /// so an open PR with passing CI reads as a single signal.
    public var statusColor: Color {
        switch self {
        case .success: return PRInfo.State.open.statusColor
        case .failure: return Color(red: 0.97, green: 0.32, blue: 0.29)
        case .pending: return Color(red: 0.82, green: 0.60, blue: 0.13)
        case .none:    return Color(red: 0.43, green: 0.46, blue: 0.51)
        }
    }
}

extension PRInfo.Mergeable {
    /// Color for the merge-conflict cue. Distinct from CI failure
    /// red so a "PR has conflicts but CI is green" state reads
    /// differently from "PR is broken in CI". Used by the sidebar
    /// reference badge when `PRBadgeStyle` returns `.conflicting`
    /// and by the breadcrumb's "merge conflict" pill.
    public var statusColor: Color {
        switch self {
        case .conflicting: return Color(red: 0.95, green: 0.46, blue: 0.20)
        case .mergeable, .unknown: return PRInfo.State.open.statusColor
        }
    }
}

/// Subtle pulsing opacity for a pending CI indicator.
public struct PulseIfPending: ViewModifier {
    let isPending: Bool
    @State private var phase = 0.0

    public init(isPending: Bool) { self.isPending = isPending }

    public func body(content: Content) -> some View {
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
