import GrafttyProtocol
import SwiftUI

/// @spec LAYOUT-2.209
/// The color that says a worktree is asking for input. System orange falls to
/// about 2:1 on light backgrounds, where color is the row's only signal.
public enum SidebarAttentionStyle {
    public static func textRGB(isDark: Bool) -> GhosttyThemeColors.RGB {
        isDark ? .init(r: 255 / 255, g: 159 / 255, b: 10 / 255) : .init(r: 163 / 255, g: 64 / 255, b: 0)
    }

    public static func tintOpacity(isDark: Bool) -> Double { isDark ? 0.14 : 0.10 }

    public static func text(isDark: Bool) -> Color {
        let rgb = textRGB(isDark: isDark)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    public static func tint(isDark: Bool) -> Color {
        text(isDark: isDark).opacity(tintOpacity(isDark: isDark))
    }
}
