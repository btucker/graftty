# Worktree operations

## Creation options

Use the delegation example in the [team skill](../SKILL.md) to launch an agent with its first task. Choose options as needed:

- `--base <ref>` selects a local revision; default is the repository's default branch or HEAD. `--base HEAD` includes committed changes only.
- `--branch <branch>` overrides the normalized worktree name. Add `--existing` for an existing branch in a new directory; this cannot reopen a directory or restart an agent, and conflicts with `--base`.
- `--prompt-stdin` requires `--agent codex` or `--agent claude` and conflicts with `--prompt`. Use stdin for dynamic or untrusted text; reserve `--prompt` for trusted literals.
- Creation is asynchronous by default; `--async` makes that explicit. Graftty waits for Git and hooks, then launches the agent after the CLI exits. `--wait` waits until Git finishes and the pane accepts the command, not until the task finishes.
- `--timeout <seconds>` bounds acceptance, or completion with `--wait`. Default 300; must be positive. Timeout does not cancel accepted creation.

The default response begins with `pending`; `--wait` returns `created` on launch acceptance. The returned address is stable across startup, and messages sent before readiness are queued. The initial task also survives in the agent's durable inbox. Confirm child reachability before relinquishing its scope.

## Another Mac

Add `--remote '<Mac-name-or-device-ID>'` over an active control connection. Both Macs must support remote creation and track the project. The destination defaults to the caller's Git origin; equivalent GitHub/GitLab SSH and HTTPS URLs match. Use `--project '<destination-name-or-absolute-repository-path>'` for another project, missing origin, or ambiguous matches, including calls outside a worktree.

Branches and `--base` resolve on the destination; `--base HEAD` uses its main checkout. Local commits, edits, and instructions are not transferred.

From your tracked worktree, send a follow-up to the full returned `graftty-mac://...` address. This gives the child your cross-Mac reply address. Local roster paths cannot route replies across Macs. After timeout or lost acknowledgement, inspect the destination roster and worktrees before retrying.

## Recover launch failures

Inspect `git worktree list` and the roster before retrying creation. Failed hooks may leave directories behind; do not recreate or automatically delete them. Diagnose registration if Git lists a worktree that Graftty does not.

For an existing worktree with no suitable agent, first open it in Graftty; `pane add` needs a running worktree. An agent pane starts even when the worktree is not selected. If panes have no automatic command, launch one:

```sh
graftty pane add '<worktree-name>' --agent codex --prompt-stdin <<'GRAFTTY_PANE_7F3A91C2'
<task>
GRAFTTY_PANE_7F3A91C2
```

Replace `codex` with `claude` as needed. `pane add` takes a worktree name. `--agent` launches the runtime as `worktree add --agent` does; the shell waits until it is ready. `--prompt-stdin` and `--prompt` require `--agent`, and `--command` runs an arbitrary shell line instead. When the worktree has no live or starting agent of that runtime, the task is also saved in the durable inbox. Confirm reachability before relinquishing the task.

The same command adds a reviewer or pair beside a live implementer. If a live or starting agent of the same runtime already uses the worktree, the added agent's task travels only in its launch command, so that agent never receives it. Address the added agent by its exact ID from `graftty team list --json`.

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
