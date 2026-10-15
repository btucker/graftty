---
name: graftty-team
description: Coordinate Graftty agents through rosters, messages, delegated worktrees, durable roles, and GRAFTTY.md instructions.
---

# Graftty team

Run commands from your tracked worktree. Use `graftty team` across providers and worktrees; provider-native messaging uses a different roster. Consult subcommand `--help` for version mismatches. Wrappers and hooks own registration.

## Choose socket permissions first

In Codex with restricted network access, use `sandbox_permissions: "require_escalated"` before the first control-socket command, including `graftty team list --json`. Keep each request scoped to the authorized command and separate from unrelated shell work. Use only command-specific reusable prefixes, never a blanket `graftty` rule.

Keep this execution mode for subsequent control-socket commands. Do not repeat a known denial, change provider sandbox configuration, or enable general networking. If escalation is unavailable or denied, report the limitation and continue independent work. A readable socket or filesystem write grant does not grant connection access.

Team, pane, worktree, image, open, and other app-control commands use the socket. `graftty attention report --stdin`, help, and local-only commands do not need socket permission. Providers that already permit the socket need no elevation. For EPERM, errno 1, or connection failures, read [socket diagnosis](references/socket-diagnosis.md).

## Find a recipient

Run `graftty team list --json`. In `members[]`, identify `name` and `worktree_path`; in `agents[]`, copy `address` and check `runtime` and `is_reachable`. Worktree `is_running` and pinned status do not establish reachability.

| Address | Destination |
| --- | --- |
| Worktree name or canonical path | Earliest reachable top-level agent there |
| `<canonical-worktree-path>#<runtime>` | Provider, with messages queued between sessions |
| `<canonical-worktree-path>#<runtime>-<12hex>` | Exact agent; fails closed when gone |

Never route by provider display labels, which may be truncated. Native subagents have no independent Graftty address. Prefer a suitable existing agent, including a pinned agent whose shared role covers the task.

For another repository, Mac, legacy message envelope, or native reply socket, read [routing details](references/routing.md).

## Send and receive

Send bodies through stdin, never shell arguments. Generate a fresh quoted heredoc delimiter absent from the body:

```sh
graftty team send --stdin '<address>' <<'GRAFTTY_7F3A91C2'
<context, requested result, and reply address>
GRAFTTY_7F3A91C2
```

`graftty team broadcast --stdin` uses the same pattern with no recipient. Use it only when every other worktree needs the message. Both commands accept `--urgent` for delivery at the next post-tool hook boundary. Success means accepted, not answered. Do not resend after uncertain delivery.

Reply with the message's supplied ID:

```sh
graftty team reply '<message-id>' --stdin <<'GRAFTTY_REPLY_5D9A7C21'
<reply>
GRAFTTY_REPLY_5D9A7C21
```

The stored sender overrides reply paths in the body. Use `--fallback` only after an explicit exact-agent-unavailable error to queue for that sender's provider on the same Mac.

Replies arrive through hooks; do not poll for completion. For deliberate inspection:

| Command | Effect |
| --- | --- |
| `graftty team inbox --keep-unread --json` | Peek at unread messages |
| `graftty team inbox --history --json` | Read history without changing delivery state |
| `graftty team inbox --json` | Read unread messages and mark them read |

`--all` fetches every matching page. `--history` and `--keep-unread` are incompatible. `--worktree`, `--repo`, or `--member` selects diagnostic scope and peeks unless `--history` is supplied. Empty output does not establish completion. Never edit state files to advance delivery; rerun the inbox command if advancement fails.

## Delegate a task

Each worktree has exactly one agent. Never create worktrees yourself with `git worktree add`, provider worktree tools, worktree-isolated subagents, or other skills. Subagents sharing your current worktree are allowed.

Delegate bounded independent work while continuing separate work. Avoid tiny or overlapping tasks. Creating a worktree alone does not delegate; launch its agent with the task:

```sh
graftty worktree add <name> --agent <codex|claude> --prompt-stdin <<'GRAFTTY_DELEGATE_7F3A91C2'
Objective: <bounded outcome>
Owned scope: <files or subsystem>
Verify: <checks>
Return: send results, changed paths, validation, and commit hash with graftty team send --stdin.
Parent exact address: <copy from roster>
Parent fallback address: <worktree_path>#<runtime>
Use the exact address while reachable; after restart or /clear, use the fallback.
GRAFTTY_DELEGATE_7F3A91C2
```

Save the operation ID, path, and returned stable reply address. Pause the delegated scope until `graftty team list --json` confirms the child is reachable. Then relinquish that scope until reviewing its result. If launch fails without a reachable child, retain ownership and report the failed handoff. Delegation within the user's repository task needs no separate confirmation and grants no additional authority.

Read only the reference relevant to the operation:

- [Worktree operations](references/worktrees.md): starting refs, existing branches, wait/timeout behavior, remote creation, launch recovery, pane inspection, removal, and reconnecting paired Macs.
- [Durable roles](references/durable-roles.md): pinning, retention, and hierarchical `.graftty/**/GRAFTTY.md` instruction files. Read before creating or changing a role or instruction file.
