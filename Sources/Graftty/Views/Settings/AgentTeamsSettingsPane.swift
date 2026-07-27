import SwiftUI
import GrafttyKit

/// Settings pane that exposes the `agentTeamsEnabled` toggle, the routing
/// matrix, and the two user-editable prompts.
struct AgentTeamsSettingsPane: View {
    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false
    @AppStorage("teamSessionPrompt") private var teamSessionPrompt: String = DefaultPrompts.sessionPrompt
    @AppStorage("teamPrompt") private var teamPrompt: String = DefaultPrompts.eventPrompt
    @AppStorage("teamEventRoutingPreferences") private var teamEventRoutingPreferences = TeamEventRoutingPreferences()

    var body: some View {
        Form {
            Section {
                Toggle("Enable agent teams", isOn: $agentTeamsEnabled)
            } footer: {
                Text("Graftty always installs Codex and Claude wrappers for panes it launches. When this is off, those wrappers still run but team hook requests return an empty no-op response. When on, hooks inject team context and deliver team inbox messages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if agentTeamsEnabled {
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
                        .frame(minHeight: 100)
                        .font(.system(.body, design: .monospaced))
                    AgentVariablesDocs(includesEventScope: false)
                } header: {
                    PromptSectionHeader(title: "Session prompt") {
                        DefaultPrompts.restoreSessionPrompt()
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stencil template rendered once when each Codex or Claude session starts. Appended to the hook-provided team context, so it stays in the agent's context for the whole session. Useful for stable team-level coordination policy that doesn't depend on individual events.")
                        Text("Clearing the editor disables this optional prompt. Restore Graftty Default removes your saved override so future built-in updates apply.")
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
                        DefaultPrompts.restoreEventPrompt()
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Stencil template rendered freshly for each automated event delivered to each agent. The rendered text is prepended to the event the agent receives. Useful for event-aware reactions — branch on agent.this_worktree to react differently when the event is about the agent's own worktree.")
                        Text("Clearing the editor disables this prompt. Restore Graftty Default removes your saved override so future built-in updates apply.")
                        Text("Changes apply to automated events written after the change. Already-written inbox events keep their existing rendered prompt.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Tall enough to fit the pane without scrolling on a typical laptop;
        // macOS clamps to the screen, so smaller displays still scroll.
        .frame(minWidth: 540, minHeight: 640)
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
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
