import SwiftUI

/// Keeps child-pane titles in one column even when parent worktrees have
/// different leading badges. Insets are relative to the worktree block.
public enum SidebarPaneLayout {
    public static let titleColumn: CGFloat = 46
    public static let markerSpacing: CGFloat = 6
    public static var markerLeading: CGFloat {
        titleColumn - SidebarPaneMarker.width - markerSpacing
    }
}

/// The pane hierarchy arrow and attention count occupy the same slot on both
/// desktop and mobile, so a count does not move the pane title.
public struct SidebarPaneMarker: View {
    public static let width: CGFloat = 18

    public let attentionCount: Int
    public let isFocused: Bool
    public let arrowColor: Color

    public init(attentionCount: Int, isFocused: Bool, arrowColor: Color) {
        self.attentionCount = attentionCount
        self.isFocused = isFocused
        self.arrowColor = arrowColor
    }

    public var body: some View {
        Group {
            if attentionCount > 0 {
                SidebarActivityBadge(attentionCount)
            } else {
                Text("↳")
                    .font(.caption)
                    .fontWeight(isFocused ? .bold : .regular)
                    .foregroundStyle(arrowColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: Self.width, alignment: .trailing)
    }
}
