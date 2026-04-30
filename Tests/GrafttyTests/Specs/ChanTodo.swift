// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("CHAN — pending specs")
struct ChanTodo {
    @Test("""
@spec CHAN-1.1: The application shall host a single `ChannelRouter` that owns the `ChannelSocketServer` and maintains a `[worktreePath: ChannelSocketServer.Connection]` map keyed by the subscriber's `worktree` field.
""", .disabled("not yet implemented"))
    func chan_1_1() async throws { }

    @Test("""
@spec CHAN-1.2: When a subscriber sends a `subscribe` message, the router shall record the connection under the subscribed worktree path (replacing any prior connection for that path) and update its observable `subscriberCount`.
""", .disabled("not yet implemented"))
    func chan_1_2() async throws { }

    @Test("""
@spec CHAN-1.3: When a subscriber disconnects, the router shall remove that connection from the subscriber map and update `subscriberCount` accordingly, regardless of which worktree path the connection had subscribed under.
""", .disabled("not yet implemented"))
    func chan_1_3() async throws { }

    @Test("""
@spec CHAN-1.4: When a subscriber first subscribes, the router shall immediately send it a `type=instructions` event whose `body` is the current prompt from the injected `promptProvider`. This initial event shall be written synchronously from the server's connection-handling thread so it reaches the subscriber even when the main actor is briefly occupied; the map mutation and `subscriberCount` update still hop to the main actor where the router's state lives.
""", .disabled("not yet implemented"))
    func chan_1_4() async throws { }

    @Test("""
@spec CHAN-1.5: When `ChannelRouter.dispatch(worktreePath:message:)` is called, the router shall forward the message only to the single connection registered under the matching worktree path, if any, and shall not broadcast it to subscribers of other worktree paths.
""", .disabled("not yet implemented"))
    func chan_1_5() async throws { }

    @Test("""
@spec CHAN-1.6: When `ChannelRouter.broadcastInstructions()` is called, the router shall build a `type=instructions` event from the current `promptProvider()` and send it to every currently-registered subscriber exactly once.
""", .disabled("not yet implemented"))
    func chan_1_6() async throws { }

    @Test("""
@spec CHAN-1.7: If a write to a subscriber's connection throws (peer gone, socket closed), the router shall remove that subscriber from its map and update `subscriberCount`, so a dead peer does not leak a stale entry and subsequent dispatches to the same worktree path do not fail against the same dead fd.
""", .disabled("not yet implemented"))
    func chan_1_7() async throws { }

    @Test("""
@spec CHAN-1.8: While `ChannelRouter.isEnabled` is `false`, both `dispatch` and `broadcastInstructions` shall become no-ops, but existing subscriber connections shall remain connected — mirroring the Settings enable toggle without forcing every subscriber to reconnect on re-enable.
""", .disabled("not yet implemented"))
    func chan_1_8() async throws { }

    @Test("""
@spec CHAN-2.1: The channel settings are part of the **Agent Teams** Settings tab; there is no separate "Channels" tab. `channelsEnabled` is no longer used; the channel infrastructure is gated entirely by `agentTeamsEnabled` (see TEAM-1.2).
""", .disabled("not yet implemented"))
    func chan_2_1() async throws { }

    @Test("""
@spec CHAN-2.3: While `agentTeamsEnabled` is `false`, the Agent Teams pane shall hide the research-preview disclosure banner, the PR-notifications sub-checkbox, and the prompt editor, showing only the main toggle and its footer.
""", .disabled("not yet implemented"))
    func chan_2_3() async throws { }

    @Test("""
@spec CHAN-2.4: When `agentTeamsEnabled` is `true`, the Agent Teams pane shall display a highlighted instructional panel containing the verbatim launch flag string `--dangerously-load-development-channels server:graftty-channel`, a one-click "Copy" button that writes that string to the system pasteboard, a note that the `--dangerously-load-development-channels` flag bypasses Claude Code's channel allowlist only for this server, and a note that events originate from Graftty's local polling. The application shall not auto-inject the flag into `defaultCommand` or any other launched command — the user is responsible for adding it to their own `claude` launch.
""", .disabled("not yet implemented"))
    func chan_2_4() async throws { }

    @Test("""
@spec CHAN-2.5: When `agentTeamsEnabled` is `true`, the Agent Teams pane shall render an editable prompt textarea bound to `@AppStorage("channelPrompt")`, seeded on first read with the default prompt template that documents the event tag format and how Claude should respond to `pr_state_changed` and `ci_conclusion_changed` events.
""", .disabled("not yet implemented"))
    func chan_2_5() async throws { }

    @Test("""
@spec CHAN-2.6: When the user clicks "Restore default" in the prompt section, the application shall overwrite `channelPrompt` with the built-in default prompt template.
""", .disabled("not yet implemented"))
    func chan_2_6() async throws { }

    @Test("""
@spec CHAN-3.1: The canonical launch-flag string the Channels pane shall disclose is `--dangerously-load-development-channels server:graftty-channel`. The `server:<name>` form addresses the user-scope MCP server entry Graftty registers via `claude mcp add` per CHAN-4.*. The `plugin:<name>@<marketplace>` form is not used, because local plugins under `~/.claude/plugins/` are not registered under any marketplace by default and the flag rejects bare `plugin:<name>`.
""", .disabled("not yet implemented"))
    func chan_3_1() async throws { }

    @Test("""
@spec CHAN-3.2: The application shall never modify the user's `defaultCommand` string, nor inject channel flags into any command it types into a terminal. The user is the sole author of the Claude launch line.
""", .disabled("not yet implemented"))
    func chan_3_2() async throws { }

    @Test("""
@spec CHAN-3.3: Existing `claude` sessions shall continue with their original launch flags when `agentTeamsEnabled` is toggled mid-session; only sessions started by the user after toggling shall see the change. Retroactively attaching channels to a running `claude` requires the user to restart it with the launch flag appended.
""", .disabled("not yet implemented"))
    func chan_3_3() async throws { }

    @Test("""
@spec CHAN-4.1: While `agentTeamsEnabled` is `true`, on app launch the application shall register an MCP server named `graftty-channel` at user scope via the `claude` CLI, with its command set to the bundled Graftty CLI path and its args set to `["mcp-channel"]`.
""", .disabled("not yet implemented"))
    func chan_4_1() async throws { }

    @Test("""
@spec CHAN-4.2: The registration shall be idempotent: when an entry already exists at user scope with the expected command and args, the application shall not re-invoke `claude mcp add`. When the existing entry differs (path change, wrong args, or wrong scope), the application shall remove the old entry and register the new one.
""", .disabled("not yet implemented"))
    func chan_4_2() async throws { }

    @Test("""
@spec CHAN-4.3: If the `claude` CLI is not present on PATH (including the augmented PATH that includes `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin`), the application shall log the absence and skip the install. Channel events simply won't reach a session until Claude Code is installed.
""", .disabled("not yet implemented"))
    func chan_4_3() async throws { }

    @Test("""
@spec CHAN-4.4: If the bundled Graftty CLI binary is not present at the expected path (e.g. when running from `swift run`), the application shall log and skip the install rather than registering an entry pointing at a nonexistent binary.
""", .disabled("not yet implemented"))
    func chan_4_4() async throws { }

    @Test("""
@spec CHAN-4.5: On app launch, the application shall remove any leftover `~/.claude/plugins/graftty-channel/` directory from prior versions (plugin-wrapper shape) **and** any leftover `~/.claude/.mcp.json` file written by prior versions that used the hand-rolled-JSON installer shape. Both removals shall be no-ops when the target is absent, and the `.mcp.json` cleanup shall only fire when the file's contents exactly match the old installer's output (to avoid deleting a file the user has repurposed manually).
""", .disabled("not yet implemented"))
    func chan_4_5() async throws { }

    @Test("""
@spec CHAN-5.1: When `PRStatusStore` detects a PR state transition (`open` ↔ `merged`), the application shall fire a `type=pr_state_changed` channel event for that worktree carrying `from`, `to`, `pr_number`, `pr_url`, `provider`, `repo`, `worktree`, and `pr_title` attributes.
""", .disabled("not yet implemented"))
    func chan_5_1() async throws { }

    @Test("""
@spec CHAN-5.2: When `PRStatusStore` detects a CI conclusion change for a tracked PR, the application shall fire a `type=ci_conclusion_changed` channel event for that worktree carrying `from`, `to`, `pr_number`, `pr_url`, `provider`, `repo`, and `worktree` attributes.
""", .disabled("not yet implemented"))
    func chan_5_2() async throws { }

    @Test("""
@spec CHAN-5.3: Events shall not be fired for idempotent polls where `previous == current` (same `PRInfo` seen twice).
""", .disabled("not yet implemented"))
    func chan_5_3() async throws { }

    @Test("""
@spec CHAN-5.4: Events shall not be fired on initial discovery of a PR for a worktree (when `previous == nil`) — a transition requires a previous state to transition FROM.
""", .disabled("not yet implemented"))
    func chan_5_4() async throws { }

    @Test("""
@spec CHAN-5.5: The `provider` attribute shall be the lowercase raw string of the hosting provider (`github` or `gitlab`), and the `repo` attribute shall be the `owner/name` slug of the repository.
""", .disabled("not yet implemented"))
    func chan_5_5() async throws { }

    @Test("""
@spec CHAN-6.1: When the user edits the channels prompt in the Settings pane, the application shall observe the change via KVO on `UserDefaults.channelPrompt` and, after a 500ms debounce, invoke `ChannelRouter.broadcastInstructions()` to fan the current prompt out to every connected subscriber.
""", .disabled("not yet implemented"))
    func chan_6_1() async throws { }

    @Test("""
@spec CHAN-6.2: The debounce shall coalesce rapid edits into a single broadcast per settled edit — successive keystrokes within the 500ms window shall reset the timer rather than each scheduling their own broadcast.
""", .disabled("not yet implemented"))
    func chan_6_2() async throws { }

    @Test("""
@spec CHAN-7.1: If the `graftty mcp-channel` subprocess fails to resolve the worktree at startup (CWD is not inside a tracked Graftty worktree), the subprocess shall emit exactly one `notifications/claude/channel` event with `meta.type = "channel_error"` on stdout, then exit with status 1.
""", .disabled("not yet implemented"))
    func chan_7_1() async throws { }

    @Test("""
@spec CHAN-7.2: If the `graftty mcp-channel` subprocess cannot connect to the channels socket at startup, the subprocess shall emit exactly one `channel_error` event and exit with status 1.
""", .disabled("not yet implemented"))
    func chan_7_2() async throws { }

    @Test("""
@spec CHAN-7.3: If the channels socket closes after a `graftty mcp-channel` subprocess has subscribed (Graftty quit, socket torn down), the subprocess shall emit one final `channel_error` event and exit cleanly.
""", .disabled("not yet implemented"))
    func chan_7_3() async throws { }

    @Test("""
@spec CHAN-7.4: When a `PRStatusStore` fetch fails (network error, rate limit, expired auth), no channel event shall be sent to any subscriber for that polling cycle. Failure is silent from the channel's perspective; only successful state-change detections fire events.
""", .disabled("not yet implemented"))
    func chan_7_4() async throws { }

    @Test("""
@spec CHAN-8.1: The channels socket shall be located at `<ApplicationSupport>/Graftty/graftty-channels.sock` by default, overridable via the `GRAFTTY_CHANNELS_SOCK` environment variable (empty-string values shall fall back to the default, matching the control socket's semantics).
""", .disabled("not yet implemented"))
    func chan_8_1() async throws { }
}
