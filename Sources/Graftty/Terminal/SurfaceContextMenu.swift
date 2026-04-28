import AppKit
import GrafttyKit
import GhosttyKit

// MARK: - Context Menu

/// Right-click / ctrl-click context menu on a terminal surface. Ported
/// from Ghostty's upstream `SurfaceView_AppKit.menu(for:)` — same items,
/// same actions, same semantics.
///
/// - Returning a non-nil menu from `NSView.menu(for:)` swallows the
///   subsequent mouse event, so on ctrl-left-click we synthesize a
///   right-mouse-press to keep the terminal's mouse-reporting in sync.
/// - When the terminal has enabled mouse capture, the menu is suppressed
///   so the underlying app can handle the click itself.
/// - Copy is only added when there's a non-empty selection — presence
///   implies "selection exists", so no separate validation is needed for
///   that item.
/// - "Terminal Read-only" reflects current state via a checkmark at
///   build time; the menu is rebuilt on each invocation so state is
///   always current.
extension SurfaceNSView {
    override func rightMouseDown(with event: NSEvent) {
        // Make sure the surface has focus before the menu appears so the
        // menu's action target (this view) is reachable via the responder
        // chain. Without this, the items can pop up but do nothing.
        window?.makeFirstResponder(self)
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let surface else { return nil }

        switch event.type {
        case .rightMouseDown:
            break
        case .leftMouseDown:
            // Only fire for ctrl-click (otherwise a regular left click).
            guard event.modifierFlags.contains(.control) else { return nil }
            // If the terminal app captures the mouse, give it the click
            // instead of popping the menu.
            if ghostty_surface_mouse_captured(surface) { return nil }
            // AppKit calls menu(for:) before dispatching any mouse event
            // for ctrl-click. Returning non-nil swallows the event, so
            // synthesize a right-press for the terminal's benefit.
            let mods = Self.ghosttyMods(from: event.modifierFlags)
            _ = ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_PRESS,
                GHOSTTY_MOUSE_RIGHT,
                mods
            )
        default:
            return nil
        }

        let menu = NSMenu()
        // Local helper: add an item and route it directly to `self`.
        // Default NSMenu dispatch walks the responder chain, which is
        // unreliable when the surface view isn't first responder at
        // menu-open time. Setting target = self makes every item's
        // selector dispatch deterministic.
        @discardableResult
        func add(_ title: String, _ action: Selector, _ symbol: String? = nil) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            if let symbol { item.setImageIfDesired(systemSymbolName: symbol) }
            return item
        }

        if hasNonEmptySelection {
            add("Copy", #selector(copyFromTerminal(_:)), "document.on.document")
        }
        add("Paste", #selector(pasteToTerminal(_:)), "document.on.clipboard")

        menu.addItem(.separator())
        add("Split Right", #selector(splitRight(_:)), "rectangle.righthalf.inset.filled")
        add("Split Left", #selector(splitLeft(_:)), "rectangle.leadinghalf.inset.filled")
        add("Split Down", #selector(splitDown(_:)), "rectangle.bottomhalf.inset.filled")
        add("Split Up", #selector(splitUp(_:)), "rectangle.tophalf.inset.filled")

        // TERM-8.10: surface the same Move-to-worktree section the
        // sidebar pane row offers (PWD-1.1 / PWD-1.2 / PWD-1.3),
        // sandwiched between the Splits block and Reset. Both context
        // and onMove are wired through TerminalManager by GrafttyApp;
        // either being nil collapses to no items rather than a no-op
        // separator.
        if let id = terminalID,
           let tm = terminalManager,
           let ctx = tm.currentPaneMoveContext?(id),
           let onMove = tm.onMovePane {
            menu.addItem(.separator())
            for item in PaneMoveMenuBuilder.items(
                terminalID: id,
                context: ctx,
                onMove: onMove
            ) {
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        add("Reset Terminal", #selector(resetTerminal(_:)), "arrow.trianglehead.2.clockwise")
        add("Toggle Terminal Inspector", #selector(toggleTerminalInspector(_:)), "scope")
        let readonlyItem = add("Terminal Read-only", #selector(toggleReadonly(_:)), "eye.fill")
        readonlyItem.state = isReadonly ? .on : .off

        return menu
    }

    // MARK: - Copy / Paste

    @objc func copyFromTerminal(_ sender: Any?) {
        bindingAction("copy_to_clipboard")
    }

    @objc func pasteToTerminal(_ sender: Any?) {
        bindingAction("paste_from_clipboard")
    }

    // MARK: - Splits
    //
    // Dispatches split requests up to the host via
    // `TerminalManager.onSplitRequest`. We *don't* call
    // `ghostty_surface_split` directly: that routes through libghostty's
    // action-callback system, which Graftty doesn't own (the action handler
    // in TerminalManager is a stub). Going through the Swift callback
    // lets the model layer (AppState → SplitTree) stay authoritative.

    @objc func splitRight(_ sender: Any?) { requestSplit(.right) }
    @objc func splitLeft(_ sender: Any?) { requestSplit(.left) }
    @objc func splitDown(_ sender: Any?) { requestSplit(.down) }
    @objc func splitUp(_ sender: Any?) { requestSplit(.up) }

    private func requestSplit(_ direction: PaneSplit) {
        guard let terminalID, let terminalManager else { return }
        terminalManager.onSplitRequest?(terminalID, direction)
    }

    // MARK: - Reset / Inspector / Read-only

    @objc func resetTerminal(_ sender: Any?) {
        bindingAction("reset")
    }

    @objc func toggleTerminalInspector(_ sender: Any?) {
        bindingAction("inspector:toggle")
    }

    @objc func toggleReadonly(_ sender: Any?) {
        bindingAction("toggle_readonly")
        // Flip our local flag so the next menu open has the right
        // checkmark. libghostty owns the authoritative state; this is
        // just our UI mirror.
        isReadonly.toggle()
    }

    // MARK: - Helpers

    /// True if libghostty reports a non-empty text selection on this
    /// surface. Drives whether "Copy" appears in the menu.
    fileprivate var hasNonEmptySelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    /// Dispatches a named binding action via
    /// `ghostty_surface_binding_action`. The action string is not
    /// NUL-required but must be sized in UTF-8 bytes, matching upstream.
    fileprivate func bindingAction(_ action: String) {
        guard let s = self.surface else { return }
        _ = action.withCString { cstr in
            ghostty_surface_binding_action(
                s,
                cstr,
                UInt(action.lengthOfBytes(using: .utf8))
            )
        }
    }
}

// MARK: - NSMenuItem helpers

extension NSMenuItem {
    /// Attach an SF Symbol to this menu item only on macOS versions that
    /// render menu icons as a norm (macOS 26 / Tahoe+). Earlier versions
    /// render menu items without icons per Apple HIG.
    func setImageIfDesired(systemSymbolName symbol: String) {
        if #available(macOS 26, *) {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
    }
}
