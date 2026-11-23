import AppKit
import GrafttyKit

enum FullDiskAccessPromptPolicy {
    static func shouldPrompt(
        status: FullDiskAccessStatus,
        isSuppressed: Bool
    ) -> Bool {
        status == .denied && !isSuppressed
    }

    static func isSuppressed(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: SettingsKeys.suppressFullDiskAccessPrompt)
    }

    static func recordSuppressed(in defaults: UserDefaults) {
        defaults.set(true, forKey: SettingsKeys.suppressFullDiskAccessPrompt)
    }
}

/// Checks macOS Full Disk Access once at launch off the main actor and, when
/// denied and not permanently suppressed, attaches an informational sheet to
/// the main window offering to open Privacy & Security → Full Disk Access
/// (LAYOUT-5.4).
enum FullDiskAccessPromptPresenter {
    @MainActor private static var hasCheckedThisProcess = false

    static let alertConfiguration = SheetAlert.Configuration(
        messageText: "Grant Full Disk Access?",
        informativeText: """
            Graftty runs terminals and coding agents that inherit its macOS \
            permissions. Without Full Disk Access, tools may be blocked from \
            protected folders or trigger repeated macOS permission prompts.

            Open System Settings → Privacy & Security → Full Disk Access and \
            turn on Graftty. macOS may ask to quit and reopen Graftty for the \
            change to take effect.
            """,
        style: .informational,
        primaryButton: "Open System Settings",
        secondaryButton: "Not Now",
        tertiaryButton: "Don't Ask Again",
        escapeButton: .secondary
    )

    @MainActor
    private static func handleResponse(
        _ response: SheetAlert.Response,
        defaults: UserDefaults,
        openURL: (URL) -> Void
    ) {
        switch response {
        case .primary:
            openURL(FullDiskAccess.settingsURL)
        case .secondary, .cancelled:
            break
        case .tertiary:
            FullDiskAccessPromptPolicy.recordSuppressed(in: defaults)
        }
    }

    @MainActor
    private static func defaultPresentWhenWindowReady(
        _ config: SheetAlert.Configuration
    ) async -> SheetAlert.Response? {
        guard let window = await SheetAlert.awaitReadyHostWindow() else { return nil }
        return await SheetAlert.presentAsync(config, on: window)
    }

    @MainActor
    static func presentWhenWindowIsReady(
        defaults: UserDefaults = .standard,
        checkStatus: @escaping @Sendable () -> FullDiskAccessStatus = {
            FullDiskAccess.checkStatus()
        },
        presentSheet: @escaping @MainActor (SheetAlert.Configuration) async -> SheetAlert.Response? = defaultPresentWhenWindowReady,
        openURL: @escaping @MainActor (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) async {
        guard !hasCheckedThisProcess else { return }
        guard !FullDiskAccessPromptPolicy.isSuppressed(in: defaults) else { return }
        hasCheckedThisProcess = true

        let status = await OffMainIO.run(checkStatus)
        guard FullDiskAccessPromptPolicy.shouldPrompt(
            status: status,
            isSuppressed: FullDiskAccessPromptPolicy.isSuppressed(in: defaults)
        ) else {
            return
        }

        guard let response = await presentSheet(alertConfiguration) else { return }
        handleResponse(response, defaults: defaults, openURL: openURL)
    }

    @MainActor
    static func resetForTests() {
        hasCheckedThisProcess = false
    }
}
