import AppKit
import GhosttyKit
import EspalierKit

/// Wraps a single `ghostty_surface_t` and its backing `NSView`.
///
/// # Ownership
/// - Owns the `ghostty_surface_t` — freed in `deinit`.
/// - The backing `SurfaceNSView` is retained directly on `view`.
/// - The `userdata` pointer passed to libghostty is an unretained reference to `self`;
///   the surface is freed before `self` deallocates, so the pointer never dangles.
/// - All C strings passed through the config (working directory, env var key/value)
///   are freed immediately after `ghostty_surface_new` returns, since libghostty
///   copies the config contents.
final class SurfaceHandle {
    let terminalID: TerminalID
    let surface: ghostty_surface_t
    let view: NSView
    let worktreePath: String

    init(
        terminalID: TerminalID,
        app: ghostty_app_t,
        worktreePath: String,
        socketPath: String
    ) {
        self.terminalID = terminalID
        self.worktreePath = worktreePath

        let surfaceView = SurfaceNSView()
        self.view = surfaceView
        defer {
            // Bind the surface to the view AFTER ghostty_surface_new returns
            // so the view can forward keystrokes/mouse events to it. The
            // view weakly references the surface via this unmanaged handle.
            surfaceView.surface = self.surface
        }

        // Allocate C strings up front so we can free them deterministically.
        let cwdCStr = strdup(worktreePath)
        let sockKey = strdup("ESPALIER_SOCK")
        let sockVal = strdup(socketPath)

        // env_vars needs a stable pointer during ghostty_surface_new; libghostty
        // copies the contents before returning.
        let envVarsPtr = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: 1)
        envVarsPtr.initialize(to: ghostty_env_var_s(key: sockKey, value: sockVal))

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(surfaceView).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.working_directory = UnsafePointer(cwdCStr)
        config.env_vars = envVarsPtr
        config.env_var_count = 1
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        guard let newSurface = ghostty_surface_new(app, &config) else {
            // Free everything we allocated, then fail. `self` is not yet fully initialized.
            envVarsPtr.deinitialize(count: 1)
            envVarsPtr.deallocate()
            free(cwdCStr)
            free(sockKey)
            free(sockVal)
            fatalError("ghostty_surface_new returned null")
        }
        self.surface = newSurface

        // userdata is set after construction so we can pass a valid `self`.
        // libghostty does not use userdata until after callbacks fire, so setting
        // it here (before any surface interaction) is safe.
        // Note: there's no public setter in the current API; userdata is already
        // part of the config copy. Passing `self` via config at construction time
        // would require a chicken-and-egg dance. Callbacks that need to find the
        // SurfaceHandle should use `ghostty_surface_userdata`, which returns the
        // pointer we set on the config — so we set it BEFORE new() instead.
        // See TerminalManager for how we resolve actions back to handles.
        //
        // We already passed config above without userdata; if callers need to map
        // a surface back to a handle, they should look it up in TerminalManager's
        // dictionary by terminalID.

        // Free the C strings now that libghostty has copied them internally.
        envVarsPtr.deinitialize(count: 1)
        envVarsPtr.deallocate()
        free(cwdCStr)
        free(sockKey)
        free(sockVal)
    }

    deinit {
        ghostty_surface_free(surface)
    }

    func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
    }

    func setSize(width: UInt32, height: UInt32) {
        ghostty_surface_set_size(surface, width, height)
    }

    var needsConfirmQuit: Bool {
        ghostty_surface_needs_confirm_quit(surface)
    }

    func requestClose() {
        ghostty_surface_request_close(surface)
    }
}

/// `NSView` subclass used as the ghostty surface's host view.
///
/// Forwards keyboard input to libghostty via `ghostty_surface_text`, which
/// feeds bytes directly into the PTY. This is the minimum viable path:
/// `NSEvent.characters` already contains the translated text for regular
/// keys, Enter (`\r`), Backspace (`\u{7F}`), arrows, etc., so most terminal
/// interaction works without a full NSTextInputClient.
///
/// `SurfaceHandle` sets `surface` after `ghostty_surface_new` returns.
/// Mouse-down focuses the view so subsequent keystrokes route here.
final class SurfaceNSView: NSView {
    /// Weak-ish reference to the libghostty surface for input forwarding.
    /// Set by `SurfaceHandle` after construction; cleared when the handle
    /// is freed (the surface pointer is only valid while the handle owns it).
    var surface: ghostty_surface_t?

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func mouseDown(with event: NSEvent) {
        // Grab keyboard focus so subsequent keystrokes route to this view.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    /// Forward trackpad/mouse-wheel scroll to libghostty so scrollback and
    /// mouse-reporting applications (less, vim, etc.) work. Ported from
    /// Ghostty's upstream `SurfaceView_AppKit.scrollWheel`.
    ///
    /// The mods parameter is a packed int (see ghostty.h):
    ///   bit 0      = precision scroll (trackpad / Magic Mouse)
    ///   bits 1..3  = momentum phase enum (NONE..MAY_BEGIN)
    ///
    /// For precision scrolling Ghostty doubles the delta: "subjective, it
    /// 'feels' better." Replicated here.
    override func scrollWheel(with event: NSEvent) {
        guard let surface else {
            super.scrollWheel(with: event)
            return
        }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        var mods: Int32 = 0
        if precision { mods |= 1 }
        let momentum = Self.momentumPhase(event.momentumPhase)
        mods |= (Int32(momentum.rawValue) & 0x7) << 1

        ghostty_surface_mouse_scroll(surface, x, y, mods)
    }

    private static func momentumPhase(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        // NSEvent.Phase is a bitmask. Match the first matching bit in the
        // order upstream Ghostty uses.
        if phase.contains(.began)       { return GHOSTTY_MOUSE_MOMENTUM_BEGAN }
        if phase.contains(.stationary)  { return GHOSTTY_MOUSE_MOMENTUM_STATIONARY }
        if phase.contains(.changed)     { return GHOSTTY_MOUSE_MOMENTUM_CHANGED }
        if phase.contains(.ended)       { return GHOSTTY_MOUSE_MOMENTUM_ENDED }
        if phase.contains(.cancelled)   { return GHOSTTY_MOUSE_MOMENTUM_CANCELLED }
        if phase.contains(.mayBegin)    { return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN }
        return GHOSTTY_MOUSE_MOMENTUM_NONE
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }

        // Cmd-modified keys go up the responder chain so AppKit can dispatch
        // them to menu items (Cmd+D split, Cmd+W close pane, etc.) or leave
        // them unhandled. Option is NOT filtered — `Option+o → ø` etc.
        // produce composed characters the user wants in the terminal.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            super.keyDown(with: event)
            return
        }

        sendKeyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        guard surface != nil else {
            super.keyUp(with: event)
            return
        }
        sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
    }

    /// Build a `ghostty_input_key_s` from an NSEvent and dispatch it.
    ///
    /// Text-field rules (ported from Ghostty's upstream macOS frontend —
    /// `NSEvent.ghosttyCharacters` + `SurfaceView_AppKit.keyAction`):
    ///
    /// - If `event.characters` is a single control byte (< 0x20), pass
    ///   `text = NULL`. libghostty's key encoder handles control-char
    ///   emission based on keycode+mods (e.g. Ctrl+Enter vs Enter).
    /// - If `event.characters` starts with a macOS function-key PUA char
    ///   (0xF700..=0xF8FF — arrow keys, F-keys, Home/End, etc.), pass
    ///   `text = NULL`. Those chars mean nothing to a PTY; libghostty
    ///   emits the right CSI sequence from the keycode.
    /// - Otherwise (regular typed characters), pass the UTF-8 bytes.
    ///
    /// `keycode` is the raw macOS virtual keycode. libghostty's Zig code
    /// maps it to its internal key representation; don't translate here.
    ///
    /// `consumed_mods` heuristic: control and command never contribute
    /// to text translation; everything else (shift, option, capsLock) did.
    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }

        let flags = event.modifierFlags
        let mods = Self.ghosttyMods(from: flags)
        let consumedMods = Self.ghosttyMods(
            from: flags.subtracting([.control, .command])
        )

        // Compute unshifted_codepoint — first scalar of the characters
        // with NO modifiers applied. Ghostty uses byApplyingModifiers: []
        // rather than charactersIgnoringModifiers because the latter
        // changes behavior under ctrl and we don't want that.
        var unshiftedCodepoint: UInt32 = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let first = chars.unicodeScalars.first {
                unshiftedCodepoint = first.value
            }
        }

        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.mods = mods
        keyEvent.consumed_mods = consumedMods
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.unshifted_codepoint = unshiftedCodepoint
        keyEvent.composing = false

        let textForPTY = Self.ghosttyTextField(for: event)
        if let text = textForPTY, !text.isEmpty {
            _ = text.withCString { cstr in
                keyEvent.text = cstr
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    /// Compute the `text` field for `ghostty_input_key_s` following
    /// Ghostty's upstream `ghosttyCharacters` rules — returns nil for
    /// events that should be encoded from keycode alone (control chars,
    /// arrow/function PUA range).
    private static func ghosttyTextField(for event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let v = scalar.value
            // Control characters: let libghostty encode.
            if v < 0x20 { return nil }
            // macOS private-use range for function keys (arrows, F1-F12,
            // Home/End/PageUp/PageDown, etc.). These chars mean nothing
            // to a shell; libghostty emits the right CSI sequence.
            if v >= 0xF700 && v <= 0xF8FF { return nil }
        }
        return chars
    }

    /// Translate an NSEvent modifier mask into libghostty's mod bitfield.
    private static func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var raw: UInt32 = 0
        if flags.contains(.shift)   { raw |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option)  { raw |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(raw)
    }

    override func becomeFirstResponder() -> Bool {
        guard let surface else { return super.becomeFirstResponder() }
        ghostty_surface_set_focus(surface, true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return super.resignFirstResponder()
    }
}
