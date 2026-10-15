import SwiftUI

/// @spec LAYOUT-2.123: While a macOS pinned section has no preceding rows, the application shall give its disclosure header a 20-point click target without extra top padding.
public struct SidebarWorktreeSectionHeader: View {
    private let title: String
    private let color: Color
    private let isCollapsed: Binding<Bool>
    private let separatesPrecedingRows: Bool
    #if os(macOS)
    private static let firstSectionTopPadding: CGFloat = 0
    #else
    private static let firstSectionTopPadding: CGFloat = 4
    #endif

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
            .padding(.top, separatesPrecedingRows ? 12 : Self.firstSectionTopPadding)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isCollapsed.wrappedValue ? "Collapsed" : "Expanded")
    }
}
