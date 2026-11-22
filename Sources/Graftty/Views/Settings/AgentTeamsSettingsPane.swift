import SwiftUI
import AppKit
import GrafttyKit
import GrafttyCommandUI

/// Settings pane for provider integration, team event routing, and the
/// per-event prompt.
struct AgentTeamsSettingsPane: View {
    private enum ProviderRowState: Equatable {
        case checking
        case status(AgentPluginProviderStatus)
        case installing
    }

    @AppStorage private var defaultAgentProvider: String
    @AppStorage private var teamPrompt: String
    /// Mirrors `SettingsKeys.agentPluginInstalledRevision` so the missing-plugin
    /// warning updates as soon as an installation records its revision.
    @AppStorage private var installedPluginRevision: Int
    @AppStorage("teamEventRoutingPreferences") private var teamEventRoutingPreferences = TeamEventRoutingPreferences()
    private let defaults: UserDefaults
    @State private var providerStates: [AgentPluginProvider: ProviderRowState] = Dictionary(
        uniqueKeysWithValues: TeamHookRuntime.allCases.map { ($0, .checking) }
    )
    @State private var isRefreshingStatuses = false
    @State private var isInstallingBulk = false
    @State private var pluginSetupStatus: String?
    @State private var showingManualCommands = false
    @State private var manualCommands = ""
    @State private var manualCommandsError: String?
    @State private var copiedManualCommands = false
    private let automaticUpdate = AgentPluginAutomaticUpdate.shared

    private var isAnyProviderInstalling: Bool {
        isInstallingBulk || providerStates.values.contains(.installing)
    }

    private var pluginSetupIsBusy: Bool {
        isAnyProviderInstalling || automaticUpdate.isRunning
    }

    private var resolvedStatuses: [AgentPluginProvider: AgentPluginProviderStatus] {
        providerStates.compactMapValues { state in
            if case .status(let status) = state { return status }
            return nil
        }
    }

    private var availableProviders: [AgentPluginProvider] {
        Self.availableProviders(in: resolvedStatuses)
    }

    private var allAvailableInstalled: Bool {
        !availableProviders.isEmpty && availableProviders.allSatisfy { resolvedStatuses[$0] == .installed }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        AgentPreference.migrate(in: defaults)
        _defaultAgentProvider = AppStorage(wrappedValue: "", AgentPreference.key, store: defaults)
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
                Picker("Default agent", selection: $defaultAgentProvider) {
                    Text("Choose an agent…").tag("")
                    ForEach(TeamHookRuntime.allCases, id: \.rawValue) { provider in
                        Label { Text(provider.displayName) } icon: {
                            AgentProviderIcon(provider: provider.rawValue)
                        }.tag(provider.rawValue)
                    }
                }
                if AgentPreference.needsMigrationChoice(in: defaults) {
                    Text("Your previous startup command includes custom options. Choose a default agent; the original command is retained for reference.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(defaults.string(forKey: "defaultCommand") ?? "")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            } header: {
                Text("New agents")
            } footer: {
                Text("Used for new agents on this host unless you choose a provider when launching. Existing agents keep their provider.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if let pluginsWarning, !isRefreshingStatuses {
                    Label(pluginsWarning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }

                ForEach(TeamHookRuntime.allCases, id: \.rawValue) { provider in
                    providerRow(for: provider)
                }

                HStack(spacing: 8) {
                    Button(allAvailableInstalled ? "Reinstall All" : "Install All") {
                        installAllAvailableProviders()
                    }
                    .disabled(pluginSetupIsBusy || isRefreshingStatuses || availableProviders.isEmpty)

                    Button {
                        Task { await refreshStatuses() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh plugin status")
                    .accessibilityLabel("Refresh plugin status")
                    .disabled(pluginSetupIsBusy || isRefreshingStatuses)

                    Spacer()

                    if let status = pluginSetupStatus ?? automaticUpdate.status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .help(status)
                    }
                }

                DisclosureGroup("Manual setup commands", isExpanded: $showingManualCommands) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let manualCommandsError {
                            Text(manualCommandsError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        } else if manualCommands.isEmpty {
                            Text("Preparing commands…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(manualCommands)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Button(copiedManualCommands ? "Copied" : "Copy Commands") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(manualCommands, forType: .string)
                                    copiedManualCommands = true
                                }
                                .controlSize(.small)
                                Spacer()
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .onChange(of: showingManualCommands) { _, isExpanded in
                    if isExpanded && manualCommands.isEmpty {
                        loadManualCommands()
                    }
                }
            } header: {
                Text("Provider plugins")
            } footer: {
                Text("Plugins connect agents to Graftty's skills, Attention, and agent teams, and refresh automatically after app updates. Start new agent sessions after installing. Add `.graftty/GRAFTTY.md` to customize agents per repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ChannelRoutingMatrixView(prefs: $teamEventRoutingPreferences)
            } header: {
                Text("Team event routing")
            } footer: {
                Text("Choose which agents receive each automated team event. \"Worktree agent\" is the agent in the event's worktree; \"Other worktree agents\" are agents in every other linked worktree in the same repo.")
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
        // Tall enough to fit the pane without scrolling on a typical laptop;
        // macOS clamps to the screen, so smaller displays still scroll.
        .frame(minWidth: 540, minHeight: 640)
        // Launch-time plugin work changes what the providers report, so read
        // the statuses once it has finished.
        .task(id: automaticUpdate.isRunning) {
            guard !automaticUpdate.isRunning else { return }
            await refreshStatuses()
        }
    }

    @ViewBuilder
    private func providerRow(for provider: AgentPluginProvider) -> some View {
        let state = providerStates[provider] ?? .checking
        HStack(spacing: 10) {
            AgentProviderIcon(provider: provider.rawValue)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                providerStatusLabel(for: provider, state: state)
            }
            Spacer()
            switch state {
            case .checking, .installing:
                ProgressView()
                    .controlSize(.small)
            case .status(.cliNotFound):
                EmptyView()
            case .status(.installed):
                Button("Reinstall") { install(provider: provider) }
                    .controlSize(.small)
                    .disabled(pluginSetupIsBusy || isRefreshingStatuses)
            case .status(.notInstalled), .status(.disabled), .status(.error):
                Button("Install") { install(provider: provider) }
                    .controlSize(.small)
                    .disabled(pluginSetupIsBusy || isRefreshingStatuses)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func providerStatusLabel(for provider: AgentPluginProvider, state: ProviderRowState) -> some View {
        switch state {
        case .checking:
            Text("Checking…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .installing:
            Text("Installing…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .status(.installed):
            statusDot(color: .green, text: "Installed")
        case .status(.disabled):
            statusDot(color: .orange, text: "Disabled in \(provider.displayName)")
        case .status(.notInstalled):
            statusDot(color: .secondary, text: "Not installed")
        case .status(.cliNotFound):
            Text("`\(provider.executable)` CLI not found")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .status(.error(let message)):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .help(message)
        }
    }

    private func statusDot(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    /// AGENT-6.173: live Codex/Claude statuses satisfy the integration once at
    /// least one is installed and no available one remains uninstalled or errored.
    static func isIntegrationSatisfied(
        by statuses: [AgentPluginProvider: AgentPluginProviderStatus]
    ) -> Bool {
        let marketplace: [AgentPluginProvider] = [.codex, .claude]
        let hasInstalled = marketplace.contains { statuses[$0] == .installed }
        guard hasInstalled else { return false }
        return marketplace.allSatisfy { provider in
            switch statuses[provider] {
            case .installed, .disabled, .cliNotFound:
                return true
            case .notInstalled, .error, .none:
                return false
            }
        }
    }

    struct InstallCheckpoints: Equatable {
        var recordsIntegration: Bool
        var advancesIntegrationBuild: Bool
        var advancesAntigravityBuild: Bool
    }

    /// AGENT-6.178: a build checkpoint stops the next launch from refreshing
    /// that plugin, and a live status of installed says nothing about which
    /// build installed it. Advance a checkpoint only for plugins this
    /// installation installed, so one it failed on or skipped still refreshes.
    static func checkpoints(
        afterInstalling installed: Set<AgentPluginProvider>,
        statuses: [AgentPluginProvider: AgentPluginProviderStatus]
    ) -> InstallCheckpoints {
        let recordsIntegration = isIntegrationSatisfied(by: statuses)
        let marketplace: [AgentPluginProvider] = [.codex, .claude]
        return InstallCheckpoints(
            recordsIntegration: recordsIntegration,
            advancesIntegrationBuild: recordsIntegration && marketplace.allSatisfy {
                statuses[$0] != .installed || installed.contains($0)
            },
            advancesAntigravityBuild: installed.contains(.antigravity)
        )
    }

    /// AGENT-6.173: bulk install targets only providers whose CLI is available.
    static func availableProviders(
        in statuses: [AgentPluginProvider: AgentPluginProviderStatus]
    ) -> [AgentPluginProvider] {
        TeamHookRuntime.allCases.filter { provider in
            guard let status = statuses[provider] else { return false }
            return status != .cliNotFound
        }
    }

    private func makeInstaller() -> AgentPluginInstaller {
        AgentPluginInstaller(grafttyCLIPath: GrafttyApp.agentHookCLIPath())
    }

    private func refreshStatuses() async {
        guard !isRefreshingStatuses else { return }
        isRefreshingStatuses = true
        for provider in TeamHookRuntime.allCases where providerStates[provider] != .installing {
            providerStates[provider] = .checking
        }
        let installer = makeInstaller()
        let statuses = await installer.providerStatuses()
        for (provider, status) in statuses where providerStates[provider] != .installing {
            providerStates[provider] = .status(status)
        }
        isRefreshingStatuses = false
    }

    private func install(provider: AgentPluginProvider) {
        guard !pluginSetupIsBusy else { return }
        providerStates[provider] = .installing
        pluginSetupStatus = nil
        Task {
            let installer = makeInstaller()
            let report = await installer.install(provider: provider)
            let updatedStatus = await installer.providerStatus(for: provider)
            providerStates[provider] = .status(updatedStatus)
            if report.succeeded {
                recordCheckpoints(afterInstalling: [provider])
            }
            pluginSetupStatus = report.summary
        }
    }

    private func installAllAvailableProviders() {
        let targets = availableProviders
        guard !pluginSetupIsBusy, !targets.isEmpty else { return }
        isInstallingBulk = true
        pluginSetupStatus = nil
        for provider in targets {
            providerStates[provider] = .installing
        }
        Task {
            defer { isInstallingBulk = false }
            let installer = makeInstaller()
            var failures: [String] = []
            var installed: Set<AgentPluginProvider> = []
            for provider in targets {
                let report = await installer.install(provider: provider)
                let updatedStatus = await installer.providerStatus(for: provider)
                providerStates[provider] = .status(updatedStatus)
                if report.succeeded {
                    installed.insert(provider)
                } else {
                    failures.append(report.summary)
                }
            }
            recordCheckpoints(afterInstalling: installed)
            if failures.isEmpty {
                pluginSetupStatus = "All available plugins installed. Start new agent sessions."
            } else {
                pluginSetupStatus = failures.joined(separator: " ")
            }
        }
    }

    private func recordCheckpoints(afterInstalling installed: Set<AgentPluginProvider>) {
        let checkpoints = Self.checkpoints(afterInstalling: installed, statuses: resolvedStatuses)
        let buildVersion = AgentPluginInstallOfferPolicy.currentBuildVersion
        if checkpoints.recordsIntegration {
            AgentPluginInstallOfferPolicy.recordInstalled(
                in: defaults,
                buildVersion: checkpoints.advancesIntegrationBuild ? buildVersion : nil
            )
        }
        if checkpoints.advancesAntigravityBuild, let buildVersion, !buildVersion.isEmpty {
            defaults.set(buildVersion, forKey: SettingsKeys.antigravityPluginInstalledBuildVersion)
        }
    }

    private func loadManualCommands() {
        copiedManualCommands = false
        manualCommandsError = nil
        let installer = makeInstaller()
        Task {
            do {
                manualCommands = try await OffMainIO.run {
                    try installer.manualCommandsScript()
                }
            } catch {
                // The commands stay empty, so opening the section again retries.
                manualCommandsError = "Could not prepare manual commands: \(error)"
            }
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
