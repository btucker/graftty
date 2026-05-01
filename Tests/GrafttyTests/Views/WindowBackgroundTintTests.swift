import AppKit
import Testing
@testable import Graftty

@MainActor
@Suite("WindowBackgroundTint application gate")
struct WindowBackgroundTintTests {
    @Test("""
@spec PERF-1.1: The window chrome tint bridge shall not reapply AppKit `NSWindow` chrome mutations when SwiftUI re-runs `updateNSView` for the same window and unchanged Ghostty theme; repeated no-op application can feed a SwiftUI/AppKit transaction loop while a terminal is otherwise idle.
""")
    func unchangedThemeAndWindowDoesNotReapply() {
        var gate = WindowTintApplyGate()
        let window = NSObject()
        let theme = GhosttyTheme.fallback

        let firstApply = gate.shouldApply(theme: theme, window: window)
        let secondApply = gate.shouldApply(theme: theme, window: window)
        #expect(firstApply)
        #expect(!secondApply)
    }

    @Test("""
@spec PERF-1.2: The window chrome tint bridge shall reapply AppKit `NSWindow` chrome mutations when either the Ghostty theme changes or SwiftUI moves the bridge view to a different host window.
""")
    func themeOrWindowChangeReapplies() {
        var gate = WindowTintApplyGate()
        let window = NSObject()
        let newWindow = NSObject()
        let dark = GhosttyTheme.fallback
        let light = GhosttyTheme(
            backgroundRGB: .init(r: 0.96, g: 0.95, b: 0.92),
            foregroundRGB: .init(r: 0.1, g: 0.1, b: 0.1)
        )

        let initialApply = gate.shouldApply(theme: dark, window: window)
        let changedThemeApply = gate.shouldApply(theme: light, window: window)
        let repeatedApply = gate.shouldApply(theme: light, window: window)
        let changedWindowApply = gate.shouldApply(theme: light, window: newWindow)
        #expect(initialApply)
        #expect(changedThemeApply)
        #expect(!repeatedApply)
        #expect(changedWindowApply)
    }
}
