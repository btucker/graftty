import SwiftUI
import AppKit

/// Preferences pane for the Claude Code Channels feature — a research-preview
/// integration that delivers PR state events into Claude sessions running in
/// tracked worktrees.
///
/// Backed entirely by `@AppStorage`:
/// - `channelsEnabled` (Bool): opt-in for the whole feature. When off, the
///   disclosure banner and prompt editor are hidden.
/// - `channelPrompt` (String): the instructions text broadcast to every
///   subscribed Claude session as the initial `type=instructions` event.
///
struct ChannelsSettingsPane: View {
    @AppStorage("channelsEnabled") private var channelsEnabled: Bool = false
    @AppStorage("channelPrompt") private var channelPrompt: String = ChannelsSettingsPane.defaultPrompt

    /// The exact flag users need to append when launching Claude for a
    /// channel-subscribing session. `server:graftty-channel` targets the
    /// user-scope MCP server Graftty registers via `claude mcp add` on
    /// enable; `plugin:<name>@<marketplace>` would require a marketplace
    /// registration we don't have.
    static let launchFlag = "--dangerously-load-development-channels server:graftty-channel"

    var body: some View {
        Form {
            Section {
                Toggle("Enable GitHub/GitLab channel", isOn: $channelsEnabled)
                Text("Claude sessions in tracked worktrees receive events for their PR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if channelsEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Launch Claude with this flag",
                            systemImage: "terminal"
                        )
                        .font(.subheadline.bold())

                        Text(verbatim:
                            "Graftty registers a user-scope MCP server with Claude Code. " +
                            "To receive channel events, launch Claude with:"
                        )
                        .font(.caption)

                        HStack(spacing: 6) {
                            Text(verbatim: Self.launchFlag)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(6)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(4)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Self.launchFlag, forType: .string)
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }

                        Text(verbatim:
                            "Research preview — the --dangerously-load-development-channels " +
                            "flag bypasses Claude Code's channel allowlist for this server only. " +
                            "Events originate from Graftty's local polling; no external senders."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if let url = URL(string: "https://docs.claude.com/en/channels") {
                            Link("Learn more →", destination: url)
                                .font(.caption)
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.orange.opacity(0.4))
                    )
                }

                Section("Prompt") {
                    Text("Applied to every Claude session with channels enabled. " +
                         "Edits propagate immediately to running sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $channelPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3))
                        )

                    HStack {
                        Spacer()
                        Button("Restore default") {
                            channelPrompt = Self.defaultPrompt
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 240)
    }

    static let defaultPrompt: String = """
    You receive events from Graftty when state changes on the PR associated with your current worktree. Each event arrives as a <channel source="graftty-channel" type="..."> tag with attributes (pr_number, provider, repo, worktree, pr_url) and a short body.

    When you see:
    - type=pr_state_changed, to=merged: The PR merged. Briefly acknowledge. Don't take destructive actions (e.g. delete the worktree) without explicit confirmation.
    - type=ci_conclusion_changed, to=failure: Read the failing check log via the pr_url if accessible, summarize what failed, and propose a fix. Don't commit without confirmation.
    - type=ci_conclusion_changed, to=success: Brief acknowledgement. If the PR is now mergeable, mention it.

    Keep replies short. The user is working in the same terminal; noisy output is disruptive.
    """
}
