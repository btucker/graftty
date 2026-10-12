import Foundation
import GhosttyKit

enum GhosttyPresentationConfig {
    static func render(config: ghostty_config_t, text: String) -> String {
        var lines = text.components(separatedBy: .newlines).filter { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return true }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            return key != "theme" && key != "config-file"
        }
        // Read the finalized host config so explicit overrides win over theme
        // values, including the host's selected branch of a light/dark pair.
        for key in ["background", "foreground", "unfocused-split-fill"] {
            var color = ghostty_config_color_s()
            let found = key.withCString {
                ghostty_config_get(config, &color, $0, UInt(key.utf8.count))
            }
            if found { lines.append("\(key) = \(hex(color))") }
        }
        var palette = ghostty_config_palette_s()
        if ghostty_config_get(config, &palette, "palette", 7) {
            withUnsafeBytes(of: &palette.colors) { bytes in
                for (index, color) in bytes.bindMemory(to: ghostty_config_color_s.self).enumerated() {
                    lines.append("palette = \(index)=\(hex(color))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func hex(_ color: ghostty_config_color_s) -> String {
        String(format: "#%02x%02x%02x", color.r, color.g, color.b)
    }
}
