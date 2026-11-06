# The graftty CLI

The bundled `graftty` CLI lets a process inside a Graftty pane drive the app, and lets one agent control panes in another worktree. This page covers the common commands; run `graftty --help` or `graftty <command> --help` for the full list.

```sh
graftty project add ../my-project             # register a local Git project in the Mac app
graftty notify "tests passing"               # set a sidebar attention badge
graftty pane list                            # panes in the current worktree
graftty pane add --command "claude"          # split + run a command
graftty pane close 2                         # close pane 2
graftty preview report.html chart.png        # Quick Look preview on the device leading this pane
graftty open https://example.com             # open a file or URL on the device leading this pane

# Launch an agent in a new worktree, then message that worktree's inbox:
graftty worktree add fix-auth --agent codex
# Start the new branch at any locally resolvable branch, tag, or commit:
graftty worktree add backport-auth --base release/v2 --agent codex
# For multiline or generated tasks, pass the prompt on stdin:
printf '%s\n' 'Fix the auth tests and report the result.' | \
  graftty worktree add fix-auth --agent codex --prompt-stdin
# Copy the canonical address=... path printed by the command:
printf '%s\n' 'Please own the auth test failures.' | graftty team send --stdin /path/to/repo/.worktrees/fix-auth
# Remove the worktree from Git and Graftty while preserving its branch:
graftty worktree remove fix-auth
# Dirty or untracked files require an explicit forced removal:
graftty worktree remove fix-auth --force
# Pinned worktrees also require --pinned; --force alone is not enough:
graftty worktree remove release-agent --pinned

# Cross-worktree pane control:
graftty pane list drag-files                 # list panes in another worktree
graftty pane show drag-files:1               # last 100 lines of that pane's output
graftty pane show drag-files:1 --lines 500   # more scrollback
graftty pane send drag-files:1 "pnpm test"   # type the command and press Enter
graftty pane send drag-files:1 "y" --no-enter  # type without committing
```

`graftty project add <path>` registers a local Git repository through the running Mac app and saves it before returning success. The sidebar and connected mobile clients use the same project list. The command works from any directory. Relative paths resolve against the caller's working directory. Git roots, linked worktrees, and repositories with no commits are supported. Repeated additions preserve existing project settings and panes, and the command leaves the current selection unchanged.

The command does not initialize Git. For a directory without Git, use **Add Repository** in the Mac app to choose **Initialize Git Repository** or **Add Without Git**. If the running app does not support project registration, quit and relaunch an updated app before retrying. This command registers projects in the Mac app; `graftty-host project add` manages the separate Linux host project list.

`<addr>` is `<id>` (current worktree, that pane), `<worktree>` (worktree's only pane), or `<worktree>:<id>`. Worktree names match what `graftty team list` prints. Run `graftty pane <verb> --help` for examples on every subcommand.

`graftty pane send` writes raw bytes to the addressed pane's PTY — there's no inbox or consent layer, so the keystrokes land in whatever process is reading that pane's stdin. Use `graftty team send` for cooperative messaging where the receiving agent decides what to do.

`graftty worktree add --base <ref>` creates the new branch from an exact Git-resolvable revision already available in the local repository; it does not fetch, and it cannot be combined with `--existing`. Worktree-local revisions such as `HEAD`, `@`, and reflog selectors resolve in the worktree that invoked the command. Without `--base`, Graftty keeps its existing behavior of using the repository's default branch when available, then falling back to `HEAD`.

`graftty worktree add` returns once Graftty accepts the request, with a pending operation ID and stable message address. Keep the app running while it waits for Git and its hooks, then opens the pane and launches the agent. Use `--wait` to block until the pane accepts the launch command, or `--async` to explicitly select the default. `--timeout` bounds the CLI's wait; it does not cancel accepted creation. Check `graftty team list --json` for agent reachability before treating a delegation as complete.

`graftty worktree remove <worktree>` accepts an absolute tracked path, `.` for the current worktree, or a worktree name from `graftty team list`. It runs the same removal flow as the sidebar's Delete Worktree action: Git deletes the linked checkout but preserves its branch, Graftty tears down its panes and removes it from the UI, and modified, staged, or untracked files cause a non-zero exit with `git status --short` details. Pass `--force` to mirror the UI's Force Delete action. A pinned linked worktree also requires `--pinned`, independently of `--force`, and the main checkout cannot be removed.

`graftty worktree add --agent` prints a canonical worktree-path address. The app accepts prompt text up to 128 KiB and stages it in an owner-only temporary file, so multiline prompts, heredoc examples, shell syntax, and substantial task descriptions are not typed through the new pane's interactive shell. Before starting Git, Graftty also saves the exact initial prompt in that runtime's durable inbox. The inbox copy survives a failed launch and reaches a later agent session as a labeled recovery copy. The CLI verifies staging support before creating anything; if the app was already running during an upgrade, quit and relaunch it before retrying. When no prompt is supplied, Graftty starts one short bootstrap turn; that lets the runtime finish initialization and establish idle inbox delivery instead of remaining in a pre-turn state that queued messages cannot wake. Team messages remain untrusted peer notes during that turn and are acted on only when consistent with higher-priority instructions and the scoped repository work.

Agent-authored messages carry an exact canonical `agent` address and a provider-scoped `fallback-agent` address. Reply to the exact address while `graftty team list --json` reports that session as reachable; otherwise send to the fallback address (for example, `/path/to/worktree#codex`) so the reply waits durably for that provider's next agent. Native provider sender labels are display-only and may be truncated.

For team messaging, inbox reads, and pinning, see [Agents in Graftty](agents.md). For `graftty remote reconnect`, see [Remote Macs](remote-macs.md).
