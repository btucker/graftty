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
        // or while a pointer selection owns the mouse button.
        if let surface = terminalView.surface, !surface.isMouseCaptured, !surface.hasSelection() {
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
        // The terminal selects the pressed word and presents its own menu,
        // clear of the handles. A press with no text nearby selects nothing.
        if terminalView.beginHostTouchSelection(at: request.sourcePoint) {
            longPressSelectedText = terminalView.touchSelectionText
            return
        }
        longPressSelectedText = nil
        let config = UIEditMenuConfiguration(
            identifier: longPressMenuIdentifier(for: longPressMenuGeneration),
            sourcePoint: convert(request.sourcePoint, from: terminalView)
        )
        longPressMenu.presentEditMenu(with: config)
    }

    /// The blank-space menu is the container's own, so the selection it
    /// starts waits a turn for that menu to begin dismissing.
    fileprivate func performSelectAll() {
        let point = lastLongPressPoint
        DispatchQueue.main.async { [weak self] in
            self?.terminalView.beginHostTouchSelection(at: point, selectAll: true)
        }
    }

    func performPaste(for menuGeneration: UInt) {
        cancelPendingApplicationScroll()
        terminalView.commitAndResetTextContext()
        onPasteRequested?()
        guard menuGeneration == longPressMenuGeneration else { return }
        pendingPasteRefocusGeneration = menuGeneration
        refocusKeyboardAfterEditMenuDismissalIfReady(for: menuGeneration)
    }

    /// Clears any touch selection: a control-bar key press or a replaced surface.
    public func cancelActiveSelectionIfAny() {
        terminalView.dismissTouchSelection()
    }

    /// Paste chosen from the terminal's selection menu. That menu belongs to
    /// the terminal view, so focus returns once its dismissal has finished.
    fileprivate func performPasteFromSelectionMenu() {
        let hadFocus = terminalView.isFirstResponder
        terminalView.dismissTouchSelection()
        cancelPendingApplicationScroll()
        terminalView.commitAndResetTextContext()
        onPasteRequested?()
        guard hadFocus else { return }
        terminalView.performAfterTouchMenuDismissal { [weak self] in
            guard let self, self.terminalView.canBecomeFirstResponder else { return }
            _ = self.focusKeyboardInput()
        }
    }

    /// Actions for the long-pressed link: open it on this device, open it
    /// through the originating pane's browser on the host, or copy it.
    /// Empty when the press was not on a link. Each action checks that its
    /// menu is still the current one, so a stale menu cannot act on a
    /// replacement pane.
    func linkMenuElements(for generation: UInt) -> [UIMenuElement] {
        guard let url = longPressURL else { return [] }
        let openLocally = openURLLocally
        let openOnHost = openURL
        let host = hostLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
                guard let self, self.longPressMenuGeneration == generation else { return }
                run()
            }
        }
        return [
            action("Open Link", "safari") { openLocally(url) },
            action("Open on \(host.isEmpty ? "Host" : host)", "macbook.and.iphone") { openOnHost(url) },
            action("Copy Link", "doc.on.doc") { [weak self] in self?.copyLink(url) },
        ]
    }

    /// The edit menu while text is selected: Copy, Select All, and Paste
    /// when the clipboard has something to paste.
    func selectionMenuElements(
        for context: TerminalTouchSelectionMenuContext, hasPasteContent: Bool
    ) -> [UIMenuElement] {
        // The link belongs to the word the long press selected. Once a
        // handle drag changes the selection, its actions go.
        var children: [UIMenuElement] = context.selectedText == longPressSelectedText
            ? linkMenuElements(for: longPressMenuGeneration) : []
        children += ["terminal.copy", "terminal.selectAll"].compactMap {
            terminalView.librarySelectionAction($0, for: context)
        }
        if hasPasteContent {
            children.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.performPasteFromSelectionMenu()
            })
        }
        return children
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
        guard configuration.identifier == longPressMenuIdentifier(for: longPressMenuGeneration)
        else { return nil }
        return longPressUIMenu(for: longPressMenuGeneration, hasPasteContent: Self.pasteboardHasContent)
    }

    public func editMenuInteraction(
        _ interaction: UIEditMenuInteraction,
        willDismissMenuFor configuration: UIEditMenuConfiguration,
        animator: any UIEditMenuInteractionAnimating
    ) {
        guard configuration.identifier == longPressMenuIdentifier(for: longPressMenuGeneration)
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
            UIAction(title: "Select All") { [weak self] _ in self?.performSelectAll() },
        ]
        children.insert(contentsOf: linkMenuElements(for: generation), at: 0)
        if hasPasteContent {
            children.append(UIAction(title: "Paste") { [weak self] _ in
                self?.performPaste(for: generation)
            })
        }
        return UIMenu(children: children)
    }

    static var pasteboardHasContent: Bool {
        UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages
    }
}
#endif
