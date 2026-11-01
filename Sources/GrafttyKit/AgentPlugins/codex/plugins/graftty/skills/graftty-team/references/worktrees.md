# Worktree operations

## Creation options

Use `graftty agent add <name> --prompt-stdin --json` to create a worktree and its agent, or pass `--worktree <existing-name-or-path>` to add an agent to a tracked checkout.

- `--provider claude|codex` overrides the destination host's Default agent. Without either choice, launch fails with a provider-selection message.
- `--base <ref>` selects the new branch's starting revision. It is incompatible with `--worktree`; `--base HEAD` includes committed changes only.
- `--prompt-stdin` conflicts with `--prompt`. Use stdin for dynamic task text.
- Creation is asynchronous. `--wait` waits for a new worktree to accept the launch, not for task completion.
- `--timeout <seconds>` bounds `--wait`, defaults to 300, and does not cancel accepted creation.
- The JSON response retains the managed identity, assignment ID, operation ID, and worktree. Use `graftty worktree status <operation-id>` for a new worktree's Git/hook progress.

The initial task is retained in the managed record for recovery. Confirm native-agent reachability before relinquishing the delegated scope. Use `graftty agent finish` and the parent's explicit `graftty agent close --completion` for assignment cleanup, as described in the [team skill](../SKILL.md).

The lower-level `graftty worktree add` remains available for explicit branch selection with `--branch` and `--existing`. `graftty pane add --command` creates an ordinary terminal running a specified shell line. These commands are not the preferred agent-creation path.

## Another Mac

The compatibility command `graftty worktree add <name> --agent <codex|claude>` accepts `--remote '<Mac-name-or-device-ID>'` over an active control connection. Both Macs must support remote creation and track the project. The destination defaults to the caller's Git origin; equivalent GitHub/GitLab SSH and HTTPS URLs match. Use `--project '<destination-name-or-absolute-repository-path>'` for another project, missing origin, or ambiguous matches, including calls outside a worktree.

Branches and `--base` resolve on the destination; `--base HEAD` uses its main checkout. Local commits, edits, and instructions are not transferred.

From your tracked worktree, send a follow-up to the full returned `graftty-mac://...` address. This gives the child your cross-Mac reply address. Local roster paths cannot route replies across Macs. After timeout or lost acknowledgement, inspect the destination roster and worktrees before retrying.

## Recover launch failures

Inspect `git worktree list` and the roster before retrying creation. Failed hooks may leave directories behind; do not recreate or automatically delete them. Diagnose registration if Git lists a worktree that Graftty does not.

For an existing worktree with no suitable agent, use:

```sh
graftty agent add reviewer --worktree '<worktree-name>' --provider codex --prompt-stdin --json <<'GRAFTTY_AGENT_7F3A91C2'
<task>
GRAFTTY_AGENT_7F3A91C2
```

The host opens a closed worktree as needed. The agent starts even if its views are not selected. Its initial task belongs to its managed record and is not delivered to another agent sharing the same provider. Use the exact native messaging ID after startup.

Inspect with `graftty pane list '<worktree-name>'` and `graftty pane show '<worktree-name>:<id>' --lines 100`, using the 1-based pane ID. `graftty pane send` writes directly to the PTY with no inbox or consent layer and presses Return by default. Run `graftty pane send --help` before using it; use team messages for coordination.

## Remove a worktree

Removal keeps the branch. Pinned targets require `--pinned`; dirty files separately require `--force`. Remove pinned roles only when retiring them is authorized; do not unpin to bypass the guard. The default-branch checkout cannot be removed.

```sh
graftty worktree remove feature-auth
graftty worktree remove release-manager --pinned
```

## Reconnect a paired Mac

On the viewing Mac, run `graftty remote reconnect '<host-name-or-id>'`. From a shell on the host, use `graftty remote reconnect-client '<viewer-name-or-id>'`; this requires a working control channel and support on both Macs. Use exact paired names or device IDs. Targeting errors list connected viewers.

Graftty must be running; a current worktree is unnecessary. Success acknowledges the request. Check the viewing Mac's Remote Hosts sidebar for status and pair again if needed. Preserve queued messages; reconnect does not resend them.
