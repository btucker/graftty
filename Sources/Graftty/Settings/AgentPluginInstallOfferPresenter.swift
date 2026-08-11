import AppKit
import GrafttyKit

enum AgentPluginInstallOfferPresenter {
    @MainActor
    static func presentWhenWindowIsReady(
        defaults: UserDefaults = .standard
    ) {
        guard AgentPluginInstallOfferPolicy.shouldOffer(in: defaults) else { return }
        if let window = NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
            presentIfNeeded(on: window, defaults: defaults)
            return
        }
        // Window restoration can take arbitrarily longer than a fixed launch
        // grace period. Keep one lightweight pending retry until a window is
        // available or the revision is acknowledged/installed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            presentWhenWindowIsReady(defaults: defaults)
        }
    }

    @MainActor
    static func presentIfNeeded(
        on window: NSWindow,
        defaults: UserDefaults = .standard,
        installer suppliedInstaller: AgentPluginInstaller? = nil
    ) {
        guard AgentPluginInstallOfferPolicy.shouldOffer(in: defaults) else { return }
        let installer = suppliedInstaller ?? AgentPluginInstaller(
            grafttyCLIPath: GrafttyApp.agentHookCLIPath()
        )
        let nativeMessagingWasEnabled = defaults.bool(
            forKey: SettingsKeys.nativeAgentMessagingEnabled
        )

        let plan: AgentPluginSetupPlan
        do {
            plan = try installer.prepare()
        } catch {
            SheetAlert.present(
                .init(
                    messageText: "Could Not Prepare Provider Plugins",
                    informativeText: "Graftty could not prepare the Codex and Claude plugins: \(error). Try again from Agent Teams Settings.",
                    style: .warning,
                    primaryButton: "OK"
                ),
                on: window
            )
            return
        }

        SheetAlert.present(
            .init(
                messageText: nativeMessagingWasEnabled
                    ? "Install Codex and Claude Plugins?"
                    : "Install Plugins and Enable Native Messaging?",
                informativeText: "Graftty can run the provider-native commands that install the shared team skill and lifecycle hooks. Native messaging is enabled only after every command succeeds, preventing the plugins and legacy wrappers from registering duplicate hooks. You can also do this later from Agent Teams Settings.",
                style: .informational,
                primaryButton: nativeMessagingWasEnabled
                    ? "Install Both Plugins"
                    : "Install and Enable",
                secondaryButton: "Not Now"
            ),
            on: window
        ) { response in
            AgentPluginInstallOfferPolicy.recordAcknowledged(in: defaults)
            guard response == .primary else { return }

            Task { @MainActor in
                let report = await installer.install(plan)
                _ = AgentPluginIntegrationActivation.apply(
                    successfulInstallation: report.succeeded,
                    defaults: defaults,
                    refreshHookAssets: { GrafttyApp.installAgentHookAssets() }
                )
                let details = report.succeeded
                    ? report.summary + (nativeMessagingWasEnabled
                        ? ""
                        : " Native messaging is now enabled.")
                    : report.summary + " Review and retry the displayed commands in Agent Teams Settings."
                SheetAlert.present(
                    .init(
                        messageText: report.succeeded
                            ? "Provider Plugins Installed"
                            : "Provider Plugin Installation Incomplete",
                        informativeText: details,
                        style: report.succeeded ? .informational : .warning,
                        primaryButton: "OK"
                    ),
                    on: window
                )
            }
        }
    }
}
