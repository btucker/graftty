# Native Claude and Codex messaging prototype

**Date:** 2026-08-10
**Observed Claude Code version:** 2.1.226
**Spec prefix:** `AGENT-6.x`

## Result

Graftty can speak Claude Code's new local peer protocol directly. A live
Graftty-to-Claude smoke test woke an idle Claude session, surfaced the input as
`Message from @peer`, and produced the requested response. A reverse smoke test
used Claude's native `SendMessage` tool to write to a non-Claude Unix listener;
the captured frame decoded through `ClaudePeerProtocol` without any hidden
session state.

The wire protocol is therefore not the blocker to replacing Claude's wrapper.
The implementation now discovers exact sessions from lifecycle hooks, writes
Claude-bound inbox rows directly to the peer socket, and leaves rows unread on
discovery or transport failure.

This differs from the conservative recommendation in
[`peer-sessions`' Codex bridge notes](https://github.com/ray-amjad/peer-sessions/blob/main/references/codex-bridge.md),
which keeps a real Claude relay and warns clients not to write directly to the
socket. The live result proves direct transport is technically possible in
2.1.226; that repository's compatibility warning remains valid because none of
the observed protocol is documented as stable.

## Observed protocol

Claude binds a mode-0600 Unix-domain socket and accepts UTF-8 JSON objects
delimited by newlines. Protocol version 1 user messages have this shape:

```json
{
  "msgV": 1,
  "msg_id": "<uuid>",
  "type": "user",
  "message": {
    "role": "user",
    "content": "<cross-session-message ...>\n<body>\n</cross-session-message>"
  },
  "priority": "next",
  "from": "uds:/path/to/reply.sock"
}
```

There is no application-level handshake or bearer token. Local filesystem
permissions provide the access boundary; Claude also reads Unix peer process
credentials for permission-mode decisions. The server accepts a minimal
`type=user` envelope with a string `message.content`, caps an unterminated
connection buffer at 1 MiB, and treats `session_id` as an optional target check.

The native sender can include `from-mode="prompting"` or `"bypass"`. Graftty
must not invent this field: it has no Claude permission mode to attest. The
consequence is intentional—some bypass-mode recipients may hold a Graftty
message for user approval.

Native delivery-status receipts are `type=control` messages with
`action=peer_message_status`, an `orig_msg_id`, and a status of `held`,
`denied`, `expired`, or `delivered`. Claude sends these receipts only when the
reply socket ends in `.sock` and lives in the same directory as the recipient
Claude socket. A production bridge that wants receipts must account for that
namespace rule.

## Discovery

`claude agents --json` still exposes PID, cwd, session ID, name, kind, and
status, but not the messaging socket. Claude's own registry record does expose
the compatibility fields:

```json
{
  "pid": 89652,
  "sessionId": "...",
  "cwd": "/path/to/worktree",
  "version": "2.1.226",
  "peerProtocol": 1,
  "messagingSocketPath": "/tmp/cc-socks/89652.sock"
}
```

The records live under `~/.claude/sessions/<pid>.json`. Claude verifies both
process liveness and socket liveness before listing a peer. Graftty should do
the same and require `peerProtocol == 1`; it should not assume every record or
future protocol version is compatible.

On the observed build the feature gate can be forced with
`CLAUDE_CODE_HARBOR_KITE=1`, and the hidden
`--messaging-socket-path <path>` option selects an explicit bind path. Neither
is a public compatibility guarantee.

## Prototype surface

- `ClaudePeerProtocol` encodes protocol-v1 messages and decodes frames captured
  from the native `SendMessage` tool.
- `ClaudePeerSocketClient` performs a bounded one-shot Unix-socket write.
- `graftty internal claude-peer-send` is a temporary live-session harness, not
  a supported user command.
- `ClaudePeerMessagingTests` cover exact framing, sender-address encoding,
  closing-tag scrubbing, the captured native frame, limits, and a real local
  Unix-socket write.

## Codex transport result

Codex 0.147 does not expose a socket for a stock TUI. Its app-server runs
in-process over socketpairs, and the official app-server daemon is limited to
the standalone managed distribution and ChatGPT device authentication. A
plugin or skill can install hooks, but it cannot make that private in-process
transport reachable.

The portable Codex transport remains a small launch wrapper:

```text
codex app-server --listen unix://…
codex --remote unix://…
```

The plugin's `SessionStart` hook supplies the exact Codex thread ID. Graftty
binds that ID to the wrapper-created socket and uses a second app-server client
to `thread/read` that exact thread immediately before delivery. An idle thread
receives `turn/start`; an active thread receives `turn/steer` with the observed
`expectedTurnId`. A failed mutation rereads once to close the idle/active race.
Approvals stay with the visible TUI—Graftty never answers them.

## Implemented bridge shape

The bridge now:

1. Installs the same `graftty-team` skill and skill-managed lifecycle hooks as
   native Codex and Claude plugins.
2. Derives stable canonical IDs from native session identity and exposes
   repository → worktree → top-level-agent → pane hierarchy through
   `graftty team list --json`.
3. Defaults an unsuffixed worktree address to its earliest reachable top-level
   agent; an exact `<canonical-worktree-path>#<runtime>-<12hex>` address fails
   closed, while short display names remain convenience input only.
4. Sends Claude-bound rows to `messagingSocketPath` and Codex-bound rows to the
   hook-bound thread through the wrapper-created app server.
5. Keeps `TeamInbox` as the only durable store and advances its shared
   worktree watermark only after the native transport accepts the message.
6. Notifies every reachable top-level agent in a worktree when its roster gains
   an agent, so the default recipient can forward to a better exact recipient.
7. Leaves native subagents out of the address space and wraps every peer body
   in an explicit untrusted-context boundary.

Reply sockets and native delivery receipts remain future work. Agent replies
currently use the skill's exact `graftty team send --stdin` path, which keeps
identity in the durable inbox address rather than trusting model-authored text
inside the native protocol.

## Wrapper-removal boundary

In native mode, the Claude plugin owns lifecycle hooks and the shared skill;
the SessionStart hook discovers and registers Claude's native PID, socket,
display label, worktree, and pane. Graftty removes its managed Claude wrapper.

The Codex plugin likewise owns hooks and instructions, but Codex still needs
the transport-only wrapper described above. Proxy takeover, daemon discovery,
consent, restoration, and PID-correlation machinery are intentionally absent:
there is no stock daemon socket to take over. Revisit plugin-only Codex
transport if a future standard Codex distribution exposes the managed daemon
to ordinary local sessions.
