# Agents in Graftty

How Graftty pins agents, gives them per-worktree instructions, and lets them coordinate as a team.

## Pinned agents

The sidebar lists temporary worktrees below a collapsible **Pinned Agents**
section. The repository's default-branch row always appears first among pinned
agents, followed by ongoing-role worktrees in saved manual order. To pin a local
worktree, drag it onto the **Pinned Agents** header or a pinned worktree row,
or right-click it and choose **Pin Agent**. Dropping on a collapsed header pins
the worktree and expands the section. This works with recent activity sorting. Choose **Unpin Agent** to
return it to the temporary list. Pin state, disclosure state, and manual pinned
order persist across sessions. Remote clients show the owning Mac's pin state.

Agents can use `graftty worktree pin` to pin their own worktree, or
`graftty worktree pin <name-or-path>` to pin another local worktree.
`graftty worktree unpin [name-or-path]` returns it to the temporary list without
changing its workspace or instructions. The default-branch checkout stays
pinned. Removing a pinned worktree with `graftty worktree remove` requires
`--pinned`. The bundled team skill explains the pinning and role-file workflow.

To configure a pinned agent's responsibilities, choose **Edit Role Instructions…**
from its context menu. Graftty opens its effective worktree-specific instruction
file, or creates an empty `.graftty/<worktree-key>/GRAFTTY.md` in the main
checkout so peer agents can read its shared role context. It uses the same
configured editor as Cmd-clicking a file in the terminal, opening CLI editors
in a new pane in the selected worktree. The action is available on pinned local
worktrees, including the default-branch checkout. Worktrees without a role key
use their local `.graftty/GRAFTTY.md`. If an Application Support base file would
override it, Graftty reports the overriding path instead of creating an
ineffective role file. Pinning does not create or change instructions.
Instruction files can also apply to temporary worktrees without pinning them.

## Agent instructions


Graftty can give the agents running in your worktrees durable, per-worktree
instructions. Files use the same relative layout in any instruction root:

```
.graftty/GRAFTTY.md                     # every worktree in the repo
.graftty/research/GRAFTTY.md            # research and worktrees beneath it
.graftty/research/vector-db/GRAFTTY.md  # research/vector-db and descendants
```

A worktree receives the repo-wide file, then each ancestor directory's
`GRAFTTY.md`, then the `GRAFTTY.md` in its own keyed directory.

For upgrade compatibility, the older `GRAFTTY.<leaf>.md` form remains a
read-only fallback when the equivalent hierarchical file is absent. New and
updated instructions should use the directory form above. If both forms exist
for one scope in the same root, Graftty uses the hierarchical file and logs a
warning naming both paths; reconcile any content that still matters, then
delete the legacy file.

Anything below a `## Private` heading goes only to the worktrees that file
applies to. Everything above it is shared with every agent in the repo, so
it's the right place for what other worktrees need in order to coordinate
with this one. A file with no such heading is entirely shared.

For each relative path, Graftty uses the first readable regular file it finds
in this order:

1. `~/Library/Application Support/Graftty/.graftty/`
2. the current worktree's `.graftty/`
3. the main checkout's `.graftty/`

Resolution is per file, so a sparse higher-precedence overlay does not hide
unrelated files below it. The Application Support root is machine-wide: a
matching relative name overrides that file in every repository. Graftty reads
current filesystem bytes and does not inspect Git, so an uncommitted edit takes
effect at the next session start. Symlinks, non-regular files, and evicted
iCloud placeholders are ignored.

This lets one agent configure another before launch. Create the child's leaf
where its first session can see it: in Application Support, in the main
checkout, or in the child's starting tree. From a linked worktree, you can put
the leaf in the starting tree by committing it and running
`graftty worktree add <name> --base HEAD --agent <codex|claude>`; Git creates
the child from that commit, but Graftty still reads the resulting filesystem
file directly. Once the child exists, its own `.graftty/` can tune later
sessions without a commit.

The bundled Graftty Team skill explains these forms and tells agents they may
suggest concise instruction files when durable team structure would help, but
to create or modify them only when authorized. Instruction files are how you
customize agents; Graftty has no separate session prompt setting.

## Agent teams

Each tracked repository has a team. Agents running in its worktrees can
register their presence, send inbox messages, and react to PR and CI events.
A repository with one local worktree can also communicate with agents on a
remote Mac.

Agents connect to Graftty through the Codex and Claude provider plugins.
Graftty offers to install them on first launch; you can also install them
from **Settings → Agent Teams**, which warns until they are installed. The
plugins add Graftty's skills and lifecycle hooks, and Graftty refreshes them
automatically after app updates. Start new agent sessions after installing.

In **Settings → Agent Teams** you also choose which events (PR state,
merges, CI conclusion, mergability) get routed to the root agent, the
per-worktree agent, peer worktrees, or any combination, and customize the
templated per-event prompt each agent receives with an automated event.
Customize agents themselves with `GRAFTTY.md` instruction files (above).

The bundled Graftty Team skill teaches agents the CLI surface for
coordination:

```sh
graftty team list                        # see teammates, worktrees, and running state
graftty team list --json                 # stable machine-readable roster
graftty team send --stdin <member>       # read a direct message literally from stdin
graftty team broadcast --stdin           # read a broadcast literally from stdin
graftty team inbox                       # read the oldest 100 unread rows and mark them read
graftty team inbox --all                 # consume the current unread snapshot page by page
graftty team inbox --keep-unread         # peek without changing delivery state
graftty team inbox --unread              # compatibility alias for --keep-unread
graftty team inbox --history             # inspect prior incoming messages without mutation
```

Delivery is native. The plugins' `SessionStart` hook points agents at the
Graftty skills and delivers their `GRAFTTY.md` instructions and any
messages queued before the session started. After that, Graftty sends new
messages into the running session: to Claude Code through its peer
messaging socket, and to Codex through Codex's app server. For Codex,
Graftty installs a `codex` shim on each agent's `PATH` that starts that app
server and registers the session.

The Codex shim routes feature, plugin marketplace, plugin, and MCP
administration to the user's durable `~/.codex` home while maintaining a
read-only-at-runtime config snapshot in an isolated managed home. Those
changes therefore survive later agent launches without requiring an agent to
rewrite Graftty's generated files. A sandboxed agent may
request normal filesystem approval before changing this user-global state.
Codex discovers plugin-provided tools when a session starts, so the shim prints
a reminder to reload the agent or start a new session after a successful
configuration mutation.

*Window → Team Activity Log* opens a unified transcript of every team
event and inter-agent message for the focused worktree's team.

### Message agents on another Mac

Pair and connect the other Mac as described in [Remote Macs](remote-macs.md). Both Macs must run a
version of Graftty that supports remote team messaging. One pairing provides
messaging in both directions while that connection is open.

Run `graftty team list --json` from a tracked worktree. The roster includes
all teams on each directly connected Mac. Copy the remote agent's `address`
unchanged into `graftty team send --stdin`. Remote addresses start with
`graftty-mac://` and include a device identity, an escaped worktree path,
and an optional `#codex`, `#claude`, or exact agent suffix.

Replies use the sender's device-qualified `agent` or `fallback-agent`
address from the message envelope. An exact agent address fails if that
session is gone. A provider address queues the message for that provider's
next agent after the receiving Mac accepts it.

A successful send means the receiving Mac wrote the message to its durable
inbox. Disconnected Macs reject new sends. If the connection breaks before
an acknowledgement arrives, check the recipient's inbox before retrying,
because the message may already have arrived. `team broadcast` continues
to send only to other worktrees in the caller's local repository.

### Team inbox delivery cursors and maintenance

The team inbox is an append-only JSONL log. Hook and watcher delivery track two
positions: a cursor for each runtime session and a shared watermark for each
worktree. Those paths advance both positions; a new session begins at the
worktree watermark. Codex app-server delivery uses the worktree watermark as
its authoritative position and does not maintain a session cursor. A normal
`graftty team inbox` read writes the oldest unread page and then advances the
current worktree's shared watermark through the last displayed row. It does not
change a session cursor. `--all` consumes a fixed upper snapshot, so rows
appended while pages are being fetched remain unread for the next invocation.

`--keep-unread` (and its compatibility alias `--unread`) peeks without changing
delivery state. `--history` is also nonmutating. Supplying `--worktree`,
`--repo`, or `--member` makes the read a diagnostic peek because a command must
not consume another scope's inbox. Graftty emits the supported consuming command
on stderr for those diagnostic reads while leaving stdout machine-readable.

The shared watermark advances only after stdout accepts the complete output.
If output fails, nothing advances. If the subsequent advance fails, the command
returns nonzero and asks the caller to rerun `graftty team inbox`; direct edits
to Graftty state files are unsupported. Pagination bounds each socket response;
it does not delete or archive records.

Both positions store a message ID that acts as an anchor into the log's append
order. If an external archive removes an anchor record, the reader cannot infer
where that record used to be and conservatively starts at the beginning of the
retained log. That can replay retained messages. Retaining anchors alone is not
enough: deleting rows newer than an anchor can discard messages that are still
pending. Direct store surgery is therefore unsupported. A safe archive must
remove only a contiguous prefix that is older than every effective delivery
position, and must retain each referenced anchor or migrate every position
atomically to a retained cutoff record. Inbox pagination removes the need to
compact the store merely to keep `graftty team inbox` usable.

When inbox messages aren't enough, any agent can drive a teammate's
pane directly — see the [CLI reference](cli.md) for `graftty pane show` (read another
worktree's terminal) and `graftty pane send` (inject keystrokes).
