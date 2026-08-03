#if canImport(UIKit)
import Foundation
import GrafttyProtocol

public extension GhosttyThemeColors {
    /// Parse `background = #RRGGBB` and `foreground = #RRGGBB` from the
    /// Mac-resolved Ghostty config text fetched via `GhosttyConfigFetcher`.
    /// Missing or unparseable keys fall back to `.fallback` component-wise.
    /// Mobile only handles hex values — the Mac side resolves named
    /// colors, palette references, and theme references before returning
    /// the text.
    init(parsingConfigText text: String) {
        var background: RGB?
        var foreground: RGB?
        var unfocusedSplitFill: RGB?
        var unfocusedSplitOpacity: Double?

        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background":
                if let rgb = Self.parseHexColor(value) { background = rgb }
            case "foreground":
                if let rgb = Self.parseHexColor(value) { foreground = rgb }
            case "unfocused-split-fill":
                if let rgb = Self.parseHexColor(value) {
                    unfocusedSplitFill = rgb
                }
            case "unfocused-split-opacity":
                if let opacity = Double(value) {
                    unfocusedSplitOpacity = opacity
                }
            default:
                continue
            }
        }

        let resolvedBackground = background
            ?? GhosttyThemeColors.fallback.backgroundRGB
        self.init(
            backgroundRGB: resolvedBackground,
            foregroundRGB: foreground
                ?? GhosttyThemeColors.fallback.foregroundRGB,
            unfocusedSplitFillRGB: unfocusedSplitFill
                ?? resolvedBackground,
            unfocusedSplitOpacity: unfocusedSplitOpacity
                ?? GhosttyThemeColors.fallback.unfocusedSplitOpacity
        )
    }

    /// Parse `#RRGGBB` or `RRGGBB` into an RGB triple. Returns nil for
    /// named colors, palette refs, or any non-hex form.
    private static func parseHexColor(_ raw: String) -> RGB? {
        var s = raw
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 else { return nil }
        guard let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xff) / 255.0
        let g = Double((value >> 8) & 0xff) / 255.0
        let b = Double(value & 0xff) / 255.0
        return RGB(r: r, g: g, b: b)
    }
}
#endif
