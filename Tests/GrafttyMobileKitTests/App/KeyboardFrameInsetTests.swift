import CoreGraphics
import Testing
@testable import GrafttyMobileKit

@Suite
struct KeyboardFrameInsetTests {

    @Test("""
@spec IOS-6.9: While the iOS software keyboard is visible for the `UIViewRepresentable`-wrapped `UITerminalView` first responder, the application shall raise the fullscreen terminal layout so its bottom edge sits at or above the keyboard's top edge rather than under it. The application shall observe `UIResponder.keyboardWillChangeFrameNotification`, compute the keyboard end-frame's vertical intersection with the screen, and apply that height as explicit bottom padding so the terminal and the `IOS-6.1` control bar both remain above the keyboard.
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
}
