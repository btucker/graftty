import CryptoKit
import Foundation

/// Resolved Ghostty colors, independent of theme names and unrelated settings.
struct WorktreeArtworkTheme: Equatable, Sendable {
    private let background: GhosttyTheme.RGB
    private let foreground: GhosttyTheme.RGB
    private let accents: [GhosttyTheme.RGB]
    private let isDark: Bool

    init(theme: GhosttyTheme) {
        background = theme.backgroundRGB
        foreground = theme.foregroundRGB
        isDark = theme.isDark
        // ANSI's six chromatic colors and their bright variants. Exclude its
        // black/white slots so worktrees can still have different accent colors.
        let colors = theme.palette.count >= 16
            ? [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14].map { theme.palette[$0] }
            : theme.palette
        accents = colors.isEmpty ? [theme.foregroundRGB] : colors
    }

    // v2 prioritizes the configured backdrop and preserves muted color tones.
    var cacheKey: String { "v2-" + colorCacheKey }

    var colorCacheKey: String {
        let bytes = ([background, foreground] + accents).flatMap { color in
            [color.r, color.g, color.b].map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        }
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    func palette(index: Int, variation: UInt64) -> String {
        let primary = (index + Int(variation % UInt64(accents.count))) % accents.count
        let secondary = (primary + max(1, accents.count / 2 - 1)) % accents.count
        return "\(Self.describe(accents[primary])) with \(Self.describe(accents[secondary])) accents"
    }

    var backgroundConcept: String {
        let lighting = isDark
            ? "low-key lighting, dim ambient shadows extending to every edge"
            : "soft daylight, gentle ambient light extending to every edge"
        return "\(isDark ? "Dark" : "Light") \(Self.describe(background)) backdrop across the entire image, \(lighting)."
    }

    func codexColorInstruction(index: Int, variation: UInt64) -> String {
        func hex(_ color: GhosttyTheme.RGB) -> String {
            "#" + [color.r, color.g, color.b].map { String(format: "%02x", Int((min(1, max(0, $0)) * 255).rounded())) }.joined()
        }
        let primary = (index + Int(variation % UInt64(accents.count))) % accents.count
        let secondary = (primary + max(1, accents.count / 2 - 1)) % accents.count
        return """
        Match only the scene's backdrop to the configured terminal background \(hex(background)).
        Dominant subject color: \(hex(accents[primary])). Small secondary accent: \(hex(accents[secondary])).
        Make the dominant color a large, unmistakable area of the subject, with strong separation from the backdrop. Keep the subject clearly lit and its color distinct, even on a dark theme. These codes describe colors; never render them as text.
        """
    }

    // ImageCreator gets ordinary color words rather than hex codes it might
    // interpret as lettering. The exact RGB values still identify the cache.
    private static func describe(_ color: GhosttyTheme.RGB) -> String {
        let high = max(color.r, color.g, color.b)
        let low = min(color.r, color.g, color.b)
        let delta = high - low
        let saturation = high == 0 ? 0 : delta / high
        if saturation < 0.12 || (high < 0.35 && saturation < 0.35) {
            switch high {
            case ..<0.12: return "near-black"
            case ..<0.35: return "charcoal gray"
            case ..<0.65: return "medium gray"
            case ..<0.9: return "light gray"
            default: return "soft white"
            }
        }
        var hue: Double
        if high == color.r { hue = (color.g - color.b) / delta }
        else if high == color.g { hue = 2 + (color.b - color.r) / delta }
        else { hue = 4 + (color.r - color.g) / delta }
        if hue < 0 { hue += 6 }
        let name: String
        switch hue {
        case ..<0.35: name = "red"
        case ..<0.8: name = "orange"
        case ..<1.2: name = "golden yellow"
        case ..<2.6: name = "green"
        case ..<3.4: name = "cyan"
        case ..<4.4: name = "blue"
        case ..<5.2: name = "violet"
        case ..<5.8: name = "magenta"
        default: name = "red"
        }
        let tone = high < 0.2 ? "near-black" : high < 0.45 ? "deep" : saturation < 0.35 ? "pale" : saturation < 0.65 || high < 0.75 ? "muted" : "rich"
        return "\(tone) \(name)"
    }
}
