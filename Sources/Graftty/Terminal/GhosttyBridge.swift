import AppKit
import Foundation
import GhosttyKit
import GrafttyCommandUI
import GrafttyProtocol
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

    /// Read a floating-point value from the config by key (e.g.
    /// "unfocused-split-opacity"). Returns nil if the key is unknown.
    func double(forKey key: String) -> Double? {
        var value = Double.zero
        let ok = key.withCString { keyPtr -> Bool in
            ghostty_config_get(config, &value, keyPtr, UInt(strlen(keyPtr)))
        }
        return ok ? value : nil
    }
}

// MARK: - GhosttyTheme

/// Snapshot of the ghostty-config-driven theme colors we apply to Graftty's
/// app chrome (sidebar, title bar, breadcrumb) so the whole window visually
/// matches the terminal's appearance.
///
/// Wraps the cross-platform `GhosttyThemeColors` (in GrafttyProtocol) with
/// Mac-specific accessors (NSColor, NSAppearance, unfocused-split dimming).
/// Mobile parses the same `GhosttyThemeColors` from the resolved config text.
struct GhosttyTheme: Equatable {
    /// Convenience alias so existing call sites (`GhosttyTheme.RGB`) keep compiling.
    typealias RGB = GhosttyThemeColors.RGB

    let core: GhosttyThemeColors
    var unfocusedSplitFillRGB: RGB { core.unfocusedSplitFillRGB }
    var unfocusedSplitOpacity: Double { core.unfocusedSplitOpacity }

    var backgroundRGB: RGB { core.backgroundRGB }
    var foregroundRGB: RGB { core.foregroundRGB }

    var background: Color { core.background }
    var foreground: Color { core.foreground }
    var sidebarBackground: Color { core.sidebarBackground }
    var isDark: Bool { core.isDark }

    // Sidebar text-color accessors live on the shared core type so the iPad
    // sidebar can read them too; forward here for natural call-site reads.
    func sidebarPrimaryText(isActive: Bool) -> Color {
        core.sidebarPrimaryText(isActive: isActive)
    }
    var sidebarStaleText: Color { core.sidebarStaleText }
    var sidebarSecondaryText: Color { core.sidebarSecondaryText }
    var sidebarDimIcon: Color { core.sidebarDimIcon }
    var sidebarChevron: Color { core.sidebarChevron }
    func paneArrow(isFocusedPane: Bool, isActiveWorktree: Bool) -> Color {
        core.paneArrow(isFocusedPane: isFocusedPane, isActiveWorktree: isActiveWorktree)
    }
    func paneTitle(isFocusedPane: Bool, isActiveWorktree: Bool, hasTitle: Bool) -> Color {
        core.paneTitle(
            isFocusedPane: isFocusedPane,
            isActiveWorktree: isActiveWorktree,
            hasTitle: hasTitle
        )
    }

    var unfocusedSplitFill: Color { core.unfocusedSplitFill }

    /// NSColor version of the background, used to tint the NSWindow so the
    /// title-bar area doesn't render as system white behind `.hiddenTitleBar`.
    var backgroundNSColor: NSColor {
        NSColor(
            srgbRed: core.backgroundRGB.r,
            green: core.backgroundRGB.g,
            blue: core.backgroundRGB.b,
            alpha: 1
        )
    }

    /// Ghostty-style unfocused split dimming. Ghostty's config value is the
    /// resulting content opacity, so the overlay alpha is the inverse.
    func paneFocusDimmingStyle(isUnfocused: Bool) -> PaneFocusDimmingStyle {
        return PaneFocusDimmingStyle(
            isUnfocused: isUnfocused,
            contentOpacity: unfocusedSplitOpacity
        )
    }

    /// NSAppearance matching the theme's light/dark-ness. Applied to the
    /// host NSWindow so system-rendered chrome (traffic lights, sidebar
    /// toggle icon, context menus, alert dialogs) picks the right
    /// contrast.
    var nsAppearance: NSAppearance? {
        NSAppearance(named: core.isDark ? .darkAqua : .aqua)
    }

    /// Fallback theme used when ghostty config is unavailable or doesn't
    /// specify background/foreground. Matches macOS dark-mode defaults so
    /// things don't look broken.
    static let fallback = GhosttyTheme(
        core: .fallback
    )

    /// Read theme colors from a `GhosttyConfig`. Missing keys fall back to
    /// `.fallback` component-wise.
    init(config: GhosttyConfig) {
        let backgroundRGB = config.color(forKey: "background").map(Self.toRGB)
            ?? GhosttyThemeColors.fallback.backgroundRGB
        let foregroundRGB = config.color(forKey: "foreground").map(Self.toRGB)
            ?? GhosttyThemeColors.fallback.foregroundRGB
        let unfocusedSplitFillRGB = config.color(forKey: "unfocused-split-fill").map(Self.toRGB)
            ?? backgroundRGB
        let unfocusedSplitOpacity = config.double(forKey: "unfocused-split-opacity")
            ?? Self.fallback.unfocusedSplitOpacity

        self.init(
            core: GhosttyThemeColors(
                backgroundRGB: backgroundRGB,
                foregroundRGB: foregroundRGB,
                unfocusedSplitFillRGB: unfocusedSplitFillRGB,
                unfocusedSplitOpacity: unfocusedSplitOpacity
            )
        )
    }

    /// Designated initializer. The cross-platform core carries Ghostty's
    /// split-focus appearance so Mac and iPad render the same treatment.
    init(core: GhosttyThemeColors) {
        self.core = core
    }

    /// Convenience initializer preserving the old `(backgroundRGB:foregroundRGB:…)` call shape
    /// so existing tests and internal callers compile without changes.
    init(
        backgroundRGB: RGB,
        foregroundRGB: RGB,
        unfocusedSplitFillRGB: RGB? = nil,
        unfocusedSplitOpacity: Double = 0.7
    ) {
        self.init(
            core: GhosttyThemeColors(
                backgroundRGB: backgroundRGB,
                foregroundRGB: foregroundRGB,
                unfocusedSplitFillRGB: unfocusedSplitFillRGB,
                unfocusedSplitOpacity: unfocusedSplitOpacity
            )
        )
    }

    private static func toRGB(_ c: ghostty_config_color_s) -> RGB {
        RGB(
            r: Double(c.r) / 255.0,
            g: Double(c.g) / 255.0,
            b: Double(c.b) / 255.0
        )
    }

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
                // OWN-2.3: a paste into a follower/ownerless pane reclaims
                // display ownership before the clipboard text is delivered.
                handle.reclaimDisplayControlForPasteIfNeeded()
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
            // the actual destruction through `onSurfaceClosed`.
            guard let userdata else { return }
            let box = Unmanaged<SurfaceUserdataBox>.fromOpaque(userdata).takeUnretainedValue()
            let terminalID = box.terminalID
            let manager = box.terminalManager
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    manager?.onSurfaceClosed?(terminalID)
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
