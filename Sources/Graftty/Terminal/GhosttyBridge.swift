import AppKit
import Foundation
import GhosttyKit
import SwiftUI

// MARK: - GhosttyConfig

/// Swift wrapper around `ghostty_config_t`.
///
/// Lifecycle: `ghostty_config_new` -> load defaults -> finalize -> hand to `GhosttyApp`.
/// `ghostty_app_new` takes ownership of the config on success, so this wrapper only frees
/// the config if ownership was never transferred.
final class GhosttyConfig {
    /// Underlying C handle (`ghostty_config_t` is `typedef void*`).
    let config: ghostty_config_t

    /// Set to `true` once ownership is transferred to a `ghostty_app_t`.
    /// Callers beyond `GhosttyBridge.swift`: `TerminalManager.reloadGhosttyConfig`
    /// sets this after `ghostty_app_update_config` takes ownership
    /// of a freshly-constructed config (TERM-9.1).
    internal var ownershipTransferred: Bool = false

    init() {
        config = ghostty_config_new()

        // `load_default_files` only walks the XDG paths
        // (`$XDG_CONFIG_HOME/ghostty/config`, `~/.config/ghostty/config`).
        // Most macOS Ghostty users keep their config in the Ghostty.app
        // sandbox location (`~/Library/Application Support/com.mitchellh.ghostty/config`),
        // and we want Graftty to honor that without asking the user to
        // duplicate or symlink the file. So we load the default files first,
        // then layer Ghostty-macOS's config on top — later loads override
        // earlier ones.
        ghostty_config_load_default_files(config)
        Self.loadGhosttyMacOSConfigIfPresent(into: config)
        // Resolve any `config-file = …` include directives that appeared in
        // the files we just loaded. No-op if there aren't any.
        ghostty_config_load_recursive_files(config)

        ghostty_config_finalize(config)
    }

    private static func loadGhosttyMacOSConfigIfPresent(into config: ghostty_config_t) {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("com.mitchellh.ghostty")
            .appendingPathComponent("config")
        guard let path = url?.path, FileManager.default.fileExists(atPath: path) else { return }
        path.withCString { ghostty_config_load_file(config, $0) }
    }

    deinit {
        if !ownershipTransferred {
            ghostty_config_free(config)
        }
    }

    /// Read a `ghostty_config_color_s` value from the config by key (e.g.
    /// "background", "foreground", "cursor-color"). Returns nil if the key
    /// is unknown or the value isn't set.
    func color(forKey key: String) -> ghostty_config_color_s? {
        var color = ghostty_config_color_s()
        let ok = key.withCString { keyPtr -> Bool in
            ghostty_config_get(config, &color, keyPtr, UInt(strlen(keyPtr)))
        }
        return ok ? color : nil
    }
}

// MARK: - GhosttyTheme

/// Snapshot of the ghostty-config-driven theme colors we apply to Graftty's
/// app chrome (sidebar, title bar, breadcrumb) so the whole window visually
/// matches the terminal's appearance.
///
/// Stores the raw RGB triples for background and foreground so we can derive
/// shifted variants (a slightly-lighter-on-dark / slightly-darker-on-light
/// sidebar shade) and expose the raw values as NSColor for NSWindow tinting.
struct GhosttyTheme: Equatable {
    /// RGB triple in 0..1 linear SwiftUI-compatible space.
    struct RGB: Equatable {
        let r: Double
        let g: Double
        let b: Double
    }

    let backgroundRGB: RGB
    let foregroundRGB: RGB

    var background: Color { color(backgroundRGB) }
    var foreground: Color { color(foregroundRGB) }

    /// NSColor version of the background, used to tint the NSWindow so the
    /// title-bar area doesn't render as system white behind `.hiddenTitleBar`.
    var backgroundNSColor: NSColor {
        NSColor(
            srgbRed: backgroundRGB.r,
            green: backgroundRGB.g,
            blue: backgroundRGB.b,
            alpha: 1
        )
    }

    /// Slightly shifted background for the sidebar, so there's visible
    /// separation between chrome and terminal content without introducing
    /// a color from outside the theme. On dark themes we lighten; on light
    /// themes we darken.
    var sidebarBackground: Color {
        let bg = backgroundRGB
        let shift = isDark ? 0.06 : -0.06
        return color(RGB(
            r: clamp01(bg.r + shift),
            g: clamp01(bg.g + shift),
            b: clamp01(bg.b + shift)
        ))
    }

    /// True when the ghostty background is closer to black than white.
    /// Drives NSWindow appearance so the traffic lights and sidebar toggle
    /// render with the right contrast, and is the single source of truth
    /// for all light-vs-dark decisions in Graftty chrome.
    var isDark: Bool {
        let bg = backgroundRGB
        let luminance = 0.299 * bg.r + 0.587 * bg.g + 0.114 * bg.b
        return luminance < 0.5
    }

    /// NSAppearance matching the theme's light/dark-ness. Applied to the
    /// host NSWindow so system-rendered chrome (traffic lights, sidebar
    /// toggle icon, context menus, alert dialogs) picks the right
    /// contrast.
    var nsAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    /// Fallback theme used when ghostty config is unavailable or doesn't
    /// specify background/foreground. Matches macOS dark-mode defaults so
    /// things don't look broken.
    static let fallback = GhosttyTheme(
        backgroundRGB: RGB(r: 0.05, g: 0.05, b: 0.1),
        foregroundRGB: RGB(r: 0.87, g: 0.87, b: 0.87)
    )

    /// Read theme colors from a `GhosttyConfig`. Missing keys fall back to
    /// `.fallback` component-wise.
    init(config: GhosttyConfig) {
        self.backgroundRGB = config.color(forKey: "background").map(Self.toRGB)
            ?? Self.fallback.backgroundRGB
        self.foregroundRGB = config.color(forKey: "foreground").map(Self.toRGB)
            ?? Self.fallback.foregroundRGB
    }

    init(backgroundRGB: RGB, foregroundRGB: RGB) {
        self.backgroundRGB = backgroundRGB
        self.foregroundRGB = foregroundRGB
    }

    private static func toRGB(_ c: ghostty_config_color_s) -> RGB {
        RGB(r: Double(c.r) / 255.0, g: Double(c.g) / 255.0, b: Double(c.b) / 255.0)
    }

    private func color(_ rgb: RGB) -> Color {
        Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}

private func clamp01(_ x: Double) -> Double {
    min(1.0, max(0.0, x))
}

// MARK: - GhosttyApp

/// Swift wrapper around `ghostty_app_t`.
///
/// # Threading
/// libghostty may invoke the wakeup callback from any thread. We hop to the main queue and
/// post `Notification.Name.ghosttyWakeup` so observers can safely call `tick()` on the main
/// thread. The action callback may also fire from any thread; the supplied `actionHandler`
/// must be thread-safe (or dispatch to the main queue before touching UI state).
final class GhosttyApp {
    /// Underlying `ghostty_app_t` handle (opaque pointer).
    let app: ghostty_app_t

    /// Theme snapshot read from the ghostty config at init time. Used by the
    /// app chrome (sidebar, breadcrumb, title area) so the whole window
    /// matches the terminal's visual theme.
    let theme: GhosttyTheme

    /// Retained so the config outlives any internal references. `GhosttyApp` owns the
    /// config from the C side's perspective once `ghostty_app_new` succeeds.
    private let config: GhosttyConfig

    /// Backing storage for the runtime config struct. libghostty copies this at
    /// `ghostty_app_new` time, but we keep it alive defensively for the app's lifetime.
    private var runtimeConfig: ghostty_runtime_config_s

    /// Raw pointer to the retained `ActionHandlerBox`; released in `deinit`.
    private let handlerBoxPointer: UnsafeMutableRawPointer

    /// Creates a new ghostty app.
    /// - Parameters:
    ///   - config: A finalized `GhosttyConfig`. Ownership is transferred to the app on success.
    ///   - actionHandler: Invoked when libghostty emits an action. May fire from any thread.
    ///     The return value is forwarded as the C callback's return value.
    init(config: GhosttyConfig, actionHandler: @escaping (ghostty_target_s, ghostty_action_s) -> Bool) {
        // Read theme BEFORE ghostty_app_new transfers config ownership.
        self.theme = GhosttyTheme(config: config)

        self.config = config

        let handlerBox = ActionHandlerBox(handler: actionHandler)
        let handlerPtr = Unmanaged.passRetained(handlerBox).toOpaque()
        self.handlerBoxPointer = handlerPtr

        // Zero-initialize then fill. All callback slots must be non-null: libghostty will
        // call them unconditionally. We stub clipboard + close_surface with safe no-ops that
        // higher layers can later replace by building a richer runtime.
        var rtConfig = ghostty_runtime_config_s()
        rtConfig.userdata = handlerPtr
        rtConfig.supports_selection_clipboard = false

        rtConfig.wakeup_cb = { _ in
            if Thread.isMainThread {
                NotificationCenter.default.post(name: .ghosttyWakeup, object: nil)
            } else {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .ghosttyWakeup, object: nil)
                }
            }
        }

        rtConfig.action_cb = { appHandle, target, action -> Bool in
            // Recover the Swift handler. libghostty's action_cb signature has no `userdata`
            // parameter, so we retrieve it from the app via `ghostty_app_userdata`, which
            // returns the `userdata` field we set on the runtime config.
            guard let appHandle, let userdata = ghostty_app_userdata(appHandle) else {
                return false
            }
            let box = Unmanaged<ActionHandlerBox>.fromOpaque(userdata).takeUnretainedValue()
            return box.handler(target, action)
        }

        rtConfig.read_clipboard_cb = { userdata, clipboardEnum, state -> Bool in
            // Surface requested a clipboard read (e.g., Cmd+V). The first
            // `userdata` here is the *surface's* userdata box — the same
            // one we set on `ghostty_surface_config_s.userdata` in
            // `SurfaceHandle.init`. That lets us locate the originating
            // surface so we can call `ghostty_surface_complete_clipboard_request`
            // to deliver the clipboard text back to it.
            guard let userdata else { return false }
            let box = Unmanaged<SurfaceUserdataBox>.fromOpaque(userdata).takeUnretainedValue()
            let terminalID = box.terminalID
            let manager = box.terminalManager
            // NSPasteboard must be touched on the main thread; we dispatch
            // there even if we're already on main (cheap, keeps the logic
            // uniform). Returning `true` tells libghostty we'll complete
            // the request asynchronously via `complete_clipboard_request`.
            DispatchQueue.main.async {
                guard let handle = manager?.handle(for: terminalID) else { return }
                let pasteboard = pasteboardForClipboard(clipboardEnum)
                let text = pasteboard.string(forType: .string) ?? ""
                text.withCString { cstr in
                    ghostty_surface_complete_clipboard_request(handle.surface, cstr, state, false)
                }
            }
            return true
        }
        rtConfig.confirm_read_clipboard_cb = { _, _, _, _ in
            // OSC 52 clipboard-read confirmation. Security-sensitive — no-op
            // until we build a proper confirmation prompt. Terminals that
            // request OSC 52 reads will silently fail, which is the safe
            // default.
        }
        rtConfig.write_clipboard_cb = { _, clipboardEnum, content, count, _ in
            // libghostty hands us an array of `{mime, data}` pairs; we
            // currently honor the plain-text entry (UTF-8 in `data`) and
            // ignore other mime types. `count` is the array length.
            guard count > 0, let content else { return }
            let pasteboard = pasteboardForClipboard(clipboardEnum)
            var plainText: String?
            for i in 0..<Int(count) {
                let entry = content[i]
                // `entry.data` is a NUL-terminated C string even for binary
                // clipboard formats libghostty exposes today; decoding as
                // UTF-8 covers every real-world copy path.
                if let dataPtr = entry.data {
                    plainText = String(cString: dataPtr)
                    break
                }
            }
            guard let text = plainText else { return }
            DispatchQueue.main.async {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
        rtConfig.close_surface_cb = { userdata, _ in
            // libghostty passes the *surface's* userdata here (set via
            // `ghostty_surface_config_s.userdata`). That's our
            // `SurfaceUserdataBox` — recover it, read the terminalID, and
            // ask the TerminalManager to tear down the pane.
            //
            // The callback may fire from any thread and is invoked while
            // libghostty is unwinding the surface — we must NOT call
            // `ghostty_surface_free` synchronously. Hop to main and defer
            // the actual destruction through `onCloseRequest`.
            guard let userdata else { return }
            let box = Unmanaged<SurfaceUserdataBox>.fromOpaque(userdata).takeUnretainedValue()
            let terminalID = box.terminalID
            let manager = box.terminalManager
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    manager?.onCloseRequest?(terminalID)
                }
            }
        }

        self.runtimeConfig = rtConfig

        guard let newApp = ghostty_app_new(&self.runtimeConfig, config.config) else {
            Unmanaged<ActionHandlerBox>.fromOpaque(handlerPtr).release()
            fatalError("ghostty_app_new returned null")
        }
        self.app = newApp
        config.ownershipTransferred = true
    }

    deinit {
        ghostty_app_free(app)
        // Release the handler box after the app is freed so libghostty can't invoke callbacks
        // against a released box.
        Unmanaged<ActionHandlerBox>.fromOpaque(handlerBoxPointer).release()
    }

    /// Advance the ghostty event loop. Call on the main thread in response to a
    /// `ghosttyWakeup` notification.
    func tick() {
        ghostty_app_tick(app)
    }

}

/// Pick the NSPasteboard that matches the libghostty clipboard enum.
/// Declared at file scope so it can be called from the C-ABI runtime
/// callbacks (closures used as C function pointers can't reference
/// `Self` or capture instance state).
///
/// macOS doesn't ship a distinct selection clipboard (that's an X11
/// concept), so we fall back to the general pasteboard for both — and
/// our runtime config already advertises `supports_selection_clipboard
/// = false`, so libghostty avoids routing SELECTION requests here.
private func pasteboardForClipboard(_ clipboardEnum: ghostty_clipboard_e) -> NSPasteboard {
    NSPasteboard.general
}

// MARK: - Action trampoline

/// Box carrying a Swift closure across the C ABI via `Unmanaged`.
private final class ActionHandlerBox {
    let handler: (ghostty_target_s, ghostty_action_s) -> Bool
    init(handler: @escaping (ghostty_target_s, ghostty_action_s) -> Bool) {
        self.handler = handler
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted on the main thread whenever libghostty's wakeup callback fires. Observers
    /// should call `GhosttyApp.tick()` in response.
    static let ghosttyWakeup = Notification.Name("com.graftty.ghostty.wakeup")
}
