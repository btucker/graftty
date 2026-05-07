# Replace Claude Channels with the Team Inbox - Design Specification

## Goal

After this ships, the Claude-channel surface (MCP server, socket server, channel router, channel-routing observer, `graftty mcp channel` CLI subcommand, and the `--dangerously-load-development-channels server:graftty-channel` launch flag) is gone. Every team event - human messages, PR/CI/merge transitions, membership changes - flows through the same `TeamInbox` substrate that the codex-hooks branch already uses for `graftty team msg` / `graftty team broadcast`. Codex and Claude sessions both consume team activity through the inbox-backed hook adapter; no Claude-only push path remains.

A new **Team Activity Log** window gives the user a read-only view of every inbox row for a team, mixing chat-style `team_message` rows with system-styled event rows.

## Scope

### In scope

- Producer-side fan-out for PR/CI/merge transitions and team membership events: matrix lookup, per-recipient body rendering, one `TeamInbox` row per recipient. Replaces `ChannelEventRouter.recipients(...)` + `EventBodyRenderer.dispatchClosure(...)` + `ChannelRouter.dispatch(...)`.
- Deletion of every channel-only file (router, socket server, MCP stdio server, MCP installer, channel event router, channel settings observer, channel socket client, `graftty mcp channel` CLI subcommand) and its tests.
- Relocation of the files that were colocated under `Channels/` only by accident - `EventBodyRenderer`, `RoutableEvent`, `ChannelRoutingPreferences`, the event-name string constants - to `Sources/GrafttyKit/Teams/`.
- Settings UI cleanup: rename "Channel routing" matrix to "Team event routing"; remove the launch-flag disclosure block; remove the `ChannelSettingsObserver` wiring.
- One-time **legacy cleanup at startup**: unregister the `graftty-channel` MCP server with `claude mcp`, delete `~/.claude/.mcp.json` and the legacy plugin wrapper directory if present. Idempotent. Slated for removal after ~3 release versions.
- A new **Team Activity Log** window: SwiftUI view of every inbox row for a team, opened from a Window menu item or a sidebar context-menu item on team-enabled repos. Real-time updates as new rows append. View-only.
- Spec annotation updates: existing TEAM-1.7 / TEAM-3.* / TEAM-5.* requirements get reworded or deleted to match the inbox-shaped delivery; new requirements added under TEAM-7 (activity log) and TEAM-8 (legacy cleanup).

### Out of scope

- Sending messages from the activity log window (compose UI, recipient picker, urgent toggle). View-only for v1; send remains CLI-only via `graftty team msg` / `graftty team broadcast`.
- A live "team prompt edit fan-out" replacement. Today, `ChannelRouter.broadcastInstructions()` pushes new instructions to live MCP sessions when the user edits the session prompt in Settings. This is dropped: agents see prompt changes at the next session start, since prompts are rendered at hook session-start now.
- Cross-repo or multi-repo activity views. The activity window scopes to one team (one repo) at a time.
- Marking inbox rows as "read" from the UI, or otherwise mutating cursors / worktree watermarks from the activity window. The window is purely diagnostic.
- Backwards compatibility for users running with `--dangerously-load-development-channels server:graftty-channel`. After upgrade, that flag will produce a Claude warning ("server graftty-channel not found") on session start. We optionally scrub the substring out of the `defaultCommand` AppStorage value at upgrade time, but no support exists for the flag in any other position.

## Architecture

### Today

```
PRStatusStore.onTransition (PR/CI/merge)
TeamMembershipEvents.fire* (member joined/left)
graftty team msg / broadcast (team_message)
              │
              │   ChannelEventRouter.recipients(event, prefs)
              │   EventBodyRenderer.dispatchClosure(repos, inner: ChannelRouter.dispatch)
              ▼
        ChannelRouter ──(socket)──► ChannelSocketServer ──(MCP stdio)──► MCPStdioServer
                                                                              │
                                                                              ▼
                                                            Claude session via launch flag
                                                            --dangerously-load-development-channels
                                                            server:graftty-channel

(separately, only for team_message)
graftty team msg / broadcast ──► TeamInbox.appendMessage / appendBroadcast
                                                ▼
                          hook(.postToolUse | .stop) pulls unread for caller worktree
                                                ▼
                                  Codex or Claude session via wrapper hooks
```

### After

```
PRStatusStore.onTransition (PR/CI/merge)         ─┐
TeamMembershipEvents.fire* (member joined/left)  ─┼─► TeamEventDispatcher.dispatch(event, repos)
graftty team msg / broadcast (team_message)      ─┘                      │
                                                                          │ 1. recipients = matrix.recipients(event)
                                                                          │ 2. for r in recipients:
                                                                          │      body = EventBodyRenderer.body(event, recipient: r)
                                                                          │      inbox.appendMessage(kind: event.type, to: r, body: body, …)
                                                                          ▼
                                            <App Support>/Graftty/team-inbox/<team>/messages.jsonl
                                                                          │
                                                                          │ pulled at hook tick
                                                                          ▼
                                                  TeamInboxRequestHandler.hook(.sessionStart | .postToolUse | .stop)
                                                                          │
                                                                          ▼
                                                  TeamHookRenderer ──► Codex / Claude session
                                                                          │
                                            (also observed by)            │
                                                                          ▼
                                                  TeamInboxObserver ──► Team Activity Log window
```

### Key shape changes

1. **One write path, one delivery path.** Every event - human or system - lands in the inbox via `TeamEventDispatcher` and is consumed by either the hook handler (for agents) or the activity window (for the user). No second pipe.
2. **Body rendering moves to write-time.** Today, `EventBodyRenderer.dispatchClosure` wraps every dispatch and renders the user's `teamPrompt` template against each recipient's agent context at delivery time. After this change, the dispatcher renders once per recipient at write time and stores the rendered text in the inbox row's `body`. The hook handler unwraps it as-is. This eliminates the dispatch-closure plumbing and the "what template was active when this delivered?" race.
3. **`team_message` collapses onto the same path.** Today it's the only event that writes to both inbox and channel. After this change, it goes through the dispatcher like everything else.
4. **The `instructions` events disappear.** The initial `instructions` push on subscribe is replaced by `hook(.sessionStart)` (already implemented). The live `broadcastInstructions()` on prompt edit is dropped (declared out of scope).

## Component changes

### New

- **`Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`** - producer-side fan-out. Owns matrix lookup, per-recipient render, inbox write. Single integration point that producers (`PRStatusStore`, `TeamMembershipEvents`, the team-msg/broadcast CLI handlers) call.
- **`Sources/GrafttyKit/Teams/TeamInboxObserver.swift`** - watches `<team>/messages.jsonl` via `DispatchSource.makeFileSystemObjectSource(.write | .extend)` (or kqueue equivalent), publishes `[TeamInboxMessage]` updates. Used by the activity window. Scoped to one team at a time. Decodes incrementally - re-reads file on event, but the inbox is small enough that a full re-read on each append is fine for v1.
- **`Sources/GrafttyKit/Teams/LegacyChannelCleanup.swift`** - one-shot startup task. Calls `claude mcp remove graftty-channel`, deletes `~/.claude/.mcp.json` and the legacy plugin wrapper directory. Tolerates each step's absence. Logs failures, never throws.
- **`Sources/Graftty/Views/TeamActivityLog/TeamActivityLogWindow.swift`** - the SwiftUI window. Title bar shows team name. Body is a chronological scrollable list of inbox rows. Empty state: "No team activity yet." Auto-scrolls to bottom on append.
- **`Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift`** - row renderer. Switches on `kind`:
  - `team_message` → chat-bubble with sender, recipient (or "Broadcast" if matrix expanded), timestamp, urgent badge, body
  - `pr_state_changed` / `ci_conclusion_changed` / `merge_state_changed` → system entry with kind icon (`circle.fill`, `checkmark.seal`, `arrow.triangle.merge`), headline ("PR #42 state: open → merged"), and body
  - `team_member_joined` / `team_member_left` → system entry with `person.fill.badge.plus` / `person.fill.badge.minus`, headline, and body
  - Unknown `kind` → fall through to a generic system entry rendering `body` verbatim. Keeps the window forward-compatible if we add new kinds.

### Touched, kept

- **`Sources/GrafttyKit/Teams/RoutableEvent.swift`** - moved here from `Channels/`. Still describes routing-relevant fields. Possibly extended with the system-event kinds.
- **`Sources/GrafttyKit/Teams/EventBodyRenderer.swift`** - moved here. `dispatchClosure(...)` deleted (no per-dispatch wrapping needed). `body(...)`, `makeAgentContext(...)`, `renderAgentTemplate(...)`, `renderSessionPrompt(...)` retained.
- **`Sources/GrafttyKit/Teams/TeamEventRoutingPreferences.swift`** - moved + renamed from `Channels/ChannelRoutingPreferences.swift`. AppStorage key migrates from `channelRoutingPreferences` to `teamEventRoutingPreferences` via a one-time read-old / write-new at startup. Field shape unchanged: still a 4×3 `RecipientSet` matrix.
- **`Sources/GrafttyKit/Teams/TeamChannelEvents.swift`** - renamed to **`TeamEvents.swift`**. The existing `TeamChannelEvents.EventType` enum absorbs the kind names (`prStateChanged`, `ciConclusionChanged`, `mergeStateChanged`) currently in `ChannelEventType`.
- **`Sources/GrafttyKit/Teams/TeamInboxMessage`** (in `TeamInbox.swift`) - the `kind` field's value-set widens to include the system kinds. Wire format unchanged.
- **`Sources/GrafttyKit/Teams/TeamInboxEndpoint`** - add a sentinel constructor `TeamInboxEndpoint.system(repoPath:)` so PR/CI/membership rows have a non-human `from` value (`member: "system"`, `worktree: <repoPath>`, `runtime: nil`). Hook renderers know to display this sender as a system event rather than a chat message.
- **`Sources/GrafttyKit/PRStatus/PRStatusStore`** - `onTransition` closure type changes from `(@MainActor (String, ChannelServerMessage) -> Void)` to `(@MainActor (RoutableEvent) -> Void)`. The subject worktree path moves into the event payload.
- **`Sources/GrafttyKit/Teams/TeamMembershipEvents`** - `fireJoined` / `fireLeft` `dispatch:` parameter changes to `(RoutableEvent) -> Void`.
- **`Sources/Graftty/GrafttyApp.swift`** - the channel-router wiring, `installChannelMCPServer`, `ChannelSettingsObserver` construction, `appStateProvider` injection, and the `dispatchTeamChannel` helper all go away. The two `installChannelMCPServer` call sites (startup + on-enable) collapse into one `LegacyChannelCleanup.run()` call at startup. The `prStatusStore.onTransition` block becomes a one-line dispatcher call.
- **`Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift`** - "Channel routing" → "Team event routing" header; footer text updated to reference inbox delivery instead of channel events. The launch-flag block (already removed in WIP) stays gone.
- **`Sources/Graftty/Channels/SettingsKeys.swift` / `DefaultPrompts.swift`** - relocated to `Sources/Graftty/Settings/`. The `Channels/` directory is removed.
- **`Sources/Graftty/Views/MainWindow.swift`** - new context-menu item *Show Team Activity…* on team-enabled worktree rows; opens (or focuses) the `TeamActivityLogWindow` for that team.
- **Window menu** - new entry *Window → Team Activity Log* (cmd-shift-T or similar; check key conflicts), enabled when a team-enabled worktree is focused; otherwise disabled.

### Deleted

| File | Reason |
|---|---|
| `Sources/GrafttyKit/Channels/ChannelRouter.swift` | No more push channel |
| `Sources/GrafttyKit/Channels/ChannelSocketServer.swift` | No socket server |
| `Sources/GrafttyKit/Channels/MCPStdioServer.swift` | No MCP server |
| `Sources/GrafttyKit/Channels/ChannelMCPInstaller.swift` | No registration (logic preserved in `LegacyChannelCleanup`) |
| `Sources/GrafttyKit/Channels/ChannelEventRouter.swift` | Folded into `TeamEventDispatcher` |
| `Sources/GrafttyKit/Channels/ChannelEvent.swift` | Reused parts already covered by `TeamInboxMessage`; constants relocate |
| `Sources/Graftty/Channels/ChannelSettingsObserver.swift` | Nothing to observe (no live broadcast, no router toggle) |
| `Sources/GrafttyCLI/MCPChannel.swift` | `graftty mcp channel` removed |
| `Sources/GrafttyCLI/ChannelSocketClient.swift` | No socket to dial |

Plus their test files.

## Data model changes

### `TeamInboxMessage.kind`

The set of allowed values widens. Today: `team_message`. After:

| Kind | Producer | Recipient computation |
|---|---|---|
| `team_message` | `graftty team msg` / `broadcast` CLI | Addressee or all-but-sender, respectively |
| `pr_state_changed` | `PRStatusStore.onTransition` | Matrix row (PR state changed; PR merged when `attrs.to == "merged"`) |
| `ci_conclusion_changed` | `PRStatusStore.onTransition` | Matrix row (CI conclusion changed) |
| `merge_state_changed` | `PRStatusStore.onTransition` (when merge-state polling lands) | Matrix row (mergability changed) |
| `team_member_joined` | `TeamMembershipEvents.fireJoined` | Lead only |
| `team_member_left` | `TeamMembershipEvents.fireLeft` | Lead only |

Wire format unchanged - just new `kind` strings in existing JSONL rows.

### `TeamInboxEndpoint`

`from` may now be a system endpoint:

```swift
TeamInboxEndpoint(member: "system", worktree: <repoPath>, runtime: nil)
```

with a convenience static `TeamInboxEndpoint.system(repoPath:)` factory. The activity window and the hook renderers detect `member == "system"` to render a non-chat presentation.

### `TeamEventRoutingPreferences` migration

At startup, if `UserDefaults.standard.string(forKey: "channelRoutingPreferences")` is non-empty and `UserDefaults.standard.string(forKey: "teamEventRoutingPreferences")` is empty, copy old value to the new key and remove the old key. Idempotent; runs once. Drop the migration after ~3 release versions.

## Settings UI

| Today | After |
|---|---|
| Toggle: *Enable agent teams* | Unchanged |
| Section: *Launch Claude with this flag* (TEAM-1.7) | **Removed** |
| Section: *Channel routing* | Renamed to *Team event routing* |
| Footer: "Choose which agents receive each automated channel message…" | "Choose which agents receive each automated team event…" |
| Section: *Session prompt* | Footer updated: "Stencil template rendered once when each Codex or Claude session starts…" (already in WIP) |
| Section: *Per-event prompt* | Footer updated: "rendered freshly for each automated event delivered to each agent…" (already in WIP) |

## Team Activity Log window

### Layout

- Title: `Team Activity - <team-name>`
- Toolbar: team-name title, member count, "Reveal in Finder" button (opens `<App Support>/Graftty/team-inbox/<team>/messages.jsonl` in Finder for diagnostics).
- Body: vertical `ScrollView` containing a `LazyVStack` of `TeamActivityLogRow` views, oldest at top, newest at bottom.
- Empty state: centered text "No team activity yet."
- Auto-scroll to bottom on append (only when already-at-bottom; preserve user scroll position otherwise).

### Open paths

- *Window → Team Activity Log* menu item (enabled when a team-enabled worktree is focused).
- Right-click on a team-enabled worktree row → *Show Team Activity…* context-menu item.
- Both paths open or focus a single window per team.

### Real-time

`TeamInboxObserver` watches the team's `messages.jsonl` via `DispatchSource.makeFileSystemObjectSource(.write | .extend, descriptor:queue:)`. On every fire, the observer re-reads the JSONL and emits the parsed array. The window's view model holds an `@Observable` of the latest array; SwiftUI refreshes incrementally. For an empty-then-populated case (file created after window opens), the watcher needs to retry-on-failure; the simplest path is to also subscribe to the parent directory and re-attach the file watcher when the file is created.

### Read state

Opening, scrolling, and closing the window do **not** advance any cursor or worktree watermark. The window is read-only diagnostic. Agents continue to consume their own unread set independently via the hook handler.

## One-time legacy cleanup

`LegacyChannelCleanup.run()` is called once per `GrafttyApp.startup`, fire-and-forget on a background `Task`. Steps, in order:

1. **Unregister MCP server.** Run `claude mcp remove graftty-channel` (best-effort). Logs on non-zero exit; never throws.
2. **Delete `~/.claude/.mcp.json` if applicable.** If the file exists and contains only the `graftty-channel` server entry (no other MCP servers), remove it. If it contains other servers, leave it alone - it's not ours to manage. (`ChannelMCPInstaller.removeLegacyMCPConfigFile` already does this conservatively; reuse the logic.)
3. **Delete the legacy plugin wrapper directory.** `~/.claude/plugins/graftty-channel` if present. (Mirror of `ChannelMCPInstaller.removeLegacyPluginDirectory`.)
4. **Scrub launch flag from `defaultCommand`.** If `UserDefaults.standard.string(forKey: SettingsKeys.defaultCommand)` contains `--dangerously-load-development-channels server:graftty-channel`, strip the substring (and any leading whitespace), write back. Notify via a one-shot `NSAlert` ("Removed legacy channels launch flag from your default command. Agent teams now run via the unified hook adapter.")

Cleanup runs on every launch (idempotent) for ~3 release versions, then the entire `LegacyChannelCleanup` module is deleted.

## Spec annotations (CLAUDE.md compliance)

### Reword

- **TEAM-1.2** - replace "no channel router, no MCP server registration, and no PR channel events fire" with "no PR/CI/membership inbox events are written and `graftty team hook` returns no-op responses".
- **TEAM-1.5** - replace "Channel events fire only when …" with "Inbox events are written only when …".
- **TEAM-1.8** - rename matrix to *Team event routing*, retitle the persisted `TeamEventRoutingPreferences` struct.
- **TEAM-1.9** - rephrase from `ChannelRouter.dispatch` to `TeamEventDispatcher.dispatch`; routing logic identical (matrix consultation per event row).
- **TEAM-3.3** - replace "prepended to the channel event's body before dispatch" with "rendered into the inbox row's body at write time per recipient". Drop the live "applies to every channel event flowing through ChannelRouter.dispatch" coda.
- **TEAM-5.1 / 5.2 / 5.3** - replace "channel event" with "inbox row" or "inbox message"; routing wording unchanged.

### Delete

- **TEAM-1.7** - the launch flag disclosure UI is gone.
- **TEAM-3.1** - `graftty mcp-channel subscriber connects` is gone; the equivalent (initial team-aware context on session start) is now covered by hook session-start, which has its own coverage.
- **TEAM-3.4** - live `broadcastInstructions` re-broadcast is dropped.

### Add

#### TEAM-7.x - Team Activity Log Window

- **TEAM-7.1** While `agentTeamsEnabled` is true and a team-enabled worktree is focused, the *Window → Team Activity Log* menu item shall be enabled and shall open (or focus) a `TeamActivityLogWindow` scoped to that worktree's team.
- **TEAM-7.2** Right-clicking any team-enabled worktree row shall include a *Show Team Activity…* context-menu item that opens (or focuses) the same `TeamActivityLogWindow` scoped to that worktree's team.
- **TEAM-7.3** When the Team Activity Log window opens, the application shall display every `TeamInboxMessage` for that team in chronological order, oldest at top.
- **TEAM-7.4** When a new inbox row is appended to the team's `messages.jsonl`, the application shall update the open Team Activity Log window within one second of the append.
- **TEAM-7.5** While displaying inbox rows, the application shall render `team_message` rows as chat bubbles attributed to the sender, and event rows (`pr_state_changed`, `ci_conclusion_changed`, `merge_state_changed`, `team_member_joined`, `team_member_left`) as system entries with kind-specific iconography and headline text.
- **TEAM-7.6** When the Team Activity Log window opens, scrolls, or closes, the application shall not advance any per-session cursor or per-worktree watermark.
- **TEAM-7.7** If a row's `kind` is not recognized, the application shall render it as a generic system entry showing the row's body text verbatim.

#### TEAM-8.x - Legacy Channel Cleanup

- **TEAM-8.1** When the application starts, the application shall best-effort run `claude mcp remove graftty-channel`, ignoring non-zero exit and logging failure.
- **TEAM-8.2** When the application starts, the application shall delete `~/.claude/.mcp.json` if it exists and contains no MCP server entries other than `graftty-channel`.
- **TEAM-8.3** When the application starts, the application shall delete `~/.claude/plugins/graftty-channel` if present.
- **TEAM-8.4** When the application starts, if `UserDefaults.standard.string(forKey: SettingsKeys.defaultCommand)` contains the substring `--dangerously-load-development-channels server:graftty-channel`, the application shall strip the substring (with any adjacent leading whitespace), write the cleaned value back to `defaultCommand`, and present a one-shot informational `NSAlert` describing the change.

### Producer-side dispatcher (revisions to TEAM-2.x and TEAM-5.x)

- **TEAM-2.X** When a worktree joins or is removed from a team-enabled repo, the application shall write a `team_member_joined` or `team_member_left` inbox row addressed to the team's lead.
- **TEAM-5.X** When `PRStatusStore.detectAndFireTransitions` produces a transition with `attrs.to == "merged"`, the application shall consult `teamEventRoutingPreferences.prMerged`; otherwise it shall consult `prStateChanged`. For each resolved recipient, the application shall write one inbox row with `kind = pr_state_changed` and a per-recipient `body` rendered through `EventBodyRenderer.body`.
- **TEAM-5.X+1** When `PRStatusStore` detects a CI conclusion change, the application shall consult `teamEventRoutingPreferences.ciConclusionChanged` and write one inbox row per resolved recipient with `kind = ci_conclusion_changed`.
- **TEAM-5.X+2** When merge-state polling detects a mergability transition, the application shall consult `teamEventRoutingPreferences.mergeStateChanged` and write one inbox row per resolved recipient with `kind = merge_state_changed`.

(Numbering placeholders pending implementation; the exact IDs land when the code is written.)

## Tests

### Delete

| Test target | Suites |
|---|---|
| `GrafttyKitTests/Channels` | All channel router, socket server, MCP server, MCP installer, channel event router suites |
| `GrafttyTests/Channels` | `ChannelSettingsObserver` suite, any view tests for the launch-flag block |
| `GrafttyCLITests/MCPChannel` | If exists |

### Add

| Test target | Suite | Coverage |
|---|---|---|
| `GrafttyKitTests/Teams` | `TeamEventDispatcherTests` | Matrix-derived recipient set; per-recipient body render; one inbox row per recipient with the right `kind` and `to`; system endpoint as `from` for non-`team_message` kinds |
| `GrafttyKitTests/Teams` | `TeamInboxObserverTests` | Watches a JSONL file via FSEvents; emits updated arrays on append; survives file-creation-after-watcher (empty inbox case) |
| `GrafttyKitTests/Teams` | `LegacyChannelCleanupTests` | Idempotent across all four steps; tolerates each step's absence; preserves a `.mcp.json` containing other MCP servers |
| `GrafttyKitTests/PRStatus` | `PRStatusStoreInboxBridgeTests` | A simulated transition writes the expected inbox rows for the matrix-resolved recipients |
| `GrafttyKitTests/Teams` | `TeamMembershipEventsInboxTests` | Joined/left transitions write inbox rows addressed to the lead |
| `GrafttyTests/Views` | `TeamActivityLogWindowTests` | Renders chat-bubble vs system-entry by `kind`; auto-scroll-to-bottom only when at bottom; cursor/watermark not advanced on open |
| `GrafttyTests/Views` | `TeamActivityLogRowTests` | Each `kind` renders the expected icon + headline + body; unknown kind falls through to generic |

### Modify

Existing inbox/hook tests in `GrafttyKitTests/Teams` are largely unaffected; the wider `kind` value-set means a couple of fixture builders need a `kind:` parameter. `TeamInboxRequestHandlerTests.sessionStartIncludesRenderedConfiguredPrompt` keeps working as-is.

## TDD build sequence

The migration moves through six phases, each with a green build between. Each phase is independently shippable; the channel router stays alive through phase 4 so behavior is uninterrupted.

1. **Add `TeamEventDispatcher` + tests, no producer wired yet.** Verify dispatcher correctly fans out to inbox given a synthetic `RoutableEvent`. Channel router untouched; behavior unchanged.
2. **Switch producers to write through the dispatcher only.** `PRStatusStore.onTransition` and `TeamMembershipEvents.fire*` move to the dispatcher; `dispatchTeamChannel` in `GrafttyApp.swift` is replaced with a dispatcher call. Channel router becomes orphan code (still wired but receiving zero events); the `--dangerously-load-development-channels` flag still works for any user-launched session that subscribes, but receives nothing because no producer writes to it. The codex/Claude hooks now see PR/CI/membership rows in their inbox.
3. **Add `TeamInboxObserver` + the activity log window + tests.** Wired to a `Window → Team Activity Log` menu item and a sidebar context menu. Verified end-to-end against a live inbox.
4. **Delete the channel surface.** All files in the *Deleted* table above; the `Sources/GrafttyKit/Channels/` and `Sources/Graftty/Channels/` directories empty out and are removed (with the kept files relocated to their new homes in step 5). Settings observer removed. Settings pane label changes. The compile error surface from this step guides the relocations and call-site rewrites.
5. **Relocate kept files.** Move `EventBodyRenderer`, `RoutableEvent`, `TeamEventRoutingPreferences` (renamed) into `GrafttyKit/Teams/`. Move `SettingsKeys` and `DefaultPrompts` into `Graftty/Settings/`. Re-key `channelRoutingPreferences` → `teamEventRoutingPreferences` with one-time UserDefaults migration.
6. **Add `LegacyChannelCleanup` + tests.** Wire into `GrafttyApp.startup`. Run `scripts/generate-specs.py` to regenerate `SPECS.md` against the updated `@spec` annotations; verify CI's `verify-specs` passes.

After phase 6, run `/simplify`, then open a PR.

## Risks and open questions

- **Window-vs-popover for activity log.** A separate window is more visible but adds a new surface to keep maintained. A sheet or popover anchored to the sidebar row would be lighter. Going with **window** because: (a) an activity log is the kind of thing users keep open while working, and a popover dismisses on click-away; (b) it scales better as we add filtering/compose later. Revisit if the window feels heavy.
- **Auto-scroll heuristic.** "Auto-scroll only when at bottom" requires tracking the user's scroll position. SwiftUI's `ScrollView` doesn't expose this directly; we'll need a `ScrollViewReader` + an `onScrollGeometryChange` (macOS 14+) or a scroll-position bridge. If macOS 13 support matters, this gets messier.
- **FSEvents granularity for the observer.** `DispatchSource.makeFileSystemObjectSource` on the file inode works while the file exists; recreating the file (e.g., a fresh inbox after team rename) drops the watcher. We compensate by also watching the parent directory for `.write` and reattaching on `<team>/messages.jsonl` recreation. This pattern is already used elsewhere in `WorktreeMonitor`; the test seam there gives us a known-good shape to copy.
- **Concurrent write safety.** Multiple producers (the dispatcher in-app, the CLI subprocess invoked by `graftty team msg`) may append concurrently. Today, `TeamInbox.append` uses `O_APPEND` plus `flock` advisory locking; verifying with a stress test is part of the dispatcher test plan.
- **Observer re-read cost.** `TeamInboxObserver` does a full JSONL re-read on every FSEvents fire. For an inbox at v1 sizes (low hundreds of rows over a typical session), this is well under a millisecond. If inboxes grow into the tens of thousands, this becomes wasteful and we'd switch to incremental reads (file-offset cursor that survives across fires). Out of scope for v1; flagged as a future optimization if profiles call for it.
- **`team_message` recipient computation.** Today, `team msg` resolves a single recipient by name and addresses one inbox row. Routing through the dispatcher adds a layer of indirection that needs to preserve this exact shape (no broadcast for a unicast message). The dispatcher's contract is "given a `RoutableEvent` and recipients-fn, fan out"; for `team_message`, the recipients-fn returns the one named recipient, not a matrix lookup.
- **Migration timing.** Running `LegacyChannelCleanup` on every launch for users who have already migrated is wasted work but harmless. The cost is one `claude mcp` subprocess and three `FileManager.fileExists` calls. Acceptable for the deprecation window.
- **No real-time prompt fan-out.** Users who edit the session prompt in Settings used to see live MCP sessions update mid-conversation (TEAM-3.4). This goes away. The replacement contract: prompt changes apply at next session start. Settings pane should add a footer note: "Changes apply when each agent session next starts."
