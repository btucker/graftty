import AppKit

enum FullDiskAccessOffer {
    private static let acknowledgedKey = "fullDiskAccessOfferAcknowledged"
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    static let explanation = "Full Disk Access lets Graftty and terminal programs you run access protected files and removable drives. Only enable it for programs you trust. This is optional; you can continue with macOS asking for access as needed."
    static let instructions = "In System Settings, enable Graftty under Privacy & Security > Full Disk Access. If it is missing, click + and select Graftty in Applications. Follow any macOS request to quit and reopen Graftty after saving your work."

    static func shouldOffer(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: acknowledgedKey)
    }

    @MainActor
    static func respond(
        openSettings: Bool,
        defaults: UserDefaults,
        open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        // Acknowledging guidance is not evidence that permission was granted.
        defaults.set(true, forKey: acknowledgedKey)
        if openSettings { open(settingsURL) }
    }

    @MainActor
    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    @MainActor
    static func presentWhenWindowIsReady(
        defaults: UserDefaults = .standard,
        completion: @escaping @MainActor () -> Void
    ) {
        guard shouldOffer(in: defaults) else {
            completion()
            return
        }
        guard let window = NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
            window.attachedSheet == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                presentWhenWindowIsReady(defaults: defaults, completion: completion)
            }
            return
        }
        SheetAlert.present(
            .init(
                messageText: "Allow Full Disk Access?",
                informativeText: explanation + "\n\n" + instructions,
                style: .informational,
                primaryButton: "Open System Settings",
                secondaryButton: "Not Now"
            ),
            on: window
        ) { response in
            respond(openSettings: response == .primary, defaults: defaults)
            completion()
        }
    }
}
