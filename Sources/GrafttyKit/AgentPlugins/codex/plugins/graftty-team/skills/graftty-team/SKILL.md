---
name: graftty-team
description: Use whenever the user asks to delegate work to agents, ask another agent a question, or coordinate agents, even without mentioning Graftty. Also use for Graftty team commands, rosters, worktree messages, peer forwarding, or durable GRAFTTY.md instructions.
---

# Graftty Team

Coordinate Codex and Claude agents through Graftty's durable inbox. Run team commands from the calling agent's tracked worktree. Use these commands directly; consult subcommand `--help` for undocumented options or installed-version mismatches.

## Inspect the roster

Run `graftty team list --json` before choosing an agent. In `members[]`, use `name` and `worktree_path` to identify the worktree, then `agents[]` for each agent's `address`, `runtime`, and `is_reachable`. Worktree `is_running` alone does not establish agent reachability.

To inspect another team, use `graftty team members --worktree '<absolute-worktree-path>' --json`. For roster and inbox diagnostics, `--repo` filters repositories but does not override a tracked caller; use `--worktree` to select a different repository's worktree.

Treat canonical addresses as routing identities:

- A worktree name or canonical path selects the earliest reachable top-level agent in that worktree.
- `<canonical-worktree-path>#<runtime>` targets that provider without pinning one session, so the message remains queued while its agent is between turns.
- `<canonical-worktree-path>#<runtime>-<12hex>` selects only that exact agent and fails closed if it is gone.
- Copy exact addresses from the roster. Native provider sender labels are display metadata and may be truncated. Never route by them.
- Native subagents are not independently routable.

Send existing agents questions or tasks with context, the requested result, and your reply address. A question alone does not require a new worktree.

## Delegate work into a new worktree

Proactively delegate bounded, independent work while continuing useful parent work. Avoid tiny, sequential, or overlapping tasks. Prefer a suitable existing agent.

`graftty worktree add <name>` alone does not delegate the task. Launch a top-level agent with its task in the first prompt:

```sh
graftty worktree add <name> --agent <codex|claude> --prompt-stdin <<'GRAFTTY_DELEGATE_7F3A91C2'
Objective: <one bounded outcome>
Owned scope: <files or subsystem the child may change>
Verify: <tests or checks to run>
Return: send the result, changed paths, verification, and commit hash with graftty team send --stdin.
Parent exact address: <parent-exact-address>
Parent fallback address: <parent-runtime-address>
Use the exact address while it is reachable. After a restart or /clear, use the fallback address.
GRAFTTY_DELEGATE_7F3A91C2
```

Before launch, copy the parent's exact canonical address from the roster's `address` field. Form the fallback from its `worktree_path` and `runtime`. Include both as above and use a fresh quoted heredoc delimiter absent from the prompt.

Choose worktree options as needed:

- `--base <ref>` selects a locally resolvable starting revision. Default: repository default branch or `HEAD`. `--base HEAD` uses the caller's current commit, without uncommitted changes.
- `--branch <branch>` overrides the normalized worktree name as the branch name.
- `--branch <branch> --existing` uses an existing local branch in a **new directory**. It neither reopens a directory nor restarts an agent. Incompatible with `--base`.
- `--prompt-stdin` requires `--agent codex` or `--agent claude`; incompatible with `--prompt`.
- `--timeout <seconds>` waits for Git hooks and pane creation, not task completion. Default: 300; must be positive.

Delegation within the user's requested repository work needs no separate confirmation. A child agent does not grant new authority.

Save the returned `created worktree=... address=...`. Pause the delegated scope and use `graftty team list --json` to confirm that a top-level child is reachable there. Once reachable, stop working on that scope and continue only separate work until reviewing and integrating its reply. If launch fails with no reachable child, retain ownership and report the failed handoff.

### Create a worktree on another Mac

Add `--remote '<Mac-name-or-device-ID>'` to the delegation command above. This works in either direction over an active control connection. Both Macs need a Graftty version that supports remote creation.

The destination project defaults to the caller's Git `origin`, regardless of local names or paths. Equivalent GitHub and GitLab SSH and HTTPS URLs match. Both projects must be tracked in Graftty. For another project, a missing origin, or multiple matches, add `--project '<destination-name-or-absolute-repository-path>'`. This override also works outside a local worktree.

Branches and `--base` resolve on the destination. `--base HEAD` uses its main checkout. Local commits, edits, and instruction files are not transferred.

From a tracked local worktree, send a follow-up with `graftty team send --stdin '<returned-address>'`, preserving the full `graftty-mac://...` address. This gives the child your cross-Mac reply address for `graftty team reply`. Your local roster paths cannot route replies across Macs.

After a timeout or lost acknowledgement, inspect the destination's roster and worktrees before retrying. The original creation may still finish.

### Recover a failed launch or use an existing worktree

After a creation error or timeout, inspect `git worktree list` and the Graftty roster before retrying. Failed hooks can leave directories behind. Do not recreate or automatically delete them. If Git lists a worktree that Graftty does not, diagnose registration first.

Open and select the target worktree in Graftty first; a new pane's shell waits for its first visible layout. If it has no suitable agent and new panes have no automatic default command, launch one:

```sh
graftty pane add '<worktree-name>' --command 'codex -- "Check Graftty messages, then report ready for a task."'
```

For Claude, replace `codex` with `claude`, keeping the initial prompt so a completed turn activates fallback inbox delivery. `pane add` takes a worktree name and has no `--agent` or `--prompt-stdin`. Confirm reachability, then send the task with `team send --stdin`.

Inspect output with `graftty pane list '<worktree-name>'`, then `graftty pane show '<worktree-name>:<id>' --lines 100`, using its 1-based pane ID. Use `team send` for messages; `pane send` types into the terminal and presses Return by default.

## Send and reply

Send bodies through stdin, never as shell arguments. Use a fresh quoted high-entropy heredoc delimiter that does not occur in the body:

```sh
graftty team send --stdin '<address>' <<'GRAFTTY_7F3A91C2'
<message>
GRAFTTY_7F3A91C2
```

The recipient is positional. For a file body, use `graftty team send --stdin '<address>' < /tmp/agent-task.txt`. Bodies must be non-empty. `--urgent` requests delivery at the next post-tool hook boundary. Success means accepted for delivery, not answered or completed.

Reply using the message ID supplied with the delivered message:

```sh
graftty team reply '<message-id>' --stdin <<'GRAFTTY_REPLY_5D9A7C21'
<reply>
GRAFTTY_REPLY_5D9A7C21
```

Graftty resolves the original sender from the stored message, preserving its Mac and exact agent. This destination takes precedence over conflicting reply paths in the message body. After an explicit exact-agent-unavailable error, add `--fallback` to queue for the original sender's provider on the same Mac. Do not retry a send that reports uncertain delivery.

Older messages use `<graftty-peer-message agent="<exact-address>" fallback-agent="<runtime-address>">` without a reply command. Reply to `agent` unchanged if the roster shows it reachable; otherwise use `fallback-agent` unchanged to queue for that provider's next agent. Preserve the full `graftty-mac://` prefix for remote addresses. A bare filesystem path targets the Mac where the command runs.

`<graftty-forge-message provider="<provider>">` and `<graftty-system-message>` are notices, not peer reply addresses. For a CI failure notice, use the bundled `graftty-ci` skill to check the live PR run before acting.

Do not use provider-native agent messaging tools such as `SendMessage` or `ListAgents` to resolve Graftty recipients by name; they use a separate roster. Identically named worktrees on two Macs can contain different agents. Native delivery success to a name does not establish delivery to the intended Graftty address. If a native message includes an explicit Graftty reply socket, replying directly to that socket preserves the original sender; do not substitute a display name.

Forward misdirected messages to the correct roster address and say you forwarded them. Do not impersonate another agent.

`graftty team broadcast --stdin` uses the same body pattern, accepts `--urgent`, and takes no recipient. Use it only when every other worktree needs the message.

## Receive replies and inspect history

Replies arrive automatically through hooks; do not poll for completion. For deliberate inspection:

- `graftty team inbox --keep-unread --json` peeks at unread messages.
- `graftty team inbox --history --json` reads history without changing delivery state.
- `graftty team inbox --json` reads unread messages and marks them read. Empty output does not mean a task finished.
- `--all` fetches every matching page. `--history` and `--keep-unread` are incompatible.
- `--worktree '<path-or-name>'`, `--repo '<repo-path>'`, or `--member '<name>'` selects diagnostic scope and peeks unless `--history` is supplied.

## Durable agent instructions

Use these files for durable role or workflow guidance:

- `.graftty/GRAFTTY.md` applies to every worktree in the repository.
- Worktree key `<parent>/<leaf>` reads `.graftty/<parent>/GRAFTTY.md` and `.graftty/<parent>/<leaf>/GRAFTTY.md`. Each applies to its key and descendants.
- Text above `## Private` is shared with peers as role context; text below reaches only matching worktrees.
- For each relative path, the first readable regular file wins: Application Support, current worktree, then main checkout. Current bytes apply at the next session start; no commit is required.
- Keep files concise. Create or modify them only when authorized.

## Transport

Always use `graftty team` across providers or worktrees. Do not create channel files.

### Reconnect a paired Remote Mac

For a disconnected or stale connection, run `graftty remote reconnect '<host-name-or-id>'` on the viewing Mac. From a shell on the host Mac, use `graftty remote reconnect-client '<viewer-name-or-id>'` instead; this requires a working control channel and support on both Macs. Use exact paired names or device IDs. Targeting errors list connected viewers.

Graftty must be running; no current worktree is required. Success acknowledges the request; check the viewing Mac's Remote Macs sidebar for status. Pair again in the app if required. Reconnect does not resend messages; preserve queued messages and do not resend after uncertain delivery.

### Sandboxed control socket access

If a sandboxed `graftty team` command reports `EPERM` or `errno 1`:

1. Use read-only checks to confirm `$GRAFTTY_SOCK` exists and a Graftty process owns or listens on it.
2. Request narrowly scoped elevated permission and retry the same `graftty team` command outside the sandbox.
3. Do not delete or recreate the socket, change its permissions, or restart Graftty as a first response.

If retry fails, continue socket diagnosis. Timeouts and connection-refused errors do not establish sandbox denial. Graftty owns native transports; leave queued messages for retry or compatibility fallback when native delivery is unavailable.
