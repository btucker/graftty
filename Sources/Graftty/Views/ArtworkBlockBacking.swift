import SwiftUI

private struct WorktreeMapIndentKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var worktreeMapIndent: CGFloat {
        get { self[WorktreeMapIndentKey.self] }
        set { self[WorktreeMapIndentKey.self] = newValue }
    }
}

/// One continuous text backing identifies a worktree and its panes as a group.
struct ArtworkBlockBacking: View {
    var showsSeparator = true

    var body: some View {
        LinearGradient(stops: [
            .init(color: .black.opacity(0.68), location: 0),
            .init(color: .black.opacity(0.54), location: 0.7),
            .init(color: .black.opacity(0.32), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
        .overlay(alignment: .top) {
            if showsSeparator {
                Color.white.opacity(0.2).frame(height: 0.5)
                    .padding(.horizontal, 8)
            }
        }
    }
}
