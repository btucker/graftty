import SwiftUI
import GrafttyKit

struct FlowStateSidebarRow: View {
    let isSelected: Bool
    let statusLabel: String
    let theme: GhosttyTheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(theme.sidebarDimIcon)
                .frame(width: 14)

            Text("Flow State")
                .font(.callout)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(theme.sidebarPrimaryText(isActive: isSelected))
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(statusLabel)
                .font(.caption)
                .foregroundColor(theme.sidebarSecondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.foreground.opacity(0.16) : .clear)
        )
    }
}
