import AppKit
import GrafttyKit

enum AgentPluginInstallOfferPresenter {
    @MainActor
    static func presentWhenWindowIsReady(
        defaults: UserDefaults = .standard,
        installer suppliedInstaller: AgentPluginInstaller? = nil
    ) async {
        guard AgentPluginInstallOfferPolicy.shouldOffer(in: defaults) else { return }
        let installer = suppliedInstaller ?? AgentPluginInstaller(
            grafttyCLIPath: GrafttyApp.agentHookCLIPath()
        )

        // prepare() rewrites the app-owned marketplace snapshots on disk
        // (recursive copy plus hooks.json rewrite). Run it off the main
        // actor before claiming a host window so launch-time file I/O cannot
        // wedge control-socket handling or race with sibling startup sheets
        // (ATTN-2.19 / OffMainIO).
        let plan: AgentPluginSetupPlan
        do {
            plan = try await OffMainIO.run { try installer.prepare() }
        } catch {
            guard let window = await SheetAlert.awaitReadyHostWindow() else { return }
            await SheetAlert.presentAsync(
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

        guard AgentPluginInstallOfferPolicy.shouldOffer(in: defaults),
              let offerWindow = await SheetAlert.awaitReadyHostWindow() else { return }
        let response = await SheetAlert.presentAsync(
            .init(
                messageText: "Install Codex and Claude Plugins?",
                informativeText: "Graftty connects Codex and Claude to its Attention and agent team features through provider plugins that add its skills and lifecycle hooks. Until they are installed, agents won't be connected to Graftty. Graftty can run the provider-native install commands now and will refresh the plugins automatically when the app updates. You can also install them later from Agent Teams Settings.",
                style: .informational,
                primaryButton: "Install Plugins",
                secondaryButton: "Not Now",
                escapeButton: .secondary
            ),
            on: offerWindow
        )
        guard response != .cancelled else { return }
        AgentPluginInstallOfferPolicy.recordAcknowledged(in: defaults)
        guard response == .primary else { return }

        let report = await installer.installReplacingLegacy(plan)
        AgentPluginInstallOfferPolicy.recordInstallation(
            succeeded: report.succeeded,
            in: defaults
        )
        guard let resultWindow = await SheetAlert.awaitReadyHostWindow() else { return }
        let details = report.succeeded
            ? report.summary
            : report.summary + " Retry from Agent Teams Settings."
        await SheetAlert.presentAsync(
            .init(
                messageText: report.succeeded
                    ? "Provider Plugins Installed"
                    : "Provider Plugin Installation Incomplete",
                informativeText: details,
                style: report.succeeded ? .informational : .warning,
                primaryButton: "OK"
            ),
            on: resultWindow
        )
    }
}
