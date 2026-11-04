import SwiftUI

/// The line under a worktree's name. Attention gets color; ambient states stay
/// dim, and unread text stays undimmed until the stopped turn is viewed.
public struct SidebarStatusLine: View {
    /// Lines the text up under the worktree's name on mobile rows.
    public static let mobileLeadingInset: CGFloat = 28
    private static let handWidth: CGFloat = 16
    private static let handGap: CGFloat = 5

    public let status: SidebarRowStatus
    public let secondary: Color
    public init(status: SidebarRowStatus, secondary: Color) {
        self.status = status
        self.secondary = secondary
    }

    public var body: some View {
        switch status {
        case .question(let text, _):
            line(text, label: "Needs your input: " + text).foregroundStyle(.orange)
        case .notification(let text, _):
            line(text, label: text).foregroundStyle(.orange)
        case .working(let text):
            line(text, label: text).italic().foregroundStyle(secondary)
        case .whereWeAre(let text, let isUnread):
            line(text, label: text).foregroundStyle(secondary).opacity(isUnread ? 1 : 0.7)
        case .none:
            EmptyView()
        }
    }

    private var isQuestion: Bool {
        if case .question = status { return true }
        return false
    }

    private func line(_ text: String, label: String) -> some View {
        Text(text).font(.caption).lineLimit(2).help(text)
            // On the text alone: on the whole line it would also replace the hand's label.
            .accessibilityLabel(label)
            // Hangs in the caller's leading inset, so the text stays under the name.
            .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                if status.needsAttention {
                    SidebarActivityBadge(1)
                        .frame(width: Self.handWidth, alignment: .trailing)
                        .offset(x: -(Self.handWidth + Self.handGap))
                        // A question's label already says it needs input.
                        .accessibilityHidden(isQuestion)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}
