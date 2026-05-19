import SwiftUI

/// @spec IPAD-1.1
/// Cross-platform snapshot of the ghostty-config-driven theme colors
/// Graftty applies to app chrome (sidebar, breadcrumb). The Mac wraps
/// this in `GhosttyTheme` (adding NSColor + NSAppearance accessors);
/// mobile constructs it by parsing the Mac-resolved config text via
/// `init(parsingConfigText:)` (in GrafttyMobileKit/Theme).
public struct GhosttyThemeColors: Sendable, Equatable {

    public struct RGB: Sendable, Equatable {
        public let r: Double
        public let g: Double
        public let b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    public let backgroundRGB: RGB
    public let foregroundRGB: RGB

    public init(backgroundRGB: RGB, foregroundRGB: RGB) {
        self.backgroundRGB = backgroundRGB
        self.foregroundRGB = foregroundRGB
    }

    public var background: Color { Self.color(backgroundRGB) }
    public var foreground: Color { Self.color(foregroundRGB) }
    public var sidebarBackground: Color { Self.color(sidebarBackgroundRGB) }

    public var sidebarBackgroundRGB: RGB {
        let shift = isDark ? 0.06 : -0.06
        return RGB(
            r: Self.clamp01(backgroundRGB.r + shift),
            g: Self.clamp01(backgroundRGB.g + shift),
            b: Self.clamp01(backgroundRGB.b + shift)
        )
    }

    public var isDark: Bool {
        let bg = backgroundRGB
        // Round to 6 decimal places so that the canonical mid-gray
        // (r=g=b=0.5, theoretical luminance=0.5) lands exactly on the
        // boundary and is treated as light (not dark), despite floating-
        // point accumulation in the weighted sum.
        let raw = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b
        let luminance = (raw * 1_000_000).rounded() / 1_000_000
        return luminance < 0.5
    }

    public static let fallback = GhosttyThemeColors(
        backgroundRGB: RGB(r: 0.05, g: 0.05, b: 0.10),
        foregroundRGB: RGB(r: 0.87, g: 0.87, b: 0.87)
    )

    private static func color(_ rgb: RGB) -> Color {
        Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    private static func clamp01(_ x: Double) -> Double {
        min(1.0, max(0.0, x))
    }
}
