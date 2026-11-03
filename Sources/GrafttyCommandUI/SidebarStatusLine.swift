import SwiftUI

/// The line under a worktree's name. Attention gets color; ambient states stay
/// dim, and unread text stays undimmed until the stopped turn is viewed.
public struct SidebarStatusLine: View {
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

    private func line(_ text: String, label: String) -> some View {
        Text(text).font(.caption).lineLimit(2).help(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
            .accessibilityLabel(label)
    }
}
