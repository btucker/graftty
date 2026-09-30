import SwiftUI
import AppKit
import GrafttyKit

/// Settings pane for provider integration, team event routing, and the
/// per-event prompt.
struct AgentTeamsSettingsPane: View {
    @AppStorage private var teamPrompt: String
    /// Mirrors `SettingsKeys.agentPluginInstalledRevision` so the missing-plugin
    /// warning updates as soon as an installation records its revision.
    @AppStorage private var installedPluginRevision: Int
    @AppStorage("teamEventRoutingPreferences") private var teamEventRoutingPreferences = TeamEventRoutingPreferences()
    private let defaults: UserDefaults
    @State private var pluginSetupCommands = ""
    @State private var pluginSetupStatus: String?
    @State private var preparedPluginPlan: AgentPluginSetupPlan?
    @State private var showingPluginInstallOffer = false
    @State private var pluginInstallInProgress = false
    private let automaticUpdate = AgentPluginAutomaticUpdate.shared

    private var pluginSetupIsBusy: Bool { pluginInstallInProgress || automaticUpdate.isRunning }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _installedPluginRevision = AppStorage(
            wrappedValue: 0,
            SettingsKeys.agentPluginInstalledRevision,
            store: defaults
        )
        _teamPrompt = AppStorage(
            wrappedValue: DefaultPrompts.eventPrompt,
            SettingsKeys.teamPrompt,
            store: defaults
        )
    }

    var body: some View {
        Form {
            Section {
                if let pluginsWarning {
                    Label(pluginsWarning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button(
                    pluginsWarning == nil
                        ? "Reinstall Codex and Claude Plugins…"
                        : "Install Codex and Claude Plugins…"
                ) {
                    prepareProviderPlugins()
                }
                .disabled(pluginSetupIsBusy)
                if preparedPluginPlan != nil {
                    Button("Install Prepared Plugins…") {
                        showingPluginInstallOffer = true
                    }
                    .disabled(pluginSetupIsBusy)
                }
                if pluginInstallInProgress {
                    ProgressView("Installing provider plugins…")
                        .controlSize(.small)
                }
                if !pluginSetupCommands.isEmpty {
                    Text(pluginSetupCommands)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let pluginSetupStatus {
                    Text(pluginSetupStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let status = automaticUpdate.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Provider plugins")
            } footer: {
                Text("The Codex and Claude plugins give agents Graftty's skills and lifecycle hooks, which connect them to Attention and agent teams. Install them once; Graftty then refreshes them automatically after app updates, and failed updates retry on the next launch. Start new agent sessions after installation or an update to use the new plugins. To customize agents, add `.graftty/GRAFTTY.md` instruction files to a repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ChannelRoutingMatrixView(prefs: $teamEventRoutingPreferences)
            } header: {
                Text("Team event routing")
            } footer: {
                Text("Choose which agents receive each automated team event. Events flow into the team inbox and are delivered to agents through hook context. \"Worktree agent\" means the agent in the worktree the event is about; \"Other worktree agents\" means agents in every other linked worktree in the same repo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $teamPrompt)
                    .frame(minHeight: 100)
                    .font(.system(.body, design: .monospaced))
                AgentVariablesDocs()
            } header: {
                PromptSectionHeader(title: "Per-event prompt") {
                    DefaultPrompts.restoreEventPrompt(in: defaults) {
                        teamPrompt = $0
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stencil template rendered freshly for each automated event delivered to each agent. The rendered text is prepended to the event the agent receives. Useful for event-aware reactions — branch on agent.this_worktree to react differently when the event is about the agent's own worktree.")
                    Text("Clearing the editor disables this prompt. Restore Graftty Default immediately reloads the built-in text and removes your saved override so future built-in updates apply.")
                    Text("Changes apply to automated events written after the change. Already-written inbox events keep their existing rendered prompt.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Install Codex and Claude plugins now?",
            isPresented: $showingPluginInstallOffer,
            titleVisibility: .visible
        ) {
            Button("Install Plugins") {
                AgentPluginInstallOfferPolicy.recordAcknowledged(in: defaults)
                installPreparedProviderPlugins()
            }
            Button("Not Now", role: .cancel) {
                AgentPluginInstallOfferPolicy.recordAcknowledged(in: defaults)
            }
        } message: {
            Text("Graftty will run the five displayed provider-native commands and refresh these plugins automatically after future app updates. Failures are reported without preventing the other provider from being attempted.")
        }
        // Tall enough to fit the pane without scrolling on a typical laptop;
        // macOS clamps to the screen, so smaller displays still scroll.
        .frame(minWidth: 540, minHeight: 640)
    }

    private var pluginsWarning: String? {
        Self.missingPluginsWarning(installedRevision: installedPluginRevision)
    }

    /// AGENT-6.46: shown until the current provider plugin integration is
    /// installed, because without the plugins agents have no Graftty hooks.
    static func missingPluginsWarning(installedRevision: Int?) -> String? {
        guard !AgentPluginInstallOfferPolicy.isCurrentIntegrationInstalled(
            installedRevision: installedRevision
        ) else { return nil }
        return "Codex and Claude agents won't be connected to Graftty until the provider plugins are installed. Install them below, then start new agent sessions."
    }

    static func missingPluginsWarning(in defaults: UserDefaults) -> String? {
        missingPluginsWarning(
            installedRevision: defaults.object(forKey: SettingsKeys.agentPluginInstalledRevision) as? Int
        )
    }

    private func prepareProviderPlugins() {
        guard !pluginSetupIsBusy else { return }
        do {
            let plan = try AgentPluginInstaller(
                grafttyCLIPath: GrafttyApp.agentHookCLIPath()
            ).prepare()
            preparedPluginPlan = plan
            pluginSetupCommands = plan.shellScript
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(plan.shellScript, forType: .string)
            pluginSetupStatus = "Setup commands copied. Approve the installation offer to run them now, or review and run them in a terminal."
            showingPluginInstallOffer = true
        } catch {
            preparedPluginPlan = nil
            pluginSetupCommands = ""
            pluginSetupStatus = "Could not prepare provider plugins: \(error)"
        }
    }

    private func installPreparedProviderPlugins() {
        guard !pluginSetupIsBusy, let plan = preparedPluginPlan else { return }
        pluginInstallInProgress = true
        pluginSetupStatus = "Installing Codex and Claude plugins…"
        Task {
            let report = await AgentPluginInstaller(
                grafttyCLIPath: GrafttyApp.agentHookCLIPath()
            ).installReplacingLegacy(plan)
            AgentPluginInstallOfferPolicy.recordInstallation(
                succeeded: report.succeeded,
                in: defaults
            )
            pluginInstallInProgress = false
            pluginSetupStatus = report.summary
        }
    }
}

private struct PromptSectionHeader: View {
    let title: String
    let restore: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button("Restore Graftty Default", action: restore)
                .buttonStyle(.link)
                .controlSize(.small)
        }
    }
}

/// Disclosure list of the Stencil variables available to the per-event
/// prompt editor.
private struct AgentVariablesDocs: View {
    var body: some View {
        DisclosureGroup("Available variables in your template") {
            VStack(alignment: .leading, spacing: 4) {
                Text("agent.branch (String) — agent's branch.")
                Text("agent.main_worktree (Bool) — true iff this agent is in the repo's main worktree.")
                Text("agent.this_worktree (Bool) — true iff event is about agent's own worktree.")
                Text("agent.other_worktree (Bool) — true iff event is about a different worktree.")
                Text("event.type (String) — wire-format event type. One of:")
                Text(verbatim: "    \"\(TeamChannelEvents.WireType.prStateChanged)\" — PR opened/closed/draft/merged.")
                Text(verbatim: "    \"\(TeamChannelEvents.WireType.ciConclusionChanged)\" — PR's CI conclusion changed.")
                Text(verbatim: "    \"\(TeamChannelEvents.WireType.mergeStateChanged)\" — branch mergeability vs. default branch changed.")
                Text(verbatim: "    \"\(TeamChannelEvents.EventType.memberJoined)\" — new worktree joined the team.")
                Text(verbatim: "    \"\(TeamChannelEvents.EventType.memberLeft)\" — worktree left the team.")
                Text("body (String) — original event body.")
                Text("event.attrs (Object) — event attribute dictionary.")
                Text("event.body (String) — original event body.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
