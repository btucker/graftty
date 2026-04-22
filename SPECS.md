# Graftty — EARS Requirements Specification

Requirements for a macOS worktree-aware terminal multiplexer built on libghostty.

## 1. App Layout

### 1.1 Window Structure

**LAYOUT-1.1** The application shall display a single main window with a resizable sidebar on the left and a terminal content area on the right.

**LAYOUT-1.2** The sidebar shall be resizable via a drag handle between the sidebar and the terminal content area.

**LAYOUT-1.3** The terminal content area shall display a breadcrumb bar above the terminal split layout showing, in order: the selected repository's display name, a `/` separator, the worktree's display name (rendered italic as `root` for the repository's main checkout, otherwise the sibling-disambiguated name per `LAYOUT-2.15`), and the branch name in parentheses at caption weight. The worktree's full filesystem path shall be available as a hover tooltip on the worktree-name element rather than rendered inline. When the worktree has a resolved PR/MR, the trailing edge of the breadcrumb shall additionally show the PR button per `PR-3.x`.

### 1.2 Sidebar — Repository List

**LAYOUT-2.1** The sidebar shall display an ordered list of repositories, each expandable to show its worktrees.

**LAYOUT-2.2** Each repository entry shall be collapsible and expandable by clicking its disclosure indicator.

**LAYOUT-2.3** When a repository is expanded, the sidebar shall display the repository's own working directory as the first child entry, labeled by its current branch name.

**LAYOUT-2.4** When a repository is expanded, the sidebar shall display each linked worktree as a child entry beneath the repository's own working directory, labeled by branch name.

**LAYOUT-2.5** The sidebar shall display an "Add Repository" button at the bottom.

**LAYOUT-2.6** When the user clicks a worktree or repository working directory entry, the terminal content area shall switch to display that entry's terminal layout.

**LAYOUT-2.7** When the user right-clicks a sidebar entry, the application shall display a context menu with actions appropriate to the entry's current state.

**LAYOUT-2.8** While a worktree is in the running state, the sidebar shall display one indented child row per terminal pane beneath the worktree entry, each labeled by that pane's current title.

**LAYOUT-2.9** If a terminal pane has no program-set title, then the pane's row shall display its last-known working directory's basename as the label. If the working directory is also unknown (root `/`, empty, or never reported), then the pane's row shall display the fallback label "shell".

**LAYOUT-2.14** When `PaneTitle.display` is asked to render a stored title consisting of only whitespace (spaces, tabs), the application shall fall through to the PWD basename (or the "shell" view-level fallback) rather than rendering visible blank space as the pane label. Real content with surrounding whitespace (e.g., `" claude "`) is preserved verbatim — the check is whitespace-only-vs-content, not a trimming operation.

**LAYOUT-2.15** `WorktreeEntry.displayName(amongSiblingPaths:)` shall grow its disambiguation suffix one path component at a time until the candidate is unique amongst siblings, rather than stopping at a single `<parent>/<leaf>` level. Previous behavior: two siblings like `/repo/.worktrees/deep/ns/feature` and `/repo/.worktrees/other/ns/feature` both rendered as `ns/feature` because the algorithm didn't grow past one parent. With `WorktreeNameSanitizer` now permitting `/` in worktree names (`GIT-5.1`), deeply nested worktrees that share both leaf and immediate parent are plausible. The new algorithm returns `deep/ns/feature` vs `other/ns/feature`; if a sibling's path is a strict suffix of another's (pathological), falls back to the full path so something still distinguishes them.

**LAYOUT-2.13** The application shall reject incoming OSC 2 titles that match either of two shapes: (a) trimmed value matching `^[A-Z_][A-Z0-9_]*=` (an uppercase identifier followed by `=`), or (b) containing the literal substring `GHOSTTY_ZSH_ZDOTDIR` anywhere in the title. Both shapes are command-echo leaks produced by ghostty's shell-integration `preexec` hook when the outer shell runs Graftty's injected `exec zmx attach …` bootstrap line; propagating them to the sidebar would display a 200+ character shell-command string as the pane's title until the inner shell's first prompt overwrites it. Shape (a) catches the pre-`ZMX-6.4` naked-env-assignment form; shape (b) catches the post-`ZMX-6.4` conditional form (`if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR=…; fi; ZDOTDIR=… exec zmx attach …`) and guards against any future bootstrap reshape that preserves the `GHOSTTY_ZSH_ZDOTDIR` marker. The previously stored title (if any) is retained; if none, the pane falls back to the LAYOUT-2.9 chain.

**LAYOUT-2.16** The application shall also reject incoming OSC 2 titles whose grapheme-cluster length exceeds `PaneTitle.maxStoredLength` (200), bounding the transient heap cost of the `titles[TerminalID: String]` dict against a misbehaving program that pushes a multi-kilobyte payload. The cap matches `Attention.textMaxLength` so the pane-title and notify-text surfaces share the same limit. Rejection semantics match `LAYOUT-2.13`: the previously stored title (if any) is retained; if none, the pane falls back to the `LAYOUT-2.9` chain.

**LAYOUT-2.17** The application shall also reject incoming OSC 2 titles containing any Unicode Cc (control) scalar — line feed, carriage return, tab, bell, ANSI escape (`\e`), DEL, or any other C0/C1 control. SwiftUI `Text` with `.lineLimit(1)` clips newlines but renders escape sequences like `\e[31m` as literal `[31m` glyphs (the ESC byte is invisible), producing sidebar strings like `[31mred[0m`. This is the same visual-garbage class as CLI's `ATTN-1.12` for notify text; the server-side OSC 2 surface was previously unchecked. Rejection semantics match `LAYOUT-2.13` / `LAYOUT-2.16`: the previously stored title (if any) is retained; if none, the pane falls back to the `LAYOUT-2.9` chain.

**LAYOUT-2.18** The application shall also reject incoming OSC 2 titles containing any Unicode bidirectional-override scalar — the embedding family (`U+202A`–`U+202C`), the override family (`U+202D`–`U+202E`), or the isolate family (`U+2066`–`U+2069`). These are Cf-category so `LAYOUT-2.17`'s Cc gate misses them, but they reverse surrounding text at render time — a rogue inner-shell program can push `printf '\e]0;\u202Edecoy\u202C\a'` and have the title display RTL-reversed in the pane row, the same "Trojan Source" visual deception (CVE-2021-42574) that `ATTN-1.14` blocks on the notify surface. Natural RTL text (Arabic, Hebrew, Persian) uses character-intrinsic directionality rather than these override scalars and still passes. Rejection semantics match `LAYOUT-2.13` / `LAYOUT-2.16` / `LAYOUT-2.17`.

**LAYOUT-2.10** When the user clicks a pane row, the application shall select that pane's worktree and focus that specific pane.

**LAYOUT-2.11** The sidebar shall display the active worktree row and all its pane rows inside a single unified highlighted block; within that block, the focused pane's row shall additionally be emphasized via text weight and color (no secondary background).

**LAYOUT-2.12** While a worktree entry is not in the stale state, its context menu shall include an "Open Worktree in Finder..." action that opens the worktree's filesystem path in the system file browser via `NSWorkspace.shared.open`.

### 1.3 Adding Repositories

**LAYOUT-3.1** When the user clicks "Add Repository", the application shall present a standard macOS open panel for selecting a directory.

**LAYOUT-3.2** When the user drops a directory onto the sidebar, the application shall add it as a repository.

**LAYOUT-3.3** When the user adds a directory that is a git worktree (rather than a repository root), the application shall trace back to the parent repository, add the full repository with all its worktrees, and auto-select the added worktree.

**LAYOUT-3.4** If the user adds a directory that is not a git repository or worktree, then the application shall display an error message and not add the directory.

**LAYOUT-3.5** If the user adds a repository that is already in the sidebar, then the application shall not create a duplicate and shall select the existing entry.

### 1.4 Removing & Relocating Repositories

#### Removing

**LAYOUT-4.1** When the user right-clicks a repository header row in the sidebar, the application shall display a context menu containing a "Remove Repository" action.

**LAYOUT-4.2** When the user triggers "Remove Repository", the application shall display a confirmation dialog whose informative text explicitly states "This removes the repository from Graftty but does not delete any files from disk."

**LAYOUT-4.3** When the user confirms "Remove Repository", the application shall (a) tear down all terminal surfaces in every worktree of the repository whose `state == .running`, (b) stop the repository-level FSEvents watchers (`.git/worktrees/` and origin refs) and each worktree's per-path, HEAD-reflog, and content watchers, (c) clear the cached PR status and divergence stats for every worktree of the repository, (d) clear `selectedWorktreePath` if it pointed to any worktree in the repository, and (e) remove the repository entry from `AppState`. Steps (a)–(d) must precede (e) for the same orphan-surfaces / orphan-caches reasons as GIT-3.10 / GIT-4.10 / GIT-3.13 and the watcher-fd-lifetime reason as GIT-3.11.

**LAYOUT-4.4** The "Remove Repository" action shall not invoke `git` and shall not modify any files on disk. Worktree directories, branches, and git metadata remain untouched; the operation affects only Graftty's in-memory model and persisted `state.json`.

#### Relocating (Rename / Move recovery)

**LAYOUT-4.5** When the user adds a repository, the application shall record a `URL` bookmark (`URL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)`) for the repository folder and persist it on the `RepoEntry` alongside the path. Bookmark minting failures shall be non-fatal — the repository entry shall be created with a nil bookmark and forgo auto-recovery.

**LAYOUT-4.6** On launch, before FSEvents watchers are installed, for each repository entry whose bookmark is non-nil, the application shall resolve the bookmark via `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`. If the resolved path differs from the stored `RepoEntry.path`, the application shall run the relocate cascade described in LAYOUT-4.8. If the bookmark is resolvable but stale (cross-volume move), the application shall re-mint and persist a fresh bookmark from the resolved URL.

**LAYOUT-4.7** When `WorktreeMonitor` reports a deletion event for a worktree path whose owning repository has a non-nil bookmark, the application shall resolve the bookmark and, if the resolved path differs from the stored `RepoEntry.path`, run the relocate cascade described in LAYOUT-4.8 before applying the existing transition-to-`.stale` path (GIT-3.3). If bookmark resolution fails or the resolved folder is no longer a git repository, the application shall fall through to the existing `.stale` path.

**LAYOUT-4.8** The relocate cascade for a repository resolved to `newURL` differing from the stored path shall: (a) verify a `.git` entry exists at `newURL.path`, aborting if not, (b) stop all existing watchers tied to old paths, (c) run `GitWorktreeDiscovery.discover(repoPath: newURL.path)`, running `git worktree repair` and re-discovering if any previously-known linked worktree is omitted from the discovery result, (d) update the `RepoEntry`'s `path` and `displayName` to the new location, (e) match each existing `WorktreeEntry` to a discovered worktree by **branch name** and preserve `id`, `splitTree`, `state`, `focusedTerminalID`, `paneAttention`, `attention`, and `offeredDeleteForMergedPR`, updating only `path`, (f) clear per-path PR-status and divergence-stats cache entries for every worktree whose path changed, (g) update `selectedWorktreePath` from its old path to the corresponding new path if applicable, and (h) re-install repository-level and per-worktree FSEvents watchers at the new paths. Steps (a)–(c) shall precede (d) so that a discovery failure leaves the model unchanged.

**LAYOUT-4.9** For a repository entry loaded from `state.json` without a bookmark (migration from a pre-LAYOUT-4.5 build), the application shall mint a fresh bookmark from the stored `path` if that path still resolves on disk, and persist it.

**LAYOUT-4.10** The application shall use regular (not security-scoped) bookmarks. Security-scoped bookmarks are unnecessary because Graftty is not sandboxed and `NSOpenPanel` already grants the app arbitrary-path URLs.

### 1.5 Window Lifecycle

**LAYOUT-5.1** When the user closes the main window (Cmd+W, red traffic-light button, or `File → Close`), the application shall keep running as a foreground app — the Dock icon remains visible, background services (socket listener, channel router, stats/PR pollers, filesystem watchers, web access server) keep running, and any running terminal panes stay attached to their underlying zmx sessions. Closing the window is not a quit; the user explicitly issues `Cmd+Q` or `File → Quit` to terminate the app.

**LAYOUT-5.2** When the user activates the app from the Dock (click, `Cmd+Tab`, or Spotlight) while no windows are visible, the application shall display the main window again, populated from the already-in-memory `AppState` (repositories, worktrees, selection, and split trees) and with the `WindowFrameTracker` frame-restoration of `PERSIST-3.4` applied to the recreated `NSWindow`. Existing running terminal panes are re-rendered from the persisted `TerminalManager`'s surface map without recreating their underlying libghostty surfaces or zmx sessions.

**LAYOUT-5.3** The application's one-time startup path (`ghostty_init` and the `ghostty_app_t` construction inside `TerminalManager.initialize()`, the `SocketServer.start()`, the `ChannelRouter.start()`, `reconcileOnLaunch()`, the stats/PR poller `start()` calls, the `restoreRunningWorktrees()` pass, and the `NSApplication.willTerminateNotification` observer registration) shall run exactly once per app-process lifetime, regardless of how many times the root `WindowGroup` scene is instantiated. The SwiftUI reopen flow (`applicationShouldHandleReopen` → `applicationOpenUntitledFile:`) and any future multi-window entry points (`File → New Window`) re-invoke the `WindowGroup` content closure and therefore fire `.onAppear` again; the implementation seam is a `@State` boolean on `GrafttyApp` whose storage persists across scene re-creations. Without this guard, `TerminalManager.initialize()`'s `ghosttyApp == nil` precondition traps the process on the second invocation.

## 2. Worktree Entry States

### 2.1 State Definitions

**STATE-1.1** Each worktree entry shall have one of three states: closed, running, or stale.

**STATE-1.2** While a worktree entry is in the closed state, the sidebar shall display its type icon (house for the main checkout, branch for linked worktrees) in a dimmed foreground color.

**STATE-1.3** While a worktree entry is in the running state, the sidebar shall display its type icon tinted green.

**STATE-1.4** While a worktree entry is in the stale state, the sidebar shall display its type icon tinted yellow, with strikethrough text and grayed-out appearance on the label.

### 2.2 Attention Overlay

**STATE-2.1** A worktree entry in any state may additionally have a worktree-scoped attention overlay, and each of its panes may additionally have a pane-scoped attention overlay keyed by pane. Worktree-scoped overlays are driven by the CLI (`ATTN-1.x`); pane-scoped overlays are driven by per-pane shell-integration events (`NOTIF-2.x`).

**STATE-2.2** While a pane row has a pane-scoped attention overlay, the sidebar shall replace *that pane's* title text with the overlay's text rendered in a red capsule. Sibling pane rows are unaffected.

**STATE-2.3** While a worktree entry has a worktree-scoped attention overlay, the sidebar shall render its text in a red capsule on the worktree's own row (next to the branch label), regardless of the worktree's running state. One worktree-scoped notification produces exactly one visible capsule — pane rows render only their own pane-scoped overlays per STATE-2.2 and do not mirror the worktree-scoped text. A notification set while a worktree is closed therefore remains visible on its row without requiring the user to launch panes first.

**STATE-2.4** When the user clicks a worktree entry that has any attention overlay (worktree-scoped or pane-scoped on any of its panes), the application shall clear all attention overlays on that worktree.

**STATE-2.5** When the CLI sends a clear message for a worktree, the application shall clear the worktree-scoped attention overlay. Pane-scoped overlays are not affected by CLI clear messages; they auto-clear on their own timers.

**STATE-2.6** When an attention overlay was set with an auto-clear duration, the application shall clear that overlay after the duration elapses, unless by then the overlay has already been cleared or replaced by a newer notification. Pane-scoped overlay timers are independent per pane.

**STATE-2.7** When a pane is removed from a worktree (user close, shell exit, or migration to a different worktree via `PWD-x.x`), the application shall drop that pane's pane-scoped attention entry from the source worktree.

**STATE-2.8** If a notify request specifies an auto-clear duration of zero or negative, then the application shall treat the notification as having no auto-clear timer (the overlay persists until cleared by the CLI or replaced by another notification).

**STATE-2.9** If a notify request specifies an auto-clear duration greater than 86400 seconds (24 hours), then the application shall clamp the duration to 86400 seconds rather than schedule a timer that could leak onto the main queue for days or years. This backs up the CLI's `ATTN-1.8` validation for non-CLI socket clients.

**STATE-2.10** When the application receives a `notify` message over the socket whose text is longer than 200 Character (grapheme cluster) units, the application shall silently drop the message rather than render or persist a blob the sidebar capsule cannot display cleanly. This backs up the CLI's `ATTN-1.10` validation for non-CLI socket clients (raw `nc -U`, web surface, custom scripts).

**STATE-2.11** When the user triggers Stop on a running worktree (`TERM-1.2`'s companion — tears down all panes at once while preserving the split tree for re-open), the application shall drop every pane-scoped attention entry on that worktree. Extends `STATE-2.7`'s per-pane rule to the all-panes-at-once case. Without this, a stale pane attention badge from before the Stop would reappear on the fresh pane's sidebar row when the user re-opens the worktree — same-`TerminalID` leaves are reused on re-open to preserve layout, so the attention dictionary must be cleared explicitly. The worktree-level `attention` slot (CLI-notify) is left untouched — it's a worktree-wide concern independent of which panes are alive.

**STATE-2.12** When the application launches and loads persisted `Attention` entries (worktree-level `wt.attention` or pane-level `wt.paneAttention[terminalID]`), for each one that carries a non-nil `clearAfter`, the application shall reschedule the auto-clear timer against the remaining time derived from `attention.timestamp + clearAfter` relative to the current clock. If the deadline has already passed, the timer shall fire on the next main-queue turn (zero-delay `asyncAfter`) and clear the stale entry immediately. Without this resume, a force-quit during a `--clear-after` window leaves the attention stuck in state.json forever because the original `DispatchQueue.main.asyncAfter` is in-memory only. For defensive handling of a persisted timestamp in the future (clock skew, hand-edit), the remaining window shall be clamped to the full `clearAfter` duration measured from now rather than a negative elapsed value.

## 3. Terminal Lifecycle

### 3.1 Starting Terminals

**TERM-1.1** When the user clicks a worktree entry in the closed state that has no saved split tree, the application shall create a single terminal pane with its working directory set to the worktree path and transition the entry to the running state.

**TERM-1.2** When the user clicks a worktree entry in the closed state that has a saved split tree, the application shall recreate terminal panes matching the saved split tree topology, each with its working directory set to the worktree path, and transition the entry to the running state.

**TERM-1.3** When the user triggers Stop on a running worktree that has processes which need quit-confirmation, the application shall present a confirmation dialog whose informative text identifies the worktree by its sidebar display name (per `WorktreeEntry.displayName(amongSiblingPaths:)` / `LAYOUT-2.15`), not its raw `branch` value. For worktrees on a detached HEAD or other git sentinel (`(detached)`, `(bare)`, `(unknown)` — see `PR-7.3`), the display name resolves to the directory basename, which reads naturally ("running processes in my-feature") whereas the raw branch would render as "running processes in (detached)".

### 3.2 Switching Between Worktrees

**TERM-2.1** When the user switches from one running worktree to another, the application shall hide the previous worktree's terminal views without destroying the terminal surfaces or their running processes.

**TERM-2.2** When the user switches back to a previously running worktree, the application shall restore the terminal views with all processes still running.

**TERM-2.3** When the user switches back to a running worktree, the application shall restore keyboard focus to the pane that was focused when the user last switched away.

**TERM-2.4** When the user clicks directly on a terminal pane's view (independent of the sidebar pane-row), the application shall persist that pane as the worktree's last-focused pane in the same model field that `TERM-2.3` reads on return. A visual-only focus change (libghostty / NSView side) without a matching model update would let focus snap back to the first leaf on the next return visit.

### 3.3 Splitting

**TERM-3.1** When the user triggers a horizontal split, the application shall insert a new terminal pane to the right of the focused pane with a 50/50 ratio.

**TERM-3.2** When the user triggers a vertical split, the application shall insert a new terminal pane below the focused pane with a 50/50 ratio.

**TERM-3.3** The new terminal pane created by a split shall have its working directory set to the worktree root path.

### 3.4 Resizing Splits

**TERM-4.1** The application shall display a draggable divider between split panes.

**TERM-4.2** When the user drags a divider, the application shall resize the adjacent panes so that the divider tracks the cursor's position inside the enclosing split container.

**TERM-4.3** When the user releases a divider drag, the application shall persist the new ratio in the worktree's split tree so that the layout survives app restarts. Intermediate positions during the drag need not be persisted.

**TERM-4.4** When a pane is removed from the split tree, the application shall forward the new layout size to libghostty so remaining panes reflow to fill the vacated space.

### 3.5 Closing a Pane

**TERM-5.1** When the user closes a terminal pane, the application shall remove it from the split tree and allow the sibling pane to fill the vacated space.

**TERM-5.2** When the user closes the last terminal pane in a worktree, the application shall transition the worktree entry to the closed state.

**TERM-5.3** When a terminal pane's child process exits, the application shall automatically remove the pane from the split tree and free its surface without requiring user action.

**TERM-5.4** When an auto-closed pane was the last pane in its worktree, the application shall transition the worktree entry to the closed state, matching the user-initiated close behavior.

**TERM-5.5** If `ghostty_surface_new` returns null (libghostty resource exhaustion, malformed config, or any internal rejection) when the application tries to create a terminal surface, the application shall skip the failed leaf and propagate a nil result to the caller rather than trap via `fatalError`. Callers shall treat nil as "surface creation failed": `splitPane` shall roll back its split-tree mutation so no dangling leaf is left behind; `addPane` (CLI `graftty pane add`) shall return a socket `.error("split failed")`; `createSurfaces` (worktree open) shall leave the leaf's surface dict entry empty so the view renders the `Color.black + ProgressView` fallback without crashing the app. Observed pre-fix: `graftty pane add --command ...` triggered a SIGTRAP inside `SurfaceHandle.init` whenever libghostty couldn't build the surface.

**TERM-5.6** When a terminal pane is removed (user close via Cmd+W, shell exit, CLI `graftty pane close`), the application shall promote `focusedTerminalID` to `remainingTree.allLeaves.first` ONLY if the removed pane was the currently-focused one. If a different pane was focused, `focusedTerminalID` shall stay on that pane — it's still present in the remaining tree, and the user's keystrokes should continue to route there. Pre-fix behavior (unconditional promotion to the first leaf) silently jumped focus whenever the user closed a pane other than their focused one, mirroring Andy's "furious when any tool kills a long-running shell unexpectedly" pain point in the focus-redirection dimension.

**TERM-5.7** When libghostty's `close_surface_cb` fires for a pane whose `SurfaceHandle` has already been torn down by Graftty (e.g. via `terminalManager.destroySurfaces(...)` during a `Stop Worktree` action), the application's close-event handler shall observe the missing surface handle and no-op rather than modifying the worktree's `splitTree`. Without this guard, the async close-event cascade that follows `Stop` would re-enter `closePane` for each leaf and strip them from the preserved split tree, emptying `splitTree` and violating `TERM-1.2`'s "re-open recreates the saved layout" contract. The guard applies only to library-initiated close events; user-initiated closes are covered by `TERM-5.8`.

**TERM-5.8** When the user explicitly invokes a pane close (`Cmd+W`, CLI `graftty pane close <id>`, or a context-menu Close action) against a leaf whose `SurfaceHandle` is absent — i.e. a phantom pane whose surface never created successfully because libghostty refused (OOM / resource pressure, `TERM-5.5`) — the application shall still remove the leaf from the worktree's `splitTree`. Without this, a phantom leaf is uncloseable: the sidebar renders a black / progress placeholder, `pane list` reports it, but every close path silently no-ops via `TERM-5.7`'s guard. The implementation seam is a `userInitiated` parameter on `closePane`: user paths pass `true` to bypass the handle guard; libghostty's async `close_surface_cb` passes `false` (default) so Stop cascades continue to preserve the tree.

**TERM-5.9** When `SurfaceHandle.setFrameSize` forwards a backing-pixel dimension to `ghostty_surface_set_size`, the conversion from `CGFloat` to `UInt32` shall be performed via a defensive clamp that maps `NaN` and values `≤ 1` to `1`, `+∞` and values `≥ UInt32.max` to `UInt32.max`, and all other finite values to their truncated `UInt32` representation. Naive `UInt32(max(1, Int(dim)))` traps on `NaN` and on out-of-`Int`-range values; SwiftUI `GeometryReader` has been observed to emit `.infinity` transiently during certain rebinding flows, and a trap on the view's layout pass crashes the whole process (every open pane dies). The helper is `SurfacePixelDimension.clamp(_:)` in GrafttyKit so the rule is unit-testable without an NSView host.

### 3.6 Stopping a Worktree

**TERM-6.1** When the user triggers "Stop" on a running worktree, if any terminal surface has a running process, then the application shall display a confirmation dialog before proceeding.

**TERM-6.2** When the user confirms stopping a worktree, the application shall close and free all terminal surfaces in the worktree's split tree, preserve the split tree topology, and transition the entry to the closed state.

### 3.7 Focus Management

**TERM-7.1** When the user clicks a terminal pane, the application shall set keyboard focus to that pane.

**TERM-7.2** The application shall support keyboard navigation between panes using directional shortcuts (e.g., Cmd+Opt+Arrow).

**TERM-7.3** When the user navigates between panes via directional keyboard (Cmd+Opt+Arrow, or libghostty's `goto_split` left/right/up/down actions), the application shall move focus to the leaf that is spatially adjacent in the requested direction — determined by walking the split tree from the focused leaf up to the nearest ancestor whose split orientation matches the motion axis and whose source-side subtree contains the current leaf, then descending into the opposite subtree's near-edge leaf. If no such ancestor exists, the application shall leave focus unchanged rather than wrapping around the tree in DFS order.

**TERM-7.6** When the user invokes `Previous Pane` / `Next Pane` (libghostty's `goto_split:previous` / `goto_split:next`), the application shall cycle focus through the worktree's leaves in DFS (reading) order regardless of spatial layout. This is distinct from the directional arrow-key navigation in `TERM-7.3` — round-robin cycling is an intentional second mode, not a fallback.

**TERM-7.4** When the application launches with a selected running worktree, the application shall automatically promote that worktree's focused pane to the window's first responder so the user can begin typing without first clicking inside a terminal.

**TERM-7.5** When the user selects a worktree or pane row in the sidebar, the application shall promote the target pane's `NSView` to the window's first responder so subsequent keystrokes route to that pane without an intermediate click.

**TERM-7.7** When a pane is created via a split (`splitPane`), a CLI-triggered add (`pane add`), or any other path that mints a fresh `SurfaceHandle` before SwiftUI has had a chance to insert the view into the window hierarchy, the application shall still promote the new pane's `NSView` to the window's first responder — overriding the previously-focused pane whose view is still the current first responder. The implementation seam is `SurfaceHandle.setFocus(true)`: if the target view is already attached to a window, first responder is claimed synchronously; if not, the claim is re-enqueued on the main queue so it runs after SwiftUI mounts the view. Pre-fix behavior: after `Cmd+D`, the model's `focusedTerminalID`, the sidebar's focus highlight, and libghostty's focused-cursor rendering all pointed at the new pane, yet AppKit's first responder remained the previously-focused pane — so keystrokes kept landing in the old pane. `SurfaceNSView.viewDidMoveToWindow` cannot fix this on its own because its first-responder grab deliberately yields to an existing `SurfaceNSView` first responder (so an incidentally-remounted view doesn't yank focus from the user); an authoritative `setFocus(true)` call is the signal that distinguishes the two cases.

### 3.8 Context Menu

**TERM-8.1** When the user right-clicks a terminal pane, the application shall display a context menu. When the user Control-clicks with the left mouse button on a terminal pane, the application shall display the same context menu, unless the terminal has enabled mouse capturing in which case the click shall be delivered to the terminal as a right-mouse-press instead.

**TERM-8.2** The context menu shall contain the following items, in this order, separated by dividers as shown:
  - Copy (only when the terminal has a non-empty text selection)
  - Paste
  - ---
  - Split Right
  - Split Left
  - Split Down
  - Split Up
  - ---
  - Reset Terminal
  - Toggle Terminal Inspector
  - Terminal Read-only

**TERM-8.3** When the user selects "Copy", the application shall copy the current terminal selection to the system clipboard.

**TERM-8.4** When the user selects "Paste", the application shall insert the system clipboard's text contents into the terminal.

**TERM-8.5** When the user selects "Split Right", "Split Left", "Split Down", or "Split Up", the application shall create a new terminal pane adjacent to the focused pane in the corresponding direction.

**TERM-8.6** When the user selects "Reset Terminal", the application shall reset the terminal's screen and state to a pristine post-init condition.

**TERM-8.7** When the user selects "Toggle Terminal Inspector", the application shall toggle the display of libghostty's built-in debug inspector overlay on the terminal.

**TERM-8.8** While a terminal pane is in read-only mode, the "Terminal Read-only" menu item shall display a checkmark.

**TERM-8.9** When the user selects "Terminal Read-only", the application shall toggle the terminal's read-only state — in read-only mode the terminal renders updates but drops keyboard input from the user.

## 4. Worktree Discovery & Monitoring

### 4.1 Initial Discovery

**GIT-1.1** When a repository is added, the application shall run `git worktree list --porcelain` and populate the sidebar with all discovered worktrees in the closed state.

**GIT-1.2** When the user picks a folder in the Add Repository flow and `git worktree list --porcelain` fails on that folder (not a git repository, missing `git` binary, permission denied), the application shall present an `NSAlert` showing the folder path and the underlying error message, rather than silently returning from the Task. Without this, the user clicks a menu, picks a folder, and sees nothing happen — no log, no error, no repo added.

**GIT-1.3** When the pre-`discover` step `GitRepoDetector.detect(path:)` throws while resolving the user-picked folder (e.g. the `.git` file exists but is unreadable due to permissions or a truncated write), the application shall present an `NSAlert` mirroring `GIT-1.2` rather than swallowing the throw via `try?`. Pre-fix the sync-detect path was the one remaining silent-return in the Add Repository flow — the async discover path (`GIT-1.2`) and the Delete Worktree path (`GIT-4.11`) already alert on throws, so the sync-detect throw stood out as the odd silent failure.

**GIT-1.4** When `GitRepoDetector.detect(path:)` reads a linked worktree's `.git` file and finds a `gitdir: <path>` entry, it shall resolve a relative `<path>` against the worktree directory (the directory containing the `.git` file) rather than feeding it verbatim to `realpath(3)`. Git ≥ 2.52 with `worktree.useRelativePaths=true` writes entries like `gitdir: ../repo/.git/worktrees/name`; passing that to `realpath` resolves against the process cwd — usually unrelated to the worktree dir — so the returned `repoPath` was wrong and the "Add Repository" flow attached a dragged worktree to the wrong repo (or none at all). The absolute-gitdir case (older git and the default config) is unaffected. Mirrors `GIT-3.14`'s same-class fix in `WorktreeMonitor.resolveHeadLogPath`.

### 4.2 Filesystem Monitoring

**GIT-2.1** While a repository is in the sidebar, the application shall watch the repository's `.git/worktrees/` directory for changes using FSEvents.

**GIT-2.2** When a change is detected in `.git/worktrees/`, the application shall re-run `git worktree list --porcelain` and reconcile the results against the current model.

**GIT-2.3** While a repository is in the sidebar, the application shall watch each worktree's directory path for deletion using FSEvents.

**GIT-2.4** While a repository is in the sidebar, the application shall detect every operation that moves a worktree's HEAD — including commits on the current branch, `checkout`, `switch`, `reset`, `merge`, and `rebase` — and surface each as a HEAD-reference change.

**GIT-2.5** While a repository is in the sidebar, the application shall watch `<repoPath>/.git/logs/refs/remotes/origin/` using FSEvents so that any operation which advances a remote-tracking ref — `git push` (the common `gh pr create` path), `git fetch`, and prune — surfaces as an origin-ref change. One watch per repository covers all linked worktrees, since they share the main checkout's git directory.

**GIT-2.6** While a worktree is in the sidebar and non-stale, the application shall recursively watch the worktree's directory with `FSEventStreamCreate` (coalescing latency 0.5s) so that working-tree edits, stages / unstages via `.git/index`, and untracked-file creation surface as content-change events. Events for the worktree root, the bare `.git` directory, and the `.git/objects/` subtree shall be filtered out: the root and `.git` are coarse parent-mtime bumps that fire alongside more specific descendant events and carry no additional signal, and `.git/objects/` is pure pack-churn noise from `git gc` / pack writes. The watched path shall be resolved via `realpath(3)` before use because FSEvents always reports canonical paths (e.g. `/private/var/...` rather than `/var/...`) and an unresolved root makes the filter's `hasPrefix` comparison miss every event. The other watchers in GIT-2.1–GIT-2.5 use kqueue vnode sources (`DispatchSourceFileSystemObject`), which cannot watch a subtree recursively; the real FSEvents API is used here because the working tree is inherently recursive.

**GIT-2.7** When a content-change event fires for a worktree, the application shall trigger a divergence-stats recompute for that worktree. The recompute is idempotent via `WorktreeStatsStore.inFlight` deduplication, so a burst of file events coalesces to at most one in-flight git subprocess pipeline.

### 4.3 Change Handling

**GIT-3.1** When a new worktree is detected, the application shall add a new entry in the closed state and briefly flash its background highlight.

**GIT-3.2** When a worktree is removed via `git worktree remove`, the application shall transition the entry to the stale state.

**GIT-3.3** When a worktree's directory is deleted externally, the application shall transition the entry to the stale state.

**GIT-3.4** While a worktree entry is in the stale state and was running, the application shall keep terminal surfaces alive until the user explicitly stops the entry.

**GIT-3.5** When a worktree's HEAD reference changes, the application shall update the entry's branch label in the sidebar.

**GIT-3.6** While a worktree entry is in the stale state, the context menu shall include a "Dismiss" action that removes the entry from the sidebar and drops its cached PR status, divergence stats, and any other per-path observable state so a future worktree added at the same path starts from a clean slate.

**GIT-3.7** When a worktree entry in the stale state reappears in `git worktree list --porcelain` output (e.g., after a transient FSEvents glitch, a `git worktree repair`, or a force-remove followed by a fresh `git worktree add` at the same path), the application shall transition the entry back to the closed state and adopt any updated branch label.

**GIT-3.8** When the user clicks a stale worktree entry whose directory still exists on disk (the stale state was a lingering artifact of a prior transient filesystem event), the application shall resurrect the entry to the closed state, clear any leftover split tree referencing destroyed surfaces, and proceed with the normal closed→running transition so terminals start rather than the content area showing the `Color.black + ProgressView` terminal-not-yet-created placeholder indefinitely.

**GIT-3.9** When resurrecting a worktree entry that was stale-while-running (per `GIT-3.4`, which kept surfaces alive across the stale transition), the application shall tear down every terminal surface in the entry's previous split tree *before* creating the fresh surface for the resurrected entry, so the old surfaces' render/IO/kqueue threads stop rather than running orphaned — orphaned surfaces have been observed to corrupt libghostty's internal `os_unfair_lock` during window resize and SIGKILL the app.

**GIT-3.10** When the user triggers "Dismiss" on a stale worktree whose surfaces are still alive per `GIT-3.4` (stale-while-running), the application shall tear down every terminal surface in the entry's split tree before removing the entry from the model, and shall clear `selectedWorktreePath` if the dismissed worktree was currently selected. Skipping the surface teardown is the same orphan-surfaces shape as `GIT-3.9` (different entry point) and has the same crash signature.

**GIT-3.11** `WorktreeMonitor`'s `DispatchSource` watchers (one per watched worktree-directory, worktree-path, HEAD reflog, and origin-refs directory) shall release their underlying file descriptors on cancel. Specifically: `createFileWatcher` installs `source.setCancelHandler { close(fd) }`, and no `watch*` method shall override that handler — DispatchSource allows only one cancel handler per source, and an override silently leaks the fd. A long-running session that churns repos (add/remove, stale/resurrect) would otherwise monotonically grow its open-fd count and eventually hit macOS's 256-fd ulimit, failing every subsequent `open` (including socket accepts, terminal PTYs, and config reloads).

**GIT-3.12** When `GitWorktreeDiscovery.discover(repoPath:)` throws (missing `git` binary, non-repo path passed due to a stale state.json entry, subprocess exceeding the timeout, transient FS glitch), the application shall log the failure via `NSLog` at every call site in `GrafttyApp` — `reconcileOnLaunch`, `worktreeMonitorDidDetectChange`, and `worktreeMonitorDidDetectBranchChange` — rather than swallow via `try?`. Analogue of `ATTN-2.7` / `PERSIST-2.2`. Without this, a transient discovery failure silently skips that repo's reconcile tick: Andy creates a new worktree, FSEvents fires, discover throws once, and the worktree never appears in the sidebar with no trail of why.

**GIT-3.13** When a worktree transitions to the `.stale` state — regardless of which FSEvents channel observed the disappearance (`worktreeMonitorDidDetectDeletion` for the worktree-directory watcher, or the reconcile-driven transitions in `reconcileOnLaunch` / `worktreeMonitorDidDetectChange` when `git worktree list --porcelain` stops listing the entry) — the application shall call `statsStore.clear(worktreePath:)` and `prStatusStore.clear(worktreePath:)` so the cached stats and PR status don't linger on the stale entry. Matches `GIT-4.10`'s rule for the explicit-remove path; the three stale-transition paths must be symmetric, otherwise a worktree made stale by reconcile keeps rendering its old PR badge until a Dismiss or Delete fires.

**GIT-3.14** When `WorktreeMonitor.resolveHeadLogPath` reads a linked worktree's `.git` file and finds a `gitdir: <path>` line, it shall resolve a relative `<path>` against the worktree directory rather than feeding it verbatim to `open(2)`. Git ≥ 2.52 with `worktree.useRelativePaths=true` writes relative gitdir entries like `gitdir: ../.git/worktrees/name`; passing that to `open` resolves it against the process cwd — usually nothing like the worktree dir — so the HEAD-reflog watcher silently targets the wrong path (or fails outright). The absolute-gitdir case (older git and the default config) is unaffected.

**GIT-3.15** When a worktree transitions to the `.stale` state — regardless of which channel observed it (`worktreeMonitorDidDetectDeletion` for the FSEvents path, or `reconcileOnLaunch` / `worktreeMonitorDidDetectChange` when `git worktree list --porcelain` stops listing an entry) — the application shall call `WorktreeMonitor.stopWatchingWorktree(_:)` to drop the path / HEAD-reflog / content watchers for that worktree. Otherwise the watchers stay registered with fds bound to the reaped inode. A subsequent `git worktree add` at the same path (resurrection) would hit the reconciler's "idempotent" re-register (`guard sources[key] == nil else { return }`) and leave the new inode uncovered — the next `rm -rf` would go undetected, and `git commit` would not refresh PR / divergence state until the 30s / 5m polling safety nets catch up. The three stale-transition paths must be symmetric on this, matching `GIT-3.13`'s rule for the stats / PR cache clear.

**GIT-3.16** When a stale worktree is resurrected via user click (`selectWorktree` per `GIT-3.8`) rather than via the reconciler, the application shall re-arm the path / HEAD-reflog / content watchers for the worktree on the new inode. A user-click resurrection does not fire a `.git/worktrees/` FSEvents tick (no git subprocess ran), so the reconciler's re-register loop in `worktreeMonitorDidDetectChange` never runs — without this, the resurrected worktree has no real-time stats / PR refresh until the 30s / 5m polling safety nets catch up or the user triggers a git operation that bumps the `.git/worktrees/` dir.

### 4.4 Deleting a Worktree

**GIT-4.1** While a worktree entry is not in the stale state and is not the repository's main checkout, the context menu shall include a "Delete Worktree" action.

**GIT-4.2** When the user triggers "Delete Worktree", the application shall display a confirmation dialog whose informative text explicitly states "This will delete the worktree but not the branch."

**GIT-4.3** When the user confirms "Delete Worktree", the application shall run `git worktree remove <path>` in the repository, leaving the worktree's branch ref untouched.

**GIT-4.4** If `git worktree remove` fails (e.g., the worktree contains uncommitted changes), then the application shall surface git's stderr in an error alert and shall leave the worktree entry and any running terminal surfaces intact.

**GIT-4.5** When `git worktree remove` succeeds on a worktree in the running state, the application shall tear down all terminal surfaces in the worktree's split tree.

**GIT-4.6** When `git worktree remove` succeeds, the application shall remove the worktree entry from the sidebar, and if that worktree was the selected worktree the application shall clear the selected-worktree state so the terminal content area shows the "no worktree selected" placeholder.

**GIT-4.7** When the application first observes a worktree's associated pull request transition into the merged state — whether from open, from no-PR-cached, or from a different previously-merged PR number — the application shall present an informational dialog offering to delete the worktree. The dialog's message text shall cite the PR number, its informative text shall read "Delete the worktree now? This will delete the worktree but not the branch.", and its buttons shall be "Delete Worktree" and "Keep".

**GIT-4.8** If the user confirms the offer dialog from GIT-4.7 by clicking "Delete Worktree", the application shall proceed directly to `git worktree remove` without re-prompting — the offer dialog IS the confirmation. The resulting success and failure paths shall be identical to GIT-4.5 and GIT-4.4 (teardown on success, stderr surfaced on failure).

**GIT-4.9** The application shall offer the dialog described in GIT-4.7 at most once per (worktree, PR-number) pair, by persisting the offered PR number on the worktree entry. On a subsequent poll that still reports the same merged PR, on an app restart that re-resolves the same already-merged PR, or if the user dismisses the dialog with "Keep", the application shall not re-offer until the worktree's PR number changes. The application shall not present this dialog for the repository's main checkout (GIT-4.1 forbids deleting it) nor for worktrees in the stale state.

**GIT-4.10** When `git worktree remove` succeeds (via either the menu-initiated Delete Worktree path per GIT-4.3 or the PR-merged offer path per GIT-4.8), the application shall drop the worktree's cached entries from every per-path observable store (PR status, divergence stats) before removing the entry from the model. Matches the contract GIT-3.6's Dismiss path already enforces — without it, orphan cache entries survive indefinitely and bleed into a future same-path re-add on its first reconcile tick.

**GIT-4.11** When `performDeleteWorktree` fails with a non-`gitFailed` error (git binary missing, subprocess launch failure, timeout), the application shall surface the error in an `NSAlert` analogous to `GIT-4.4`, not silently return. Without this, the user clicks Delete Worktree and nothing happens — matches the shape of the cycle 101 `addRepoFromPath` (GIT-1.2) silent-failure fix, on the symmetric delete path.

### 4.5 Creating a Worktree

**GIT-5.1** When the user types or pastes into the "Worktree name" or "Branch" field of the Add Worktree sheet, the application shall replace any character outside the set `A-Z a-z 0-9 . _ - /` with `-`, and shall collapse any run of consecutive `-` (including dashes the user typed directly) into a single `-`. `/` is permitted so branch names can use the conventional namespace separator (`feature/foo`); the resulting worktree path becomes a nested `.worktrees/<ns>/<leaf>` directory that `git worktree add` creates. Ref-format rules git already enforces (`//`, leading/trailing `/`, components beginning with `.`) are not duplicated here — git reports them at submit time. The replacement shall apply live on every edit so the field shows only sanitized content.

**GIT-5.2** While the branch field is still mirroring the worktree name (i.e. the user has not manually diverged the branch field), the sanitized worktree name shall be propagated into the branch field on each edit so both fields stay in sync.

**GIT-5.3** When the user submits the Add Worktree sheet, the application shall additionally strip leading and trailing `-`, `.`, and whitespace from both values before invoking `git worktree add`. Live editing intentionally preserves those characters (trimming them as-you-type would swallow the separator between words); the final submit trim ensures no request ever asks git to create `-foo` or `foo.` as a branch.

## 5. Attention Notification System

### 5.1 CLI Tool

**ATTN-1.1** The application shall include a CLI binary (`graftty`) in the app bundle at `Graftty.app/Contents/Helpers/graftty`. The CLI is placed in `Contents/Helpers/` (not `Contents/MacOS/`) because on macOS's default case-insensitive APFS, the binary name `graftty` collides with the app's main executable `Graftty` if both are in the same directory. The Swift Package Manager product that builds this binary is named `graftty-cli` for the same reason; it is renamed to `graftty` when installed into the app bundle. When the user invokes "Install CLI Tool…" and the bundled CLI is missing at this path (typical for a raw `swift run`-built Graftty that hasn't been put through `scripts/bundle.sh`), the application shall surface an actionable "CLI Binary Not Found" alert rather than create a dangling symlink at `/usr/local/bin/graftty`. `CLIInstaller.plan` returns `.sourceMissing(source:)` in this case.

**ATTN-1.2** The CLI shall support the command `graftty notify "<text>"` to set attention on the worktree containing the current working directory.

**ATTN-1.3** The CLI shall support the flag `--clear-after <seconds>` to auto-clear the attention after a specified duration.

**ATTN-1.4** The CLI shall support the command `graftty notify --clear` to clear attention on the current worktree.

**ATTN-1.5** The CLI shall resolve the current worktree by walking up from `$PWD` looking for a `.git` file (linked worktree) or `.git` directory (main working tree). When normalizing `$PWD` before the walk, the CLI shall use POSIX `realpath(3)` semantics (physical path, `/tmp` → `/private/tmp`) rather than Foundation's `URL.resolvingSymlinksInPath` (logical path, which collapses the other direction). This must match the path form that `git worktree list --porcelain` emits — the same form the app's `state.json` stores — so the tracked-worktree lookup matches when the user's `$PWD` traverses a private-root symlink. Without this, `graftty notify` fails `"Not inside a tracked worktree"` from any `/tmp/*` or `/var/*` worktree even when the worktree is tracked.

**ATTN-1.6** If `graftty notify` is invoked with both a `<text>` argument and the `--clear` flag, then the CLI shall exit non-zero with a usage error rather than silently dropping the text and performing a clear.

**ATTN-1.7** If `graftty notify` is invoked with text that is empty or contains only whitespace characters (including tabs and newlines), then the CLI shall exit non-zero with a usage error rather than sending a visually-empty attention badge.

**ATTN-1.8** If `graftty notify` is invoked with `--clear-after` greater than 86400 seconds (24 hours), then the CLI shall exit non-zero with a usage error. Values at or below 86400 are accepted; values at or below zero are handled server-side per `STATE-2.8`.

**ATTN-1.9** If `graftty notify` is invoked with both `--clear` and `--clear-after`, then the CLI shall exit non-zero with a usage error. `--clear-after` applies only to notify messages; combining it with `--clear` is ambiguous and previously resulted in the `--clear-after` value being silently dropped.

**ATTN-1.10** If `graftty notify` is invoked with text longer than 200 Character (grapheme cluster) units, then the CLI shall exit non-zero with a usage error. Attention overlays are designed for short status pings rendered in a narrow sidebar capsule; large inputs (e.g. a piped `git log` or `ls -la`) blow up layout and drown the intended signal.

**ATTN-1.11** Each row of `graftty pane list` output shall be formatted as `<marker> <id><padding> <title?>` where `marker` is `*` for the focused pane or a space otherwise, `id` is right-padded to at least width 3 for typical layouts (so ids 1–99 align their titles at the same column), and exactly one space separates the id from the title regardless of id width — so ids ≥ 100 don't collide visually with their title. Panes with no title render without trailing whitespace. A whitespace-only title is treated the same as nil / empty (same blank-vs-content rule as `LAYOUT-2.14`) so the row clips cleanly rather than rendering `*  3      ` with trailing spaces where a label should be.

**ATTN-1.12** If `graftty notify` is invoked with text containing any Unicode Cc (control) scalar — line feed, carriage return, tab, bell, ANSI escape, DEL, null byte, or any other C0/C1 control — then the CLI shall exit non-zero with a usage error reading "Notification text cannot contain control characters (newlines, tabs, ANSI escapes, or other non-printable characters)". The sidebar capsule renders `Text(attentionText)` with `.lineLimit(1)` + `.truncationMode(.tail)`; newlines clip to the first line, tabs render at implementation-defined width, and ANSI escape sequences like `\e[31m` show up as literal glyphs (the ESC byte is invisible in SwiftUI Text, producing strings like `[31mred[0m`). All of those are data loss or visual garbage from the user's perspective. The server-side `Attention.isValidText` applies the same rejection (silently drops) as a backstop for raw socket clients (`nc -U`, web surface, custom scripts) bypassing the CLI.

**ATTN-1.13** If `graftty notify` is invoked with text whose scalars are entirely Unicode Format-category (Cf) and/or whitespace — e.g., `"\u{FEFF}"` (BOM), `"\u{200B}\u{200C}\u{FEFF}"` (mixed zero-width scalars) — then the CLI shall reject the message as `emptyText`. Swift's `whitespacesAndNewlines` trim strips some Cf scalars (ZWSP U+200B) but not others (BOM U+FEFF), producing a would-be zero-width badge; the extra allSatisfy check closes the gap. Mixed content that still carries at least one visible scalar (including ZWJ-joined emoji sequences like `👨‍👩‍👧`) remains valid. `Attention.isValidText` applies the same rejection server-side.

**ATTN-1.14** If `graftty notify` is invoked with text containing any Unicode bidirectional-override scalar — the embedding family (`U+202A`–`U+202C`), the override family (`U+202D`–`U+202E`), or the isolate family (`U+2066`–`U+2069`) — then the CLI shall reject the message as `bidiControlInText` with the user-visible error "Notification text cannot contain bidirectional-override characters (U+202A-U+202E, U+2066-U+2069) — they visually reverse the text in the sidebar". These scalars are Unicode Format (Cf) so they slip past both `ATTN-1.12`'s Cc-control check and `ATTN-1.13`'s all-Cf-invisible check when mixed with visible content; a notify like `"\u{202E}evil"` renders RTL-reversed in the sidebar capsule (the "Trojan Source" class of visual deception, CVE-2021-42574). RTL-natural text (Arabic, Hebrew) uses character-intrinsic directionality and does not use these override scalars, so it still validates cleanly. `Attention.isValidText` applies the same rejection server-side for raw socket clients that bypass the CLI.

### 5.2 Communication Protocol

**ATTN-2.1** The application shall listen on a Unix domain socket at `~/Library/Application Support/Graftty/graftty.sock`.

**ATTN-2.2** The CLI shall communicate with the application by sending JSON messages over the Unix domain socket.

**ATTN-2.3** The application shall support the following message types over the socket:
- Notify: `{"type": "notify", "path": "<worktree-path>", "text": "<text>"}`
- Notify with auto-clear: `{"type": "notify", "path": "<worktree-path>", "text": "<text>", "clearAfter": <seconds>}`
- Clear: `{"type": "clear", "path": "<worktree-path>"}`

**ATTN-2.4** The application shall set the environment variable `GRAFTTY_SOCK` in each terminal surface's environment, pointing to the socket path.

**ATTN-2.5** The CLI shall read the `GRAFTTY_SOCK` environment variable to locate the socket. If the variable is unset or set to an empty string, the CLI shall fall back to the default path `<Application Support>/Graftty/graftty.sock`. Treating empty as unset prevents a blank `GRAFTTY_SOCK=` line (e.g. from a sourced `.env` file) from redirecting the CLI to a nonexistent socket at the empty path.

**ATTN-2.6** When the application receives a `notify` message over the socket whose text is empty or contains only whitespace characters, the application shall silently drop the message rather than render an invisible attention overlay. This backs up the CLI's ATTN-1.7 validation for non-CLI socket clients.

**ATTN-2.7** When `SocketServer.start()` fails during application startup, the application shall (a) log the error via `NSLog` (surfacing it in Console.app), (b) retain the error in `SocketServer.lastStartError` for in-process introspection, and (c) present a one-time `NotifySocketBanner` alert describing what broke and suggesting recovery steps (quit+relaunch, clear `GRAFTTY_SOCK`). The banner mirrors the `ZmxFallbackBanner` pattern from `ZMX-5.2`. The app shell historically wrapped `start()` in `try?`, producing a running Graftty with a dead control socket and no diagnostic trail — ATTN-3.4 recovers this case at the CLI side, ATTN-2.7 surfaces the root cause at the app side upfront rather than waiting for the user to trip over the CLI.

**ATTN-2.8** The application's Unix-domain socket server shall call `listen(2)` with a backlog of 64, not the historical default of 5. A user scripting parallel `graftty notify` invocations (e.g. from a hook that fans out across a monorepo) can easily exceed 5 pending connections, and the extra backlog entries cost negligible kernel resources while preventing spurious `ECONNREFUSED` for the later clients.

**ATTN-2.9** Each accepted client connection shall have `SO_RCVTIMEO` set to 2 seconds before the server enters its read loop. Without this, a silent peer (a `nc -U` that connects but never writes, a crashed CLI client whose kernel-level connection lingers, etc.) pins the server's serial dispatch queue on a blocking `read(2)` indefinitely — and since `acceptConnection` shares that queue, every subsequent `graftty notify` hangs for the duration. 2 seconds mirrors the CLI's client-side timeout (`ATTN-3.3`); JSON notify/pane messages are ≤~1 KB over a local socket, so any well-behaved client finishes in milliseconds.

**ATTN-2.10** When a request-style socket message (`list_panes`, `add_pane`, `close_pane`) hands its handler to the main queue via `DispatchQueue.main.async`, the server shall wait at most `SocketServer.onRequestTimeout` (5 seconds in production) for the handler to return. If the handler has not completed within that window — main queue stalled by a modal dialog, heavy synchronous work, or a main-actor reentrancy bug — the server shall close the client fd without writing a response rather than pin its serial worker on `semaphore.wait()` indefinitely. The CLI's 2s client-side timeout (`ATTN-3.3`) then surfaces the event as a clean `socketTimeout`. The main-queue closure may still complete and write into the retained response box after the worker has returned; its `signal()` lands on a no-longer-awaited semaphore harmlessly.

**ATTN-2.11** Each accepted client connection's read loop shall cap total accumulated bytes at `SocketServer.maxPerClientBytes` (1 MB in production) before giving up and closing the fd. Without this, a local writer that keeps the pipe continuously full (`cat /dev/urandom | nc -U graftty.sock`) never trips `SO_RCVTIMEO` (which fires only when data STOPS flowing) — the historical unbounded read loop would grow the per-connection buffer until process memory was exhausted. 1 MB is 1000× the ≤~1 KB typical JSON notify/pane message size, so well-behaved clients never hit it. Tests can shrink the cap to bound per-test runtime.

### 5.3 Error Handling

**ATTN-3.1** If the application is not running, then the CLI shall print "Graftty is not running" and exit with code 1.

**ATTN-3.2** If the current working directory is not inside a tracked worktree, then the CLI shall print "Not inside a tracked worktree" and exit with code 1.

**ATTN-3.3** If the socket is unresponsive, then the CLI shall time out after 2 seconds, print an error, and exit with code 1.

**ATTN-3.4** If the control socket file exists on disk but `connect()` fails with `ECONNREFUSED`, then the CLI shall print "Graftty is running but not listening on `<path>`. Quit and relaunch Graftty to reset the control socket." and exit with code 1, rather than conflating this stale-listener case with `ATTN-3.1`'s "not running" message. The conditions differ: `ENOENT` (file missing) means the app never created the socket, whereas `ECONNREFUSED` on an existing file means a prior Graftty instance crashed without unlinking, or its `SocketServer.start()` failed after the file was created but before listening began.

**ATTN-3.5** When a `pane list`, `pane add`, or `pane close` request targets a tracked worktree that is not in the `.running` state (i.e., no terminals currently alive in it), the server shall respond with `.error("worktree not running")`. `list` in particular shall NOT return an empty `.paneList` — that reads as a silent success to callers scripting `pane list | wc -l` or similar, when in fact the worktree needs to be clicked to start its terminals.

**ATTN-3.6** The CLI's response-read path shall cap total accumulated bytes at 1 MB via `SocketIO.readAll(fd:cap:)`. Mirrors the server-side `ATTN-2.11`: `SO_RCVTIMEO` only fires on idle pipes, so a misbehaving or compromised server that keeps the pipe continuously full would otherwise grow the CLI's per-response buffer without bound. 1 MB is 1000× the typical ≤1 KB response size; a legit server never hits it.

### 5.4 CLI Distribution

**ATTN-4.1** The application shall provide a menu item (Graftty -> Install CLI Tool...) to create or update a symlink at `/usr/local/bin/graftty` pointing to the CLI binary in the app bundle. CLI installation is opt-in via this menu item; the application shall not auto-prompt for installation on launch.

## 6. Persistence

### 6.1 Storage

**PERSIST-1.1** The application shall store all persistent state in `~/Library/Application Support/Graftty/`.

**PERSIST-1.2** The application shall persist state to a `state.json` file containing: the ordered list of repositories and their worktrees, per-worktree split tree topology and `state` enum (`.closed`, `.running`, `.stale`), selected worktree, window frame, and sidebar width.

### 6.2 Save Triggers

**PERSIST-2.1** The application shall save state when any of the following occur: split tree changes, worktree state changes, repository added or removed, selection changes, window resize or move (debounced), app moving to background, or app quit.

**PERSIST-2.2** When a state save fails (full disk, read-only `$HOME`, permissions clash, or any other `FileManager` / `Data.write` throw), the application shall log the error via `NSLog` so it surfaces in Console.app, rather than silently discarding every subsequent persisted mutation. Analogue of `ATTN-2.7` for the `AppState.save(to:)` path. `AppState.save(to:)` shall continue to throw so the caller can surface or recover; the spec pins only that the app-level caller stops using `try?` to mask it.

### 6.3 Restore on Launch

**PERSIST-3.1** When the application launches with an existing `state.json`, it shall restore the sidebar with all saved repositories and worktrees.

**PERSIST-3.2** When the application launches, it shall restore the saved split tree topology for each worktree.

**PERSIST-3.3** When the application launches, it shall automatically start fresh terminal surfaces for each worktree whose persisted `state` was `.running`.

**PERSIST-3.4** When the application launches, it shall restore the window frame position, size, and sidebar width.

**PERSIST-3.5** When the application launches, it shall re-select the previously selected worktree.

**PERSIST-3.6** When the application launches, it shall run worktree discovery for each repository to reconcile saved state against current disk state.

**PERSIST-3.7** If `state.json` exists but fails to decode at launch (corruption from a crashed mid-write, hand-edit typo, or schema mismatch across app versions), then the application shall move the file aside to a timestamped backup at `state.json.corrupt.<milliseconds-since-epoch>` and proceed with a fresh `AppState`. The corrupt file shall remain on disk so the user can recover the prior data manually; the application shall not silently overwrite it on the next save.

### 6.4 Non-Persisted State

**PERSIST-4.1** The application shall not persist shell scrollback, terminal screen buffer content, or the specific processes that were running.

## 7. Manual Pane Routing

### 7.1 User-Initiated Move

**PWD-1.1** When the user opens the right-click context menu on a pane in the sidebar, the application shall offer a "Move to <worktree-name>" entry that targets the worktree whose filesystem path is the longest prefix of the pane's inner-shell working directory across all repos. The shell's working directory is resolved by reading the inner-shell PID from the zmx session log at `<ZMX_DIR>/logs/<session>.log` (falling back to the rotated sibling `<ZMX_DIR>/logs/<session>.log.old` when the spawn line is no longer in the current file) and querying its current working directory via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.

**PWD-1.2** If no worktree path is a prefix of the inner-shell working directory, or the matching worktree is the pane's current host, then the application shall render the entry from `PWD-1.1` as a disabled "Move to current worktree" item so the user can see *why* the action is unavailable rather than have it disappear.

**PWD-1.3** When the user opens the right-click context menu on a pane, the application shall additionally offer a "Move to worktree" submenu listing every other worktree in the same repository as the pane's current host. Selecting an entry shall move the pane to that worktree regardless of the pane's current shell working directory. Cross-repository moves are out of scope — the submenu shall not list worktrees from other repos.

### 7.2 Reassignment

**PWD-2.1** When the destination worktree differs from the current worktree, the application shall remove the pane from the source worktree's split tree and insert it into the destination worktree's split tree.

**PWD-2.2** When a reassignment leaves the source worktree with no remaining panes, the application shall transition the source worktree to the closed state.

**PWD-2.3** When a reassignment completes, the application shall set the destination worktree as the selected worktree and focus the moved pane — but only when the reassigned pane was the focused pane of the currently-selected worktree at the moment of the move. For any reassignment of a non-focused pane (a background shell's `cd`, e.g. an autonomous claude-code session in a worktree the user isn't looking at), the sidebar shall reflect the move via `PWD-2.1` / `PWD-2.2` but the user's current selection shall not change. This guards against multiple concurrent agent sessions autonomously yanking the user's view around; without the gate a single background `cd` hijacks the UI mid-typing.

**PWD-2.4** When the destination worktree was previously in the closed state, the application shall transition it to the running state as part of the reassignment.

### 7.3 Position Memory

**PWD-3.1** Before removing a pane from a source worktree, the application shall record its split-tree position — an anchor leaf, split direction, and before/after placement — keyed by `(terminalID, worktreePath)`.

**PWD-3.2** When reinserting a pane into a worktree for which a remembered position exists and whose anchor leaf is still present, the application shall restore the pane adjacent to that anchor with the recorded direction and placement.

**PWD-3.3** If no usable remembered position exists for the destination worktree, the application shall insert the pane at the first available leaf with a horizontal split as a fallback.

**PWD-3.4** Position memory shall be maintained in-process only and not persisted across app restarts.

## 8. Keyboard, Clipboard, and Mouse Integration

### 8.1 Keyboard Forwarding

**KEY-1.1** The application shall forward all keyboard input, including Command-modified keys, to libghostty so that libghostty's default keybindings (Cmd+C copy, Cmd+V paste, Cmd+A select-all, Cmd+K clear, etc.) take effect.

**KEY-1.2** When libghostty reports that a key was not handled, the application shall allow the event to continue up the responder chain.

**KEY-1.3** Application-level menu keyboard shortcuts (Cmd+D split, Cmd+W close pane, Cmd+O add repository, and pane navigation shortcuts) shall be matched by AppKit's menu `keyEquivalent` interception before the keyDown event reaches the terminal, so menu shortcuts override any conflicting libghostty keybinding.

### 8.2 Clipboard

**KEY-2.1** When libghostty requests a clipboard write (e.g., from `Cmd+C` or the context menu Copy), the application shall write the provided content to `NSPasteboard.general`.

**KEY-2.2** When libghostty requests a clipboard read (e.g., from `Cmd+V` or the context menu Paste), the application shall read from `NSPasteboard.general` and return the text via `ghostty_surface_complete_clipboard_request`.

**KEY-2.3** Selection clipboard requests (X11-style primary selection) shall route to the same general pasteboard, as macOS does not provide a distinct selection clipboard.

**KEY-2.4** OSC 52 read-confirmation prompts shall be declined by default for security; terminal programs requesting OSC 52 reads shall fail silently rather than succeeding without user consent.

### 8.3 Mouse

**MOUSE-1.1** When libghostty requests a new mouse cursor shape via `MOUSE_SHAPE`, the application shall map the shape to the closest `NSCursor` and apply it to the targeted surface view.

**MOUSE-1.2** When libghostty requests cursor visibility change via `MOUSE_VISIBILITY`, the application shall hide or show the system cursor, using a reference-counted pair of `NSCursor.hide()` / `NSCursor.unhide()` so repeated HIDDEN events do not leak into permanent invisibility.

**MOUSE-1.3** When a terminal pane is destroyed while its cursor is hidden, the application shall unhide the cursor as part of teardown so the destroyed pane cannot leave the cursor invisible.

**MOUSE-1.4** When libghostty fires `OPEN_URL` in response to a user gesture on a detected URL (e.g., Cmd-click), the application shall open the URL using `NSWorkspace.shared.open`.

### 8.4 Bell

**BELL-1.1** When libghostty fires `RING_BELL`, the application shall play the system beep sound.

## 9. Desktop Notifications and Shell Integration Signals

### 9.1 Desktop Notifications

**NOTIF-1.1** When libghostty fires `DESKTOP_NOTIFICATION` (OSC 9), the application shall post a banner notification via `UNUserNotificationCenter` using the title and body provided.

**NOTIF-1.2** If notification authorization has not yet been determined, the application shall request authorization on the first notification and post once authorization is granted.

**NOTIF-1.3** If the user has denied notification authorization, the application shall silently skip the notification rather than surfacing an error.

### 9.2 Attention Badge Auto-Population

**NOTIF-2.1** When libghostty fires `COMMAND_FINISHED` with a zero exit code on a pane, the application shall set *that pane's* pane-scoped attention overlay to a checkmark indicator that auto-clears after 3 seconds. Sibling panes in the same worktree are unaffected.

**NOTIF-2.2** When libghostty fires `COMMAND_FINISHED` with a non-zero exit code on a pane, the application shall set *that pane's* pane-scoped attention overlay to an error indicator that auto-clears after 8 seconds. Sibling panes in the same worktree are unaffected.

**NOTIF-2.3** Auto-populated attention overlays from shell-integration events shall share the clearing semantics defined in STATE-2.x; a subsequent event on the same pane replaces that pane's previous overlay without affecting sibling panes' overlays.

## 10. Shell Integration Configuration

### 10.1 Config Loading

**CONFIG-1.1** At startup, the application shall call `ghostty_config_load_default_files` to load the XDG-standard ghostty config paths.

**CONFIG-1.2** In addition to the XDG paths, the application shall load the Ghostty macOS app's config file at `~/Library/Application Support/com.mitchellh.ghostty/config` if the file exists. Values loaded later shall override earlier values.

**CONFIG-1.3** After loading config files, the application shall call `ghostty_config_load_recursive_files` to resolve any `config-file = …` include directives.

### 10.2 Shell Integration Script Discovery

**CONFIG-2.1** Before calling `ghostty_init`, the application shall set the `GHOSTTY_RESOURCES_DIR` environment variable so libghostty can locate its per-shell integration scripts.

**CONFIG-2.2** If `GHOSTTY_RESOURCES_DIR` is already set in the process environment, the application shall not override it; the user's explicit setting wins.

**CONFIG-2.3** Otherwise, the application shall probe standard locations (`/Applications/Ghostty.app/Contents/Resources/ghostty` and `~/Applications/Ghostty.app/Contents/Resources/ghostty`) and, on first match, set `GHOSTTY_RESOURCES_DIR` to the match.

**CONFIG-2.4** If no Ghostty.app installation is found, shell integration features (OSC 7 auto-reporting, OSC 133 prompt marks, `COMMAND_FINISHED`, and `PROGRESS_REPORT`) shall silently be unavailable rather than surfacing an error; spawned shells shall still function.

## 11. Worktree Divergence Indicator

### 11.1 Display

**DIVERGE-1.1** Each worktree entry in the sidebar shall display a trailing-aligned divergence indicator, placed to the left of the attention badge (or at the trailing edge when no attention badge is present).

**DIVERGE-1.2** The indicator shall display zero, one, or both of the following on a single line, separated by a single space when both are present:
- `↑<N>` when the worktree's HEAD has N commits not reachable from the base ref (ahead). Additionally, when the worktree has uncommitted changes, a `+` shall be appended, yielding `↑<N>+`. When N is zero, the ahead segment shall be rendered (as `↑0+`) only if uncommitted changes exist; otherwise the ahead segment shall be omitted. The ahead segment shall be rendered in the sidebar's muted ambient color.
- `↓<N>` when the base ref has N commits not reachable from the worktree's HEAD (behind). Omitted when N is zero. The behind segment shall be rendered in red so incoming origin commits draw the eye in contrast to the muted `↑` segment.

**DIVERGE-1.3** On hover, the indicator shall surface a system tooltip containing the insertion/deletion line counts in the form `+<I> -<D> lines` (with zero sides omitted), optionally suffixed with `, uncommitted changes` when the worktree has uncommitted changes. When there are neither line changes nor uncommitted changes, no tooltip is shown.

**DIVERGE-1.4** When the worktree's ahead count, behind count, insertion count, and deletion count are all zero and there are no uncommitted changes, the indicator shall render no text.

**DIVERGE-1.5** When the repository has no `origin` remote or the default branch name cannot be resolved, the indicator shall render no text for any worktree in that repository.

**DIVERGE-1.6** While a worktree is in the stale state, the indicator shall render no text.

### 11.2 Origin Default Branch Resolution

**DIVERGE-2.1** The application shall resolve each repository's default branch name by running `git symbolic-ref --short refs/remotes/origin/HEAD` and stripping the `origin/` prefix from the result.

**DIVERGE-2.2** If `refs/remotes/origin/HEAD` is not set, the application shall probe the refs `origin/main`, `origin/master`, and `origin/develop` in that order via `git show-ref --verify` and use the matching branch name.

**DIVERGE-2.3** The application shall not perform any network operations to resolve the default branch name.

**DIVERGE-2.4** The application shall cache the resolved default branch name per repository for the duration of the session.

### 11.3 Computation

**DIVERGE-3.0** Divergence shall be measured against the union of a worktree's upstream refs:
- `origin/<defaultBranch>` — always included. Catches PR merges on the default branch, which advance this ref regardless of which worktree is in focus.
- `origin/<worktree-branch>` — additionally included when `git show-ref --verify refs/remotes/origin/<branch>` succeeds. Catches collaborator pushes to the worktree's own branch.

When `branch == defaultBranch` or no tracking ref exists for the worktree's branch, the union collapses to the single default ref. The default branch name shall be the one `GitOriginDefaultBranch.resolve` returns per `DIVERGE-2.x` — the compute path shall contain no hardcoded branch names.

**DIVERGE-3.1** The application shall compute the behind count by running `git rev-list --count <refs> ^HEAD` and the ahead count by running `git rev-list --count HEAD ^<refs>` (each `<ref>` from `DIVERGE-3.0` prefixed with `^` for the ahead command). `rev-list` natively dedupes, so a commit reachable from both upstream refs is counted once.

**DIVERGE-3.2** The application shall compute insertion and deletion line counts by running `git diff --shortstat <ref>...HEAD` where `<ref>` is `origin/<worktree-branch>` when that tracking ref exists, otherwise `origin/<defaultBranch>`. The diff uses a single ref rather than the full union so the tooltip reports "your commits on this branch" rather than conflating feature-branch work with default-branch churn.

**DIVERGE-3.3** The application shall detect uncommitted changes in each worktree by running `git status --porcelain` and treating any non-empty output (including modified, staged, deleted, or untracked entries) as "has uncommitted changes".

**DIVERGE-3.4** All git computation for divergence indicators shall run off the main thread and shall not block the UI.

**DIVERGE-3.5** Divergence counts and the uncommitted-changes flag shall be held in memory only and shall not be written to `state.json`.

### 11.4 Refresh Triggers

**DIVERGE-4.1** When a repository is added to the sidebar, the application shall compute divergence counts for each of its worktrees.

**DIVERGE-4.2** When a worktree's HEAD reference changes, the application shall recompute that worktree's divergence counts.

**DIVERGE-4.3** The application shall run `git fetch --no-tags --prune origin` (with no refspec, so the remote's configured fetch rules advance every tracked branch) and recompute divergence counts per repository on a 30-second base cadence, doubling the interval for each consecutive fetch failure (capped by `ExponentialBackoff`'s 32× max shift and a 30-minute hard cap, whichever binds first). A fast 5-second polling ticker drives the eligibility check; actual fetches are gated by the per-repo cadence so tracked repositories are not hammered.

**DIVERGE-4.4** While a divergence computation is in flight for a particular worktree, duplicate refresh requests for the same worktree shall be dropped — but only while the in-flight Task is plausibly still running. After a period equal to DIVERGE-4.6's 30-second per-worktree cadence, a subsequent refresh shall supersede the prior Task: the generation counter is bumped so the stuck Task's late `apply` is discarded, and a fresh compute is dispatched. Without the staleness cap, a `git` subprocess blocked on a ref-transaction lock (e.g., during a concurrent `git push`) permanently locks the worktree's divergence gutter at whatever value was observed in the lock window.

**DIVERGE-4.5** When `WorktreeStatsStore.clear(worktreePath:)` is called — whether from a stale transition (GIT-3.13), a Dismiss (GIT-3.6), or a Delete (GIT-4.10) — a fetch that was already in flight at that moment shall not repopulate `stats` after the clear. Each `clear` bumps a per-path generation counter; `apply` captures the generation at refresh time and drops the write if the counter changed during the await. Without this, a `git worktree remove` that fires shortly after the 5s-polling refresh leaves the divergence indicator flashing back onto a cleared row for the duration of the git subprocess (~50–200ms). Mirrors `PRStatusStore`'s pattern (PR status gained this protection earlier; stats store was lagging).

**DIVERGE-4.6** The polling loop shall also recompute divergence counts for every non-stale worktree on a 30-second per-worktree cadence, independent of the network `git fetch` cadence in DIVERGE-4.3. Local-only recomputation uses no network — `git rev-list`, `git diff --shortstat`, and `git status --porcelain` all run against the local object store — so it catches local changes (a `git add` in an external shell, a commit made by a tool other than Graftty) even when the repo's fetch cooldown is still active. When a tick finds a per-repo fetch is due in the same cycle, the per-worktree cadence is skipped for that repo because the fetch handler itself recomputes every worktree on success.

**DIVERGE-4.7** When a remote-tracking-ref change event fires (GIT-2.5), the application shall refresh divergence stats for every non-stale worktree in the affected repository in addition to PR status. Local `git fetch` from another terminal advances `origin/<defaultBranch>` and therefore changes every worktree's ahead/behind count against it, not just the PR state.

**DIVERGE-4.8** The polling ticker for divergence stats shall continue to fire while Graftty is not the frontmost application. Users frequently run their editor or Claude session in a different app while the sidebar's divergence indicator tracks their work; pausing on `resignActive` leaves those updates queued until the user clicks back into Graftty, defeating the purpose of the indicator.

**DIVERGE-4.9** When a compute attempt fails transiently (the default branch was resolvable but `git rev-list`/`diff-tree`/etc. threw), the application shall preserve the worktree's last-known `WorktreeStats` rather than clearing the sidebar gutter. Only when the repo has no resolvable default branch at all (origin removed, clone converted to non-origin setup) shall the stats be wiped. Without this, the ↑N ↓M badge flickers off for the polling window whenever git is briefly unhealthy — same UX concern as `PR-7.10`.

## 12. Technology Constraints

**TECH-1** The application shall be built in Swift using SwiftUI for app chrome and AppKit for terminal view hosting.

**TECH-2** The application shall use libghostty (via the libghostty-spm Swift Package) as its terminal engine.

**TECH-3** The application shall target macOS 14 Sonoma as its minimum supported version.

**TECH-4** The application shall reuse the following components from the Ghostty project (MIT-licensed): `SplitTree`, `SplitView`, `Ghostty.Surface`, `Ghostty.App`, `Ghostty.Config`, and `SurfaceView_AppKit`.

**TECH-5** The application shall invoke every external tool (`git`, `gh`, `glab`, `zmx`) with `LC_ALL=C` in the child environment so output parsers written against English strings (e.g. `git diff --shortstat` "insertion"/"deletion" markers, `gh pr checks` bucket names) keep working when the user's shell locale is non-English. This is a forcing function — the alternative (locale-robust parsers across multiple tools) is fragile and brittle.

## 13. zmx Session Backing

### 13.1 Bundling

**ZMX-1.1** The application shall include a `zmx` binary in the app bundle at `Graftty.app/Contents/Helpers/zmx`, mirroring the placement of the `graftty` CLI.

**ZMX-1.2** The bundled `zmx` binary shall be a universal Mach-O containing both `arm64` and `x86_64` slices, produced by `scripts/bump-zmx.sh`.

**ZMX-1.3** The application shall pin the vendored `zmx` version in `Resources/zmx-binary/VERSION` and record its SHA256 in `Resources/zmx-binary/CHECKSUMS`.

### 13.2 Session Naming

**ZMX-2.1** The application shall derive the zmx session name for each pane as the literal string `"graftty-"` followed by the first 8 lowercase hex characters (i.e., the leading 4 bytes, yielding 32 bits of namespace uniqueness) of the pane's UUID with dashes stripped.

**ZMX-2.2** The session-naming function shall be deterministic and shall not change across releases without an explicit migration step, since changing it orphans every existing user's daemons.

### 13.3 Sandboxing

**ZMX-3.1** The application shall pass `ZMX_DIR=~/Library/Application Support/Graftty/zmx/` in the environment of every spawned `zmx` invocation, so Graftty-owned daemons live in a private socket directory distinct from any user-personal `zmx` usage.

**ZMX-3.2** The application shall create the `ZMX_DIR` path if it does not exist at launch.

### 13.4 Lifecycle Mapping

**ZMX-4.1** When the application creates a new terminal pane, it shall leave the libghostty surface configuration's `command` field unset and instead write `exec '<bundled-zmx-path>' attach graftty-<short-id> '<user-shell>'\n` into the surface's `initial_input` field, with each substituted path single-quoted to defend against spaces. The leading `exec` replaces the default shell with `zmx attach` so that when the inner shell ends, the PTY child dies and libghostty's `close_surface_cb` fires. Setting `command` instead would trigger libghostty's automatic `wait-after-command` enablement (see upstream `src/apprt/embedded.zig`), which would keep panes open after `exit` and show a "Press any key to close" overlay.

**ZMX-4.2** When the application restores a worktree's split tree on launch (per `PERSIST-3.x`), each restored pane's surface shall be created with the same session name derived from the persisted pane UUID, so reattach to a surviving daemon is automatic.

**ZMX-4.3** When the application destroys a terminal surface (user-initiated close, automatic close on shell exit, or worktree stop), it shall asynchronously invoke `zmx kill --force <session>` for the matching session.

**ZMX-4.4** When the application quits, it shall not invoke `zmx kill` — pending PTY teardown by the OS is the desired detach signal that lets daemons survive.

### 13.5 Fallback

**ZMX-5.1** If the bundled `zmx` binary is missing or not executable, the application shall fall back to libghostty's default `$SHELL` spawn behavior on a per-pane basis.

**ZMX-5.2** If the bundled `zmx` binary is unavailable at launch, the application shall present a single non-blocking informational alert explaining that terminals will not survive app quit. The alert shall not be re-presented within the same process lifetime.

### 13.6 Pass-through Guarantees

**ZMX-6.1** Shell-integration OSC sequences (OSC 7 working directory, OSC 9 desktop notification, OSC 133 prompt marks, OSC 9;4 progress reports) shall continue to flow from the inner shell through `zmx` to libghostty unchanged. The `PWD-x.x`, `NOTIF-x.x`, and `KEY-x.x` requirements remain in force regardless of whether `zmx` is mediating the PTY.

**ZMX-6.2** The `GRAFTTY_SOCK` environment variable shall continue to be set in the spawned shell's environment per `ATTN-2.4`. Because `zmx` inherits its child shell's env from the spawning process, this is satisfied by setting it on the libghostty surface as today.

**ZMX-6.3** If `GHOSTTY_RESOURCES_DIR` is set (per `CONFIG-2.1`) and the user's shell basename is `zsh`, the `initial_input` written per `ZMX-4.1` shall prefix the `exec` line with `if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; fi; ZDOTDIR='<ghostty-resources>/shell-integration/zsh'` so the inner shell zmx spawns re-sources Ghostty's zsh integration. Without this re-injection, Ghostty's integration `.zshenv` in the outer shell has already restored `ZDOTDIR` to the user's original value, so the post-`exec` inner shell sources only the user's plain rc files — precmd hooks do not run, no OSC 7 / OSC 133 sequences are emitted, and `PWD-x.x`, the default-command first-PWD trigger, and shell-integration-driven attention badges all go silent.

**ZMX-6.4** If the outer shell's `ZDOTDIR` is unset or empty, the `GHOSTTY_ZSH_ZDOTDIR` assignment in `ZMX-6.3` shall not execute. Ghostty's integration `.zshenv` gates its restore branch on `${GHOSTTY_ZSH_ZDOTDIR+X}` (which matches empty-string-set), and zsh's dotfile lookup uses `${ZDOTDIR-$HOME}` (falls back to `$HOME` only when *unset*, not when empty) — so an unguarded assignment would export `ZDOTDIR=""` into the inner shell and cause it to silently skip the user's `.zshenv`/`.zprofile`/`.zshrc`/`.zlogin`. Guarding keeps `GHOSTTY_ZSH_ZDOTDIR` unset so the integration's `else: unset ZDOTDIR` branch fires and dotfile lookup defaults to `$HOME`.

### 13.7 Session-Loss Recovery

**ZMX-7.1** When the application restores a worktree's split tree on launch (per `PERSIST-3.x` and `ZMX-4.2`), it shall, before creating each pane's surface, query the live zmx session set and clear the pane's rehydration label if the expected session name is absent. This ensures a freshly-created daemon (the result of `zmx attach`'s create-on-miss semantics) is not mistaken for a surviving session by `defaultCommandDecision`.

**ZMX-7.2** If `zmx list` fails for any reason at the cold-start query site (per `ZMX-7.1`), the application shall treat the result as "session not missing" and take no recovery action — preferring a missed recovery over a spurious rehydration clear.

**ZMX-7.3** When `close_surface_cb` fires for a pane, the application shall always route to the close-pane path (remove from the split tree, free the surface) regardless of the zmx session's liveness. The mid-flight "rebuild surface in place" recovery explored in an earlier design was withdrawn because the available signals (session-missing + no Graftty-initiated close) cannot distinguish a clean user `exit` from an external daemon kill, and the rebuild path regressed `TERM-5.3`. Recovery from daemon loss while Graftty is running is deferred until a zmx-side signal disambiguates the two cases.

**ZMX-7.4** At application launch, before any terminal surface is spawned, the application shall `unsetenv(...)` a known list of "leaky" environment variables from its own process so every downstream spawn (libghostty surface shells, CLIRunner subprocesses, zmx attach) sees a clean env regardless of the shell Graftty was launched from. The list shall include at minimum:

- `ZMX_SESSION` — zmx's `attach <positional>` silently prefers `$ZMX_SESSION` over its positional argument. A parent shell that itself lived inside a zmx session would otherwise hijack every new pane's attach to the parent's session. User-visible as "created a new worktree, its Claude swapped out for an older worktree's Claude".
- `GIT_DIR` and `GIT_WORK_TREE` — git's env-var-wins rule trumps `currentDirectoryURL`. A parent shell with either set would redirect every `GitRunner.run(at: repoPath)` invocation (worktree discovery, stats, PR resolution) to the parent shell's `.git` dir instead of the target repo.

The sweep runs once at `GrafttyApp.init()`. `ZmxLauncher.subprocessEnv` additionally strips `ZMX_SESSION` from inline subprocess envs as belt-and-suspenders, but the process-level sweep is the primary defense — it also covers libghostty's surface env overlay, which cannot be routed through `subprocessEnv` before the spawn.

### 13.8 Manual Restart

**ZMX-8.1** The Settings → General pane shall expose a "Restart ZMX…" button that, after user confirmation, tears down every running pane across every worktree — invoking the same `destroySurface` / `zmx kill --force` path as per-worktree Stop (`TERM-1.2` / `ZMX-4.3`) — and then marks each affected worktree `.closed` via `prepareForStop` (`STATE-2.11`), preserving each worktree's `splitTree` and `focusedTerminalID` so re-opening recreates the same layout at the same leaf IDs under freshly-spawned zmx daemons. The confirmation alert (`NSAlert` with `.warning` style) shall name the destructive consequence explicitly — how many sessions across how many worktrees will end, with a "Any unsaved work in those sessions will be lost" warning (pluralization per `ZmxRestartConfirmation.informativeText`) — and shall offer "Restart ZMX" and "Cancel" buttons with Cancel as the default dismissal. If no worktrees are running at click time, the alert shall state that the action will have no effect rather than silently no-op.

## 14. Distribution

### 14.1 Build Bundle

**DIST-1.1** The build script (`scripts/bundle.sh`) shall produce a self-contained `Graftty.app` bundle in `.build/` containing the SwiftUI application binary at `Contents/MacOS/Graftty`, the CLI helper at `Contents/Helpers/graftty`, and the bundled `zmx` binary at `Contents/Helpers/zmx`.

**DIST-1.2** While the `GRAFTTY_VERSION` environment variable is set, the build script shall write that value into both `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.

**DIST-1.3** If the `GRAFTTY_VERSION` environment variable is not set, then the build script shall use `0.0.0-dev` as the default version.

**DIST-1.4** The build script shall ad-hoc codesign every Mach-O in the bundle in inner-to-outer order: `Contents/Helpers/zmx`, `Contents/Helpers/graftty`, `Contents/MacOS/Graftty`, then the bundle itself, and shall verify the resulting signature with `codesign --verify --strict`.

### 14.2 Release Automation

**DIST-2.1** When a git tag matching `v*` is pushed to origin, the GitHub Actions workflow `.github/workflows/release.yml` shall build the app bundle in release configuration, verify codesigning, zip the bundle as `Graftty-<version>.zip`, ensure a GitHub release tagged `v<version>` has the zip attached, and ensure the `btucker/homebrew-graftty` cask reflects the new version and sha256.

**DIST-2.2** If the pushed tag does not start with `v`, then the release workflow shall fail before building.

**DIST-2.3** If a release for the pushed tag already exists, then the workflow shall re-upload the zip with `--clobber` and continue to the cask update step rather than failing.

**DIST-2.4** The release zip shall be produced with `ditto -c -k --keepParent` (not `zip`) so that codesign-relevant extended attributes survive — `zip` strips them and installs fail with opaque "damaged" errors after reboot.

### 14.3 Homebrew Cask

**DIST-3.1** The Homebrew tap `btucker/homebrew-graftty` shall expose a cask `graftty` that downloads the release zip, installs `Graftty.app` to `/Applications`, and symlinks `Graftty.app/Contents/Helpers/graftty` onto the user's PATH as `graftty`.

**DIST-3.2** While the application is ad-hoc signed (not Developer ID notarized), the cask shall display a `caveats` notice explaining that macOS will refuse to open the app on first launch and providing the steps to bypass Gatekeeper.

**DIST-3.3** When the user runs `brew uninstall --cask --zap graftty`, the cask shall remove `~/Library/Application Support/Graftty`, `~/Library/Preferences/com.graftty.app.plist`, and `~/Library/Caches/com.graftty.app`.

## 15. Web Access

### 15.1 Binding

**WEB-1.1** When web access is enabled, the application shall bind a local HTTPS server to each Tailscale IPv4 and IPv6 address reported by the Tailscale LocalAPI, on the user-configured port (default 8799). The application shall not bind to `127.0.0.1`.

**WEB-1.2** The application shall not bind to `0.0.0.0`.

**WEB-1.3** If no Tailscale addresses are available, the application shall not bind the server and shall surface a "Tailscale unavailable" status in the Settings pane.

**WEB-1.4** The feature shall be off by default.

**WEB-1.5** If the user-configured port is outside the 0–65535 range NIO will accept (e.g., the Settings TextField lets the user type any integer, including "99999" or a negative number), the application shall surface a readable "Port must be 0–65535 (got N)" error in the Settings status row rather than attempting to bind and surfacing an opaque `NIOBindError`, and shall not start the server until the value is corrected.

**WEB-1.6** When resolving the Tailscale LocalAPI, the application shall try Unix domain socket endpoints first (OSS / sandboxed App Store installs) and, if none are reachable, shall fall back to the macsys DMG's TCP endpoint by reading the port from `/Library/Tailscale/ipnport` (file or symlink) and the auth token from `/Library/Tailscale/sameuserproof-<port>`.

**WEB-1.7** Every UI surface that renders a TCP port — the Settings pane's Port input `TextField`, the status row, any future port label — shall suppress the locale grouping separator (e.g., `Listening on 100.64.0.5:49161`, never `49,161`; Port field value `8799`, never `8,799`). Input and display formatters go through `WebPortFormat.noGrouping` (an `IntegerFormatStyle<Int>` with `.grouping(.never)`) so every surface is identical.

**WEB-1.8** The diagnostic "Listening on …" row in the Settings pane shall bracket IPv6 hosts per RFC 3986 authority syntax (e.g., `[fd7a:115c::5]:8799`). Copyable URLs (Settings Base URL, sidebar "Copy web URL") no longer contain IP literals — they use the MagicDNS FQDN (WEB-8.1) — so this bracketing rule applies only to the diagnostic list. `WebURLComposer.authority(host:port:)` owns the bracket logic.

**WEB-1.9** When `WebURLComposer.url(session:host:port:)` percent-encodes the session name for interpolation into the URL path, it shall use `CharacterSet.urlPathAllowed` rather than `urlQueryAllowed`. The latter leaves reserved path/query/fragment separators (`?`, `#`) unescaped, so a session name containing `?` would cause the browser to parse the URL as path-and-query and the client router would see only the prefix. Graftty's own session names per `ZMX-2.1` never include such characters, but socket clients producing custom session names would otherwise silently break.

**WEB-1.10** The Settings pane status row ("Listening on …") shall render each listening address with its port individually (via `WebURLComposer.authority(host:port:)`), bracketing IPv6 hosts. Example: `Listening on [fd7a:115c::5]:49161, 100.64.0.5:49161`. (127.0.0.1 is no longer bound per WEB-1.1.)

**WEB-1.11** When the server fails to bind because the configured port is already in use (EADDRINUSE), the application shall surface the status as `.portUnavailable` — rendered as "Port in use" in the Settings pane — rather than the raw NIO error string (`"bind(descriptor:ptr:bytes:): Address already in use) (errno: 48)"`). Recognition is locale-stable: classify by the bridged `NSPOSIXErrorDomain` + `EADDRINUSE` errno code, with the NIO string-match kept as a secondary path. Both `WebServer.start` and `WebServerController` use a single shared `WebServer.isAddressInUse(_:)` classifier so they cannot drift on recognising the same error.

**WEB-1.12** While the server is listening, the Settings pane shall render a **Base URL** row distinct from the diagnostic "Listening on" row. The Base URL is the HTTPS URL composed from the machine's MagicDNS FQDN (WEB-8.1) and the listening port — the URL a user copies to open the web client. It renders as a clickable `Link` opening the default browser, plus a copy button (`doc.on.doc`, accessible label "Copy URL") that writes to `NSPasteboard.general`. The "Listening on" row below is informational (which sockets are actually up) and must not be conflated with the Base URL. Plain selectable text is not sufficient for the Base URL — users were expected to triple-click, copy, then switch apps and paste (four steps for one ask).

**WEB-1.13** While the server is listening, the Settings pane shall render a 160 pt QR code inline beneath the Base URL row, encoding the Base URL so that an iOS client can scan it on first run to add a saved host. Alongside the QR, the pane shall render a one-sentence usage hint ("Scan with Graftty") so a reader who has never onboarded a phone before knows what the code is for. Hiding it behind a disclosure is rejected on discoverability grounds: a user who has Web Access on has almost certainly enabled it to onboard a phone, and the QR is the payoff for that action. When the server is not listening, the Base URL row (and therefore the QR) is not rendered at all, per the existing status-gated layout.

### 15.2 Authorization

**WEB-2.1** The application shall resolve each incoming peer IP via Tailscale LocalAPI `whois` before serving any content at any path.

**WEB-2.2** The application shall accept a connection only when the resolved `UserProfile.LoginName` equals the current Mac's Tailscale `LoginName`.

**WEB-2.3** When `whois` fails or the resolved LoginName differs, the application shall respond with HTTP `403 Forbidden`.

**WEB-2.4** When Tailscale is not running, the application shall refuse all incoming connections (the server is not bound; connections are refused at TCP).

**WEB-2.5** _(Removed; superseded by WEB-1.1.)_ The prior loopback-bypass carve-out existed because `WEB-1.1` bound `127.0.0.1`; with that bind gone, local connections now arrive as Tailscale peers via the MagicDNS hostname (WEB-8.1) and are accepted under the normal `WEB-2.2` same-user check.

### 15.3 Protocol

**WEB-3.1** The application shall serve a single static page at `/` (and `/index.html`) that bootstraps the bundled web client.

**WEB-3.2** When a client requests any path that does not match a bundled
static asset and does not begin with `/ws`, the application shall respond
with the bundled `index.html` body and `Content-Type: text/html; charset=utf-8`.
This serves the SPA fallback for client-side-routed URLs such as
`/session/<name>`.

**WEB-3.3** The application shall upgrade `/ws?session=<name>` to WebSocket after the authorization check passes.

**WEB-3.4** WebSocket binary frames shall carry raw PTY bytes in both directions.

**WEB-3.5** WebSocket text frames shall carry JSON control envelopes. The only Phase 2 envelope shape shall be `{"type":"resize","cols":<uint16>,"rows":<uint16>}`.

**WEB-3.6** When the application responds to an HTTP request with `Connection: close`, it shall transmit exactly the number of body bytes declared in its `Content-Length` header to the client before closing the TCP connection, so clients never observe a truncated response (`ERR_CONTENT_LENGTH_MISMATCH`). This requirement applies even on links (e.g., Tailscale `utun`, MTU ~1280) whose kernel TCP send buffer cannot absorb the full response in a single non-blocking write.

> **Test coverage note (2026-04-22):** the raw-socket Content-Length verifier (`appJSRawReadMatchesContentLength`) was gated behind `#if false` during the HTTPS migration because URLSession hides short reads and `rawHTTPGet` was HTTP-only. A follow-up should implement the equivalent probe over HTTPS via `NWConnection` + `NWProtocolTLS` to restore the regression guard.

### 15.4 Lifecycle

**WEB-4.1** When the user enables web access in Settings, the application shall probe Tailscale, bind, and transition status to `.listening(...)` or an error status.

**WEB-4.2** When the user disables web access, the application shall close all listening sockets and terminate all in-flight `zmx attach` children spawned for the web.

**WEB-4.3** When the application quits, the application shall stop the server (same tear-down as 15.4.2) as part of normal shutdown.

**WEB-4.4** For each incoming WebSocket, the application shall spawn one child `zmx attach <session>` whose PTY it owns (per §13 naming and ZMX_DIR rules from Phase 1).

**WEB-4.5** When a WebSocket closes, the application shall send SIGTERM to the associated `zmx attach` child, leaving the zmx daemon alive.

**WEB-4.6** When the application forks a `zmx attach` child for a web WebSocket, the child shall close every inherited file descriptor above 2 before `execve`. Rationale: without this, parent-opened sockets (notably the `WebServer` listen socket) without `FD_CLOEXEC` leak into the zmx child and survive the parent. After Graftty quits, the listen port stays bound to an orphan zmx process and the next Graftty launch cannot rebind.

**WEB-4.7** When the application transitions the forked child into `zmx attach`, the final `execve` shall be performed via `posix_spawn` with `POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGMASK` and an empty initial signal mask. `fork(2)` preserves the parent's sigmask and plain `execve(2)` carries it across — and the Swift runtime (GCD/Dispatch) blocks a family of signals on its service threads, so a child inheriting that mask starts with SIGWINCH blocked. `zmx attach` installs a SIGWINCH handler to forward PTY resize events to the daemon; if SIGWINCH is blocked the handler never fires, the kernel sets the signal pending, and WebSocket-sent resize events silently vanish until an unrelated signal or explicit unblock drains them. The spawn-level mask reset is the kernel-boundary fix that guarantees the exec'd image starts with every signal unblocked.

### 15.5 Client

**WEB-5.1** The bundled client shall render a single terminal (ghostty-web, a WASM build of libghostty — the same VT parser as the native app pane) that attaches to the session indicated by the `/session/<name>` URL path. If a client arrives at the root path `/` with a `?session=<name>` query parameter, the client shall redirect to `/session/<name>` (backward compatibility). Sharing a parser with the native pane is what keeps escape-sequence behavior (cursor movement, SGR state, OSC 8 hyperlinks, scrollback) identical across clients.

**WEB-5.4** When a client requests `GET /sessions`, the application shall respond with a JSON array of the currently-running sessions, one entry per live pane across all running worktrees, with fields `name` (the zmx session name derived per `ZMX-2.1`), `worktreePath`, `repoDisplayName`, and `worktreeDisplayName`. The bundled client's root page (`/`) shall fetch this endpoint and render a clickable picker grouped by `repoDisplayName`, so a user who visits the server's root URL without a session query gets a functional entry point rather than a bare "no session" placeholder. Access to `/sessions` shall be gated by the same Tailscale-whois authorization as every other path (`WEB-2.1` / `WEB-2.2`).

**WEB-5.2** The client shall send terminal data events as binary WebSocket frames.

**WEB-5.3** The client shall send resize events as JSON control envelopes in text frames, including an initial resize sent on WebSocket open so the server-side PTY is sized to the client's actual viewport rather than the `zmx attach` default.

**WEB-5.5** The client shall size the terminal grid to fill the host element using the renderer's font metrics (`cols = floor(host.clientWidth / metrics.width)`, `rows = floor(host.clientHeight / metrics.height)`) and shall not reserve any horizontal pixels for a native scrollbar, so the canvas occupies the full viewport width and the PTY column count matches the visible grid. Rationale: ghostty-web's bundled `FitAddon` unconditionally subtracts 15 px from available width for a DOM scrollbar (`proposeDimensions()` in `ghostty-web.js`), but Ghostty renders its scrollback scrollbar as a canvas overlay — using `FitAddon` leaves a ~15 px gap on the right edge and narrows wrapping (e.g., 148 cols instead of 150 on a 1200 px viewport with 8 px cells).

**WEB-5.6** When the client's WebSocket closes for any reason other than a deliberate page unmount (mobile tab suspension, laptop sleep, transient network wobble, Tailscale peer rotation), the client shall automatically attempt to reconnect to the same `/ws?session=<name>` URL with exponential backoff starting at 500 ms and capped at 8 s, with ±25 % jitter per attempt, keeping the `Terminal` instance and its scrollback alive across reconnects; on `visibilitychange` to `visible`, if the socket is not `OPEN` the client shall reset backoff and reconnect immediately rather than wait out any pending timeout. On each successful `open`, the client shall resend the current `(cols, rows)` as a resize envelope so the freshly-spawned `zmx attach` child's PTY matches the terminal grid. Rationale: without this, every transient drop required a full page refresh — a refresh loses the URL-bound session-picker state and visually blanks the terminal for the ~300 ms of wasm re-init. The daemon session surviving per `WEB-4.5` makes reconnection a safe retry rather than a "recreate from scratch" cost.

**WEB-5.7** On mobile browsers the client shall (a) translate a single-finger vertical drag on the terminal host into `term.scrollLines(-deltaLines)` so scrollback is reachable without a hardware wheel (ghostty-web's built-in scrolling is wheel-only and mobile browsers do not synthesize wheel events from single-finger drag); and (b) size the terminal host to `window.visualViewport.{width,height}` (fallback `window.innerWidth/Height`), updating on `visualViewport` `resize` and `scroll` events, so when the software keyboard opens the host shrinks to the remaining visible area and the existing ResizeObserver refits `(cols, rows)` — keeping the cursor row above the keyboard rather than occluded beneath it. Taps shorter than one character-cell of movement shall still reach the terminal's own focus handler (which shows the mobile keyboard); multi-touch gestures (pinch, two-finger pan) shall pass through untouched. The terminal host shall declare `touch-action: none` and `overscroll-behavior: none` so the browser doesn't interpret the drag as page-scroll/pan/zoom or rubber-band the viewport before our handler sees the event.

**WEB-5.8** While the user is viewing scrollback on the normal screen (i.e., `term.viewportY > 0`), incoming PTY output shall not move the viewport: the client shall capture `viewportY` and scrollback length immediately before each `term.write()` call and, after the write, re-apply `viewportY` shifted by the number of lines that scrolled into scrollback so the viewport stays pinned to the same absolute content rather than the same offset-from-bottom. While the alternate screen is active on either side of the write, the viewport shall be left at the library-default bottom position. Rationale: ghostty-web's `Terminal.writeInternal` unconditionally calls `scrollToBottom()` whenever `viewportY !== 0` at write time, so without this wrapper the viewport snaps to the newest output on every WebSocket data frame — making wheel/touch scrollback unusable on any session that is actively producing output. Pinning to absolute content (not offset) is what lets the user read older lines while the shell continues to print.

### 15.6 Security and non-goals

**WEB-6.1** The web server shall bind HTTPS only, using a cert+key pair fetched from Tailscale LocalAPI for the machine's MagicDNS name (WEB-8.2). The application shall not bind any HTTP listener; clients with old `http://` bookmarks will fail to connect until they update the URL.

**WEB-6.2** Phase 2 shall not implement multi-pane layout, mouse events, OSC 52 clipboard sync, or reboot survival. (A minimal session-list picker is provided by `WEB-5.4`; worktree creation is provided by `WEB-7`.)

**WEB-6.3** Phase 2 shall not implement rate limiting, URL tokens, or cookies; authorization shall be via Tailscale WhoIs only.

### 15.7 Adding worktrees from the web client

**WEB-7.1** When a client requests `GET /repos`, the application shall respond with a JSON array of the currently-tracked repositories (one entry per top-level `RepoEntry` in `AppState.repos`) with fields `path` (opaque absolute path round-tripped on `POST /worktrees`) and `displayName` (matching the native sidebar's top-level label). Access is gated by the same Tailscale-whois authorization (`WEB-2.1` / `WEB-2.2`).

**WEB-7.2** When a client sends `POST /worktrees` with a JSON body `{repoPath, worktreeName, branchName}`, the application shall create a new worktree under `<repoPath>/.worktrees/<worktreeName>` on a fresh branch named `<branchName>`, starting from the repo's resolved default branch (same `GitOriginDefaultBranch` resolution the native sheet uses); discover the new worktree into `AppState.repos` so it appears in the sidebar immediately; spawn its first ghostty surface via the same `TerminalManager.createSurfaces` path the native sheet uses; and respond with `200` and `{sessionName, worktreePath}`. The `sessionName` is the `ZMX-2.1`-derived name of the first leaf, suitable for use as `/session/<sessionName>`.

**WEB-7.3** The application shall reject `POST /worktrees` requests with invalid JSON, missing fields, or whitespace-only `worktreeName`/`branchName` with `400 Bad Request` and a JSON `{error: "<message>"}` body. `GET /worktrees` and other verbs shall return `405 Method Not Allowed`. Request bodies exceeding 64 KiB shall return `413 Payload Too Large` before any creator is invoked.

**WEB-7.4** When `git worktree add` fails (branch already exists, path already in use, fatal ref-format rejection, etc.), the application shall respond `409 Conflict` with the captured stderr as `{error: "<stderr>"}`. When post-git discovery or surface creation fails, the application shall respond `500 Internal Server Error` with the underlying message. The web-created worktree shall not leave the Mac's `AppState` holding a half-materialized entry: either the entry appears in `.running` state with a surface, or not at all.

**WEB-7.5** The native Mac window's `selectedWorktreePath` shall not change as a side effect of a web-initiated `POST /worktrees`. Rationale: remote-creating a worktree from an iPad should not yank the local user's Mac window focus away from whatever they are currently doing. The new worktree still appears in the sidebar (via `WEB-7.2`'s discovery step) and a running pane is visible there.

**WEB-7.6** The bundled web client shall expose an "Add worktree" entry point on its root page that routes to `/new`. `/new` shall render a form containing (a) a repository picker populated from `GET /repos` (hidden when only one repo is tracked), (b) a worktree-name field, (c) a branch-name field defaulting to mirror the worktree-name field until the user types a differing branch name. Both name fields shall sanitize input live to the same allowed set as the native sheet (`A-Z a-z 0-9 . _ - /`, consecutive disallowed chars collapsing to a single `-`) and shall trim whitespace plus leading/trailing `-` / `.` at submit time. On successful `POST /worktrees` the client shall navigate to `/session/<sessionName>`; on failure it shall display the server's `error` message inline next to the form.

**WEB-7.7** When `AppState.repos` is empty (no repositories tracked yet), the `/new` route shall render an empty-state message directing the user to open a repository in the native Graftty app first, with a back-link to `/`. The web client shall not implement repository-adding (the Mac-side file dialog + security-scoped bookmark mint has no web equivalent in Phase 2).

### 15.8 Web TLS (HTTPS)

**WEB-8.1** When binding the HTTPS server, the application shall read `Self.DNSName` from Tailscale LocalAPI `/status`, strip the trailing dot, and use the resulting FQDN as the TLS SNI name and as the hostname in every composed Base URL / session URL. If `DNSName` is absent or empty, the application shall enter `.magicDNSDisabled` status and not bind. Settings shall render a "MagicDNS must be enabled on your tailnet" message plus a link to `https://login.tailscale.com/admin/dns`.

**WEB-8.2** The application shall fetch the TLS cert+key pair for the MagicDNS FQDN from Tailscale LocalAPI `/localapi/v0/cert/<fqdn>?type=pair`. If the response is classified (HTTP status ≥ 400 + body mentioning "HTTPS" and "enable") as "HTTPS disabled for this tailnet", the application shall enter `.httpsCertsNotEnabled` status and render an admin-console link without attempting to bind. Any other fetch failure shall enter `.certFetchFailed(<message>)` status.

**WEB-8.3** While the server is listening, the application shall re-fetch the cert every 24 hours. If the returned PEM bytes differ from the currently-serving material, the application shall construct a new `NIOSSLContext` and atomically swap the reference read by the per-channel `ChannelInitializer` via `WebTLSContextProvider.swap(_:)`. The application shall not close the listening socket and shall not disturb in-flight connections — existing WebSocket streams keep their prior context for their lifetime.

**WEB-8.4** For `.magicDNSDisabled` and `.httpsCertsNotEnabled`, the Settings pane shall render a human-readable explanation plus a SwiftUI `Link` to the relevant Tailscale admin page (`https://login.tailscale.com/admin/dns`). For `.certFetchFailed`, it shall render the underlying message plus a note that Graftty retries automatically.

### 15.9 Cross-references to §13

The web access path uses Phase 1's session-naming and sandbox requirements unchanged. See §13.2 (session naming), §13.3 (`ZMX_DIR` sandbox), §13.4 (lifecycle mapping), and §13.6 (pass-through guarantees).

## 16. Keyboard Shortcuts

**KBD-1.1** When the user presses a chord bound in their Ghostty config
to an apprt action Graftty supports, the application shall dispatch
that action.

**KBD-1.2** When the user's Ghostty config omits a binding for an action,
the corresponding Graftty menu item shall render without a shortcut hint
but remain clickable.

**KBD-2.1** When the user presses `toggle_split_zoom` on a focused pane
inside a split tree, the application shall render only that pane and
keep all surfaces alive at their current size.

**KBD-2.2** When the user presses `toggle_split_zoom` on a lone pane
(tree has no siblings), the application shall no-op.

**KBD-2.3** When the user presses a `goto_split:*` chord while a pane is
zoomed and `split-preserve-zoom` does not include `navigation`, the
application shall unzoom before navigating.

**KBD-3.1** When the user presses a `resize_split:<direction>` chord,
the application shall walk up from the focused leaf to the nearest
split ancestor with matching orientation and adjust its ratio by
`amount` pixels, clamped to [0.1, 0.9].

**KBD-3.2** When no matching-orientation ancestor exists, the
application shall log at debug and no-op.

**KBD-4.1** When `reload_config` fires, the application shall rebuild
its Ghostty-config-derived menu shortcuts without requiring a restart.

**TERM-9.1** When the user activates "Reload Ghostty Config"
(either via the Graftty menu or via a Ghostty keybinding mapped to
the `reload_config` action), the application shall construct a fresh
`GhosttyConfig` — re-walking the XDG default paths, `com.mitchellh.ghostty/config`,
and recursive `config-file =` includes — and push it into the live
`ghostty_app_t` via `ghostty_app_update_config`, so subsequent key
presses and theme reads reflect edits to the on-disk config without
a restart. A stale earlier comment claimed libghostty-spm lacked a
reload C API; `ghostty_app_update_config` has been available on the
vendored surface and is what this spec pins.

**TERM-9.2** When the user activates "Open Ghostty Settings"
(either via the Graftty menu under the app-info group or via a
Ghostty keybinding mapped to the `open_config` action), the
application shall resolve the on-disk Ghostty config file and open
it via `NSWorkspace.shared.open`, which hands the file to the user's
default editor for that file type — mirroring Ghostty.app's own
"Open Configuration" behavior. Resolution priority matches Ghostty's
load order: (1) `$XDG_CONFIG_HOME/ghostty/config` if `XDG_CONFIG_HOME`
is set and non-empty, (2) `~/.config/ghostty/config`, (3)
`~/Library/Application Support/com.mitchellh.ghostty/config`; the
highest-priority existing file wins. If none of the candidate files
exist, the application shall create an empty file at location (3)
(and any missing parent directories) before opening, so the user
always receives an editable file rather than a failed-to-open no-op
on first run. If directory or file creation fails, the application
shall surface an actionable alert rather than silently continue.

## 17. PR/MR Status Display

### 17.1 Branch-to-PR Association

**PR-1.1** When the application resolves the PR for a worktree's branch on a GitHub origin, it shall scope the lookup to PRs whose head ref lives in the same repository as the base so that PRs from forks which happen to share the branch name are not associated with the worktree. Because `gh pr list --head` does not support the `<owner>:<branch>` syntax (it silently returns an empty result), the filter shall be implemented by passing the bare branch name to `gh`, requesting `headRepositoryOwner` in the JSON output, and discarding results whose `headRepositoryOwner.login` does not match the origin owner (compared case-insensitively).

**PR-1.2** If more than one PR in the same repository matches the worktree's branch and state, the application shall associate the worktree with the most recently created one.

### 17.2 Refresh Triggers

**PR-2.1** When a worktree's HEAD reference changes (per GIT-2.4), the application shall drop the worktree's previously cached PR display synchronously and shall trigger a fresh PR resolution for the new branch — rather than waiting for the next polling tick to discover the change. This prevents the previous branch's PR from continuing to display through the polling cadence window after a `git checkout`, rebase, or other HEAD-rewriting operation.

**PR-2.2** When the application observes an origin-ref change for a repository (per GIT-2.5), the application shall trigger a fresh PR resolution for every non-stale worktree in that repository whose branch is fetchable. This catches the `gh pr create` / `git push` flow — neither moves local HEAD, so PR-2.1 doesn't fire, and without this trigger the user would wait up to the full `absent` polling cadence before a newly-opened PR appears in the sidebar.

### 17.3 Sidebar Indicator

**PR-3.1** While a worktree has a resolved PR/MR (open or merged), its sidebar row shall use the SF Symbol `arrow.triangle.pull` as its leading icon in place of the default `arrow.triangle.branch` (linked worktree) or `house` (main checkout) glyph. The icon's color shall continue to encode the worktree's running state (closed / running / stale) per existing behavior; the leading-icon change communicates only the PR's existence, while detailed PR state (number, title, check status) remains in the breadcrumb's PR button.

**PR-3.2** While a worktree has a resolved PR/MR, its sidebar row shall display a `#<number>` badge between the leading icon and the branch label. The badge text shall be colored using the PR's state color: green for open, purple for merged.

**PR-3.3** The `#<number>` sidebar badge shall be a tappable button that opens the PR URL in the system browser when clicked. Clicking the badge shall not trigger the row's worktree-selection action.

**PR-3.4** The `#<number>` sidebar badge shall have an accessibility label of the form "Pull request `<number>`, open/merged. Click to open in browser." and a tooltip showing "Open #`<number>` on `<host>`".

### 17.4 Host Detection

**PR-4.1** The application shall resolve the hosting origin for a repository by running `git remote get-url origin` in the repository's path and parsing the returned URL. Both scp-style (`git@<host>:<owner>/<repo>`) and HTTP(S)/SSH URLs (`https://<host>/<owner>/<repo>`, `ssh://<host>/<owner>/<repo>`) shall be accepted; `file://`, `git://`, and bare local paths shall resolve to no origin.

**PR-4.2** Hosts whose name is `github.com`, ends in `.github.com`, or begins with `github.` shall classify as provider `github`. Hosts whose name is `gitlab.com`, ends in `.gitlab.com`, or begins with `gitlab.` shall classify as provider `gitlab`. Any other host shall classify as `unsupported`.

**PR-4.3** For worktrees belonging to a repository whose origin resolves to an `unsupported` provider or to no origin at all, the application shall not attempt PR fetches and shall not display a PR badge.

**PR-4.4** `GitOriginHost.detect` shall treat a `git remote get-url origin` nonZeroExit as a legitimate "no origin remote" answer (returning nil, cacheable per `PR-7.11`) only when stderr contains "no such remote" (case-insensitive). Every other nonZeroExit shall rethrow so the store's caller-side don't-cache-on-throw safeguard prevents a transient failure — e.g. `.git/config` being rewritten during a concurrent `git worktree add`, brief lock contention under load, an FSEvents-driven re-read mid-pack-operation — from poisoning `hostByRepo` with nil for the remainder of the session. Without this discrimination, a single transient git error at first-poll turns a repo's PR status off until Espalier is relaunched; the symptom is silent (no logs, no badge) because `tick()` skips cached-nil repos and `performFetch` treats the cache as authoritative. `LC_ALL=C` (`TECH-5`) keeps the stderr match locale-stable.

### 17.5 PR Fetching

**PR-5.1** For GitHub origins, the application shall fetch open PRs via `gh pr list --repo <owner>/<repo> --head <branch> --state open --limit 5 --json number,title,url,state,headRefName,headRepositoryOwner` and take the first result whose `headRepositoryOwner.login` matches the origin owner. Merged PRs shall use the same shape with `--state merged` and the additional `mergedAt` JSON field. The limit is 5 (rather than 1) so a fork PR returned first by `gh`'s default sort cannot crowd out a same-repo PR that the owner filter would otherwise accept.

**PR-5.2** For GitHub origins, the application shall fetch per-check status via `gh pr checks <number> --repo <owner>/<repo> --json name,state,bucket`. The `bucket` field (values `pass`/`fail`/`pending`/`skipping`/`cancel`) is the canonical verdict; `conclusion` is not a field `gh` emits from this command.

**PR-5.4** When `gh pr list` succeeds but the subsequent `gh pr checks` call for the resolved PR fails (auth hiccup, rate limit, subcommand regression, network blip), the application shall still surface the PR's identity with `.none` check status rather than propagating the checks error out of the fetch. The `#<number>` sidebar badge (`PR-3.2`) and the breadcrumb PR button shall remain visible — losing them because checks couldn't be resolved produces worse UX than displaying them with neutral check state.

**PR-5.3** For GitLab origins, the application shall fetch merge requests via `glab mr list --repo <path> --source-branch <branch> --state <opened|merged> --per-page 5 -F json` and take the first result whose `source_project_id` equals its `target_project_id`. Per-pipeline status is derived from the MR's `head_pipeline.status` field in the same response. The per-page bound is 5 (rather than 1) so a fork MR returned first by glab's default sort cannot crowd out a same-repo MR that the source/target project-id filter would otherwise accept — parity with the GitHub-side fork defense in `PR-5.1`. An MR whose project IDs cannot be verified (both fields absent in the response) is excluded rather than accepted, for the same reason the GitHub filter excludes PRs with a missing `headRepositoryOwner`.

**PR-5.5** When the application stores a PR/MR title into a `PRInfo` for display (breadcrumb `PRButton`, accessibility label, tooltip), it shall first strip every Unicode bidirectional-override scalar (the embedding, override, and isolate families — the same ranges as `ATTN-1.14`). PR titles are author-controlled, including authors who submit from malicious forks; a poisoned title like `"Fix \u{202E}redli\u{202C} helper"` would otherwise render RTL-reversed in the breadcrumb as `"Fix ildeeper helper"`-style text — the same Trojan Source visual deception (CVE-2021-42574) `ATTN-1.14` and `LAYOUT-2.18` block on self-owned surfaces. Unlike those surfaces, the PR-title path STRIPS rather than REJECTS: a poisoned title shouldn't hide the PR entirely from the user (they still need to see "a PR exists"); stripping yields a legible-ish version and the user can click through to the hosting provider for the raw text. Applies to both `GitHubPRFetcher` and `GitLabPRFetcher`.

**PR-5.6** When `GitOriginHost.parse` normalises a remote URL, it shall strip trailing `/` characters from the repo path segment before stripping the `.git` suffix. Scp-style URLs (`git@host:owner/repo.git/`) don't go through `URL`'s path normalisation, so a configured remote with a stray trailing slash — common on copy-paste from a browser address bar into `git remote set-url` — would otherwise retain `repo.git` as the repo slug. The downstream `gh pr list --repo <owner>/<repo.git>` returns no results and the sidebar silently shows no PR badge for the whole session.

**GIT-2.6** When the application renders a worktree's branch name in the UI (the breadcrumb bar per `LAYOUT-1.3`, the secondary label in the sidebar row, and the main-checkout label in right-click "Move to <name>" menu entries per `PWD-1.1` / `PWD-1.3`), it shall read `WorktreeEntry.displayBranch` rather than `WorktreeEntry.branch`. `displayBranch` strips every Unicode bidirectional-override scalar (same ranges as `PR-5.5`) so a collaborator-controlled branch name like `"feat\u{202E}lanigiro"` — which git accepts and which propagates into `state.json` via `git worktree list --porcelain` — can't render RTL-reversed in the breadcrumb, row, or menu items. `branch` itself is preserved unchanged so downstream `git` subprocess calls, `gh pr list --head <branch>`, and the `PRStatusStore.isFetchableBranch` gate keep operating on the real ref. This is the same strip-not-reject policy `PR-5.5` uses for externally-sourced text. The shared `SidebarWorktreeLabel.text(for:inRepoAtPath:siblingPaths:)` helper is the single call site for sidebar-adjacent labels so menu items and the row can't drift on the main-checkout path.

### 17.6 Check Rollup

**PR-6.1** A PR's overall check status shall roll up its individual check buckets as follows: any `fail` → `.failure`; any `pending` bucket or any in-flight state (`IN_PROGRESS`, `QUEUED`, `PENDING`) → `.pending`; all-`pass` → `.success`; anything else (including `skipping`, `cancel`, or unclassified) → `.none` (neutral).

**PR-6.2** When a PR has no checks, its overall status shall be `.none`.

### 17.7 Polling Cadence and Backoff

**PR-7.1** The application shall poll a worktree's PR status on a base cadence of 30 seconds whenever a PR is known (open or merged) or the worktree has been observed to have no associated PR (absent). A faster or tiered cadence is not applied, because `watchOriginRefs` (per GIT-2.5) catches local push/fetch but is blind to a merge landing on the hosting provider without a local `git fetch` — polling is therefore the sole detection channel for that event, and a slower cadence directly surfaces as user-visible staleness in the sidebar badge and breadcrumb PR button.

**PR-7.2** When a fetch for a worktree fails, the application shall apply exponential backoff to its cadence: the base interval (or 60s if the base is zero) shall be doubled for each consecutive failure up to a shift of 5 (32×), capped at 30 minutes.

**PR-7.3** The application shall not poll worktrees whose branch is a git sentinel value (`(detached)`, `(bare)`, `(unknown)`, any other parenthesized value, or empty / whitespace-only), since none of these correspond to a real ref that a hosting provider can associate with a PR.

**PR-7.4** The application shall not poll stale worktrees.

**PR-7.5** `PRStatusStore.refresh` and `PRStatusStore.branchDidChange` shall also apply the `PR-7.3` sentinel-branch gate, not just the background polling loop. Otherwise an on-demand refresh (sidebar selection, HEAD-change event) against a detached / bare / unknown worktree still fires two wasted `gh pr list --head <sentinel>` invocations per event — the gate belongs at the fetch entry point, not duplicated at every caller.

**PR-7.12** When the user selects a worktree in the sidebar, the application shall call `PRStatusStore.refresh` for that worktree, bypassing the `PR-7.2` cadence backoff. Rationale: a run of transient `gh` failures can push the next scheduled poll out to the 30-minute cap, during which a real state change (e.g., the PR getting merged) stays invisible in the breadcrumb. Sidebar selection is a strong "user cares about this worktree now" signal, and the existing `refresh` path already short-circuits cadence and resets `failureStreak` on success — wiring it to selection closes the stale-UI escape hatch without any new mechanism.

**PR-7.6** The PR polling ticker shall continue to fire while Graftty is not the frontmost application. `gh pr list` is the only detection channel for an open→merged transition that happens on GitHub without a local `git fetch`; pausing while the app is backgrounded leaves the sidebar's PR badge stuck on "open" until the user clicks back into Graftty, even though the merge may have happened many minutes earlier. The cost (one `gh pr list` per worktree every 30s) is negligible compared to the staleness it would otherwise produce.

**PR-7.9** When `PRStatusStore.refresh` schedules a fetch, it shall snapshot the worktree's per-path generation counter synchronously at scheduling time (not inside the spawned Task). A subsequent `branchDidChange` between the original `refresh` and when its spawned Task actually starts running would otherwise let the stale Task snapshot the post-bump generation and pass its post-await check — allowing the prior branch's still-in-flight fetch to write over the new branch's freshly-landed result when the network returns them out of order.

**PR-7.10** When a PR fetch fails (network error, rate limit, expired `gh` auth), the application shall preserve the worktree's last-known `PRInfo` cache entry rather than removing it. A transient failure is not evidence that the PR stopped existing, and dropping cached info on every failed poll makes the sidebar badge and breadcrumb PR button flicker in and out while the `PR-7.2` backoff waits to retry. The next successful fetch either confirms the cached state or updates it.

**PR-7.11** When host detection (`GitOriginHost.detect` or equivalent) throws for a repository — process launch failure, git binary missing from PATH, etc. — the application shall not cache the failure in the `hostByRepo` map. Only successful detections (whether returning a resolved `HostingOrigin` or a legitimate "no origin remote" nil) shall be cached. Otherwise a transient environment glitch at first fetch poisons the repo's PR tracking for the whole session, since the poll tick skips cached-nil repos and no code path re-attempts detection.

**PR-7.13** `PRStatusStore` shall time-bound its per-worktree `inFlight` refresh guard so a hung `gh pr list` / `gh pr checks` subprocess cannot permanently lock out subsequent polls and user-triggered refreshes. A dispatch whose start timestamp is within the base refresh cadence (`PR-7.1`, 30 seconds) shall suppress a fresh refresh; beyond that cap, the prior dispatch shall be treated as abandoned and superseded, with the per-path `generation` counter bumped so the abandoned Task's late write is dropped if it ever returns. Without this, a single stuck subprocess (network flake, rate-limit back-off, expired gh auth refresh loop) freezes that worktree's sidebar badge and breadcrumb PR button at their last-cached state until the app is relaunched — the user-observable shape "PR status only updates when I click between worktrees". Mirrors `WorktreeStatsStore`'s `DIVERGE-4.4` recovery pattern for the equivalent stats-store bug.

## 18. Claude Code Channels

### 18.1 Router and Subscriber Routing

**CHAN-1.1** The application shall host a single `ChannelRouter` that owns the `ChannelSocketServer` and maintains a `[worktreePath: ChannelSocketServer.Connection]` map keyed by the subscriber's `worktree` field.

**CHAN-1.2** When a subscriber sends a `subscribe` message, the router shall record the connection under the subscribed worktree path (replacing any prior connection for that path) and update its observable `subscriberCount`.

**CHAN-1.3** When a subscriber disconnects, the router shall remove that connection from the subscriber map and update `subscriberCount` accordingly, regardless of which worktree path the connection had subscribed under.

**CHAN-1.4** When a subscriber first subscribes, the router shall immediately send it a `type=instructions` event whose `body` is the current prompt from the injected `promptProvider`. This initial event shall be written synchronously from the server's connection-handling thread so it reaches the subscriber even when the main actor is briefly occupied; the map mutation and `subscriberCount` update still hop to the main actor where the router's state lives.

**CHAN-1.5** When `ChannelRouter.dispatch(worktreePath:message:)` is called, the router shall forward the message only to the single connection registered under the matching worktree path, if any, and shall not broadcast it to subscribers of other worktree paths.

**CHAN-1.6** When `ChannelRouter.broadcastInstructions()` is called, the router shall build a `type=instructions` event from the current `promptProvider()` and send it to every currently-registered subscriber exactly once.

**CHAN-1.7** If a write to a subscriber's connection throws (peer gone, socket closed), the router shall remove that subscriber from its map and update `subscriberCount`, so a dead peer does not leak a stale entry and subsequent dispatches to the same worktree path do not fail against the same dead fd.

**CHAN-1.8** While `ChannelRouter.isEnabled` is `false`, both `dispatch` and `broadcastInstructions` shall become no-ops, but existing subscriber connections shall remain connected — mirroring the Settings enable toggle without forcing every subscriber to reconnect on re-enable.

### 18.2 Channels Settings Pane

**CHAN-2.1** The application shall expose a "Channels" tab in the Settings window alongside "General" and "Web Access", using the `antenna.radiowaves.left.and.right` SF Symbol.

**CHAN-2.2** The Channels pane shall present an "Enable GitHub/GitLab channel" toggle bound to `@AppStorage("channelsEnabled")`, defaulting to `false` on first launch so the research-preview feature is opt-in.

**CHAN-2.3** While `channelsEnabled` is `false`, the Channels pane shall hide the research-preview disclosure banner and the prompt editor, showing only the toggle and its caption.

**CHAN-2.4** When `channelsEnabled` is `true`, the Channels pane shall display a highlighted instructional panel containing the verbatim launch flag string `--dangerously-load-development-channels server:graftty-channel`, a one-click "Copy" button that writes that string to the system pasteboard, a note that the `--dangerously-load-development-channels` flag bypasses Claude Code's channel allowlist only for this server, and a note that events originate from Graftty's local polling. The application shall not auto-inject the flag into `defaultCommand` or any other launched command — the user is responsible for adding it to their own `claude` launch.

**CHAN-2.5** When `channelsEnabled` is `true`, the Channels pane shall render an editable prompt textarea bound to `@AppStorage("channelPrompt")`, seeded on first read with the default prompt template that documents the event tag format and how Claude should respond to `pr_state_changed` and `ci_conclusion_changed` events.

**CHAN-2.6** When the user clicks "Restore default" in the prompt section, the application shall overwrite `channelPrompt` with the built-in default prompt template.

### 18.3 Launch Flag Disclosure

**CHAN-3.1** The canonical launch-flag string the Channels pane shall disclose is `--dangerously-load-development-channels server:graftty-channel`. The `server:<name>` form addresses the MCP server entry Graftty merges into `~/.claude/.mcp.json` per CHAN-4.*. The `plugin:<name>@<marketplace>` form is not used, because local plugins under `~/.claude/plugins/` are not registered under any marketplace by default and the flag rejects bare `plugin:<name>`.

**CHAN-3.2** The application shall never modify the user's `defaultCommand` string, nor inject channel flags into any command it types into a terminal. The user is the sole author of the Claude launch line.

**CHAN-3.3** Existing `claude` sessions shall continue with their original launch flags when `channelsEnabled` is toggled mid-session; only sessions started by the user after toggling shall see the change. Retroactively attaching channels to a running `claude` requires the user to restart it with the launch flag appended.

### 18.4 MCP Server Installation

**CHAN-4.1** While `channelsEnabled` is `true`, on app launch the application shall merge an `mcpServers.graftty-channel` entry into `~/.claude/.mcp.json` whose `command` is the absolute path of the bundled Graftty CLI binary and whose `args` are `["mcp-channel"]`. The merge shall preserve every other key at the document root and every other key under `mcpServers`; only the `graftty-channel` key shall be written.

**CHAN-4.2** The MCP server install shall be idempotent: repeated invocations with the same CLI path shall produce byte-identical output. A subsequent install with a different CLI path (e.g. after the user reinstalls Graftty to a new location) shall overwrite the `graftty-channel` entry while leaving other `mcpServers` entries untouched.

**CHAN-4.3** If `~/.claude/.mcp.json` exists but its contents are not valid JSON, or its `mcpServers` key is present and is not a JSON object, the application shall log the failure via `NSLog` and leave the file byte-for-byte unchanged rather than clobber a user edit that may be mid-flight. Startup shall continue without channels in that case.

**CHAN-4.4** If the bundled CLI binary is not present at the expected path (e.g. when running from `swift run` in a development build), the application shall log and skip the install, rather than writing an `.mcp.json` entry pointing at a nonexistent binary — a poisoned entry would break any Claude session the user opens outside Graftty.

**CHAN-4.5** On app launch, the application shall remove any leftover `~/.claude/plugins/graftty-channel/` directory from prior versions that installed the plugin-wrapper shape. The removal shall be a no-op when the directory is absent.

### 18.5 Event Emission

**CHAN-5.1** When `PRStatusStore` detects a PR state transition (`open` ↔ `merged`), the application shall fire a `type=pr_state_changed` channel event for that worktree carrying `from`, `to`, `pr_number`, `pr_url`, `provider`, `repo`, `worktree`, and `pr_title` attributes.

**CHAN-5.2** When `PRStatusStore` detects a CI conclusion change for a tracked PR, the application shall fire a `type=ci_conclusion_changed` channel event for that worktree carrying `from`, `to`, `pr_number`, `pr_url`, `provider`, `repo`, and `worktree` attributes.

**CHAN-5.3** Events shall not be fired for idempotent polls where `previous == current` (same `PRInfo` seen twice).

**CHAN-5.4** Events shall not be fired on initial discovery of a PR for a worktree (when `previous == nil`) — a transition requires a previous state to transition FROM.

**CHAN-5.5** The `provider` attribute shall be the lowercase raw string of the hosting provider (`github` or `gitlab`), and the `repo` attribute shall be the `owner/name` slug of the repository.

### 18.6 Prompt Update Lifecycle

**CHAN-6.1** When the user edits the channels prompt in the Settings pane, the application shall observe the change via KVO on `UserDefaults.channelPrompt` and, after a 500ms debounce, invoke `ChannelRouter.broadcastInstructions()` to fan the current prompt out to every connected subscriber.

**CHAN-6.2** The debounce shall coalesce rapid edits into a single broadcast per settled edit — successive keystrokes within the 500ms window shall reset the timer rather than each scheduling their own broadcast.

### 18.7 Error Handling

**CHAN-7.1** If the `graftty mcp-channel` subprocess fails to resolve the worktree at startup (CWD is not inside a tracked Graftty worktree), the subprocess shall emit exactly one `notifications/claude/channel` event with `meta.type = "channel_error"` on stdout, then exit with status 1.

**CHAN-7.2** If the `graftty mcp-channel` subprocess cannot connect to the channels socket at startup, the subprocess shall emit exactly one `channel_error` event and exit with status 1.

**CHAN-7.3** If the channels socket closes after a `graftty mcp-channel` subprocess has subscribed (Graftty quit, socket torn down), the subprocess shall emit one final `channel_error` event and exit cleanly.

**CHAN-7.4** When a `PRStatusStore` fetch fails (network error, rate limit, expired auth), no channel event shall be sent to any subscriber for that polling cycle. Failure is silent from the channel's perspective; only successful state-change detections fire events.

### 18.8 Socket Infrastructure

**CHAN-8.1** The channels socket shall be located at `<ApplicationSupport>/Graftty/graftty-channels.sock` by default, overridable via the `GRAFTTY_CHANNELS_SOCK` environment variable (empty-string values shall fall back to the default, matching the control socket's semantics).

## 19. iOS App

### 19.1 Target and platform

**IOS-1.1** The application shall provide a universal iOS app, `GrafttyMobile`, targeting iOS 17 or later, running on both iPhone and iPad form factors with layouts forked on `horizontalSizeClass`. (iOS 17 is the minimum because the app uses Swift's `@Observable` macro, which requires iOS 17 at runtime.)

**IOS-1.2** All iOS business logic (views, stores, session management, terminal bridging) shall live in the SwiftPM library target `GrafttyMobileKit`. The iOS .app bundle shall live in a separate Xcode project at `Apps/GrafttyMobile/GrafttyMobile.xcodeproj` that depends on `GrafttyMobileKit` by local package reference.

**IOS-1.3** Wire-format types shared between `GrafttyMobile` and the `GrafttyKit` web server — `SessionInfo`, `WebControlEnvelope` — shall live in a shared library target `GrafttyProtocol`, imported by both targets. This ensures a breaking JSON-shape change is a compile-time error on both sides.

**IOS-1.4** While the iOS application is installed, it shall appear on the home screen and in the app switcher as "Graftty" (via `CFBundleDisplayName`) and shall use the same app icon as the macOS application, sourced from the shared master `Resources/AppIcon.png`. The Xcode target, `.xcodeproj`, on-disk sources directory, and bundle identifier keep the `GrafttyMobile` name internally so `Bundle.main.bundleIdentifier` checks, keychain service strings, and the `GrafttyMobileKit` SPM target continue to work unchanged — "GrafttyMobile" is the codebase's internal handle, "Graftty" is the user-facing brand on both platforms.

### 19.2 Discovery and host storage

**IOS-2.1** The application shall provide a QR-code scanner (`AVFoundation`) that accepts any URL matching `^(http|https)://<host>(:\d+)?/?$` as a new saved host. A QR payload failing this parse shall keep the scanner open and present a non-dismissing toast `QR did not contain a Graftty URL`.

**IOS-2.2** The application shall provide manual URL entry as an equivalent alternative to the QR scanner, reaching the same `HostStore.add(_:)` entry point.

**IOS-2.3** The application shall persist the saved-host list to a JSON file in `~/Library/Application Support/<bundleID>/hosts.json`, written atomically on each mutation. Each host record shall carry `{id, label, baseURL, lastUsedAt, addedAt}`. Keychain was initially specified here, but a saved host contains no secret (just URL, label, and timestamps), and iOS-simulator Keychain access requires a signing context that ad-hoc-signed Xcode builds without a `DEVELOPMENT_TEAM` cannot obtain (every `SecItemAdd` returns `errSecMissingEntitlement`, -34018). File storage works identically on simulator and device and upgrades cleanly to a per-field Keychain split when we later persist a secret (e.g., a bearer token).

**IOS-2.4** The macOS application's Settings pane shall render the current Base URL (as already composed by `WebURLComposer.baseURL(host:port:)`) as a scannable QR code alongside the existing copy/open actions (`WEB-1.12`). When the server status is not `.listening`, the QR-code area shall render a placeholder explaining why (e.g., "Tailscale unavailable").

### 19.3 Authentication

**IOS-3.1** On cold launch, the application shall display a full-screen lock overlay until `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)` resolves successfully. While locked, no saved hostnames, session names, or terminal contents shall be visible.

**IOS-3.2** When the application enters the background, it shall record the wall-clock timestamp. When it foregrounds, if ≥5 minutes have elapsed since that timestamp, the application shall re-prompt per `IOS-3.1`.

**IOS-3.3** On authentication denial or cancellation, the application shall remain locked with a retry button; no UI behind the lock shall become interactive.

### 19.4 Session fetching and rendering

**IOS-4.1** When the user selects a saved host, the application shall issue `GET <baseURL>/worktrees/panes` and render the response as a **worktree** picker grouped by `WorktreePanes.repoDisplayName` (one row per running worktree, not one row per pane). This differs from the web client's flat session list (`WEB-5.4`) because the mobile flow is drill-down — worktree → pane tree → single pane — rather than flat selection.

**IOS-4.10** When the user selects a worktree from the picker (`IOS-4.1`), the application shall present a second screen rendering the worktree's pane split tree faithfully to the Mac sidebar's layout: each split respects its `direction` (horizontal/vertical) and `ratio`; each leaf is a tappable tile labelled with the pane's current title (or the session name when no title has been set yet). Tapping a tile pushes the fullscreen terminal for that session.

**IOS-4.11** When the user taps a pane tile, the application shall open a fullscreen terminal view for that session — a single `TerminalPaneView` with the navigation bar hidden and the terminal extending beneath the top safe area (`IOS-4.8`). The WebSocket is opened on view appear and closed on view disappear; system edge-swipe-back returns to the worktree detail.

**IOS-4.2** When `GET /sessions` returns a non-2xx status or a body that fails to decode as `[SessionInfo]`, the application shall render an error banner displaying the status code (or "malformed response") and a manual retry button. A 403 response shall instead render `Not authorized — is this device on your tailnet?` with a link that opens the Tailscale iOS app.

**IOS-4.3** When the user selects a session, the application shall open a `URLSessionWebSocketTask` at `<ws-or-wss>://<host>:<port>/ws?session=<urlEncoded name>` and attach it to an `InMemoryTerminalSession` from `libghostty-spm` rendered by `GhosttyTerminal.TerminalView`.

**IOS-4.4** On WebSocket open, the application shall send an initial `{"type":"resize","cols":<n>,"rows":<m>}` text frame derived from the terminal view's first-layout viewport, before forwarding any user input. This mirrors `WEB-5.3`.

**IOS-4.5** Server-sent binary WebSocket frames shall be forwarded to `InMemoryTerminalSession.receive(_:)` unmodified. User input emitted by libghostty via the `writeHandler` callback shall be sent as a binary WebSocket frame, mirroring `WEB-3.4` and `WEB-5.2`.

**IOS-4.6** On subsequent terminal resizes (viewport change, keyboard appearance, rotation), the application shall send a `{"type":"resize",...}` text frame matching the new viewport, mirroring `WEB-5.3`.

**IOS-4.7** When the user selects a saved host, the application shall issue `GET <baseURL>/ghostty-config` and, if the response is a non-empty 2xx body, pass it to `TerminalController.shared.updateConfigSource(.generated(text))` before mounting any `TerminalPaneView`. A missing or empty response is a non-fatal condition — the client shall fall back to `libghostty-spm`'s default configuration. The endpoint is a concatenation of the user's on-disk Ghostty configs (`$XDG_CONFIG_HOME/ghostty/config`, then `~/Library/Application Support/com.mitchellh.ghostty/config`) in the same priority order the Mac app applies them at launch, so terminals render with the same fonts, theme, and colors as the desktop.

**IOS-4.8** While a pane is mounted, the application shall hide the navigation bar (`.toolbar(.hidden, for: .navigationBar)`) and extend the terminal beneath every safe-area edge (`.ignoresSafeArea()`) — top (under the notch), bottom (under the home indicator), and the left/right safe-area strips in landscape. libghostty renders its configured background color to the full view bounds, so the unsafe regions pick up the terminal's own background rather than the SwiftUI default. The user returns to the worktree detail via the system edge-swipe-back gesture rather than an explicit button.

**IOS-4.9** The application shall display a floating keyboard button at the bottom-trailing corner of the pane view with three states:
  1. While the software keyboard is visible, the button shall render the `keyboard.chevron.compact.down` SF Symbol with an accessibility label of "Hide keyboard". Tapping it shall resign first-responder on the key window AND set the internal "keyboard allowed" flag to false.
  2. While the keyboard is hidden and the user has explicitly dismissed it (flag is false), the button shall render the `keyboard` SF Symbol with an accessibility label of "Show keyboard". Tapping it shall set the flag to true and programmatically call `becomeFirstResponder()` on the underlying `UITerminalView` (via a monotonic focus-request counter threaded through `TerminalPaneView.updateUIView`).
  3. When the keyboard is hidden and the flag is true (the default on first pane entry), no button shall render; the user can summon the keyboard by tapping the terminal.

While the "keyboard allowed" flag is false, any stray keyboard-will-show event (e.g. triggered by a mistaken tap that lets `UITerminalView` become first responder internally) shall be dismissed immediately by posting `resignFirstResponder` to the responder chain. This produces a one-frame flicker at worst but guarantees the user's dismissal intent is honoured until they explicitly reopen the keyboard.

### 19.5 Multi-pane layout

**IOS-5.1** On iPad (regular `horizontalSizeClass`), the application shall render a `NavigationSplitView` sidebar + detail layout. The sidebar shall show saved hosts; tapping a host reveals the session picker; tapping a session renders the detail as a terminal pane.

**IOS-5.2** On iPad, the application shall support an in-app left/right split in the detail area, with up to two concurrent panes. Each pane owns its own `URLSessionWebSocketTask` + `InMemoryTerminalSession`. Each pane independently emits its own resize envelopes.

**IOS-5.3** On iPhone (compact `horizontalSizeClass`), the application shall collapse the layout to a `NavigationStack`. Only one pane is visible at a time; session switching is via a bottom-edge session switcher.

**IOS-5.4** When multiple panes exist, only one pane shall be focused at a time. The keyboard accessory bar and hardware keyboard routing shall deliver input only to the focused pane.

### 19.6 Input

**IOS-6.1** Above the software keyboard, the application shall render a `KeyboardAccessoryBar` exposing, at minimum: Esc, Tab, Ctrl (sticky), ↑ ↓ ← →, `|`, `/`, `~`, `-`. The Ctrl key shall be a one-shot modifier — tapping Ctrl then any subsequent key (letter, digit, space, or symbol) shall send that key with the control modifier applied to the focused pane's `TerminalView` via libghostty-spm's key-event API; the modifier shall clear after that one key, or on a second Ctrl tap if no intervening key was pressed.

**IOS-6.2** libghostty-spm's `TerminalView` shall be the primary owner of key-event translation for every pane; software-keyboard text and hardware-keyboard key events shall reach it directly. The application shall additionally publish a `UIKeyCommand` table solely for **application-level** shortcuts that must be intercepted before the terminal sees them (e.g., Cmd-\\ to split on iPad, Cmd-1…9 to switch visible sessions). `UIKeyCommand` shall not be used to re-implement terminal chord translation — that path belongs to libghostty-spm.

### 19.7 Lifecycle

**IOS-7.1** When the application enters the background, it shall close every active `URLSessionWebSocketTask` with WebSocket close code 1000 (normal closure) and tear down every `InMemoryTerminalSession`. The server's response (SIGTERM to each `zmx attach` child per `WEB-4.5`) leaves the zmx daemon alive per `ZMX-4.4`, so reconnect picks up the same session.

**IOS-7.2** When the application foregrounds and the biometric gate is satisfied (either the ≥5 min path with re-prompt per `IOS-3.2` or the within-5-min fast path), the application shall re-fetch `/sessions` for each host whose panes were previously active and then re-dial every pane whose session name is still present in the response, re-mounting its `TerminalView`. Per `PERSIST-4.1` the application does not persist scrollback itself; whatever the zmx daemon still has is what the user sees.

**IOS-7.3** When a previously active pane's session name is absent from the fresh `/sessions` response (e.g., the worktree was stopped on the Mac while the iOS app was backgrounded), the application shall mark that pane as `sessionEnded` with a non-retryable banner and shall not open a WebSocket for it. The banner shall offer "Back to sessions" as the only action.

**IOS-7.4** On WebSocket failure (upgrade failure, read/write error, or close frame not initiated by the app) for a pane whose session name is still listed in `/sessions`, the application shall display a per-pane "disconnected" banner with "Reconnect" and "Back to sessions" buttons. While the host view is visible, the application shall retry automatically with exponential backoff: the delay starts at 1 second, doubles after each successive failure, and is capped at 30 seconds. Each successful connect resets the delay to 1 second. When the host view is not visible, no automatic retry shall occur.

### 19.8 Non-goals (recorded for future specs)

**IOS-8.1** The v1 iOS app shall not support connecting to non-Graftty SSH/mosh hosts.

**IOS-8.2** The v1 iOS app shall not forward terminal mouse events, OSC 52 clipboard reads, or Kitty graphics/keyboard-protocol sequences. (Mirrors `WEB-6.2`.)

**IOS-8.3** The v1 iOS app shall not initiate any pane / worktree / session lifecycle operations on the Mac (create, close, split, move, stop). Any such control surface is deferred to a future spec.

**IOS-8.4** The v1 iOS app shall not persist terminal scrollback on the device. On reconnect, it renders whatever the zmx daemon's buffer still contains.

**IOS-8.5** The v1 iOS app shall not use push notifications for PR status, build completions, or session events.

**CHAN-8.2** The channels socket shall be distinct from the control socket at `graftty.sock`; a failure affecting one shall not disrupt the other.
