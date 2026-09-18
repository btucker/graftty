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

/// Native backing stays readable independently of the generated map's detail.
struct ArtworkTextBacking: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .background {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.black.opacity(0.72))
                        .padding(.horizontal, -3)
                        .padding(.vertical, -1)
                }
        } else {
            content
        }
    }
}
