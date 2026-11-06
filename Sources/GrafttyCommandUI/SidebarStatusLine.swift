import SwiftUI

/// The line under a worktree's name. A line asking for input gets the attention
/// color on a soft tint; ambient states stay dim, and unread text stays undimmed
/// until the stopped turn is viewed.
public struct SidebarStatusLine: View {
    @Environment(\.colorScheme) private var colorScheme

    /// @spec LAYOUT-2.213
    /// Space below a line on the Mac. A tint needs the same inset as its trailing
    /// edge, so it sits evenly inside the selection.
    public static func macBottomInset(_ status: SidebarRowStatus) -> CGFloat {
        status == .none ? 0 : status.needsAttention ? 8 : 3
    }

    /// @spec LAYOUT-2.214
    /// Pulls a status line toward its name on the Mac, into the padding of the
    /// heading's click target.
    public static var macTopInset: CGFloat { -3 }

    public let status: SidebarRowStatus
    public let secondary: Color
    public init(status: SidebarRowStatus, secondary: Color) {
        self.status = status
        self.secondary = secondary
    }

    public var body: some View {
        switch status {
        case .question(let text, _):
            attention(text, label: "Needs your input: " + text)
        case .notification(let text, _):
            attention(text, label: text)
        case .working(let text):
            line(text).italic().foregroundStyle(secondary)
        case .whereWeAre(let text, let isUnread):
            line(text).foregroundStyle(secondary).opacity(isUnread ? 1 : 0.7)
        case .none:
            EmptyView()
        }
    }

    private func attention(_ text: String, label: String) -> some View {
        Text(text).font(.caption).lineLimit(2).help(text)
            .accessibilityLabel(label)
            .foregroundStyle(SidebarAttentionStyle.text(isDark: colorScheme == .dark))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SidebarAttentionStyle.tint(isDark: colorScheme == .dark),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.top, 2)
    }

    private func line(_ text: String) -> some View {
        Text(text).font(.caption).lineLimit(2).help(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }
}
