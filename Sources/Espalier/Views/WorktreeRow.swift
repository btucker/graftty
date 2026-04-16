import SwiftUI
import EspalierKit

struct WorktreeRow: View {
    let entry: WorktreeEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            stateIndicator
            branchLabel
            Spacer()
            attentionBadge
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch entry.state {
        case .closed:
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1)
                .frame(width: 8, height: 8)
        case .running:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        case .stale:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.yellow)
        }
    }

    @ViewBuilder
    private var branchLabel: some View {
        if entry.state == .stale {
            Text(entry.branch)
                .strikethrough()
                .foregroundColor(.secondary)
        } else {
            Text(entry.branch)
                .foregroundColor(isSelected ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var attentionBadge: some View {
        if let attention = entry.attention {
            Text(attention.text)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.red)
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
    }
}
