import SwiftUI

public struct WorktreeContextPanel: View {
    public let context: SidebarWorktreeContext
    private let foreground: Color
    private let secondary: Color
    private let onClose: () -> Void

    public init(context: SidebarWorktreeContext, foreground: Color = .primary,
                secondary: Color = .secondary, onClose: @escaping () -> Void) {
        self.context = context
        self.foreground = foreground
        self.secondary = secondary
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Context", systemImage: "text.alignleft")
                    .font(.callout).fontWeight(.medium)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close context")
                .accessibilityIdentifier("worktree.context.close")
            }.padding(.horizontal, 20).padding(.vertical, 8)
            Divider()
            ScrollView {
                WorktreeBriefContent(context: context, foreground: foreground, secondary: secondary)
                    .padding(24)
            }
        }
        .foregroundStyle(foreground)
    }
}
