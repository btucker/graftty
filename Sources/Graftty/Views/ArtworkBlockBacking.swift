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

/// Light shading keeps each worktree grouped without obscuring its map colors.
struct ArtworkBlockBacking: View {
    var showsSeparator = true
    static let shadingOpacity = 0.14

    var body: some View {
        Color.black.opacity(Self.shadingOpacity)
        .overlay(alignment: .top) {
            if showsSeparator {
                Color.white.opacity(0.2).frame(height: 0.5)
                    .padding(.horizontal, 8)
            }
        }
    }
}

extension View {
    /// Protect glyph edges on bright terrain without covering the artwork between labels.
    func artworkTextContrast(_ enabled: Bool) -> some View {
        shadow(color: .black.opacity(enabled ? 0.95 : 0), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(enabled ? 0.8 : 0), radius: 3)
    }
}
