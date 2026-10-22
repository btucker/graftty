#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

extension TerminalInputContainerView {
    @discardableResult
    func applyObservedFontSizeStepsForTesting(
        _ steps: Int,
        pinchScale: CGFloat? = nil
    ) -> (configuredFontSize: Float?, pinchScale: CGFloat) {
        if let pinchScale {
            observedPinchScale = pinchScale
        }
        applyObservedFontSizeSteps(steps)
        return (configuredFontSize, observedPinchScale)
    }

    /// Internal-visibility access for unit tests: terminal pan recognizers
    /// accept indirect pointer scroll input while selection gestures remain
    /// owned by `selectionPanRecognizer`.
    var terminalPanRecognizersAllowIndirectScrollingForTesting: Bool {
        let pans = terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
        return !pans.isEmpty && pans.allSatisfy {
            $0.allowedScrollTypesMask.contains(.continuous)
                && $0.allowedScrollTypesMask.contains(.discrete)
        }
    }

    /// Internal-visibility access for unit tests: invokes `enterSelectionMode`.
    func enterSelectionModeForTesting() {
        enterSelectionMode()
    }

    /// Internal-visibility access for unit tests: invokes `exitSelectionMode`.
    func exitSelectionModeForTesting() {
        exitSelectionMode()
    }

    /// Internal-visibility access for unit tests: invokes the paste menu
    /// action without presenting UIKit's edit menu.
    func performPasteForTesting() {
        performPaste(for: longPressMenuGeneration)
    }

    /// Internal-visibility access for unit tests: drives the real long-press
    /// edit-menu interaction's dismissal callback without presenting UIKit UI.
    func dismissLongPressMenuForTesting(animator: any UIEditMenuInteractionAnimating) {
        editMenuInteraction(
            longPressMenu,
            willDismissMenuFor: UIEditMenuConfiguration(
                identifier: longPressMenuIdentifier(for: longPressMenuGeneration),
                sourcePoint: .zero
            ),
            animator: animator
        )
    }

    /// Internal-visibility access for unit tests: proves the independent
    /// selection-menu interaction cannot consume a pending Paste refocus.
    func dismissSelectionMenuForTesting(animator: any UIEditMenuInteractionAnimating) {
        editMenuInteraction(
            selectionMenu,
            willDismissMenuFor: UIEditMenuConfiguration(
                identifier: "selection" as AnyHashable,
                sourcePoint: .zero
            ),
            animator: animator
        )
    }

    /// Internal-visibility access for unit tests: simulates the any-touch
    /// observer's `touchesBegan` callback without a real UIKit touch event.
    func simulateAnyTouchBeganForTesting(changesCursor: Bool = false) {
        handleAnyTouchBegan(changesCursor: changesCursor)
    }

    func longPressMenuActionTitlesForTesting(hasPasteContent: Bool) -> [String] {
        longPressMenuForTesting(hasPasteContent: hasPasteContent)
            .children.compactMap { ($0 as? UIAction)?.title }
    }

    func longPressMenuForTesting(hasPasteContent: Bool) -> UIMenu {
        longPressUIMenu(
            for: longPressMenuGeneration,
            hasPasteContent: hasPasteContent
        )
    }

    func performHardwareKeyboardCommandForTesting(input: String, modifierFlags: UIKeyModifierFlags) {
        let normalizedModifiers = modifierFlags.appCommandModifiers
        guard let command = effectiveHardwareKeyboardCommands.first(where: {
            $0.input == input
                && $0.modifierFlags.appCommandModifiers == normalizedModifiers
        }) else { return }
        handleHardwareKeyboardCommand(UIKeyCommand(
            title: command.title,
            image: nil,
            action: #selector(handleHardwareKeyboardCommand(_:)),
            input: command.input,
            modifierFlags: command.modifierFlags.appCommandModifiers,
            propertyList: command.id,
            alternates: [],
            discoverabilityTitle: command.title,
            attributes: [],
            state: .off
        ))
    }
}
#endif
