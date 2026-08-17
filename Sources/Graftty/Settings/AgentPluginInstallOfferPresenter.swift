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

        Task { @MainActor in
            // prepare() rewrites the app-owned marketplace snapshots on disk
            // (recursive copy plus hooks.json rewrite). Run it off the main
            // actor so launch-time file I/O cannot wedge control-socket
            // handling or UI events (ATTN-2.19 / OffMainIO).
            let plan: AgentPluginSetupPlan
            do {
                plan = try await OffMainIO.run { try installer.prepare() }
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
            presentOffer(
                plan: plan,
                installer: installer,
                nativeMessagingWasEnabled: nativeMessagingWasEnabled,
                defaults: defaults,
                on: window
            )
        }
    }

    @MainActor
    private static func presentOffer(
        plan: AgentPluginSetupPlan,
        installer: AgentPluginInstaller,
        nativeMessagingWasEnabled: Bool,
        defaults: UserDefaults,
        on window: NSWindow
    ) {
        let actionDescription = nativeMessagingWasEnabled
            ? "Installing both plugins preserves your messaging-mode selection."
            : "This install-and-enable action enables native messaging after every command succeeds."
        SheetAlert.present(
            .init(
                messageText: nativeMessagingWasEnabled
                    ? "Install Codex and Claude Plugins?"
                    : "Install Plugins and Enable Native Messaging?",
                informativeText: "Graftty can run the provider-native commands that install the shared team skill and lifecycle hooks. \(actionDescription) If a provider CLI is not installed, you can still enable native messaging independently in Agent Teams Settings.",
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
            let userSelectionRevision = AgentPluginIntegrationActivation
                .userSelectionRevision(in: defaults)

            Task { @MainActor in
                let report = await installer.install(plan)
                let enabledByInstallation = report.succeeded
                    && !nativeMessagingWasEnabled
                    && AgentPluginIntegrationActivation.userSelectionRevision(in: defaults)
                        == userSelectionRevision
                _ = AgentPluginIntegrationActivation.apply(
                    successfulInstallation: report.succeeded,
                    enableNativeMessagingOnSuccess: !nativeMessagingWasEnabled,
                    userSelectionRevisionAtStart: userSelectionRevision,
                    defaults: defaults,
                    refreshHookAssets: { GrafttyApp.installAgentHookAssets() }
                )
                let details = report.succeeded
                    ? report.summary + (enabledByInstallation
                        ? " Native messaging is now enabled."
                        : "")
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
