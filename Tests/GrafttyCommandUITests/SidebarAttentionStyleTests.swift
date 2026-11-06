import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyCommandUI

struct SidebarAttentionStyleTests {
    private typealias RGB = GhosttyThemeColors.RGB

    private func luminance(_ color: RGB) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    private func contrast(_ first: RGB, _ second: RGB) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func hex(_ value: Int) -> RGB {
        RGB(r: Double(value >> 16 & 0xFF) / 255, g: Double(value >> 8 & 0xFF) / 255, b: Double(value & 0xFF) / 255)
    }

    @Test("@spec LAYOUT-2.209: While a status line asks for input, the application shall keep its text at 4.5:1 or better against its tint on both light and dark backgrounds.",
          arguments: [(0x000000, true), (0x1C1C1E, true), (0x1A1B26, true), (0x282A36, true), (0x282828, true),
                      (0xFFFFFF, false), (0xFDF6E3, false), (0xEFF1F5, false)])
    func questionTextStaysReadableOnItsTint(background: Int, isDark: Bool) {
        let base = hex(background)
        let text = SidebarAttentionStyle.textRGB(isDark: isDark)
        let alpha = SidebarAttentionStyle.tintOpacity(isDark: isDark)
        let tinted = RGB(r: text.r * alpha + base.r * (1 - alpha),
                         g: text.g * alpha + base.g * (1 - alpha),
                         b: text.b * alpha + base.b * (1 - alpha))
        #expect(contrast(text, tinted) >= 4.5)
    }
}
