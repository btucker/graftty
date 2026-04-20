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
/// Small reference object we pass to libghostty as the surface's `userdata`.
/// Lets `close_surface_cb` (and other surface-scoped libghostty callbacks)
/// recover the Espalier-side `TerminalID` without having to scan the
/// `TerminalManager.surfaces` map.
///
/// Memory management: `SurfaceHandle` retains an `Unmanaged` reference to
/// the box via `passRetained`, hands the opaque pointer to libghostty, and
/// releases the box in `deinit` — so the box outlives the surface. The
/// `terminalManager` reference is weak to avoid a retain cycle (the manager
/// owns the handle, which owns the box).
final class SurfaceUserdataBox {
    let terminalID: TerminalID
    weak var terminalManager: TerminalManager?
    init(terminalID: TerminalID, terminalManager: TerminalManager?) {
        self.terminalID = terminalID
        self.terminalManager = terminalManager
    }
}

final class SurfaceHandle {
    let terminalID: TerminalID
    let surface: ghostty_surface_t
    let view: NSView
    let worktreePath: String

    /// Retained pointer to the userdata box; released in `deinit`. libghostty
    /// keeps a copy of the pointer in its surface struct and passes it back
    /// through callbacks that want per-surface identity.
    private let userdataPointer: UnsafeMutableRawPointer

    /// Failable because `ghostty_surface_new` can return null — e.g. under
    /// resource exhaustion or internal libghostty state the app can't
    /// recover from. Returning nil instead of trapping lets the caller
    /// surface an error (a socket `.error("...")`, a logged warning) and
    /// keep the rest of the app alive. Previously a `fatalError` here
    /// brought down Espalier mid-`espalier pane add` (`TERM-5.5`).
    init?(
        terminalID: TerminalID,
        app: ghostty_app_t,
        worktreePath: String,
        socketPath: String,
        zmxInitialInput: String? = nil,
        zmxDir: String? = nil,
        terminalManager: TerminalManager? = nil
    ) {
        self.terminalID = terminalID
        self.worktreePath = worktreePath

        let userdataBox = SurfaceUserdataBox(
            terminalID: terminalID,
            terminalManager: terminalManager
        )
        let userdataPtr = Unmanaged.passRetained(userdataBox).toOpaque()
        self.userdataPointer = userdataPtr

        let surfaceView = SurfaceNSView()
        self.view = surfaceView
        surfaceView.terminalID = terminalID
        surfaceView.terminalManager = terminalManager
        // NB: the original impl used a `defer` here to bind
        // `surfaceView.surface = self.surface` after all exit paths. That
        // was fine for a non-failable init, but failable-init's nil-return
        // path runs defer before `self.surface` is assigned — which the
        // compiler rejects. Inline the bind after the success assignment
        // (line below the `guard let newSurface`).

        // Allocate C strings up front so we can free them deterministically.
        let cwdCStr = strdup(worktreePath)
        let sockKey = strdup("ESPALIER_SOCK")
        let sockVal = strdup(socketPath)

        // Optional: when ZmxLauncher is available, these are the bytes
        // libghostty will write into the PTY as soon as the user's
        // default $SHELL starts — an `exec <zmx> attach <session>
        // <shell>\n` line that replaces the shell with `zmx attach`.
        //
        // We deliberately avoid `config.command` here: upstream Ghostty
        // auto-enables `wait-after-command = true` whenever `command` is
        // set (see `src/apprt/embedded.zig`), which would keep panes
        // open after the shell exits and show a "Press any key to close"
        // overlay. For Espalier we want the opposite — exit should
        // close the pane — so we leave `command` nil and use
        // `initial_input` instead. See `ZmxLauncher.attachInitialInput`.
        let initialInputCStr: UnsafeMutablePointer<CChar>? = zmxInitialInput.flatMap { strdup($0) }

        let zmxDirKey: UnsafeMutablePointer<CChar>? = zmxDir.flatMap { _ in strdup("ZMX_DIR") }
        let zmxDirVal: UnsafeMutablePointer<CChar>? = zmxDir.flatMap { strdup($0) }
        let envCount = zmxDir == nil ? 1 : 2

        // env_vars needs a stable pointer during ghostty_surface_new; libghostty
        // copies the contents before returning.
        let envVarsPtr = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: envCount)
        envVarsPtr.initialize(to: ghostty_env_var_s(key: sockKey, value: sockVal))
        if let zmxDirKey, let zmxDirVal {
            envVarsPtr.advanced(by: 1).initialize(
                to: ghostty_env_var_s(key: zmxDirKey, value: zmxDirVal)
            )
        }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(surfaceView).toOpaque()
        config.userdata = userdataPtr
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.working_directory = UnsafePointer(cwdCStr)
        if let initialInputCStr {
            config.initial_input = UnsafePointer(initialInputCStr)
        }
        config.env_vars = envVarsPtr
        config.env_var_count = envCount
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        guard let newSurface = ghostty_surface_new(app, &config) else {
            // Free everything we allocated, then fail gracefully. `self`
            // is not yet fully initialized, so `deinit` won't run —
            // release owned allocations explicitly before returning nil.
            // `TERM-5.5`: previous behavior was `fatalError`, which
            // crashed the entire app mid-`espalier pane add` when
            // libghostty rejected the config for any reason.
            envVarsPtr.deinitialize(count: envCount)
            envVarsPtr.deallocate()
            free(cwdCStr)
            free(sockKey)
            free(sockVal)
            if let initialInputCStr { free(initialInputCStr) }
            if let zmxDirKey { free(zmxDirKey) }
            if let zmxDirVal { free(zmxDirVal) }
            Unmanaged<SurfaceUserdataBox>.fromOpaque(userdataPtr).release()
            return nil
        }
        self.surface = newSurface
        // Bind the surface to the view now that ghostty_surface_new succeeded.
        // The view weakly references the surface via this unmanaged handle;
        // it forwards keystrokes/mouse events back into libghostty.
        surfaceView.surface = newSurface

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
        envVarsPtr.deinitialize(count: envCount)
        envVarsPtr.deallocate()
        free(cwdCStr)
        free(sockKey)
        free(sockVal)
        if let initialInputCStr { free(initialInputCStr) }
        if let zmxDirKey { free(zmxDirKey) }
        if let zmxDirVal { free(zmxDirVal) }
    }

    deinit {
        // Nil the view's surface pointer BEFORE freeing: the `NSView` can
        // still be in the window hierarchy at this moment (SwiftUI hasn't
        // yet processed the model change that removed this pane), and any
        // AppKit-driven callback that fires in the window between here and
        // the view's removal — `resignFirstResponder`, `setFrameSize`,
        // `mouseUp` for an in-progress drag — would otherwise dereference
        // freed memory and crash libghostty's os_unfair_lock. Every
        // NSView override on `SurfaceNSView` already guards on the
        // optional surface, so nil-ing it turns those callbacks into
        // safe no-ops.
        if let surfaceView = view as? SurfaceNSView {
            // Undo any lingering `NSCursor.hide()` so the destroyed pane
            // doesn't leave the mouse invisible for the rest of the app.
            surfaceView.setCursorHidden(false)
            surfaceView.surface = nil
        }
        ghostty_surface_free(surface)
        // Surface is gone, so libghostty won't fire further callbacks against
        // our userdata pointer — safe to release the box.
        Unmanaged<SurfaceUserdataBox>.fromOpaque(userdataPointer).release()
    }

    func setFocus(_ focused: Bool) {
        ghostty_surface_set_focus(surface, focused)
        // Keep AppKit's first-responder in sync with libghostty's focus
        // state: if the view is already in a window, promote it so keyDown
        // events route here. `makeFirstResponder` on a detached view is a
        // silent no-op, so callers that focus a pane before SwiftUI has
        // mounted the view are covered by `SurfaceNSView.viewDidMoveToWindow`.
        if focused,
           let surfaceView = view as? SurfaceNSView,
           let window = surfaceView.window {
            window.makeFirstResponder(surfaceView)
        }
    }

    func setSize(width: UInt32, height: UInt32) {
        ghostty_surface_set_size(surface, width, height)
    }

    var needsConfirmQuit: Bool {
        ghostty_surface_needs_confirm_quit(surface)
    }

    /// Programmatically inject text into the surface's PTY, as if the user
    /// had typed it. Routed through libghostty's `ghostty_surface_text`,
    /// which writes raw UTF-8 bytes directly into the PTY. Passing
    /// `"claude\r"` behaves identically to typing "claude" and pressing
    /// Return — it enters shell history, supports ↑ recall, and its
    /// child process lives and dies inside the surrounding shell.
    /// (Regular key events flow through `ghostty_surface_key` via
    /// `sendKeyEvent` instead; `ghostty_surface_text` is the text-input
    /// sibling used for non-key-event writes.)
    func typeText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let ptr = base.assumingMemoryBound(to: CChar.self)
            ghostty_surface_text(surface, ptr, UInt(raw.count))
        }
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

    /// The terminal ID this view represents, and a weak reference to the
    /// terminal manager. Both are set by `SurfaceHandle` during init so
    /// the context menu and other UI paths can request actions (splits,
    /// close, etc.) that need model-layer cooperation.
    var terminalID: TerminalID?
    weak var terminalManager: TerminalManager?

    /// Mirror of libghostty's `toggle_readonly` state. Maintained from the
    /// context-menu action so the checkmark reflects the current mode.
    /// libghostty owns authoritative state; this is our UI shadow.
    var isReadonly: Bool = false

    /// Cursor to display when the mouse is over this surface. libghostty
    /// drives this via `GHOSTTY_ACTION_MOUSE_SHAPE` (e.g., pointer when
    /// over a link, text beam over normal cells). Defaults to the text
    /// I-beam — standard for terminal-cell hit areas.
    var desiredCursor: NSCursor = .iBeam

    /// Counter matching our outstanding `NSCursor.hide()` calls; needed
    /// because `hide()`/`unhide()` are *counted*, and libghostty may fire
    /// repeated HIDDEN actions (e.g., while the user types). We only
    /// forward the first → hide, and on VISIBLE we unhide once.
    private var cursorHidden: Bool = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    /// When this surface view joins a window (app launch, worktree switch,
    /// split created), grab keyboard focus so the user can start typing
    /// immediately — unless another terminal view already has focus, in
    /// which case we respect that. Without this, the window's first
    /// responder stays the content view / sidebar button and keystrokes
    /// never reach libghostty until the user clicks into the terminal.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, surface != nil else { return }
        if !(window.firstResponder is SurfaceNSView) {
            window.makeFirstResponder(self)
        }
    }

    /// Maintain a single full-bounds tracking area so AppKit routes
    /// `cursorUpdate(_:)` and mouse-move events to us. Rebuilt on each
    /// layout change so it tracks the current frame.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseMoved,
            .inVisibleRect,
            .cursorUpdate,
        ]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil))
    }

    /// AppKit calls this whenever the cursor crosses the tracking area or
    /// needs refreshing. Using `set()` on the desired cursor is the
    /// idiomatic way to apply a per-view cursor without coordinating with
    /// `resetCursorRects`.
    override func cursorUpdate(with event: NSEvent) {
        desiredCursor.set()
    }

    /// Called by `TerminalManager` when libghostty requests a new cursor
    /// shape. Updates our stored cursor and — if the mouse is currently
    /// over this view — applies it immediately so the user doesn't have
    /// to jiggle to see the change.
    func applyCursor(_ cursor: NSCursor) {
        desiredCursor = cursor
        if let window, window.firstResponder is SurfaceNSView,
           let mouseLoc = window.mouseLocationOutsideOfEventStream as NSPoint?,
           self.frame.contains(convert(mouseLoc, from: nil)) {
            cursor.set()
        }
    }

    /// Called by `TerminalManager` for `GHOSTTY_ACTION_MOUSE_VISIBILITY`.
    /// `NSCursor.hide()` / `unhide()` are counted, so we guard against
    /// mismatched pairs that would either leave the cursor permanently
    /// hidden or trigger an unhide-past-zero.
    func setCursorHidden(_ hidden: Bool) {
        if hidden, !cursorHidden {
            NSCursor.hide()
            cursorHidden = true
        } else if !hidden, cursorHidden {
            NSCursor.unhide()
            cursorHidden = false
        }
    }

    /// Forward frame changes to libghostty so the terminal's cell grid and
    /// render target track the view's on-screen size. Fires for both
    /// user-driven resizes (divider drag) and programmatic ones (SwiftUI
    /// rerendering after a split is added/removed).
    ///
    /// `convertToBacking(_:)` turns points → backing-store pixels, which is
    /// what `ghostty_surface_set_size` expects; libghostty uses the
    /// `scale_factor` we passed at surface-create time for HiDPI metrics.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let surface else { return }
        let pixels = convertToBacking(newSize)
        // Naive `UInt32(max(1, Int(pixels.width)))` traps on NaN /
        // ±Infinity — observed transiently from SwiftUI GeometryReader
        // during certain rebinding flows, and a single trap on the
        // main thread takes out every open pane.
        ghostty_surface_set_size(
            surface,
            SurfacePixelDimension.clamp(pixels.width),
            SurfacePixelDimension.clamp(pixels.height)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func mouseDown(with event: NSEvent) {
        // Grab keyboard focus so subsequent keystrokes route to this view.
        window?.makeFirstResponder(self)
        guard let surface else { return }
        // Tell libghostty where the cursor is (so selection anchor is
        // correct) before the press event — same order as Ghostty upstream.
        sendMousePos(event, to: surface)
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_LEFT,
            Self.ghosttyMods(from: event.modifierFlags)
        )
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else {
            super.mouseUp(with: event)
            return
        }
        sendMousePos(event, to: surface)
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_LEFT,
            Self.ghosttyMods(from: event.modifierFlags)
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event, to: surface)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        sendMousePos(event, to: surface)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_PRESS,
            GHOSTTY_MOUSE_MIDDLE,
            Self.ghosttyMods(from: event.modifierFlags)
        )
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(
            surface,
            GHOSTTY_MOUSE_RELEASE,
            GHOSTTY_MOUSE_MIDDLE,
            Self.ghosttyMods(from: event.modifierFlags)
        )
    }

    /// Forward the event's cursor position to libghostty.
    /// Converts AppKit's bottom-left-origin coords to ghostty's
    /// top-left-origin coords with `frame.height - pos.y`.
    private func sendMousePos(_ event: NSEvent, to surface: ghostty_surface_t) {
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface,
            pos.x,
            frame.height - pos.y,
            Self.ghosttyMods(from: event.modifierFlags)
        )
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
        guard surface != nil else {
            super.keyDown(with: event)
            return
        }
        // Forward ALL keys to libghostty — including Cmd-modified ones —
        // so its default keybinds (Cmd+C → copy, Cmd+V → paste, Cmd+A →
        // select all, etc.) fire. App-level menu shortcuts (Cmd+D split,
        // Cmd+W close pane, Cmd+O add repo, …) don't reach this method:
        // AppKit's menu-keyEquivalent interception runs before keyDown
        // dispatch, so the menu fires first and libghostty never sees
        // them. If libghostty returns "not handled", bubble up the
        // responder chain so unhandled shortcuts still have a chance.
        let handled = sendKeyEvent(
            event,
            action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        )
        if !handled {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard surface != nil else {
            super.keyUp(with: event)
            return
        }
        _ = sendKeyEvent(event, action: GHOSTTY_ACTION_RELEASE)
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
    @discardableResult
    private func sendKeyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }

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
            return text.withCString { cstr in
                keyEvent.text = cstr
                return ghostty_surface_key(surface, keyEvent)
            }
        } else {
            keyEvent.text = nil
            return ghostty_surface_key(surface, keyEvent)
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
    static func ghosttyMods(from flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
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
