import CoreGraphics
import Testing
@testable import GrafttyMobileKit

@Suite
struct KeyboardFrameInsetTests {

    @Test("""
@spec IOS-6.9: While the iOS software keyboard is visible, the application shall raise the fullscreen terminal layout so its bottom edge sits at or above the keyboard's top edge rather than under it. SwiftUI's automatic `.keyboard` safe-area avoidance does not engage reliably while the first responder is the `UIViewRepresentable`-wrapped `UIKeyInput` proxy from `IOS-6.6` — SwiftUI's focus system is unaware of the proxy, so the avoidance machinery skips the layout. The application shall instead observe `UIResponder.keyboardWillChangeFrameNotification`, compute the keyboard end-frame's vertical intersection with the screen, and apply that height as an explicit `.padding(.bottom, …)` on the fullscreen layout so the terminal — and the `IOS-6.1` control bar overlaid at the bottom — both ride above the keyboard's top edge.
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
