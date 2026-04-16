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

        // Use `ghostty_surface_key` rather than `ghostty_surface_text` so
        // libghostty handles special-key translation (Backspace, arrows,
        // Home/End, Tab, Enter, function keys). `ghostty_surface_text` is
        // for already-translated text (e.g., from NSTextInputClient's
        // insertText); raw keyDown should go through the key path so the
        // right terminal escape sequences get emitted.
        //
        // The `text` field is the user-visible characters the keystroke
        // would produce with modifiers applied (same as `event.characters`).
        // `keycode` is macOS's NSEvent.keyCode — libghostty's own key
        // translation table has mappings, and when it doesn't, the `text`
        // field carries the intended input.
        let chars = event.characters ?? ""
        chars.withCString { cstr in
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.mods = Self.ghosttyMods(from: mods)
            keyEvent.consumed_mods = ghostty_input_mods_e(GHOSTTY_MODS_NONE.rawValue)
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.text = cstr
            keyEvent.unshifted_codepoint = chars.unicodeScalars.first.map { $0.value } ?? 0
            keyEvent.composing = false
            _ = ghostty_surface_key(surface, keyEvent)
        }
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
