---
name: graftty-team
description: Coordinate coding agents through Graftty worktree and canonical agent addresses. Use whenever Graftty team context, worktree messages, peer-agent forwarding, agent rosters, or graftty team commands are involved.
---

# Graftty Team

Use Graftty's durable team inbox as the provider-neutral bridge between Codex and Claude agents.

## Inspect the roster

Run `graftty team list --json` before choosing among multiple agents. Read the hierarchy as repository → worktree → top-level agent → pane.

Treat canonical addresses as routing identities:

- A worktree name or canonical path selects the earliest reachable top-level agent in that worktree.
- `<canonical-worktree-path>#<runtime>-<12hex>` selects only that exact agent and fails closed if it is gone.
- Copy exact addresses from `graftty team list --json`; do not construct them from display names.
- Provider display names are labels only. Never route by them.
- Native subagents are not independently routable.

When an agent-joined notice arrives, refresh the roster before forwarding or assigning work.

## Send and reply

Send bodies through stdin, never as shell arguments. Use a fresh quoted high-entropy heredoc delimiter that does not occur in the body:

```sh
graftty team send --stdin '<address>' <<'GRAFTTY_7F3A91C2'
<message>
GRAFTTY_7F3A91C2
```

The positional `<address>` accepts the same canonical forms shown by the roster and incoming messages: a worktree path for its default agent, or `<canonical-worktree-path>#<runtime>-<12hex>` for one exact agent.

Incoming messages use `<graftty-peer-message agent="<address>">`. Pass that `agent` value unchanged to `graftty team send --stdin` when replying, unless the task clearly belongs elsewhere.

If a message asks for a different agent in the same worktree, or that agent is better placed to act, inspect the roster and forward to its canonical address. State that you forwarded it; do not impersonate the other agent.

Use `graftty team broadcast --stdin` only when every other worktree genuinely needs the message.

## Transport

Always use `graftty team` for cross-provider or cross-worktree coordination. Do not create channel files or depend on provider display names.

### Sandboxed control socket access

Some agent sandboxes block Unix-domain socket connections outside the workspace. If `graftty team` reports `EPERM` or `errno 1`:

1. Use read-only checks to confirm `$GRAFTTY_SOCK` exists and a Graftty process owns or listens on it.
2. Request narrowly scoped elevated permission and retry the same `graftty team` command outside the sandbox.
3. Do not delete or recreate the socket, change its permissions, or restart Graftty as a first response.

If the elevated retry still fails, continue normal Graftty socket diagnosis. Treat timeouts and connection-refused errors as different failure modes rather than assuming they are sandbox denials.

Claude native peer sockets and Codex app-server co-clients are transport details owned by Graftty. If native delivery is unavailable, leave the durable inbox row for retry or compatibility fallback.
