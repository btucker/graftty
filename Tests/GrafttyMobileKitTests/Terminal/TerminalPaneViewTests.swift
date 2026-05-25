#if canImport(UIKit)
import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit
import UIKit

@Suite
@MainActor
struct TerminalPaneViewTests {

    @Test
    func softwareKeyboardProxyDoesNotExposeGhosttyAccessoryView() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(container.inputProxy.inputAccessoryView == nil)
        #expect(container.inputProxy !== container.terminalView)
    }

    @Test("""
@spec IOS-6.7: While a terminal pane is rendered in the iOS app, GrafttyMobile shall prevent libghostty-spm's built-in `TerminalInputAccessoryView` from appearing by suppressing both `UITerminalView.inputAccessoryView` and `UITerminalView.canBecomeFirstResponder` at the UIKit ObjC dispatch path. With `canBecomeFirstResponder` returning false, libghostty's `touchesBegan`-driven `becomeFirstResponder()` is a no-op, so GrafttyMobile's `UIKeyInput` proxy wins the keyboard responder race and the GhosttyKit accessory bar never mounts. The only visible software-keyboard accessory row shall be GrafttyMobile's terminal control bar (`IOS-6.1`).
""")
    func terminalPaneShowsOnlyGrafttyKeyboardAccessory() {
        UITerminalView.suppressGhosttyInputAccessory()
        // UIKit reads the first responder's `inputAccessoryView` through
        // `objc_msgSend`, so the assertion mirrors that path. Direct
        // Swift property access on a concrete type can statically
        // dispatch and bypass the runtime IMP swap, hiding the
        // suppression in production.
        let term = UITerminalView(frame: .zero)
        let accessory = term.perform(
            #selector(getter: UIResponder.inputAccessoryView)
        )?.takeUnretainedValue()
        #expect(accessory == nil)

        // canBecomeFirstResponder must return false through the same
        // ObjC dispatch path that UIKit uses when libghostty's
        // touchesBegan calls becomeFirstResponder().
        let nsterm = term as NSObject
        let canBecome = nsterm.value(forKey: "canBecomeFirstResponder") as? Bool
        #expect(canBecome == false)
    }

    @Test("""
@spec IOS-6.8: While a terminal pane is rendered in the iOS app, libghostty-spm's built-in pan-to-scroll and pinch-to-zoom gestures on `UITerminalView` shall remain functional. The iOS scaffolding shall not place an interaction-blocking overlay above `UITerminalView`: the `UIKeyInput` proxy responsible for software-keyboard text (`IOS-6.6`) shall be hit-test transparent so touches reach `UITerminalView`'s gesture recognizers underneath.
""")
    func touchesPassThroughInputProxyToTerminalView() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.layoutIfNeeded()

        let hitView = container.hitTest(CGPoint(x: 160, y: 120), with: nil)

        #expect(hitView !== container.inputProxy)
        // The proxy must still be eligible to be the keyboard's first
        // responder — touch transparency is about hit-testing, not the
        // responder chain.
        #expect(container.inputProxy.canBecomeFirstResponder)
    }
}

@Suite("@spec IOS-6.11: The pinch-driven leadership claim from `IOS-6.5` shall fire only on pinch gestures whose scale departure from 1.0 exceeds a small threshold (~5%), so accidental two-finger touches (during scroll, near-tap) do not silently claim leadership.")
struct LeadershipPinchGateTests {

    @Test
    func nonBeganStatesDoNotClaim() {
        for state: UIGestureRecognizer.State in [.possible, .changed, .ended, .cancelled, .failed] {
            #expect(!LeadershipPinchGate.shouldClaim(state: state, scale: 1.5))
        }
    }

    @Test
    func beganBelowThresholdDoesNotClaim() {
        // Default threshold is 0.05 (~5% scale change).
        #expect(!LeadershipPinchGate.shouldClaim(state: .began, scale: 1.0))
        #expect(!LeadershipPinchGate.shouldClaim(state: .began, scale: 1.03))
        #expect(!LeadershipPinchGate.shouldClaim(state: .began, scale: 0.97))
    }

    @Test
    func beganAboveThresholdClaims() {
        #expect(LeadershipPinchGate.shouldClaim(state: .began, scale: 1.10))
        #expect(LeadershipPinchGate.shouldClaim(state: .began, scale: 0.90))
        #expect(LeadershipPinchGate.shouldClaim(state: .began, scale: 2.0))
    }

    @Test
    func zeroScaleNeverClaims() {
        // A UIPinchGestureRecognizer with scale 0 is degenerate; treat as
        // no-claim rather than as a maximum-zoom-out claim.
        #expect(!LeadershipPinchGate.shouldClaim(state: .began, scale: 0))
    }
}

@Suite("@spec IOS-6.12: while a pane is in selection mode (IOS-11.4 pan-extends a live selection), the leadership-claim pinch recognizer shall be disabled — a mid-selection pinch shall not flip the server's PTY dims out from under the selection geometry.")
@MainActor
struct LeadershipPinchSelectionModeTests {

    @Test
    func enterSelectionModeDisablesLeadershipPinch() {
        let view = TerminalInputContainerView()
        #expect(view.leadershipPinchRecognizerIsEnabledForTesting)
        view.enterSelectionModeForTesting()
        #expect(!view.leadershipPinchRecognizerIsEnabledForTesting)
    }

    @Test
    func exitSelectionModeReenablesLeadershipPinch() {
        let view = TerminalInputContainerView()
        view.enterSelectionModeForTesting()
        view.exitSelectionModeForTesting()
        #expect(view.leadershipPinchRecognizerIsEnabledForTesting)
    }
}
#endif
