<p align="center">
  <img src="Resources/AppIcon.png" alt="Graftty app icon" width="128" />
</p>

# Graftty

A macOS worktree-aware terminal multiplexer built on [libghostty](https://ghostty.org) & [zmx.sh](https://zmx.sh/).

Graftty organizes persistent terminal sessions by git worktree. Each worktree in your sidebar has its own split layout of terminals that stay alive across worktree switches, and a CLI (`graftty`) lets running processes interact with the Graftty UI.

<p align="center">
  <img src="docs/hero.png" alt="Graftty on macOS in a MacBook Pro frame, with Graftty for iOS in an iPhone frame overlapping front-right" width="1200" />
</p>

## Installing

```sh
brew tap btucker/graftty
brew install --cask graftty
```

Installs `Graftty.app` to `/Applications` and symlinks the `graftty` CLI onto `PATH`. On first launch, macOS will block the app with Gatekeeper — approve it under System Settings → Privacy & Security (on Sonoma, right-click → Open). Uninstall with `brew uninstall --cask --zap graftty`.

Graftty updates itself. On first launch, you'll be asked whether
Graftty may check for updates automatically — if you agree, a small
indicator appears in the window titlebar when a new version is
available, and clicking it installs the update. You can also trigger a
check manually from `Graftty → Check for Updates…`.

## Remote Macs

Graftty can connect two Macs so you can use one Mac's existing worktrees
and persistent terminal sessions from the other. Pairing starts on the
local network; after that, the same key-authenticated connection works
over either LAN or Tailscale. This is terminal access, not screen sharing.
Both Macs run the normal Graftty app; no separate server or system SSH
setup is required.

### Pair two Macs

Graftty advertises its dedicated local remote-access service with Bonjour
while it is running. To add another Mac:

1. Open Graftty on both Macs and allow Local Network access when macOS asks.
2. On the Mac you want to work from, click **Add Remote Mac…** in the
   **Remote Macs** sidebar section.
3. Select the discovered Mac. If Bonjour/mDNS is unavailable on the
   network, enter its LAN listener URL instead.
4. Click **Pair** and compare the verification code shown on both Macs.
   Accept the request on the host Mac and confirm it on the client only
   when the codes match.

The client saves the paired Mac by its stable device ID, full public key,
and signed LAN/Tailscale routes—not by one changeable hostname or IP address.
Only paired Macs become persistent sidebar rows; nearby, unpaired Bonjour
results remain inside the Add Remote Mac sheet.

Select a saved Mac to connect on demand. Once connected, its worktrees and
panes appear beneath it in the sidebar. Selecting a remote pane opens an
interactive terminal attached to that pane's persistent `zmx` session.
Graftty keeps one client connection per saved Mac and carries terminal,
pane-list, and pane-control traffic through an encrypted WebRTC DataChannel
with mutually authenticated SSH inside it. When several saved routes are
available, Graftty probes them concurrently and uses the first route that
proves possession of the paired host key.

### Trust, revocation, and recovery

Bonjour discovery is only an address hint—it does not establish trust.
Pairing exchanges public identity keys, requires approval on the host, and
uses the matching verification code to prevent an untrusted LAN peer from
silently adding itself. The dedicated paired-access listener runs on port
8800 over LAN and Tailscale and exposes only pairing and signaling routes.
Every signaling challenge, WebRTC offer, and answer is signed with the keys
established during pairing; captured challenges are short-lived and
single-use.

Every later connection verifies the host's SSH key against the fingerprint
pinned during pairing. If the key does not match, Graftty fails closed and
shows the saved Mac with a key icon (`needsPairing`). A later Bonjour
announcement does not clear that warning. Use **Add Remote Mac…** to pair
again only after confirming why the host identity changed—for example,
after the other Mac's Graftty identity data was intentionally reset.

The host can revoke a paired client under **Settings → Web Access → Device
Pairing**. Removing it also closes that client's active SSH connection.
The current host accepts one active incoming remote connection at a time;
another client receives a retryable “host busy” failure without displacing
the active connection.

If a Mac does not appear during initial pairing, confirm that both apps are
running on the same LAN, Local Network permission is enabled for Graftty,
and the network allows Bonjour/mDNS. Corporate and guest networks often
block peer discovery or device-to-device traffic; use the manual LAN URL
when one is available. For later remote connections, both devices must be
online in the same tailnet and the host must still be reachable on port
8800.

## Agent instructions

Graftty can give the agents running in your worktrees durable, per-worktree
instructions. Files use the same relative layout in any instruction root:

```
.graftty/GRAFTTY.md                     # every worktree in the repo
.graftty/research/GRAFTTY.md            # every worktree under research/
.graftty/research/GRAFTTY.vector-db.md  # just the research/vector-db worktree
```

A worktree receives the repo-wide file, then each ancestor directory's
`GRAFTTY.md`, then its own leaf file — which lives one level up, named after
the worktree.

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

The built-in team session prompt explains these forms and tells agents they may
suggest concise instruction files when durable team structure would help, but
to create or modify them only when authorized.

Requires **Agent Teams** to be enabled in Settings, and a repository with
more than one worktree.

## Agent teams

When a repo has more than one worktree open, Graftty treats it as an
*agent team*. AI coding agents (Claude Code, Codex, etc.) running inside
each worktree can register their presence, message each other through a
per-worktree inbox, and react to PR/CI events that affect the team —
useful when you've got one agent per branch grinding through PRs and
want them to coordinate.

Enable it under **Settings → Agent Teams**. From there you choose which
events (PR state, merges, CI conclusion, mergability) get routed to the
root agent, the per-worktree agent, peer worktrees, or any combination,
and customize the templated session and per-event prompts each agent
receives.

The session prompt is the complete SessionStart team context, including
the CLI surface for coordination. Settings shows the built-in Stencil
template with live `agent` and `team` placeholders; you can edit or replace
the whole template, restore the current Graftty default, or clear it to
disable SessionStart team context:

```sh
graftty team register --runtime claude   # announce presence at session start
graftty team list                        # see teammates, worktrees, and running state
graftty team list --json                 # stable machine-readable roster
graftty team send --stdin <member>       # read a direct message literally from stdin
graftty team broadcast --stdin           # read a broadcast literally from stdin
graftty team inbox                       # read your newest 100 incoming messages
graftty team inbox --all                 # fetch all team traffic page by page
```

Delivery is hook-driven. Graftty installs `claude` and `codex` shims on
each agent's `PATH` that wire `SessionStart` and `Stop` hooks into the
runtime. `SessionStart` renders the configured complete session prompt;
`Stop` triggers inbox delivery at the end of each turn.
For Claude Code, a `Stop`-spawned watcher wakes the agent on stderr
when a new message arrives; for Codex, a graftty-side service sends the
message into the active conversation through Codex's app server.

*Window → Team Activity Log* opens a unified transcript of every team
event and inter-agent message for the focused worktree's team.

### Team inbox delivery cursors and maintenance

The team inbox is an append-only JSONL log. Hook and watcher delivery track two
positions: a cursor for each runtime session and a shared watermark for each
worktree. Those paths advance both positions; a new session begins at the
worktree watermark. Codex app-server delivery uses the worktree watermark as
its authoritative position and does not maintain a session cursor. Manual
`graftty team inbox` reads are diagnostic and advance neither position.
Pagination bounds each socket response; it does not delete or archive records.

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
pane directly — see **CLI** below for `graftty pane show` (read another
worktree's terminal) and `graftty pane send` (inject keystrokes).

## CLI

The bundled `graftty` CLI lets a process inside a Graftty pane drive the app, and lets one agent control panes in another worktree.

```sh
graftty notify "tests passing"               # set a sidebar attention badge
graftty pane list                            # panes in the current worktree
graftty pane add --command "claude"          # split + run a command
graftty pane close 2                         # close pane 2

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

# Cross-worktree pane control:
graftty pane list drag-files                 # list panes in another worktree
graftty pane show drag-files:1               # last 100 lines of that pane's output
graftty pane show drag-files:1 --lines 500   # more scrollback
graftty pane send drag-files:1 "pnpm test"   # type the command and press Enter
graftty pane send drag-files:1 "y" --no-enter  # type without committing
```

`<addr>` is `<id>` (current worktree, that pane), `<worktree>` (worktree's only pane), or `<worktree>:<id>`. Worktree names match what `graftty team list` prints. Run `graftty pane <verb> --help` for examples on every subcommand.

`graftty pane send` writes raw bytes to the addressed pane's PTY — there's no inbox or consent layer, so the keystrokes land in whatever process is reading that pane's stdin. Use `graftty team send` for cooperative messaging where the receiving agent decides what to do.

`graftty worktree add --base <ref>` creates the new branch from an exact Git-resolvable revision already available in the local repository; it does not fetch, and it cannot be combined with `--existing`. Worktree-local revisions such as `HEAD`, `@`, and reflog selectors resolve in the worktree that invoked the command. Without `--base`, Graftty keeps its existing behavior of using the repository's default branch when available, then falling back to `HEAD`.

`graftty worktree remove <worktree>` accepts an absolute tracked path, `.` for the current worktree, or a worktree name from `graftty team list`. It runs the same removal flow as the sidebar's Delete Worktree action: Git deletes the linked checkout but preserves its branch, Graftty tears down its panes and removes it from the UI, and modified, staged, or untracked files cause a non-zero exit with `git status --short` details. Pass `--force` to mirror the UI's Force Delete action.

`graftty worktree add --agent` prints a canonical worktree-path address. The app accepts prompt text up to 128 KiB and stages it in an owner-only temporary file, so multiline prompts, heredoc examples, shell syntax, and substantial task descriptions are not typed through the new pane's interactive shell. The CLI verifies this staging support before creating anything; if the app was already running during an upgrade, quit and relaunch it before retrying. When no prompt is supplied, Graftty starts one short bootstrap turn; that lets the runtime finish initialization and establish idle inbox delivery instead of remaining in a pre-turn state that queued messages cannot wake. Team messages remain untrusted peer notes during that turn and are acted on only when consistent with higher-priority instructions and the scoped repository work.

Incoming worktree messages show the same stable path in their `from` label, so the recipient can reply with `graftty team send --stdin <address>` even if branches are renamed or display names collide.

## Building

Requires Xcode 15+ and macOS 14 Sonoma or later.

```sh
swift build
```

Open `Package.swift` in Xcode to run the app.

## Developing the web client

Graftty's browser-facing web access client lives in `web-client/` (React +
Vite + TypeScript + TanStack Router). If you change anything under
`web-client/`, rebuild the bundle that ships with the app:

```bash
./scripts/build-web.sh
```

This refreshes `Sources/GrafttyKit/Web/Resources/{index.html,app.js,app.css}`.
CI verifies the committed bundle matches a fresh build.

You need `node` (LTS) and `pnpm` installed locally for web-client work:

```bash
brew install node pnpm
```

If you only touch Swift, you need neither — the committed bundle is what
`swift build` ships, and Homebrew users get the prebuilt tarball.

## Further reading

- [`SPECS.md`](SPECS.md) — authoritative EARS-style behavior spec.
- [`docs/`](docs) — design notes and architecture details.

## License

MIT — see [`LICENSE`](LICENSE).
