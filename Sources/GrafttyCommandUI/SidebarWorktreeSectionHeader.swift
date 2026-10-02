import SwiftUI

public struct SidebarWorktreeSectionHeader: View {
    private let title: String
    private let color: Color
    private let isCollapsed: Binding<Bool>
    private let separatesPrecedingRows: Bool

    public init(_ title: String, color: Color = .secondary, isCollapsed: Binding<Bool>, separatesPrecedingRows: Bool = true) {
        self.title = title
        self.color = color
        self.isCollapsed = isCollapsed
        self.separatesPrecedingRows = separatesPrecedingRows
    }

    @ViewBuilder
    public var body: some View {
        Button { isCollapsed.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: isCollapsed.wrappedValue ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18)
                Text(title).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(color)
            .frame(height: 16)
            .padding(.horizontal, 8)
            .padding(.top, separatesPrecedingRows ? 12 : 4)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isCollapsed.wrappedValue ? "Collapsed" : "Expanded")
    }
}
