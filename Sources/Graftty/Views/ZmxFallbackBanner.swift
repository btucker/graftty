import AppKit

/// One-time non-blocking alert presented at app launch when the bundled
/// zmx binary is missing or unloadable. The user gets a "your terminals
/// won't survive quit" warning so the missing survival behavior doesn't
/// look like a silent regression.
///
/// State is process-local — re-launching the app re-presents the alert
/// if the binary is still missing.
enum ZmxFallbackBanner {

    private static var hasShown = false

    /// Present the banner if it hasn't been shown yet this process.
    /// Safe to call from any thread; hops to main if needed.
    @MainActor
    static func presentIfNeeded() {
        guard !hasShown else { return }
        hasShown = true

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "zmx unavailable"
        alert.informativeText = """
            Graftty couldn't load its bundled session-persistence helper. \
            Terminals will work, but they won't survive Graftty quitting.

            This usually means the app bundle was modified or wasn't \
            built with `scripts/bundle.sh`. Re-running the bundle script \
            normally restores the helper.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
