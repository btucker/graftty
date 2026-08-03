import CoreGraphics
import Testing
@testable import GrafttyMobileKit

@Suite
struct KeyboardFrameInsetTests {

    @Test("""
@spec IOS-6.9: While the iOS software keyboard is docked against the bottom edge of the `UIViewRepresentable`-wrapped `UITerminalView` container, the application shall raise the terminal layout by the keyboard's bottom-edge overlap so the terminal and the `IOS-6.1` control bar remain above it. A floating keyboard that does not reach the container's bottom edge shall not shrink the terminal tree.
""")
    func dockedKeyboardReturnsItsHeight() {
        // iPhone 14 portrait: 390×844pt screen, default keyboard ~342pt
        // docked at the bottom edge.
        let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
        let keyboard = CGRect(x: 0, y: 502, width: 390, height: 342)

        #expect(KeyboardFrameInset.bottomInset(
            keyboardEndFrame: keyboard,
            screenBounds: screen
        ) == 342)
    }

    @Test
    func offScreenKeyboardReturnsZero() {
        // keyboardWillHide reports an end-frame whose origin.y is the
        // screen height — i.e. the keyboard has slid entirely below
        // the visible area. No overlap, no padding.
        let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
        let kbWillHide = CGRect(x: 0, y: 844, width: 390, height: 342)

        #expect(KeyboardFrameInset.bottomInset(
            keyboardEndFrame: kbWillHide,
            screenBounds: screen
        ) == 0)
    }

    @Test
    func partiallyOffScreenKeyboardReturnsIntersectionHeight() {
        // Mid-animation snapshot: keyboard frame straddles the screen
        // bottom. Intersection y=700..844 → height 144.
        let screen = CGRect(x: 0, y: 0, width: 390, height: 844)
        let partial = CGRect(x: 0, y: 700, width: 390, height: 200)

        #expect(KeyboardFrameInset.bottomInset(
            keyboardEndFrame: partial,
            screenBounds: screen
        ) == 144)
    }

    @Test("a floating keyboard does not shrink the terminal tree")
    func floatingKeyboardReturnsZero() {
        let screen = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let floating = CGRect(x: 550, y: 700, width: 420, height: 320)

        #expect(KeyboardFrameInset.bottomInset(
            keyboardEndFrame: floating,
            screenBounds: screen
        ) == 0)
    }
}
