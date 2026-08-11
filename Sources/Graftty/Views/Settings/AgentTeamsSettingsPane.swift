import SwiftUI
import AppKit
import GrafttyKit

/// Settings pane that exposes the `agentTeamsEnabled` toggle, the routing
/// matrix, and the two user-editable prompts.
struct AgentTeamsSettingsPane: View {
    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false
    @AppStorage(SettingsKeys.nativeAgentMessagingEnabled)
    private var nativeAgentMessagingEnabled: Bool = false
    @AppStorage private var teamSessionPrompt: String
    @AppStorage private var teamPrompt: String
    @AppStorage("teamEventRoutingPreferences") private var teamEventRoutingPreferences = TeamEventRoutingPreferences()
    private let defaults: UserDefaults
    @State private var pluginSetupCommands = ""
    @State private var pluginSetupStatus: String?
    @State private var preparedPluginPlan: AgentPluginSetupPlan?
    @State private var showingPluginInstallOffer = false
    @State private var pluginInstallInProgress = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _teamSessionPrompt = AppStorage(
            wrappedValue: DefaultPrompts.sessionPrompt,
            SettingsKeys.teamSessionPrompt,
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
                Toggle("Enable agent teams", isOn: $agentTeamsEnabled)
            } footer: {
                Text("When native provider integration is off, Graftty installs compatibility wrappers that register sessions, inject lifecycle hooks, and deliver team inbox messages. Native integration moves hooks and team instructions into provider plugins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if agentTeamsEnabled {
                Section {
                    Toggle(
                        "Use native agent messaging (experimental)",
                        isOn: $nativeAgentMessagingEnabled
                    )
                    Button("Prepare Codex and Claude Plugins…") {
                        prepareProviderPlugins()
                    }
                    .disabled(pluginInstallInProgress)
                    if preparedPluginPlan != nil {
                        Button("Install Prepared Plugins…") {
                            showingPluginInstallOffer = true
                        }
                        .disabled(pluginInstallInProgress)
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
                    }
                } header: {
                    Text("Native provider integration")
                } footer: {
                    Text("Preparation copies a Graftty-owned marketplace snapshot and four provider-native setup commands to the clipboard, then offers to run those commands. Graftty changes provider configuration only after you explicitly approve that offer. The plugins install the shared team skill and lifecycle hooks. Native mode removes Graftty's Claude wrapper and uses Claude's peer socket. Codex 0.147 still needs a small Graftty transport wrapper to launch an app-server/remote pair; its plugin owns hooks and instructions. After changing this setting or installing the plugins, restart Graftty and then start new provider sessions.")
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
                    TextEditor(text: $teamSessionPrompt)
                        .frame(minHeight: 260)
                        .font(.system(.body, design: .monospaced))
                    AgentVariablesDocs(includesEventScope: false)
                } header: {
                    PromptSectionHeader(title: "Session prompt") {
                        DefaultPrompts.restoreSessionPrompt(in: defaults) {
                            teamSessionPrompt = $0
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Complete Stencil template rendered once when each Codex or Claude session starts. This is the team context delivered by the session-start hook; dynamic identity and roster values are represented by the placeholders listed below.")
                        Text("Clearing the editor disables this session-start prompt. Restore Graftty Default immediately reloads the complete built-in template and removes your saved override so future built-in updates apply.")
                        Text("Changes apply when each agent session next starts. Live in-session refresh has been removed.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $teamPrompt)
                        .frame(minHeight: 100)
                        .font(.system(.body, design: .monospaced))
                    AgentVariablesDocs(includesEventScope: true)
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
        }
        .formStyle(.grouped)
        .confirmationDialog(
            nativeAgentMessagingEnabled
                ? "Install Codex and Claude plugins now?"
                : "Install plugins and enable native messaging?",
            isPresented: $showingPluginInstallOffer,
            titleVisibility: .visible
        ) {
            Button(nativeAgentMessagingEnabled ? "Install Both Plugins" : "Install and Enable") {
                AgentPluginInstallOfferPolicy.recordAcknowledged(in: defaults)
                installPreparedProviderPlugins()
            }
            Button("Not Now", role: .cancel) {
                AgentPluginInstallOfferPolicy.recordAcknowledged(in: defaults)
            }
        } message: {
            Text("Graftty will run the four displayed provider-native commands. Each provider remains responsible for its own plugin configuration, and failures are reported without preventing the other provider from being attempted.")
        }
        .onChange(of: nativeAgentMessagingEnabled) { _, enabled in
            guard enabled,
                  AgentPluginInstallOfferPolicy.shouldOffer(in: defaults) else { return }
            prepareProviderPlugins()
        }
        .onChange(of: agentTeamsEnabled) { _, enabled in
            guard enabled,
                  AgentPluginInstallOfferPolicy.shouldOffer(in: defaults) else { return }
            prepareProviderPlugins()
        }
        // Tall enough to fit the pane without scrolling on a typical laptop;
        // macOS clamps to the screen, so smaller displays still scroll.
        .frame(minWidth: 540, minHeight: 640)
    }

    private func prepareProviderPlugins() {
        do {
            let plan = try AgentPluginInstaller().prepare()
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
        guard let plan = preparedPluginPlan else { return }
        pluginInstallInProgress = true
        pluginSetupStatus = "Installing Codex and Claude plugins…"
        Task {
            let report = await AgentPluginInstaller().install(plan)
            if AgentPluginIntegrationActivation.apply(
                successfulInstallation: report.succeeded,
                defaults: defaults,
                refreshHookAssets: { GrafttyApp.installAgentHookAssets() }
            ) {
                nativeAgentMessagingEnabled = true
            }
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

/// Disclosure list of `agent.*` Stencil variables shown beneath each prompt
/// editor. The session prompt suppresses the event-scoped variables, since
/// they're always `false` at session start.
private struct AgentVariablesDocs: View {
    let includesEventScope: Bool

    var body: some View {
        DisclosureGroup("Available variables in your template") {
            VStack(alignment: .leading, spacing: 4) {
                Text("agent.branch (String) — agent's branch.")
                Text("agent.main_worktree (Bool) — true iff this agent is in the repo's main worktree.")
                if includesEventScope {
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
                } else {
                    Text("agent.name (String) — stable member name.")
                    Text("agent.worktree (String) — absolute worktree path.")
                    Text("agent.running (Bool) — whether the worktree currently has a running pane backend.")
                    Text("team.repo (String) — repository display name.")
                    Text("team.repo_path (String) — main repository worktree path.")
                    Text("team.main_worktree (Object) — main member; exposes name, branch, worktree, main_worktree, and running.")
                    Text("team.members (Array) — all team members using that same object shape.")
                    Text("team.other_worktrees (Array) — linked worktrees other than the current agent, using that same object shape.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
