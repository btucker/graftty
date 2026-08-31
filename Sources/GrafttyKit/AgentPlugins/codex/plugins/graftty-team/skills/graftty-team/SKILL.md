---
name: graftty-team
description: Coordinate coding agents through Graftty worktrees, canonical addresses, messages, rosters, and durable GRAFTTY.md instructions. Use whenever Graftty team context, worktree messages, peer-agent forwarding, agent rosters, instruction files, or graftty team commands are involved.
---

# Graftty Team

Use Graftty's durable team inbox as the provider-neutral bridge between Codex and Claude agents.

## Inspect the roster

Run `graftty team list --json` before choosing among multiple agents. Read the hierarchy as repository → worktree → top-level agent → pane.

Treat canonical addresses as routing identities:

- A worktree name or canonical path selects the earliest reachable top-level agent in that worktree.
- `<canonical-worktree-path>#<runtime>` targets that provider without pinning one session, so the message remains queued while its agent is between turns.
- `<canonical-worktree-path>#<runtime>-<12hex>` selects only that exact agent and fails closed if it is gone.
- Copy exact addresses from `graftty team list --json`; do not construct them from display names.
- Native provider sender labels are display metadata and may be truncated. Never route by them.
- Native subagents are not independently routable.

## Delegate work into a new worktree

Proactively delegate a concrete, bounded task when it can run independently and useful parent work can continue. Do not delegate a tiny task, a sequential dependency, or work likely to edit the same files. If a suitable agent already exists, send the task to that agent instead of creating another worktree.

`graftty worktree add <name>` alone creates a worktree for the current agent. It does not delegate the task. A real handoff launches a new top-level agent and gives that agent the task in its first prompt:

```sh
graftty worktree add <name> --agent <codex|claude> --prompt-stdin <<'GRAFTTY_DELEGATE_7F3A91C2'
Objective: <one bounded outcome>
Owned scope: <files or subsystem the child may change>
Verify: <tests or checks to run>
Return: send the result, changed paths, verification, and commit hash to <parent-exact-address> with graftty team send --stdin.
GRAFTTY_DELEGATE_7F3A91C2
```

Before creating the child, run `graftty team list --json` and copy the parent's exact canonical address into the prompt. Use a fresh heredoc delimiter. Use `--base <ref>` when the child needs a start point other than the repository default branch or `HEAD`.

If the handoff stays within the repository work the user requested, treat worktree and agent creation as a normal implementation step. Do not ask for confirmation only because you are delegating. A child agent does not grant new authority. Ask before any action that the parent could not already take within the user's request.

After the command returns, save the delegated worktree's stable address. Stop working on the delegated scope in the parent worktree. Do not change into the child worktree or implement the child's task yourself. Continue only with separate work, then review and integrate the child's result when it replies.

## Send and reply

Send bodies through stdin, never as shell arguments. Use a fresh quoted high-entropy heredoc delimiter that does not occur in the body:

```sh
graftty team send --stdin '<address>' <<'GRAFTTY_7F3A91C2'
<message>
GRAFTTY_7F3A91C2
```

The positional `<address>` accepts a worktree path for its default agent, `<canonical-worktree-path>#<runtime>` for the next agent of one provider, or `<canonical-worktree-path>#<runtime>-<12hex>` for one exact live agent.

Agent-authored messages use `<graftty-peer-message agent="<exact-address>" fallback-agent="<runtime-address>">`. If the exact sender is listed with `is_reachable: true` in `graftty team list --json`, reply by passing `agent` unchanged to `graftty team send --stdin`. Otherwise pass `fallback-agent` unchanged; the reply will wait durably for the provider's next agent.

Do not use provider-native agent messaging tools such as `SendMessage` or `ListAgents` for Graftty addresses. Those tools use a separate roster, and their native sender label is not a canonical Graftty route. Senders named for an SCM (e.g. GitHub) or `Graftty team` are automated notices with no reply target.

If a message asks for a different agent in the same worktree, or that agent is better placed to act, inspect the roster and forward to its canonical address. State that you forwarded it; do not impersonate the other agent.

Use `graftty team broadcast --stdin` only when every other worktree genuinely needs the message.

## Durable agent instructions

Use Graftty instruction files for durable role or workflow guidance that should reach later agent sessions:

- `.graftty/GRAFTTY.md` applies to every worktree in the repository.
- For worktree key `<parent>/<leaf>`, use `.graftty/<parent>/<leaf>/GRAFTTY.md`. The stack also includes `.graftty/<parent>/GRAFTTY.md`; each file applies to its matching worktree key and descendants.
- Text above the first `## Private` heading is shared with peer agents as role context. Text below it is delivered only to matching worktrees.
- For each relative path, Graftty uses the first readable regular file from Application Support, the current worktree, then the main checkout. It reads current filesystem bytes, so staging or committing is not required.
- Graftty resolves and injects applicable content at the next session start; an edit does not update an already-running agent.
- Keep instruction files concise. Suggest one when durable team structure would help, but create or modify one only when authorized.

## Transport

Always use `graftty team` for cross-provider or cross-worktree coordination. Do not create channel files or depend on provider display names.

### Sandboxed control socket access

Some agent sandboxes block Unix-domain socket connections outside the workspace. If `graftty team` reports `EPERM` or `errno 1`:

1. Use read-only checks to confirm `$GRAFTTY_SOCK` exists and a Graftty process owns or listens on it.
2. Request narrowly scoped elevated permission and retry the same `graftty team` command outside the sandbox.
3. Do not delete or recreate the socket, change its permissions, or restart Graftty as a first response.

If the elevated retry still fails, continue normal Graftty socket diagnosis. Treat timeouts and connection-refused errors as different failure modes rather than assuming they are sandbox denials.

Claude native peer sockets and Codex app-server co-clients are transport details owned by Graftty. If native delivery is unavailable, leave the durable inbox row for retry or compatibility fallback.
