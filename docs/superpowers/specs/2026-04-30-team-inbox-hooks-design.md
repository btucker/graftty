# Team Inbox Hooks - Design Specification

A new Agent Teams foundation that replaces direct, runtime-specific messaging with a shared durable team inbox and per-runtime delivery adapters. Claude channels remain available as the best push adapter for Claude Code, while Claude hooks and Codex hooks use the same inbox and prompt-rendering substrate for boundary-based delivery. The same hook substrate also becomes the reliable source for agent completion notifications: every agent `Stop` means the agent needs user input, posts a desktop notification, and routes notification clicks back to the relevant Graftty worktree.

## Goal

After this ships, this user story works:

> I enable Agent Teams and open three worktrees. Graftty launches Claude and Codex through app-owned wrappers, so both runtimes receive team context without me editing global config. A Codex agent can run `graftty team send main "Can you review this migration?"`; Graftty stores the message in a durable team inbox. If the recipient is a Claude session with channels active, it gets a channel event. If the recipient is a Codex session, urgent messages arrive after tool use and normal messages arrive at Stop. When any agent hits Stop, macOS shows a notification like "Codex needs input - feature-auth is waiting for you." Clicking it activates Graftty and selects that worktree. Selecting the worktree clears the sidebar attention state but does not mark inbox messages read.

## Scope

In scope for v1:

- A shared append-only team inbox backed by JSONL files, with one logical message per addressed recipient.
- Per-session cursors plus a per-worktree delivery watermark, so offline messages are delivered once to the next session without replaying ancient history.
- A revised `graftty team` CLI surface with point-to-point `send`, team-wide `broadcast`, hook adapter commands, and no-ack human diagnostics.
- Claude channel, Claude hook, and Codex hook delivery adapters that consume the same inbox and shared team context renderer.
- Ghostree-style app-owned wrappers for Graftty-launched `claude` and `codex` sessions. Wrappers are the default install path; global hook mutation is explicit opt-in.
- Agent lifecycle/status notifications from hooks, with every `Stop` treated as "needs user input."
- Desktop notification click handling that activates Graftty, selects the relevant worktree, and clears the sidebar attention for that Stop event.

Out of scope for v1:

- Cross-repo teams.
- Sender-side `--blocking` priority. V1 has only `normal` and `urgent`.
- Broadcast to self.
- Automatic classification of urgent messages from free text.
- Marking diagnostic reads as acknowledged by default.
- Replacing Claude channels. Channels become one delivery adapter; they are not the whole team model.
- Supporting non-Graftty-launched external agent sessions by default. Users can opt into global hook install later.

## Architecture

The feature has three layers:

1. `TeamInbox` is the durable substrate. It stores messages, cursors, and worktree watermarks. It does not know how Claude or Codex inject context.
2. `TeamDeliveryAdapter`s render and deliver inbox items into a specific runtime. Claude channels can push. Claude hooks and Codex hooks deliver at hook boundaries.
3. `AgentHookInstaller` owns app-generated wrapper scripts and hook settings used only inside Graftty-launched terminals by default.

```
  agent CLI command              durable core                     delivery adapters
  ----------------              ------------                     -----------------

  graftty team send main  ->  TeamInbox JSONL  ->  Claude channel event
                         ->  session cursors  ->  Claude hook JSON
                         ->  wt watermark     ->  Codex hook JSON

  Claude/Codex Stop hook  ->  AgentStatusStore -> desktop notification
                                              -> sidebar attention
                                              -> notification click selects worktree
```

This intentionally separates "message exists" from "this runtime saw it." A message can be delivered through a channel adapter, a hook adapter, or both, without changing the CLI or storage model.

## Data Model

### Team Inbox Files

Each team gets one append-only JSONL file:

`<Application Support>/Graftty/team-inbox/<team-id>/messages.jsonl`

Each line is one addressed message:

```json
{
  "id": "01HX...",
  "batch_id": "01HY...",
  "created_at": "2026-04-30T15:30:00Z",
  "team": "acme-web",
  "repo_path": "/repos/acme-web",
  "from": {
    "member": "feature-auth",
    "worktree": "/repos/acme-web/.worktrees/feature-auth",
    "runtime": "codex"
  },
  "to": {
    "member": "main",
    "worktree": "/repos/acme-web"
  },
  "priority": "normal",
  "kind": "team_message",
  "body": "Can you check the migration before I proceed?"
}
```

`id` must be monotonic-sortable. `batch_id` is present for broadcasts and absent or equal to `id` for point-to-point sends. The body is always rendered as untrusted peer content when injected into an agent.

### Cursors And Watermarks

Session cursors live separately:

`<team-id>/cursors/<session-id>.json`

```json
{
  "session_id": "codex:feature-auth:019e...",
  "worktree": "/repos/acme-web/.worktrees/feature-auth",
  "runtime": "codex",
  "last_seen_id": "01HX..."
}
```

Each worktree also has a delivery watermark:

`<team-id>/worktrees/<worktree-id>.json`

```json
{
  "worktree": "/repos/acme-web/.worktrees/feature-auth",
  "last_delivered_to_any_session_id": "01HX..."
}
```

New sessions initialize from the worktree watermark, not from "now." This preserves offline delivery: a message sent while a worktree has no running agent is delivered to the next session once. Existing live sessions continue to use their own session cursor; the worktree watermark is only used to initialize new sessions and prevent old replay.

## CLI Surface

Agent-facing commands:

```text
graftty team send [--urgent] [--stdin] <member> [message]
graftty team broadcast [--urgent] [--stdin] [message]
graftty team members
```

`send` is point-to-point. `broadcast` expands to one addressed message per teammate, excluding the sender, with a shared `batch_id`. Any teammate may broadcast in v1.

Hook adapter commands:

```text
graftty team hook codex session-start
graftty team hook codex post-tool-use
graftty team hook codex stop
graftty team hook claude session-start
graftty team hook claude post-tool-use
graftty team hook claude stop
```

Hook commands resolve the current worktree/session, render runtime-specific hook JSON, deliver any eligible messages, and advance only the relevant session cursor after successful emission.

Human diagnostics:

```text
graftty team inbox [--worktree <path|member>] [--repo <path>] [--member <name>] [--unread] [--all] [--json]
graftty team tail [--worktree <path|member>] [--repo <path>] [--member <name>] [--follow] [--json]
graftty team sessions [--worktree <path|member>] [--repo <path>] [--json]
graftty team members [--worktree <path|member>] [--repo <path>] [--json]
```

Diagnostic commands accept `--worktree` and `--repo` because humans should not have to `cd` into a worktree to inspect it. If omitted, they fall back to the current directory's tracked worktree. Diagnostic reads never advance session cursors or worktree watermarks.

## Delivery Semantics

### Shared Prompt Rendering

The existing Agent Teams prompt logic is split into two concepts:

- Session context: stable team identity, role, peers, and available commands. Delivered on session start/resume.
- Message context: guidance wrapped around dynamic inbox messages. Delivered at channel/hook boundaries.

Team messages are never rendered as system or user instructions. They are explicitly labeled as untrusted peer content.

### Codex Hook Adapter

- `SessionStart`: injects team session context.
- `PostToolUse`: injects unread `urgent` messages only. The text says the messages are unrelated to the just-finished tool result and that the agent should continue current work unless directly blocked.
- `Stop`: injects unread `normal` messages plus any remaining urgent messages. Stop also reports agent status as `needs_input` and posts a desktop notification.

### Claude Hook Adapter

Claude hooks use the same delivery policy as Codex hooks, but render Claude's hook JSON shape.

### Claude Channel Adapter

Claude channels remain the preferred Claude delivery mechanism when available. Session context is delivered through MCP instructions or the existing `instructions` event. Inbox messages are delivered as channel events. Normal messages still include guidance not to interrupt current work unless relevant.

## Hook Installation

Graftty follows Ghostree's wrapper pattern for Graftty-launched panes:

- Generate app-owned assets under `<Application Support>/Graftty/agent-hooks/`.
- Generate wrapper executables in `<Application Support>/Graftty/agent-hooks/bin/claude` and `.../codex`.
- Prepend that bin directory to the pane `PATH` only inside Graftty terminals.
- Wrappers find the real binary by searching `PATH` while skipping the wrapper directory.
- Generated files contain markers and version strings so they can be idempotently repaired.
- `GRAFTTY_DISABLE_AGENT_HOOKS=1` disables wrapper/hook injection.

The Claude wrapper can use an app-owned generated settings file and launch real Claude with `--settings <path>`, matching Ghostree's approach. The generated settings file contains only Graftty hooks.

The Codex wrapper should use the most isolated supported Codex hook configuration surface available at implementation time. If Codex supports an app-owned hook config path or CLI config override for hook definitions, the wrapper uses that. If not, Graftty provides an explicit user-level installer instead of silently mutating global config.

Explicit global install remains available:

```text
graftty team hooks status
graftty team hooks install [--runtime codex|claude|all] [--scope user]
graftty team hooks uninstall [--runtime codex|claude|all] [--scope user]
graftty team hooks repair
```

Global install parses and merges JSON/TOML, preserves unrelated settings, creates backups before first mutation, and removes only Graftty-owned hook entries on uninstall.

## Agent Status And Notifications

Every `Stop` hook means the agent needs user input.

On Stop:

1. Set the agent status for the worktree/session to `needs_input`.
2. Set or refresh a sidebar attention badge for the worktree.
3. Post a desktop notification.
4. Deliver normal inbox messages through the hook response.

Notification content:

```text
title: Codex needs input
body:  feature-auth is waiting for you.
```

Notification payload:

```json
{
  "kind": "agent_stop",
  "runtime": "codex",
  "worktree_path": "/repo/.worktrees/feature-auth",
  "session_id": "codex:feature-auth:019e...",
  "attention_timestamp": "2026-04-30T15:30:00Z"
}
```

Click behavior:

1. Activate Graftty.
2. Bring the main window forward.
3. Set `appState.selectedWorktreePath` to `worktree_path`.
4. Focus the worktree's recorded focused pane, or the first pane if none is recorded.
5. Clear the sidebar attention for that worktree if its timestamp still matches the clicked notification.

Any user action that selects the worktree also acknowledges the current `needs_input` attention state. This includes clicking the worktree row, keyboard/sidebar navigation, and clicking the desktop notification. Acknowledgement does not advance inbox cursors and does not mark messages read. A later Stop event carries a new timestamp and must not be cleared by an old click.

This should be implemented with a new app-level notification service rather than the existing terminal desktop notification helper, because agent notifications need `userInfo` and click routing.

## Error Handling

- Hook commands must be fast and silent outside tracked Graftty team worktrees.
- If Graftty is not running, hook commands return no model context and do not block the agent.
- If the inbox JSONL contains a corrupt line, the reader skips that line, logs a diagnostic, and continues.
- If cursor writes fail after message emission, the adapter logs the failure; duplicate delivery is safer than message loss.
- If desktop notification authorization is denied, sidebar attention still records `needs_input`.

## Testing

Unit tests:

- `TeamInbox` appends and reads messages in monotonic order.
- `broadcast` writes one addressed message per teammate with one shared `batch_id`.
- Session cursor and worktree watermark initialization preserve offline delivery.
- Diagnostic reads do not mutate cursors or watermarks.
- Hook renderers label peer messages as untrusted content.
- Stop notifications build the expected `userInfo` payload.
- Attention acknowledgement clears only matching timestamps.

Integration tests:

- `graftty team send` from one worktree is delivered to another session through the selected adapter.
- `PostToolUse` delivers urgent messages only.
- `Stop` delivers normal messages, sets `needs_input`, and triggers notification dispatch.
- Wrapper generation is idempotent and repairs stale versions.
- Global hook installer preserves unrelated user hooks and uninstalls only Graftty entries.

Manual smoke tests:

1. Launch Codex in a Graftty worktree and verify SessionStart injects team context.
2. Send a normal message to that worktree, wait for Stop, and verify the message arrives then.
3. Send an urgent message while Codex is actively using tools and verify PostToolUse delivery.
4. Verify every Stop posts a desktop notification.
5. Click the notification and verify Graftty selects the target worktree and clears sidebar attention.

## Risks And Questions

- Codex hook configuration may not support app-owned per-launch settings as cleanly as Claude's `--settings` path. If so, Graftty should keep wrapper install for Claude and require explicit global Codex hook install until Codex exposes a safer per-launch hook config.
- Claude channels and Claude hooks can both be installed. The design must prevent duplicate message delivery to the same live Claude session by giving each adapter a distinct session identity and enabling only one delivery adapter per runtime session by default.
- Stop frequency may be higher than users expect. The chosen product rule is explicit: every Stop means the agent needs input and should notify.
- Broadcast can create noise. V1 excludes the sender and has no broadcast-to-self option.

