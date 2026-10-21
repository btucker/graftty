#if canImport(UIKit)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI
import UIKit

extension TerminalInputContainerView {
    func prepareLongPressMenu(at point: CGPoint, text: String) {
        lastLongPressPoint = point
        longPressURL = terminalGridMetrics.flatMap {
            TerminalLinkResolver.url(
                in: text, at: point, grid: $0,
                displayScale: terminalView.contentScaleFactor
            )
        }
        longPressMenuGeneration &+= 1
        pendingPasteRefocusGeneration = nil
        completedLongPressMenuDismissalGeneration = nil
    }

    private func presentLongPressMenu(for request: TerminalTextSelectionRequest) {
        prepareLongPressMenu(
            at: request.sourcePoint, text: request.text
        )
        // Text alone cannot distinguish an OSC8 display label from its target.
        // Verify through native metadata only when pointer motion is safe.
        longPressURL = nil
        // Native lookup uses the real terminal cell map, including OSC8.
        // Never synthesize pointer motion in a mouse-reporting application
        // or while a selection drag owns the mouse button.
        if let surface = terminalView.surface, !surface.isMouseCaptured, !selectionController.isActive, !surface.hasSelection() {
            longPressURL = TerminalLinkResolver.url(in: request.text, anchor: request.anchorRange)
            probingLink = true
            probedLink = nil
            surface.sendMousePos(x: -1, y: -1, modifiers: .super_)
            surface.sendMousePos(x: Double(request.sourcePoint.x), y: Double(request.sourcePoint.y), modifiers: .super_)
            let link = probedLink
            probingLink = false
            surface.sendMousePos(x: Double(request.sourcePoint.x), y: Double(request.sourcePoint.y))
            if let link {
                // An unsupported OSC8 target must not fall back to its label.
                longPressURL = TerminalLinkResolver.webURL(link)
            }
        }
        let config = UIEditMenuConfiguration(
            identifier: longPressMenuIdentifier(for: longPressMenuGeneration),
            sourcePoint: convert(request.sourcePoint, from: terminalView)
        )
        longPressMenu.presentEditMenu(with: config)
    }

    @objc func handleSelectionPan(_ recognizer: UIPanGestureRecognizer) {
        guard selectionController.isActive else { return }
        let point = recognizer.location(in: terminalView)
        switch recognizer.state {
        case .began:
            selectionPanStartedInViewport = acceptsTerminalInput(
                at: recognizer.location(in: self)
            )
            guard selectionPanStartedInViewport else { return }
            selectionMenu.dismissMenu()
            selectionController.extend(to: point)
        case .changed:
            guard selectionPanStartedInViewport else { return }
            selectionController.extend(to: point)
        case .ended, .cancelled, .failed:
            guard selectionPanStartedInViewport else { return }
            selectionPanStartedInViewport = false
            selectionController.endExtension(
                at: point,
                viewportHeight: terminalView.bounds.height,
                displayScale: terminalView.contentScaleFactor
            )
            presentSelectionMenu(near: point)
        default: break
        }
    }

    /// Touch types masked pan recognizers may keep receiving while selection
    /// mode is active: indirect pointer only, so trackpad/mouse scrolling
    /// (IOS-6.17) stays live while finger drags belong to the selection pan.
    static let indirectPointerOnlyTouchTypes: [NSNumber] = [
        NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
    ]

    /// @spec IOS-11.4: While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and the active terminal or checkpoint-canvas scroll recognizers shall stop receiving direct touches (indirect trackpad/mouse scrolling stays enabled) until selection mode exits.
    func enterSelectionMode() {
        guard !selectionPanRecognizer.isEnabled else { return }
        selectionPanRecognizer.isEnabled = true
        selectionModeSavedTouchTypes = []
        ((terminalView.gestureRecognizers ?? []) + [snapshotScrollView.panGestureRecognizer]).forEach { recognizer in
            if let pan = recognizer as? UIPanGestureRecognizer,
               !pan.allowedScrollTypesMask.isEmpty {
                // A non-empty scroll mask only ADDS indirect scroll-event
                // recognition — the pan still recognizes finger drags, and
                // left enabled it would race the selection pan for them.
                // Narrow it to indirect touches instead of disabling it so
                // trackpad scrolling keeps working during selection.
                selectionModeSavedTouchTypes.append((pan, pan.allowedTouchTypes))
                pan.allowedTouchTypes = Self.indirectPointerOnlyTouchTypes
                return
            }
        }
        updateTerminalGestureEnablement()
    }

    func exitSelectionMode() {
        selectionPanRecognizer.isEnabled = false
        for (pan, savedTouchTypes) in selectionModeSavedTouchTypes {
            pan.allowedTouchTypes = savedTouchTypes
        }
        selectionModeSavedTouchTypes = []
        updateTerminalGestureEnablement()
    }

    fileprivate func performSelectAtLongPressPoint() {
        selectionController.beginSelection(at: lastLongPressPoint)
        enterSelectionMode()
        presentSelectionMenu(near: lastLongPressPoint)
    }

    fileprivate func performSelectAll() {
        selectionController.selectAll()
        enterSelectionMode()
        let center = CGPoint(x: terminalView.bounds.midX, y: terminalView.bounds.midY)
        presentSelectionMenu(near: center)
    }

    func performPaste(for menuGeneration: UInt) {
        cancelPendingApplicationScroll()
        terminalView.commitAndResetTextContext()
        onPasteRequested?()
        guard menuGeneration == longPressMenuGeneration else { return }
        pendingPasteRefocusGeneration = menuGeneration
        refocusKeyboardAfterEditMenuDismissalIfReady(for: menuGeneration)
    }

    fileprivate func performCopy() {
        _ = selectionController.copy(toPasteboard: UIPasteboard.general)
        exitSelectionMode()
    }

    fileprivate func performCancelSelection() {
        selectionController.cancel()
        exitSelectionMode()
    }

    /// Called by parent SwiftUI layer when a control-bar key is pressed,
    /// to satisfy IOS-11.7's "press a key while active" cancel path.
    public func cancelActiveSelectionIfAny() {
        guard selectionController.isActive else { return }
        performCancelSelection()
    }

    /// @spec IOS-11.5: When selection mode is active and the user lifts their finger after Select / Select All / extend, the application shall present a second `UIEditMenuInteraction` menu anchored near the selection rect containing **Copy** and **Cancel**.
    private func presentSelectionMenu(near point: CGPoint) {
        let config = UIEditMenuConfiguration(
            identifier: "selection" as AnyHashable,
            sourcePoint: convert(point, from: terminalView)
        )
        selectionMenu.presentEditMenu(with: config)
    }

    private func refocusKeyboardAfterEditMenuDismissalIfReady(for generation: UInt) {
        guard pendingPasteRefocusGeneration == generation,
              completedLongPressMenuDismissalGeneration == generation
        else { return }
        pendingPasteRefocusGeneration = nil
        // Leave UIKit's dismissal-completion turn before asking its terminal
        // responder to focus, so any remaining internal cleanup runs first.
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.longPressMenuGeneration == generation,
                  self.terminalView.canBecomeFirstResponder
            else { return }
            _ = self.focusKeyboardInput()
        }
    }

    func longPressMenuIdentifier(for generation: UInt) -> AnyHashable {
        "long-press:\(generation)" as AnyHashable
    }
}

extension TerminalInputContainerView: TerminalSurfaceTextSelectionRequestDelegate {
    /// @spec IOS-11.1: While a focused terminal pane is interactive, the application shall handle libghostty's built-in long-press selection request through `TerminalInputContainerView` and present a menu at the touch point containing **Select**, **Select All**, and (when the clipboard contains text or an image at menu-build time) **Paste**, without installing a competing long-press recognizer on the container.
    public func terminalDidRequestTextSelection(_ request: TerminalTextSelectionRequest) {
        presentLongPressMenu(for: request)
    }
}

extension TerminalInputContainerView: UIEditMenuInteractionDelegate {
    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        menuFor configuration: UIEditMenuConfiguration,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        if interaction === longPressMenu {
            guard configuration.identifier == longPressMenuIdentifier(for: longPressMenuGeneration)
            else { return nil }
            return longPressUIMenu(
                for: longPressMenuGeneration,
                hasPasteContent: UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
            )
        }
        return selectionUIMenu()
    }

    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        guard interaction === longPressMenu,
              configuration.identifier == longPressMenuIdentifier(for: longPressMenuGeneration)
        else { return }
        let generation = longPressMenuGeneration
        animator.addCompletion { [weak self] in
            guard let self, self.longPressMenuGeneration == generation else { return }
            self.completedLongPressMenuDismissalGeneration = generation
            self.refocusKeyboardAfterEditMenuDismissalIfReady(for: generation)
        }
    }

    func longPressUIMenu(for generation: UInt, hasPasteContent: Bool) -> UIMenu {
        var children: [UIMenuElement] = [
            UIAction(title: "Select") { [weak self] _ in self?.performSelectAtLongPressPoint() },
            UIAction(title: "Select All") { [weak self] _ in self?.performSelectAll() },
        ]
        if let url = longPressURL {
            let open = openURL
            children.insert(UIAction(title: "Copy Link", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                guard let self, self.longPressMenuGeneration == generation else { return }
                self.copyLink(url)
            }, at: 0)
            children.insert(UIAction(title: "Open Link", image: UIImage(systemName: "safari")) { [weak self] _ in
                guard let self, self.longPressMenuGeneration == generation else { return }
                open(url)
            }, at: 0)
        }
        if hasPasteContent {
            children.append(UIAction(title: "Paste") { [weak self] _ in
                self?.performPaste(for: generation)
            })
        }
        return UIMenu(children: children)
    }

    private func selectionUIMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Copy") { [weak self] _ in self?.performCopy() },
            UIAction(title: "Cancel", attributes: .destructive) { [weak self] _ in
                self?.performCancelSelection()
            },
        ])
    }
}
#endif
