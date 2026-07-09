#if canImport(UIKit)
import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit
import UIKit

private final class NilInputKeyCommand: UIKeyCommand {
    override var input: String? { nil }
}

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
        // Without owner-installed software-keyboard handlers, a tap shall not
        // summon the keyboard. Enabling those handlers restores responder
        // eligibility without changing hit-test transparency.
        #expect(!container.inputProxy.canBecomeFirstResponder)
        container.inputProxy.softwareKeyboardInputEnabled = true
        #expect(container.inputProxy.canBecomeFirstResponder)
    }

    @Test("""
@spec IOS-6.17: While a terminal pane is rendered on iPad with a trackpad, indirect pointer scroll gestures shall reach libghostty's terminal scroll/input recognizers rather than being blocked by GrafttyMobile's keyboard proxy or selection overlay.
""")
    func terminalPanRecognizersAllowIndirectScrolling() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(container.terminalPanRecognizersAllowIndirectScrollingForTesting)
    }

    @Test("""
@spec IPAD-9.9: The active iPad terminal input responder shall publish app-level Ghostty shortcuts as UIKeyCommands and synchronously request a UIKit menu-system rebuild whenever the effective command identities, titles, inputs, or modifiers change, so hardware-keyboard commands remain current while terminal input owns first responder status.
""")
    func activeTerminalInputResponderRefreshesPublishedHardwareKeyboardCommands() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let proxy = container.inputProxy

        #expect(proxy.keyCommands == nil)
        #expect(proxy.keyCommandUpdateRequestCountForTesting == 0)
        #expect(container.keyCommands == nil)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        #expect(proxy.keyCommandUpdateRequestCountForTesting == 1)
        #expect(proxy.keyCommands?.count == 1)
        #expect(proxy.keyCommands?.first?.input == "d")
        #expect(proxy.keyCommands?.first?.modifierFlags == [.command])
        #expect(container.keyCommands == nil)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        #expect(proxy.keyCommandUpdateRequestCountForTesting == 2)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        #expect(proxy.keyCommandUpdateRequestCountForTesting == 3)
        #expect(proxy.keyCommands?.first?.input == "j")

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command, .shift],
                perform: {}
            ),
        ]
        #expect(proxy.keyCommandUpdateRequestCountForTesting == 4)
        #expect(proxy.keyCommands?.first?.modifierFlags == [.command, .shift])

        container.hardwareKeyboardCommands = []
        #expect(proxy.keyCommandUpdateRequestCountForTesting == 5)
        #expect(proxy.keyCommands == nil)
        #expect(container.keyCommands == nil)
    }

    @Test("equivalent hardware command signatures retain UIKit's table and replace dispatch closures")
    func equivalentHardwareCommandSignatureUsesReplacementClosureWithoutInvalidation() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let proxy = container.inputProxy
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("old") }
            ),
        ]

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command, .numericPad],
                perform: { performed.append("new") }
            ),
        ]

        #expect(proxy.keyCommandUpdateRequestCountForTesting == 1)
        #expect(proxy.keyCommands?.first?.modifierFlags == [.command])
        proxy.performHardwareKeyboardCommandForTesting(
            input: "d",
            modifierFlags: [.command, .numericPad]
        )
        #expect(performed == ["new"])
    }

    @Test("changed hardware command titles request a menu rebuild")
    func changedHardwareCommandTitleRequestsMenuRebuild() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let proxy = container.inputProxy
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Pane Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        #expect(proxy.keyCommandUpdateRequestCountForTesting == 2)
        #expect(proxy.keyCommands?.first?.title == "Split Pane Right")
        #expect(proxy.keyCommands?.first?.discoverabilityTitle == "Split Pane Right")
    }

    @Test("hardware command dispatch requires an exact normalized input and modifier match")
    func hardwareCommandDispatchUsesExactNormalizedMatch() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let proxy = container.inputProxy
        var performed = 0
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed += 1 }
            ),
        ]

        proxy.performHardwareKeyboardCommandForTesting(input: "D", modifierFlags: [.command])
        proxy.performHardwareKeyboardCommandForTesting(input: "d", modifierFlags: [.command, .shift])
        #expect(performed == 0)

        proxy.performHardwareKeyboardCommandForTesting(
            input: "d",
            modifierFlags: [.command, .numericPad]
        )
        #expect(performed == 1)
        #expect(container.keyCommands == nil)
    }

    @Test("stale cached hardware commands are rejected while current commands remain dispatchable")
    func staleCachedHardwareCommandIsRejected() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let proxy = container.inputProxy
        var performed: [String] = []
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("old") }
            ),
        ]
        let staleCommand = try! #require(proxy.keyCommands?.first)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: { performed.append("current") }
            ),
        ]
        let currentCommand = try! #require(proxy.keyCommands?.first)
        let commandAction = try! #require(currentCommand.action)

        #expect(!proxy.canPerformAction(commandAction, withSender: staleCommand))
        #expect(proxy.canPerformAction(commandAction, withSender: currentCommand))

        proxy.perform(commandAction, with: currentCommand)
        #expect(performed == ["current"])
    }

    @Test("hardware command validation rejects nil input and mismatched modifiers")
    func hardwareCommandValidationRequiresExactNormalizedMatch() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let proxy = container.inputProxy
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        let currentCommand = try! #require(proxy.keyCommands?.first)
        let commandAction = try! #require(currentCommand.action)
        let nilInputCommand = NilInputKeyCommand(
            title: "Missing Input",
            action: commandAction,
            input: "j",
            modifierFlags: [.command]
        )
        let mismatchedModifierCommand = UIKeyCommand(
            title: "Wrong Modifiers",
            action: commandAction,
            input: "j",
            modifierFlags: [.command, .shift]
        )

        #expect(!proxy.canPerformAction(commandAction, withSender: nilInputCommand))
        #expect(!proxy.canPerformAction(commandAction, withSender: mismatchedModifierCommand))
    }

    @Test("hardware command changes do not alter unrelated action validation")
    func unrelatedActionValidationIsUnchanged() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let proxy = container.inputProxy
        let action = #selector(UIResponderStandardEditActions.copy(_:))
        let resultBeforeCommand = proxy.canPerformAction(action, withSender: nil)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        #expect(proxy.canPerformAction(action, withSender: nil) == resultBeforeCommand)
    }

    @Test("selection mode keeps indirect terminal pan recognizers enabled")
    func selectionModeKeepsIndirectScrollingEnabled() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        container.enterSelectionModeForTesting()

        let pans = container.terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        #expect(!pans.isEmpty)
        #expect(pans.allSatisfy { $0.isEnabled })
    }

    @Test("focus requests remain pending until the keyboard proxy can become first responder")
    func focusRequestNotConsumedWhenProxyCannotFocus() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let coordinator = TerminalPaneView.Coordinator()
        container.inputProxy.softwareKeyboardInputEnabled = false

        coordinator.applyFocusRequest(1, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(coordinator.lastFocusRequest == 0)
    }

    @Test
    func dismantleUIViewDoesNotCaptureLayerSnapshotDuringTeardown() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let coordinator = TerminalPaneView.Coordinator()
        var didNotifyUnmount = false
        var receivedSnapshot: UIImage?
        coordinator.onWillUnmount = { snapshot in
            didNotifyUnmount = true
            receivedSnapshot = snapshot
        }

        TerminalPaneView.dismantleUIView(container, coordinator: coordinator)

        #expect(didNotifyUnmount)
        #expect(receivedSnapshot == nil)
    }

    @Test("""
@spec IOS-11.12: When the user taps Paste from the terminal long-press edit menu, the application shall forward the clipboard paste request and then re-focus GrafttyMobile's software-keyboard proxy when it is eligible, so dismissing the UIKit edit menu does not leave the user without terminal keyboard control.
""")
    func pasteMenuRefocusesKeyboardProxyAfterForwardingPaste() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.inputProxy.softwareKeyboardInputEnabled = true
        var didRequestPaste = false
        container.onPasteRequested = { didRequestPaste = true }

        container.performPasteForTesting()

        #expect(didRequestPaste)
        #expect(container.keyboardRefocusRequestCountForTesting == 1)
    }
}

@Suite("Terminal gestures do not claim ownership")
@MainActor
struct OwnershipNeutralGestureTests {

    @Test
    func terminalInputContainerHasNoOwnershipClaimGestureHook() {
        let view = TerminalInputContainerView()
        #expect(!view.hasOwnershipClaimGestureHookForTesting)
    }

    @Test
    func longPressAndPinchRemainOwnershipNeutral() {
        let view = TerminalInputContainerView()

        view.simulateLongPressBeganForTesting()
        view.simulatePinchForTesting(state: .began, scale: 1.2)

        #expect(!view.hasOwnershipClaimGestureHookForTesting)
    }
}
#endif
