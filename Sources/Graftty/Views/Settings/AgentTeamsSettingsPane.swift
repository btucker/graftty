import AppKit
import SwiftUI
import GrafttyKit

/// Settings pane that exposes the `agentTeamsEnabled` toggle, the channel
/// routing matrix (TEAM-1.8), the launch-flag disclosure (TEAM-1.7), and the
/// two user-editable prompts (TEAM-1.6).
struct AgentTeamsSettingsPane: View {
    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false
    @AppStorage("teamSessionPrompt") private var teamSessionPrompt: String = ""
    @AppStorage("teamPrompt") private var teamPrompt: String = ""
    @AppStorage("channelRoutingPreferences") private var channelRoutingPreferences = ChannelRoutingPreferences()

    static let launchFlag = "--dangerously-load-development-channels server:graftty-channel"

    var body: some View {
        Form {
            Section {
                Toggle("Enable agent teams", isOn: $agentTeamsEnabled)
            } footer: {
                Text("When on, every Claude pane Graftty launches in a multi-worktree repo participates in a team. Add the launch flag below to your `claude` invocation for channel events to flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if agentTeamsEnabled {
                Section {
                    HStack {
                        Text(Self.launchFlag)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.launchFlag, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                } header: {
                    Text("Launch Claude with this flag")
                } footer: {
                    Text("Add this flag to your `claude` invocation (e.g., the Default Command field on the General Settings pane) for channel events to flow into the session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ChannelRoutingMatrixView(prefs: $channelRoutingPreferences)
                } header: {
                    Text("Channel routing")
                } footer: {
                    Text("Choose which agents receive each automated channel message. \"Worktree agent\" means the agent in the worktree the event is about (e.g., the branch whose CI just failed); \"Other worktree agents\" means every other coworker in the same repo. Use the prompt below to define what each agent should do when it receives an event.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $teamSessionPrompt)
                        .frame(minHeight: 100)
                        .font(.system(.body, design: .monospaced))
                    DisclosureGroup("Available variables in your template") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("agent.branch (String) — agent's branch.")
                            Text("agent.lead (Bool) — true iff this agent is the team's lead.")
                            Text("agent.this_worktree (Bool) — always false (no event yet).")
                            Text("agent.other_worktree (Bool) — always false (no event yet).")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Session prompt")
                } footer: {
                    Text("Stencil template rendered once when each Claude session starts. Appended to that session's MCP instructions, so it stays in the agent's system context for the whole session. Useful for stable team-level coordination policy that doesn't depend on individual events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $teamPrompt)
                        .frame(minHeight: 100)
                        .font(.system(.body, design: .monospaced))
                    DisclosureGroup("Available variables in your template") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("agent.branch (String) — agent's branch.")
                            Text("agent.lead (Bool) — true iff this agent is the team's lead.")
                            Text("agent.this_worktree (Bool) — true iff event is about agent's own worktree.")
                            Text("agent.other_worktree (Bool) — true iff event is about a different worktree.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Per-event prompt")
                } footer: {
                    Text("Stencil template rendered freshly for each channel event delivered to each agent. The rendered text is prepended to the event the agent receives. Useful for event-aware reactions — branch on agent.this_worktree to react differently when the event is about the agent's own worktree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 360)
    }
}
