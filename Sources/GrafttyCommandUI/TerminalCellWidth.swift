/// Estimates the cells used by text on Ghostty's grid. Joined emoji use two
/// cells, including zero-width-joiner sequences. Native viewport reads join
/// soft wraps, so callers need cell widths to recognize wrapped text.
public enum TerminalCellWidth {
    public static func estimate(_ text: some StringProtocol) -> Int {
        text.reduce(0) { total, character in
            let scalarWidth = character.unicodeScalars.reduce(0) { width, scalar in
                let value = scalar.value
                if scalar.properties.generalCategory == .nonspacingMark
                    || scalar.properties.generalCategory == .enclosingMark
                    || value == 0x200D { return width }
                let wide = scalar.properties.isEmojiPresentation
                    || (0x1100...0x115F).contains(value)
                    || (0x2329...0x232A).contains(value)
                    || (0x2E80...0xA4CF).contains(value)
                    || (0xAC00...0xD7A3).contains(value)
                    || (0xF900...0xFAFF).contains(value)
                    || (0xFE10...0xFE6F).contains(value)
                    || (0xFF00...0xFF60).contains(value)
                    || (0xFFE0...0xFFE6).contains(value)
                    || (0x20000...0x3FFFD).contains(value)
                return width + (wide ? 2 : 1)
            }
            return total + min(2, max(1, scalarWidth))
        }
    }
}
