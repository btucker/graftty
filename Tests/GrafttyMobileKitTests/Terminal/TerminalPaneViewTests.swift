#if canImport(UIKit)
import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit
import UIKit

private final class NilInputKeyCommand: UIKeyCommand {
    override var input: String? { nil }
}

@MainActor
private final class DeferredEditMenuAnimator: NSObject, UIEditMenuInteractionAnimating {
    private var completions: [() -> Void] = []

    func addAnimations(_ animations: @escaping () -> Void) {
        animations()
    }

    func addCompletion(_ completion: @escaping () -> Void) {
        completions.append(completion)
    }

    func finish() {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0() }
    }
}

@Suite
@MainActor
struct TerminalPaneViewTests {

    @Test
    func terminalDoesNotExposeGhosttyAccessoryView() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(!container.terminalView.showsInputAccessory)
        #expect(container.terminalView.inputAccessoryView == nil)
    }

    @Test("""
@spec IOS-6.7: While a terminal pane is rendered in the iOS app, `UITerminalView` shall remain the sole terminal keyboard responder and its supported `showsInputAccessory` property shall be false, so the GhosttyKit accessory is absent without Objective-C runtime swizzling. The only visible software-keyboard accessory row shall be GrafttyMobile's terminal control bar (`IOS-6.1`).
""")
    func terminalPaneShowsOnlyGrafttyKeyboardAccessory() {
        let container = TerminalInputContainerView(frame: .zero)

        #expect(!container.terminalView.showsInputAccessory)
        #expect(container.terminalView.inputAccessoryView == nil)
    }

    @Test("""
@spec IOS-6.8: While a terminal pane is rendered in the iOS app, libghostty-spm's built-in pan-to-scroll and pinch-to-zoom gestures on `UITerminalView` shall remain functional. `UITerminalView` shall be the container's sole full-size subview and touch target, with no keyboard or selection overlay above it.
""")
    func terminalViewIsSoleFullSizeSubviewAndTouchTarget() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.layoutIfNeeded()

        let hitView = container.hitTest(CGPoint(x: 160, y: 120), with: nil)

        #expect(container.subviews == [container.terminalView])
        #expect(container.terminalView.frame == container.bounds)
        #expect(hitView === container.terminalView)
        #expect(!container.terminalView.canBecomeFirstResponder)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        #expect(container.terminalView.canBecomeFirstResponder)
    }

    @Test("""
@spec IOS-6.17: While a terminal pane is rendered on iPad with a trackpad, indirect pointer scroll gestures shall reach libghostty's terminal scroll/input recognizers on the sole `UITerminalView` touch surface, with no GrafttyMobile keyboard or selection overlay blocking them.
""")
    func terminalPanRecognizersAllowIndirectScrolling() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(container.terminalPanRecognizersAllowIndirectScrollingForTesting)
    }

    @Test("""
@spec IPAD-9.9: The `TerminalInputContainerView` in the active iPad terminal responder chain shall publish only app-level Ghostty shortcuts as `UIKeyCommand`s that take priority over conflicting focus and text-input system behavior, and synchronously request a UIKit menu-system rebuild whenever the effective command identities, titles, inputs, or modifiers change. General terminal hardware keys remain owned by the sole `UITerminalView` responder.
""")
    func activeTerminalInputResponderRefreshesPublishedHardwareKeyboardCommands() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        #expect(container.keyCommands == nil)
        #expect(container.keyCommandUpdateRequestCountForTesting == 0)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Right",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
            .init(
                id: "next-worktree",
                title: "Next Worktree",
                input: "\t",
                modifierFlags: [.control],
                perform: {}
            ),
        ]

        #expect(container.keyCommandUpdateRequestCountForTesting == 1)
        let publishedCommands = try! #require(container.keyCommands)
        #expect(publishedCommands.count == 2)
        #expect(publishedCommands[0].input == "d")
        #expect(publishedCommands[0].modifierFlags == [.command])
        #expect(publishedCommands[1].input == "\t")
        #expect(publishedCommands[1].modifierFlags == [.control])
        for command in publishedCommands {
            #expect(command.wantsPriorityOverSystemBehavior)
        }
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "d",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        #expect(container.keyCommandUpdateRequestCountForTesting == 2)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        #expect(container.keyCommandUpdateRequestCountForTesting == 3)
        #expect(container.keyCommands?.first?.input == "j")

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command, .shift],
                perform: {}
            ),
        ]
        #expect(container.keyCommandUpdateRequestCountForTesting == 4)
        #expect(container.keyCommands?.first?.modifierFlags == [.command, .shift])

        container.hardwareKeyboardCommands = []
        #expect(container.keyCommandUpdateRequestCountForTesting == 5)
        #expect(container.keyCommands == nil)
    }

    @Test("equivalent hardware command signatures retain UIKit's table and replace dispatch closures")
    func equivalentHardwareCommandSignatureUsesReplacementClosureWithoutInvalidation() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
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

        #expect(container.keyCommandUpdateRequestCountForTesting == 1)
        #expect(container.keyCommands?.first?.modifierFlags == [.command])
        container.performHardwareKeyboardCommandForTesting(
            input: "d",
            modifierFlags: [.command, .numericPad]
        )
        #expect(performed == ["new"])
    }

    @Test("changed hardware command titles request a menu rebuild")
    func changedHardwareCommandTitleRequestsMenuRebuild() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
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

        #expect(container.keyCommandUpdateRequestCountForTesting == 2)
        #expect(container.keyCommands?.first?.title == "Split Pane Right")
        #expect(container.keyCommands?.first?.discoverabilityTitle == "Split Pane Right")
    }

    @Test("hardware command dispatch requires an exact normalized input and modifier match")
    func hardwareCommandDispatchUsesExactNormalizedMatch() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
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

        container.performHardwareKeyboardCommandForTesting(input: "D", modifierFlags: [.command])
        container.performHardwareKeyboardCommandForTesting(input: "d", modifierFlags: [.command, .shift])
        #expect(performed == 0)

        container.performHardwareKeyboardCommandForTesting(
            input: "d",
            modifierFlags: [.command, .numericPad]
        )
        #expect(performed == 1)
    }

    @Test("stale cached hardware commands are rejected while current commands remain dispatchable")
    func staleCachedHardwareCommandIsRejected() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
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
        let staleCommand = try! #require(container.keyCommands?.first)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: { performed.append("current") }
            ),
        ]
        let currentCommand = try! #require(container.keyCommands?.first)
        let commandAction = try! #require(currentCommand.action)

        #expect(!container.canPerformAction(commandAction, withSender: staleCommand))
        #expect(container.canPerformAction(commandAction, withSender: currentCommand))

        container.perform(commandAction, with: currentCommand)
        #expect(performed == ["current"])
    }

    @Test("stale cached command identity is rejected when its chord is reused")
    func staleCachedHardwareCommandWithReusedChordIsRejected() {
        let container = TerminalInputContainerView(frame: .zero)
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
        let staleCommand = try! #require(container.keyCommands?.first)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-right",
                title: "Split Pane Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("retitled") }
            ),
        ]
        let retitledCommand = try! #require(container.keyCommands?.first)
        let commandAction = try! #require(retitledCommand.action)

        #expect(!container.canPerformAction(commandAction, withSender: staleCommand))
        container.perform(commandAction, with: staleCommand)
        #expect(performed.isEmpty)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Pane Right",
                input: "d",
                modifierFlags: [.command],
                perform: { performed.append("new") }
            ),
        ]
        let currentCommand = try! #require(container.keyCommands?.first)
        #expect(!container.canPerformAction(commandAction, withSender: retitledCommand))
        container.perform(commandAction, with: retitledCommand)
        #expect(performed.isEmpty)

        #expect(container.canPerformAction(commandAction, withSender: currentCommand))
        container.perform(commandAction, with: currentCommand)
        #expect(performed == ["new"])
    }

    @Test("hardware command validation rejects nil input and mismatched modifiers")
    func hardwareCommandValidationRequiresExactNormalizedMatch() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        let currentCommand = try! #require(container.keyCommands?.first)
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

        #expect(!container.canPerformAction(commandAction, withSender: nilInputCommand))
        #expect(!container.canPerformAction(commandAction, withSender: mismatchedModifierCommand))
    }

    @Test("ordinary reconstructed key commands validate stable identity and title")
    func reconstructedHardwareCommandValidatesStableIdentityAndTitle() {
        let container = TerminalInputContainerView(frame: .zero)
        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]
        let action = try! #require(container.keyCommands?.first?.action)

        let matching = UIKeyCommand(
            title: "Split Down",
            image: nil,
            action: action,
            input: "j",
            modifierFlags: [.command],
            propertyList: "split-down",
            alternates: [],
            discoverabilityTitle: "Split Down",
            attributes: [],
            state: .off
        )
        let staleID = UIKeyCommand(
            title: "Split Down",
            image: nil,
            action: action,
            input: "j",
            modifierFlags: [.command],
            propertyList: "split-right",
            alternates: [],
            discoverabilityTitle: "Split Down",
            attributes: [],
            state: .off
        )
        let staleTitle = UIKeyCommand(
            title: "Split Right",
            image: nil,
            action: action,
            input: "j",
            modifierFlags: [.command],
            propertyList: "split-down",
            alternates: [],
            discoverabilityTitle: "Split Right",
            attributes: [],
            state: .off
        )

        #expect(container.canPerformAction(action, withSender: matching))
        #expect(!container.canPerformAction(action, withSender: staleID))
        #expect(!container.canPerformAction(action, withSender: staleTitle))
    }

    @Test("hardware command changes do not alter unrelated action validation")
    func unrelatedActionValidationIsUnchanged() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let action = #selector(UIResponderStandardEditActions.copy(_:))
        let resultBeforeCommand = container.canPerformAction(action, withSender: nil)

        container.hardwareKeyboardCommands = [
            .init(
                id: "split-down",
                title: "Split Down",
                input: "j",
                modifierFlags: [.command],
                perform: {}
            ),
        ]

        #expect(container.canPerformAction(action, withSender: nil) == resultBeforeCommand)
    }

    @Test("keyCommands are cached between queries and invalidated on signature change")
    func keyCommandsAreCachedUntilSignatureChanges() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        container.hardwareKeyboardCommands = [
            .init(id: "split-right", title: "Split Right", input: "d", modifierFlags: [.command], perform: {}),
        ]

        // UIKit queries keyCommands on every hardware key-down; repeated
        // queries must return the cached objects, not fresh allocations.
        let first = container.keyCommands?.first
        let second = container.keyCommands?.first
        #expect(first != nil)
        #expect(first === second)

        // A signature-equal update (fresh closures, same chords) keeps the cache.
        container.hardwareKeyboardCommands = [
            .init(id: "split-right", title: "Split Right", input: "d", modifierFlags: [.command], perform: {}),
        ]
        #expect(container.keyCommands?.first === first)

        // A real signature change rebuilds.
        container.hardwareKeyboardCommands = [
            .init(id: "split-down", title: "Split Down", input: "j", modifierFlags: [.command], perform: {}),
        ]
        let rebuilt = container.keyCommands?.first
        #expect(rebuilt !== first)
        #expect(rebuilt?.input == "j")
    }

    @Test("selection mode keeps indirect terminal pan recognizers enabled")
    func selectionModeKeepsIndirectScrollingEnabled() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))

        container.enterSelectionModeForTesting()

        let pans = container.terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        #expect(!pans.isEmpty)
        #expect(pans.allSatisfy { $0.isEnabled })
    }

    @Test("""
@spec IOS-11.4: While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and libghostty's built-in pan-to-scroll recognizers on the underlying `UITerminalView` shall stop receiving direct touches (indirect trackpad/mouse scrolling stays enabled) until selection mode exits.
""")
    func selectionModeStripsDirectTouchesFromScrollPans() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let maskedPans = {
            (container.terminalView.gestureRecognizers ?? [])
                .compactMap { $0 as? UIPanGestureRecognizer }
                .filter { !$0.allowedScrollTypesMask.isEmpty }
        }
        let savedTouchTypes = maskedPans().map(\.allowedTouchTypes)
        #expect(!maskedPans().isEmpty)

        container.enterSelectionModeForTesting()
        // allowedScrollTypesMask only adds indirect scroll recognition; the
        // direct-touch block must come from narrowing allowedTouchTypes.
        #expect(maskedPans().allSatisfy {
            $0.allowedTouchTypes == TerminalInputContainerView.indirectPointerOnlyTouchTypes
        })

        container.exitSelectionModeForTesting()
        #expect(maskedPans().map(\.allowedTouchTypes) == savedTouchTypes)
    }

    @Test("focus requests remain pending until the terminal can become first responder")
    func focusRequestNotConsumedUntilTerminalCanFocus() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let coordinator = TerminalPaneView.Coordinator()
        var consumedCount = 0
        coordinator.onFocusRequestsConsumed = { consumedCount += 1 }
        container.committedSoftwareInput = nil

        coordinator.applyFocusRequest(1, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(consumedCount == 0)

        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        coordinator.applyFocusRequest(1, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(consumedCount == 1)
        #expect(container.terminalView.isFirstResponder)
    }

    @Test("""
@spec IPAD-8.9: When a terminal pane remounts with zero pending focus requests (all prior requests already honored and consumed), the application shall not call becomeFirstResponder, so a keyboard the user dismissed is not re-summoned by idle-snapshot swaps or other view recreations.
""")
    func remountWithNoPendingFocusRequestsDoesNotSummonKeyboard() async {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        // Keyboard-eligible: a stale-total replay would succeed if attempted.
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        // A remount creates a fresh Coordinator with no memory; the counter
        // owners survive the remount and report zero pending requests.
        let freshCoordinator = TerminalPaneView.Coordinator()
        var consumedCount = 0
        freshCoordinator.onFocusRequestsConsumed = { consumedCount += 1 }
        freshCoordinator.applyFocusRequest(0, to: container)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(consumedCount == 0)
        #expect(!container.terminalView.isFirstResponder)
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
@spec IOS-11.12: When the user taps Paste from the terminal long-press edit menu, the application shall forward the clipboard paste request and re-focus the eligible `UITerminalView` after UIKit's edit-menu dismissal completes, so the dismissal cannot subsequently resign the terminal and leave the user without keyboard control.
""")
    func pasteMenuRefocusesEligibleTerminalAfterDismissalCompletes() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        var didRequestPaste = false
        container.onPasteRequested = { didRequestPaste = true }

        let animator = DeferredEditMenuAnimator()
        container.editMenuInteraction(
            UIEditMenuInteraction(delegate: nil),
            willDismissMenuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero),
            animator: animator
        )
        // UIKit is allowed to begin dismissal before invoking the selected
        // action. Register the completion first to cover that ordering.
        container.performPasteForTesting()

        #expect(didRequestPaste)
        #expect(!container.terminalView.isFirstResponder)

        animator.finish()

        #expect(container.terminalView.isFirstResponder)
    }

    @Test("any touch on the terminal container fires onUserInteraction")
    func touchBeganFiresUserInteraction() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        var fired = 0
        container.onUserInteraction = { fired += 1 }

        container.simulateAnyTouchBeganForTesting()

        #expect(fired == 1)
    }

    @Test("""
@spec IOS-6.6: While an owner terminal pane is focused on iOS, committed software-keyboard text and delete shall flow through `UITerminalView`'s supported `TerminalSoftwareInputDelegate` and be forwarded exactly once to `SessionClient.sendSoftwareKeyboardText(_:)` and `deleteBackward()`. A single software-keyboard newline shall be translated to CR (`0x0D`) per `IOS-6.3`, and delete shall send DEL (`0x7F`), without using Ghostty's paste-text path.
""")
    func committedSoftwareInputDelegateForwardsExactlyOnce() {
        let container = TerminalInputContainerView(frame: .zero)
        var texts: [String] = []
        var deletes = 0
        container.committedSoftwareInput = .init(
            insertText: { texts.append($0) },
            deleteBackward: { deletes += 1 }
        )

        #expect(container.terminalView.softwareInputDelegate === container)
        container.terminalView.insertText("hello")
        container.terminalView.deleteBackward()
        #expect(texts == ["hello"])
        #expect(deletes == 1)
    }

    @Test("ineligible terminal consumes pending committed input after owner loss")
    func ownerLossConsumesPendingCommittedInputWithoutForwarding() {
        let container = TerminalInputContainerView(frame: .zero)
        let delegate: any TerminalSoftwareInputDelegate = container
        var texts: [String] = []
        var deletes = 0
        container.committedSoftwareInput = .init(
            insertText: { texts.append($0) },
            deleteBackward: { deletes += 1 }
        )

        container.committedSoftwareInput = nil

        #expect(delegate.terminalView(container.terminalView, insertText: "pending"))
        #expect(delegate.terminalViewDeleteBackward(container.terminalView))
        #expect(texts.isEmpty)
        #expect(deletes == 0)
        #expect(!container.terminalView.isKeyboardInputEnabled)
    }

    @Test("""
@spec IOS-6.2: `UITerminalView` shall be the sole terminal keyboard responder and the primary owner of rendering and hardware-key event translation for every iOS pane. All general hardware keys, including Escape and arrows, shall flow through libghostty; GrafttyMobile shall publish `UIKeyCommand`s only for application-level shortcuts and shall not reimplement terminal key translation.
""")
    func eligibleTerminalBecomesFirstResponderInWindow() {
        let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let controller = UIViewController()
        controller.view = container
        let window = UIWindow(frame: container.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        #expect(container.terminalView.becomeFirstResponder())
        #expect(container.terminalView.isFirstResponder)
        #expect(container.terminalView.next === container)

        container.committedSoftwareInput = nil
        #expect(!container.terminalView.isFirstResponder)
        #expect(!container.terminalView.canBecomeFirstResponder)
    }

    @Test("""
@spec IOS-6.18: When hardware Escape, arrow, or other terminal key presses reach an iOS terminal pane, the sole `UITerminalView` responder shall pass them to libghostty's hardware-key translation. GrafttyMobile shall not install per-key handlers; explicit control-bar Escape remains a `SessionClient.sendEscape()` command under `IOS-6.1`.
""")
    func containerPublishesNoGeneralTerminalKeyCommands() {
        let container = TerminalInputContainerView(frame: .zero)

        #expect(container.keyCommands == nil)
    }
}

#endif
