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
                defaults: defaults,
                on: window
            )
        }
    }

    @MainActor
    private static func presentOffer(
        plan: AgentPluginSetupPlan,
        installer: AgentPluginInstaller,
        defaults: UserDefaults,
        on window: NSWindow
    ) {
        SheetAlert.present(
            .init(
                messageText: "Install Codex and Claude Plugins?",
                informativeText: "Graftty connects Codex and Claude to its Attention and agent team features through provider plugins that add its skills and lifecycle hooks. Until they are installed, agents won't be connected to Graftty. Graftty can run the provider-native install commands now and will refresh the plugins automatically when the app updates. You can also install them later from Agent Teams Settings.",
                style: .informational,
                primaryButton: "Install Plugins",
                secondaryButton: "Not Now"
            ),
            on: window
        ) { response in
            AgentPluginInstallOfferPolicy.recordAcknowledged(in: defaults)
            guard response == .primary else { return }

            Task { @MainActor in
                let report = await installer.installReplacingLegacy(plan)
                AgentPluginInstallOfferPolicy.recordInstallation(
                    succeeded: report.succeeded,
                    in: defaults
                )
                let details = report.succeeded
                    ? report.summary + " Start new agent sessions to use the plugins."
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
