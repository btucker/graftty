import SwiftUI

public struct SidebarWorktreeSectionHeader: View {
    private let title: String
    private let color: Color
    private let isCollapsed: Binding<Bool>?

    public init(_ title: String, color: Color = .secondary, isCollapsed: Binding<Bool>? = nil) {
        self.title = title
        self.color = color
        self.isCollapsed = isCollapsed
    }

    @ViewBuilder
    public var body: some View {
        if let isCollapsed {
            Button { isCollapsed.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isCollapsed.wrappedValue ? "Collapsed" : "Expanded")
        } else {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }
}
