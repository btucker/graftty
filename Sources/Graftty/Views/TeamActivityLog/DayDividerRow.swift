import SwiftUI

/// Day-boundary marker. Same hairline-rule shape as
/// CenteredMarkerRow, but the centered label is uppercase and
/// styled like a section header — visually distinct so the day
/// rollover doesn't read as a member-join/leave event.
struct DayDividerRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Divider()
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
                .padding(.horizontal, 8)
                .fixedSize()
            Divider()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}
