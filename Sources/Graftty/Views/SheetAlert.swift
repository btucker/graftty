import AppKit

/// @spec GIT-4.19
/// Shared presenter for delete-flow confirmation dialogs. Centralises
/// `NSAlert.beginSheetModal(for:)` so every dialog renders as a
/// window-attached sheet — matching the policy GIT-4.14 already pins
/// for the auto-triggered PR-resolved offer. `runModal()` blocks the
/// main run loop's default mode, freezing libghostty's PTY callbacks
/// for every embedded terminal pane while the dialog is on screen;
/// sheets let the run loop keep pumping so panes keep rendering. The
/// `Configuration` value type stays free of AppKit so each call site's
/// message-text and button-label rules can be unit-tested without
/// booting `NSApplication` (NSAlert.init() lazy-loads a NIB that needs
/// a running app).
enum SheetAlert {
    struct Configuration {
        var messageText: String
        var informativeText: String
        var style: NSAlert.Style
        var primaryButton: String
        var secondaryButton: String?
    }

    enum Response {
        case primary
        case secondary
    }

    /// Presents `config` as a sheet on `window`. Caller owns the
    /// host-window guard — typically `guard let host = NSApp.mainWindow
    /// else { return }` — so a no-op when no window is foregrounded
    /// matches the GIT-4.7 offer-delete behaviour. For a single-button
    /// alert (`secondaryButton == nil`), the completion fires with
    /// `.primary` on the lone "OK" click.
    @MainActor
    static func present(
        _ config: Configuration,
        on window: NSWindow,
        completion: @escaping (Response) -> Void = { _ in }
    ) {
        let alert = NSAlert()
        alert.messageText = config.messageText
        alert.informativeText = config.informativeText
        alert.alertStyle = config.style
        alert.addButton(withTitle: config.primaryButton)
        if let secondary = config.secondaryButton {
            alert.addButton(withTitle: secondary)
        }
        alert.beginSheetModal(for: window) { code in
            completion(code == .alertFirstButtonReturn ? .primary : .secondary)
        }
    }
}
