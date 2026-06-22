# Graftty — EARS Requirements Specification

Requirements for a macOS worktree-aware terminal multiplexer built on libghostty.

This file is generated from `@spec` annotations in `Sources/` and `Tests/`. Do not edit manually — run `scripts/generate-specs.py` to regenerate.

## LAYOUT — App Layout

### LAYOUT-1.x — Window Structure

**LAYOUT-1.1** The application shall display a single main window with a resizable sidebar on the left and a terminal content area on the right.

**LAYOUT-1.2** The sidebar shall be resizable via a drag handle between the sidebar and the terminal content area.

**LAYOUT-1.3** The terminal content area shall display a breadcrumb bar above the terminal split layout showing, in order: the selected repository's display name, a `/` separator, the worktree's display name (rendered italic as `root` for the repository's main checkout, otherwise the sibling-disambiguated name per `LAYOUT-2.15`), and the branch name in parentheses at caption weight. The worktree's full filesystem path shall be available as a hover tooltip on the worktree-name element rather than rendered inline. When the worktree has a resolved PR/MR, the trailing edge of the breadcrumb shall additionally show the PR button per `PR-3.x`.

**LAYOUT-1.4** While the sidebar is hidden (`NavigationSplitViewVisibility.detailOnly`), the breadcrumb bar shall apply a leading inset wide enough to clear the window's traffic-light buttons and the sidebar-toggle button so its text remains legible at the window's left edge. While the sidebar is visible, the breadcrumb shall use its standard 12pt leading padding because the sidebar column already offsets the detail content past the traffic lights.

### LAYOUT-2.x — Sidebar — Repository List

**LAYOUT-2.1** The sidebar shall display an ordered list of repositories, each expandable to show its worktrees.

**LAYOUT-2.2** Each repository entry shall be collapsible and expandable by clicking its disclosure indicator.

**LAYOUT-2.3** When a repository is expanded, the sidebar shall display the repository's own working directory as the first child entry, labeled by its current branch name.

**LAYOUT-2.4** When a repository is expanded, the sidebar shall display each linked worktree as a child entry beneath the repository's own working directory, labeled by branch name.

**LAYOUT-2.5** The sidebar shall display an "Add Repository" button at the bottom.

**LAYOUT-2.6** When the user clicks a worktree or repository working directory entry, the terminal content area shall switch to display that entry's terminal layout.

**LAYOUT-2.7** When the user right-clicks a sidebar entry, the application shall display a context menu with actions appropriate to the entry's current state.

**LAYOUT-2.8** While a worktree is in the running state, the sidebar shall display one indented child row per terminal pane beneath the worktree entry, each labeled by that pane's current title.

**LAYOUT-2.9** If a terminal pane has no program-set title, then the pane's row shall display its last-known working directory's basename as the label. If the working directory is also unknown (root `/`, empty, or never reported), then the pane's row shall display the fallback label "shell".

**LAYOUT-2.10** When the user clicks a pane row, the application shall select that pane's worktree and focus that specific pane.

**LAYOUT-2.11** The sidebar shall display the active worktree row and all its pane rows inside a single unified highlighted block; within that block, the focused pane's row shall additionally be emphasized via text weight and color (no secondary background).

**LAYOUT-2.12** While a worktree entry is not in the stale state, its context menu shall include an "Open Worktree in Finder..." action that opens the worktree's filesystem path in the system file browser via `NSWorkspace.shared.open`.

**LAYOUT-2.13** The application shall reject incoming OSC 2 titles that match either of two shapes: (a) trimmed value matching `^[A-Z_][A-Z0-9_]*=` (an uppercase identifier followed by `=`), or (b) containing the literal substring `GHOSTTY_ZSH_ZDOTDIR` anywhere in the title. These shapes are command-echo leaks historically produced by ghostty's shell-integration `preexec` hook when the legacy native zmx bootstrap typed an `exec zmx attach …` line through an outer shell; propagating them to the sidebar would display a 200+ character shell-command string as the pane's title until the inner shell's first prompt overwrites it. Shape (a) catches the pre-`ZMX-6.4` naked-env-assignment form; shape (b) catches the post-`ZMX-6.4` conditional form (`if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR=…; fi; ZDOTDIR=… exec zmx attach …`) and guards against any future bootstrap-like regression that preserves the `GHOSTTY_ZSH_ZDOTDIR` marker. The previously stored title (if any) is retained; if none, the pane falls back to the LAYOUT-2.9 chain.

**LAYOUT-2.14** When `PaneTitle.display` is asked to render a stored title consisting of only whitespace (spaces, tabs), the application shall fall through to the PWD basename (or the "shell" view-level fallback) rather than rendering visible blank space as the pane label. Real content with surrounding whitespace (e.g., `" claude "`) is preserved verbatim — the check is whitespace-only-vs-content, not a trimming operation.

**LAYOUT-2.15** `WorktreeEntry.displayName(amongSiblingPaths:)` shall grow its disambiguation suffix one path component at a time until the candidate is unique amongst siblings, rather than stopping at a single `<parent>/<leaf>` level. Previous behavior: two siblings like `/repo/.worktrees/deep/ns/feature` and `/repo/.worktrees/other/ns/feature` both rendered as `ns/feature` because the algorithm didn't grow past one parent. With `WorktreeNameSanitizer` now permitting `/` in worktree names (`GIT-5.1`), deeply nested worktrees that share both leaf and immediate parent are plausible. The new algorithm returns `deep/ns/feature` vs `other/ns/feature`; if a sibling's path is a strict suffix of another's (pathological), falls back to the full path so something still distinguishes them.

**LAYOUT-2.16** The application shall also reject incoming OSC 2 titles whose grapheme-cluster length exceeds `PaneTitle.maxStoredLength` (200), bounding the transient heap cost of the `titles[PaneSlotID: String]` dict against a misbehaving program that pushes a multi-kilobyte payload. The cap matches `Attention.textMaxLength` so the pane-title and notify-text surfaces share the same limit. Rejection semantics match `LAYOUT-2.13`: the previously stored title (if any) is retained; if none, the pane falls back to the `LAYOUT-2.9` chain.

**LAYOUT-2.17** The application shall also reject incoming OSC 2 titles containing any Unicode Cc (control) scalar — line feed, carriage return, tab, bell, ANSI escape (`\e`), DEL, or any other C0/C1 control. SwiftUI `Text` with `.lineLimit(1)` clips newlines but renders escape sequences like `\e[31m` as literal `[31m` glyphs (the ESC byte is invisible), producing sidebar strings like `[31mred[0m`. This is the same visual-garbage class as CLI's `ATTN-1.12` for notify text; the server-side OSC 2 surface was previously unchecked. Rejection semantics match `LAYOUT-2.13` / `LAYOUT-2.16`: the previously stored title (if any) is retained; if none, the pane falls back to the `LAYOUT-2.9` chain.

**LAYOUT-2.18** The application shall also reject incoming OSC 2 titles containing any Unicode bidirectional-override scalar — the embedding family (`U+202A`–`U+202C`), the override family (`U+202D`–`U+202E`), or the isolate family (`U+2066`–`U+2069`). These are Cf-category so `LAYOUT-2.17`'s Cc gate misses them, but they reverse surrounding text at render time — a rogue inner-shell program can push `printf '\e]0;\u202Edecoy\u202C\a'` and have the title display RTL-reversed in the pane row, the same "Trojan Source" visual deception (CVE-2021-42574) that `ATTN-1.14` blocks on the notify surface. Natural RTL text (Arabic, Hebrew, Persian) uses character-intrinsic directionality rather than these override scalars and still passes. Rejection semantics match `LAYOUT-2.13` / `LAYOUT-2.16` / `LAYOUT-2.17`.

**LAYOUT-2.19** When repeated terminal title or PWD actions leave a pane's rendered sidebar title unchanged, the application shall retain the latest raw metadata without publishing a sidebar invalidation.

**LAYOUT-2.20** While a program-set pane title is the rendered sidebar title, incoming PWD actions shall update the raw pane PWD without publishing sidebar invalidations.

**LAYOUT-2.21** When a terminal title action sanitizes to a rendered sidebar title equal to the current fallback title, the application shall store the raw title without publishing a sidebar invalidation.

**LAYOUT-2.22** When a PaneTitleRow's pane title would render wider than the row's available width, the row's reported intrinsic size shall remain bounded by that width so the enclosing worktree block's `.listRowInsets(leading: -20)` outdent is preserved and the WorktreeRow above does not appear indented.

**LAYOUT-2.23** When the user drags worktree rows within a repository section, the application shall reorder only that repository's persisted `worktrees` array so the order survives state save/load.

**LAYOUT-2.24** When a worktree enters the stale/yellow state, the application shall permanently move stale worktrees to the bottom of that repository's persisted `worktrees` array while preserving relative order within stale and non-stale groups.

**LAYOUT-2.25** The application shall display the repository's resolved default branch name as the main-checkout sidebar row's primary label, regardless of the worktree's current HEAD.

**LAYOUT-2.26** When the main-checkout worktree's current branch differs from the repository's resolved default branch, the sidebar row shall render the current branch as a dimmed secondary caption beneath the primary label.

**LAYOUT-2.27** The application shall render the `house` SF Symbol on the main-checkout sidebar row regardless of whether a PR is associated with that worktree, so the home affordance never disappears.

**LAYOUT-2.28** The application shall fall back to `main` for the main-checkout row label when no default branch has been resolved.

**LAYOUT-2.29** Repository's default branch as resolved by `GitOriginDefaultBranch.resolve` (origin/HEAD symbolic-ref with main/master/develop probe fallback). `nil` when no default branch can be identified.

**LAYOUT-2.30** When a pane has an active attention capsule, the application shall render the capsule to the right of the pane title (not in place of it), truncating the title so the capsule keeps its intrinsic width — the row stays a single line (pill beside, not stacked under) and its width stays bounded by the row.

**LAYOUT-2.31** The agent "needs input" attention (source .agentStop) shall render as a bare red `rectangle.and.pencil.and.ellipsis` SF Symbol (no pill) beside a red-colored pane title, with the text retained as the icon's accessibility label; user-notify and command-finished capsules shall render as text in a red pill.

### LAYOUT-3.x — Adding Repositories

**LAYOUT-3.1** When the user clicks "Add Repository", the application shall present a standard macOS open panel for selecting a directory.

**LAYOUT-3.2** When the user drops a directory onto the sidebar, the application shall add it as a repository.

**LAYOUT-3.3** When the user adds a directory that is a git worktree (rather than a repository root), the application shall trace back to the parent repository, add the full repository with all its worktrees, and auto-select the added worktree.

**LAYOUT-3.4** If the user adds a directory that is not a git repository or worktree, then the application shall display an error message and not add the directory.

**LAYOUT-3.5** If the user adds a repository that is already in the sidebar, then the application shall not create a duplicate and shall select the existing entry.

### LAYOUT-4.x — Removing & Relocating Repositories

**LAYOUT-4.1** When the user right-clicks a repository header row in the sidebar, the application shall display a context menu containing a "Remove Repository" action.

**LAYOUT-4.2** When the user triggers "Remove Repository", the application shall display a confirmation dialog whose informative text explicitly states "This removes the repository from Graftty but does not delete any files from disk."

**LAYOUT-4.3** When the user confirms "Remove Repository", the application shall (a) tear down all terminal surfaces in every worktree of the repository whose `state == .running`, (b) stop the repository-level FSEvents watchers (`.git/worktrees/` and origin refs) and each worktree's per-path, HEAD-reflog, and content watchers, (c) clear the cached PR status and divergence stats for every worktree of the repository, (d) clear `selectedWorktreePath` if it pointed to any worktree in the repository, and (e) remove the repository entry from `AppState`. Steps (a)–(d) must precede (e) for the same orphan-surfaces / orphan-caches reasons as GIT-3.10 / GIT-4.10 / GIT-3.13 and the watcher-fd-lifetime reason as GIT-3.11.

**LAYOUT-4.4** The "Remove Repository" action shall not invoke `git` and shall not modify any files on disk. Worktree directories, branches, and git metadata remain untouched; the operation affects only Graftty's in-memory model and persisted `state.json`.

**LAYOUT-4.5** When the user adds a repository, the application shall record a `URL` bookmark (`URL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)`) for the repository folder and persist it on the `RepoEntry` alongside the path. Bookmark minting failures shall be non-fatal — the repository entry shall be created with a nil bookmark and forgo auto-recovery.

**LAYOUT-4.6** On launch, before FSEvents watchers are installed, for each repository entry whose bookmark is non-nil, the application shall resolve the bookmark via `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`. If the resolved path differs from the stored `RepoEntry.path`, the application shall run the relocate cascade described in LAYOUT-4.8. If the bookmark is resolvable but stale (cross-volume move), the application shall re-mint and persist a fresh bookmark from the resolved URL.

**LAYOUT-4.7** When `WorktreeMonitor` reports a deletion event for a worktree path whose owning repository has a non-nil bookmark, the application shall resolve the bookmark and, if the resolved path differs from the stored `RepoEntry.path`, run the relocate cascade described in LAYOUT-4.8 before applying the existing transition-to-`.stale` path (GIT-3.3). If bookmark resolution fails or the resolved folder is no longer a git repository, the application shall fall through to the existing `.stale` path.

**LAYOUT-4.8** The relocate cascade for a repository resolved to `newURL` differing from the stored path shall: (a) verify a `.git` entry exists at `newURL.path`, aborting if not, (b) stop all existing watchers tied to old paths, (c) run `GitWorktreeDiscovery.discover(repoPath: newURL.path)`, running `git worktree repair` and re-discovering if any previously-known linked worktree is omitted from the discovery result, (d) update the `RepoEntry`'s `path` and `displayName` to the new location, (e) match each existing `WorktreeEntry` to a discovered worktree by **branch name** and preserve `id`, `splitTree`, `state`, `focusedPaneSlotID`, `paneAttention`, `attention`, and `offeredDeleteForResolvedPR`, updating only `path`, (f) clear per-path PR-status and divergence-stats cache entries for every worktree whose path changed, (g) update `selectedWorktreePath` from its old path to the corresponding new path if applicable, and (h) re-install repository-level and per-worktree FSEvents watchers at the new paths. Steps (a)–(c) shall precede (d) so that a discovery failure leaves the model unchanged.

**LAYOUT-4.9** For a repository entry loaded from `state.json` without a bookmark (migration from a pre-LAYOUT-4.5 build), the application shall mint a fresh bookmark from the stored `path` if that path still resolves on disk, and persist it.

**LAYOUT-4.10** The application shall use regular (not security-scoped) bookmarks. Security-scoped bookmarks are unnecessary because Graftty is not sandboxed and `NSOpenPanel` already grants the app arbitrary-path URLs.

### LAYOUT-5.x — Window Lifecycle

**LAYOUT-5.1** When the user closes the main window (Cmd+W, red traffic-light button, or `File → Close`), the application shall keep running as a foreground app — the Dock icon remains visible, background services (socket listener, stats/PR pollers, filesystem watchers, web access server) keep running, and any running terminal panes stay attached to their underlying zmx sessions. Closing the window is not a quit; the user explicitly issues `Cmd+Q` or `File → Quit` to terminate the app.

**LAYOUT-5.2** When the user activates the app from the Dock (click, `Cmd+Tab`, or Spotlight) while no windows are visible, the application shall display the main window again, populated from the already-in-memory `AppState` (repositories, worktrees, selection, and split trees) and with the `WindowFrameTracker` frame-restoration of `PERSIST-3.4` applied to the recreated `NSWindow`. Existing running terminal panes are re-rendered from the persisted `TerminalManager`'s surface map without recreating their underlying libghostty surfaces or zmx sessions.

**LAYOUT-5.3** The application's one-time startup path (`ghostty_init` and the `ghostty_app_t` construction inside `TerminalManager.initialize()`, the `SocketServer.start()`, `reconcileOnLaunch()`, the stats/PR poller `start()` calls, the `restoreRunningWorktrees()` pass, and the `NSApplication.willTerminateNotification` observer registration) shall run exactly once per app-process lifetime, regardless of how many times the root `WindowGroup` scene is instantiated. The SwiftUI reopen flow (`applicationShouldHandleReopen` → `applicationOpenUntitledFile:`) and any future multi-window entry points (`File → New Window`) re-invoke the `WindowGroup` content closure and therefore fire `.onAppear` again; the implementation seam is a `@State` boolean on `GrafttyApp` whose storage persists across scene re-creations. Without this guard, `TerminalManager.initialize()`'s `ghosttyApp == nil` precondition traps the process on the second invocation.

## STATE — Worktree Entry States

### STATE-1.x — State Definitions

**STATE-1.2** While a worktree entry is in the closed state, the sidebar shall display its type icon (house for the main checkout, branch for linked worktrees) in a dimmed foreground color.

**STATE-1.3** While a worktree entry is in the running state, the sidebar shall display its type icon tinted green.

**STATE-1.4** While a worktree entry is in the stale state, the sidebar shall display its type icon tinted yellow, with strikethrough text and grayed-out appearance on the label.

### STATE-2.x — Attention Overlay

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

**STATE-2.11** When the user triggers Stop on a running worktree (`TERM-1.2`'s companion — tears down all panes at once while preserving the split tree for re-open), the application shall drop every pane-scoped attention entry on that worktree. Extends `STATE-2.7`'s per-pane rule to the all-panes-at-once case. Without this, a stale pane attention badge from before the Stop would reappear on the fresh pane's sidebar row when the user re-opens the worktree — same-`PaneSlotID` leaves are reused on re-open to preserve layout, so the attention dictionary must be cleared explicitly. The worktree-level `attention` slot (CLI-notify) is left untouched — it's a worktree-wide concern independent of which panes are alive.

**STATE-2.12** When the application launches and loads persisted `Attention` entries (worktree-level `wt.attention` or pane-level `wt.paneAttention[terminalID]`), for each one that carries a non-nil `clearAfter`, the application shall reschedule the auto-clear timer against the remaining time derived from `attention.timestamp + clearAfter` relative to the current clock. If the deadline has already passed, the timer shall fire on the next main-queue turn (zero-delay `asyncAfter`) and clear the stale entry immediately. Without this resume, a force-quit during a `--clear-after` window leaves the attention stuck in state.json forever because the original `DispatchQueue.main.asyncAfter` is in-memory only. For defensive handling of a persisted timestamp in the future (clock skew, hand-edit), the remaining window shall be clamped to the full `clearAfter` duration measured from now rather than a negative elapsed value.

## TERM — Terminal Lifecycle

### TERM-1.x — Starting Terminals

**TERM-1.1** When the user clicks a worktree entry in the closed state that has no saved split tree, the application shall create a single terminal pane with its working directory set to the worktree path and transition the entry to the running state.

**TERM-1.2** When the user clicks a worktree entry in the closed state that has a saved split tree, the application shall recreate terminal panes matching the saved split tree topology, each with its working directory set to the worktree path, and transition the entry to the running state.

**TERM-1.3** When the user triggers Stop on a running worktree that has processes which need quit-confirmation, the application shall present a confirmation dialog whose informative text identifies the worktree by its sidebar display name (per `WorktreeEntry.displayName(amongSiblingPaths:)` / `LAYOUT-2.15`), not its raw `branch` value. For worktrees on a detached HEAD or other git sentinel (`(detached)`, `(bare)`, `(unknown)` — see `PR-7.3`), the display name resolves to the directory basename, which reads naturally ("running processes in my-feature") whereas the raw branch would render as "running processes in (detached)".

### TERM-2.x — Switching Between Worktrees

**TERM-2.1** When the user switches from one running worktree to another, the application shall hide the previous worktree's terminal views without destroying the terminal surfaces or their running processes.

**TERM-2.2** When the user switches back to a previously running worktree, the application shall restore the terminal views with all processes still running.

**TERM-2.3** When the user switches back to a running worktree, the application shall restore keyboard focus to the pane that was focused when the user last switched away.

**TERM-2.4** When the user clicks directly on a terminal pane's view (independent of the sidebar pane-row), the application shall persist that pane as the worktree's last-focused pane in the same model field that `TERM-2.3` reads on return. A visual-only focus change (libghostty / NSView side) without a matching model update would let focus snap back to the first leaf on the next return visit.

**TERM-2.5** When the selected worktree changes, the application shall call `ghostty_surface_set_occlusion(surface, false)` for surfaces in the old selected worktree and `ghostty_surface_set_occlusion(surface, true)` followed by `ghostty_surface_refresh(surface)` for surfaces in the newly selected worktree. The boolean passed to `ghostty_surface_set_occlusion` is Ghostty's `visible` flag, not an `occluded` flag. When a terminal pane's `SurfaceViewWrapper` is mounted, focused, resized, or receives keyboard input, the application shall also mark the surface visible and refresh it so libghostty performs a full clean repaint of the current state. The application shall not derive hidden state directly from SwiftUI `.onDisappear`, because transient unmount/remount callbacks can race with focus and attach. If SwiftUI/AppKit reports a collapsed zero- or sub-pixel resize, then the application shall ignore that resize rather than forwarding a one-pixel size to libghostty, so background output does not accumulate scrollback wrapped at one column while the pane is hidden.

**TERM-2.6** On application restart, persisted `.running` worktrees shall be marked as rehydrated but only the currently-selected worktree shall immediately recreate libghostty surfaces and run `zmx attach`. Other running worktrees shall attach lazily when selected. This keeps hidden panes from rendering or reattaching while they are not displayed, and prevents a large saved workspace from delaying input in the pane the user is actually returning to.

### TERM-3.x — Splitting

**TERM-3.1** When the user triggers a horizontal split, the application shall insert a new terminal pane to the right of the focused pane with a 50/50 ratio.

**TERM-3.2** When the user triggers a vertical split, the application shall insert a new terminal pane below the focused pane with a 50/50 ratio.

**TERM-3.3** The new terminal pane created by a split shall have its working directory set to the worktree root path.

### TERM-4.x — Resizing Splits

**TERM-4.1** The application shall display a draggable divider between split panes.

**TERM-4.2** When the user drags a divider, the application shall resize the adjacent panes so that the divider tracks the cursor's position inside the enclosing split container.

**TERM-4.3** When the user releases a divider drag, the application shall persist the new ratio in the worktree's split tree so that the layout survives app restarts. Intermediate positions during the drag need not be persisted.

**TERM-4.4** When a pane is removed from the split tree, the application shall forward the new layout size to libghostty so remaining panes reflow to fill the vacated space.

### TERM-5.x — Closing a Pane

**TERM-5.1** When the user closes a terminal pane, the application shall remove it from the split tree and allow the sibling pane to fill the vacated space.

**TERM-5.2** When the user closes the last terminal pane in a worktree, the application shall transition the worktree entry to the closed state.

**TERM-5.3** When a terminal pane's child process exits, the application shall automatically remove the pane from the split tree and free its surface without requiring user action.

**TERM-5.4** When an auto-closed pane was the last pane in its worktree, the application shall transition the worktree entry to the closed state, matching the user-initiated close behavior.

**TERM-5.5** If `ghostty_surface_new` returns null (libghostty resource exhaustion, malformed config, or any internal rejection) when the application tries to create a terminal surface, the application shall skip the failed leaf and propagate a nil result to the caller rather than trap via `fatalError`. Callers shall treat nil as "surface creation failed": `splitPane` shall roll back its split-tree mutation so no dangling leaf is left behind; `addPane` (CLI `graftty pane add`) shall return a socket `.error("split failed")`; `createSurfaces` (worktree open) shall leave the leaf's surface dict entry empty so the view renders the `Color.black + ProgressView` fallback without crashing the app. Observed pre-fix: `graftty pane add --command ...` triggered a SIGTRAP inside `SurfaceHandle.init` whenever libghostty couldn't build the surface.

**TERM-5.6** When a terminal pane is removed (user close via Cmd+W, shell exit, CLI `graftty pane close`), the application shall promote `focusedPaneSlotID` to `remainingTree.allLeaves.first` ONLY if the removed pane was the currently-focused one. If a different pane was focused, `focusedPaneSlotID` shall stay on that pane — it's still present in the remaining tree, and the user's keystrokes should continue to route there. Pre-fix behavior (unconditional promotion to the first leaf) silently jumped focus whenever the user closed a pane other than their focused one, mirroring Andy's "furious when any tool kills a long-running shell unexpectedly" pain point in the focus-redirection dimension.

**TERM-5.7** When libghostty's `close_surface_cb` fires for a pane whose `SurfaceHandle` has already been torn down by Graftty (e.g. via `terminalManager.destroySurfaces(...)` during a `Stop Worktree` action), the application's close-event handler shall observe the missing surface handle and no-op rather than modifying the worktree's `splitTree`. Without this guard, the async close-event cascade that follows `Stop` would re-enter `closePane` for each leaf and strip them from the preserved split tree, emptying `splitTree` and violating `TERM-1.2`'s "re-open recreates the saved layout" contract. The guard applies only to library-initiated close events; user-initiated closes are covered by `TERM-5.8`.

**TERM-5.8** When the user explicitly invokes a pane close (`Cmd+W`, CLI `graftty pane close <id>`, or a context-menu Close action) against a leaf whose `SurfaceHandle` is absent — i.e. a phantom pane whose surface never created successfully because libghostty refused (OOM / resource pressure, `TERM-5.5`) — the application shall still remove the leaf from the worktree's `splitTree`. Without this, a phantom leaf is uncloseable: the sidebar renders a black / progress placeholder, `pane list` reports it, but every close path silently no-ops via `TERM-5.7`'s guard. The implementation seam is a `userInitiated` parameter on `closePane`: user paths pass `true` to bypass the handle guard; libghostty's async `close_surface_cb` passes `false` (default) so Stop cascades continue to preserve the tree.

**TERM-5.9** When `SurfaceHandle.setFrameSize` forwards a backing-pixel dimension to `ghostty_surface_set_size`, the conversion from `CGFloat` to `UInt32` shall be performed via a defensive clamp that maps `NaN` and values `≤ 1` to `1`, `+∞` and values `≥ UInt32.max` to `UInt32.max`, and all other finite values to their truncated `UInt32` representation. Naive `UInt32(max(1, Int(dim)))` traps on `NaN` and on out-of-`Int`-range values; SwiftUI `GeometryReader` has been observed to emit `.infinity` transiently during certain rebinding flows, and a trap on the view's layout pass crashes the whole process (every open pane dies). The helper is `SurfacePixelDimension.clamp(_:)` in GrafttyKit so the rule is unit-testable without an NSView host.

**TERM-5.10** When `NativePtySession.close()` is called while a `writeToSurface` callback is mid-execution on the PTY reader thread, the application shall block `close()` until that callback returns and shall ensure no further `writeToSurface` invocation occurs after `close()` has returned. The barrier prevents `SurfaceHandle.deinit` (which calls `close()` and then `ghostty_surface_free`) from racing with an in-flight `ghostty_surface_write_buffer` on the reader thread; without it, the reader dereferences the freed surface and aborts with `BUG IN CLIENT OF LIBPLATFORM: os_unfair_lock is corrupt`.

### TERM-6.x — Stopping a Worktree

**TERM-6.1** When the user triggers "Stop" on a running worktree, if any terminal surface has a running process, then the application shall display a confirmation dialog before proceeding.

**TERM-6.2** When the user confirms stopping a worktree, the application shall close and free all terminal surfaces in the worktree's split tree, preserve the split tree topology, and transition the entry to the closed state.

### TERM-7.x — Focus Management

**TERM-7.1** When the user clicks a terminal pane, the application shall set keyboard focus to that pane.

**TERM-7.2** The application shall support keyboard navigation between panes using directional shortcuts (e.g., Cmd+Opt+Arrow).

**TERM-7.3** When the user navigates between panes via directional keyboard (Cmd+Opt+Arrow, or libghostty's `goto_split` left/right/up/down actions), the application shall move focus to the leaf that is spatially adjacent in the requested direction — determined by walking the split tree from the focused leaf up to the nearest ancestor whose split orientation matches the motion axis and whose source-side subtree contains the current leaf, then descending into the opposite subtree's near-edge leaf. If no such ancestor exists, the application shall leave focus unchanged rather than wrapping around the tree in DFS order.

**TERM-7.4** When the application launches with a selected running worktree, the application shall automatically promote that worktree's focused pane to the window's first responder so the user can begin typing without first clicking inside a terminal.

**TERM-7.5** When the user selects a worktree or pane row in the sidebar, the application shall promote the target pane's `NSView` to the window's first responder so subsequent keystrokes route to that pane without an intermediate click.

**TERM-7.6** When the user invokes `Previous Pane` / `Next Pane` (libghostty's `goto_split:previous` / `goto_split:next`), the application shall cycle focus through the worktree's leaves in DFS (reading) order regardless of spatial layout. This is distinct from the directional arrow-key navigation in `TERM-7.3` — round-robin cycling is an intentional second mode, not a fallback.

**TERM-7.7** When a pane is created via a split (`splitPane`), a CLI-triggered add (`pane add`), or any other path that mints a fresh `SurfaceHandle` before SwiftUI has had a chance to insert the view into the window hierarchy, the application shall still promote the new pane's `NSView` to the window's first responder — overriding the previously-focused pane whose view is still the current first responder. The implementation seam is `SurfaceHandle.setFocus(true)`: if the target view is already attached to a window, first responder is claimed synchronously; if not, the claim is re-enqueued on the main queue so it runs after SwiftUI mounts the view. Pre-fix behavior: after `Cmd+D`, the model's `focusedPaneSlotID`, the sidebar's focus highlight, and libghostty's focused-cursor rendering all pointed at the new pane, yet AppKit's first responder remained the previously-focused pane — so keystrokes kept landing in the old pane. `SurfaceNSView.viewDidMoveToWindow` cannot fix this on its own because its first-responder grab deliberately yields to an existing `SurfaceNSView` first responder (so an incidentally-remounted view doesn't yank focus from the user); an authoritative `setFocus(true)` call is the signal that distinguishes the two cases.

### TERM-8.x — Context Menu

**TERM-8.1** When the user right-clicks a terminal pane, the application shall display a context menu. When the user Control-clicks with the left mouse button on a terminal pane, the application shall display the same context menu, unless the terminal has enabled mouse capturing in which case the click shall be delivered to the terminal as a right-mouse-press instead.

**TERM-8.2** The context menu shall contain the following items, in this order, separated by dividers as shown:

**TERM-8.3** When the user selects "Copy", the application shall copy the current terminal selection to the system clipboard.

**TERM-8.4** When the user selects "Paste", the application shall insert the system clipboard's text contents into the terminal.

**TERM-8.5** When the user selects "Split Right", "Split Left", "Split Down", or "Split Up", the application shall create a new terminal pane adjacent to the focused pane in the corresponding direction.

**TERM-8.6** When the user selects "Reset Terminal", the application shall reset the terminal's screen and state to a pristine post-init condition.

**TERM-8.7** When the user selects "Toggle Terminal Inspector", the application shall toggle the display of libghostty's built-in debug inspector overlay on the terminal.

**TERM-8.8** While a terminal pane is in read-only mode, the "Terminal Read-only" menu item shall display a checkmark.

**TERM-8.9** When the user selects "Terminal Read-only", the application shall toggle the terminal's read-only state — in read-only mode the terminal renders updates but drops keyboard input from the user.

**TERM-8.10** When the user opens the right-click context menu on a pane via `TERM-8.1`, the application shall include the Move-to-worktree items defined by `PWD-1.1`, `PWD-1.2`, and `PWD-1.3` in the position specified by `TERM-8.2`. The semantics — cwd-matching, disabled-when-no-match, same-repo-only submenu, sanitized display labels per `GIT-2.10` — are inherited from those requirements; this requirement only fixes the menu position and the surface (Ghostty terminal pane) where the items appear, mirroring what's already required on the sidebar pane row.

### TERM-9.x

**TERM-9.1** When the user activates "Reload Ghostty Config"

**TERM-9.2** When the user activates "Open Ghostty Settings"

### TERM-10.x

**TERM-10.1** When the user drops one or more file URLs onto a terminal pane, the application shall insert each file's POSIX path at the cursor position. Paths that contain shell-special characters shall be POSIX-single-quoted (internal `'` rendered as `'\''`) so the inserted text can be passed unchanged to bash/zsh; paths made entirely of shell-safe characters shall be inserted verbatim. Multiple paths shall be joined with a single space, matching how Ghostty.app, Terminal.app, and iTerm2 render multi-file drops.

### TERM-11.x

**TERM-11.1** When pane layout settles and no remote client is attached to the zmx session, the application shall resize the zmx PTY to the current libghostty grid size without waiting for user input.

**TERM-11.2** While no remote client is attached and layout has settled, a libghostty viewport callback shall resize the zmx PTY immediately, before any user input.

**TERM-11.3** When the silent gate disengages on first user input, the application shall resize the PTY to the current libghostty grid size and force a surface refresh.

**TERM-11.4** When the last remote client detaches from a session whose pane has not yet been engaged, the application shall resize the PTY to the current libghostty grid size.

**TERM-11.5** The application shall track the number of remote clients attached to each zmx session; a session is remote-attached while its count is positive, and an observer fires when the count returns to zero.

**TERM-11.6** When user input engages the silent gate before layout has settled, the application shall defer the engagement PTY sync until layout settles rather than resize the PTY to the pre-layout grid.

**TERM-11.7** While layout has not settled, the application shall not forward viewport callbacks to the zmx PTY regardless of engagement state.

**TERM-11.8** If libghostty emits PTY-bound bytes outside a user-input scope (terminal query auto-responses, automation), then the application shall not treat them as engaging user input; bytes emitted inside the scope shall engage.

**TERM-11.9** While a rapid sequence of libghostty viewport callbacks arrives, the application shall forward the first resize to the zmx PTY immediately and coalesce the remainder, delivering at most one trailing resize with the latest dimensions per quiet window, so a divider drag emits a bounded SIGWINCH stream that always ends at the final size.

**TERM-11.10** When a zmx-backed pane's surface is created or recreated, the application shall defer spawning the `zmx attach` client until the owning view's first layout settles, so the attach replay is parsed into a grid already at its settled size rather than the pre-layout placeholder.

**TERM-11.11** A show-time reconcile shall forward the live libghostty grid to the zmx PTY unconditionally, not short-circuiting on an in-sync comparison against the optimistic last-forwarded record — a same-size forward is a kernel no-op (no SIGWINCH) so it never churns the TUI, while a Mac/daemon size divergence is always corrected on the next show instead of being hidden by a false in-sync check. The failure case that makes the optimistic record unsafe to trust is exercised by `TERM-11.15`.

**TERM-11.12** While the zmx session has not yet started, the application shall queue PTY writes and deliver them in order once the session starts (after any queued resize) — a `pane add --command` issued before the pane's first layout shall not be dropped.

**TERM-11.13** When a pane re-enters the visible set, the application shall forward the live libghostty grid to the zmx PTY unconditionally — so a row count latched while the surface was occluded (which libghostty never re-reported because the grid had no delta to emit) is corrected on every show rather than hidden by an optimistic last-forwarded record. A same-size forward is a kernel no-op (no SIGWINCH), so plain focus switches do not churn the TUI; a drifted grid produces exactly one real resize.

**TERM-11.14** When a kept-alive pane is switched back to and the live grid differs from the PTY, the application shall forward exactly that live grid once (a single real resize / SIGWINCH) and never a synthetic rows-1/rows bounce.

**TERM-11.15** When a forward to the PTY fails (a swallowed resize error), the application shall not record it as the last-forwarded size; a subsequent show reconcile shall re-forward the live grid and correct the divergence rather than treat the failed size as in sync.

**TERM-11.16** When AppKit resizes a zmx-backed terminal view, the application shall update libghostty's surface size before marking the pane visible and reconciling zmx to the live grid, so the show-time reconcile cannot forward the previous row count during a real resize.

## GIT — Worktree Discovery & Monitoring

### GIT-1.x — Initial Discovery

**GIT-1.1** When a repository is added, the application shall run `git worktree list --porcelain` and populate the sidebar with all discovered worktrees in the closed state.

**GIT-1.2** When the user picks a folder in the Add Repository flow and `git worktree list --porcelain` fails on that folder (not a git repository, missing `git` binary, permission denied), the application shall present an `NSAlert` showing the folder path and the underlying error message, rather than silently returning from the Task. Without this, the user clicks a menu, picks a folder, and sees nothing happen — no log, no error, no repo added.

**GIT-1.3** When the pre-`discover` step `GitRepoDetector.detect(path:)` throws while resolving the user-picked folder (e.g. the `.git` file exists but is unreadable due to permissions or a truncated write), the application shall present an `NSAlert` mirroring `GIT-1.2` rather than swallowing the throw via `try?`. Pre-fix the sync-detect path was the one remaining silent-return in the Add Repository flow — the async discover path (`GIT-1.2`) and the Delete Worktree path (`GIT-4.11`) already alert on throws, so the sync-detect throw stood out as the odd silent failure.

**GIT-1.4** When `GitRepoDetector.detect(path:)` reads a linked worktree's `.git` file and finds a `gitdir: <path>` entry, it shall resolve a relative `<path>` against the worktree directory (the directory containing the `.git` file) rather than feeding it verbatim to `realpath(3)`. Git ≥ 2.52 with `worktree.useRelativePaths=true` writes entries like `gitdir: ../repo/.git/worktrees/name`; passing that to `realpath` resolves against the process cwd — usually unrelated to the worktree dir — so the returned `repoPath` was wrong and the "Add Repository" flow attached a dragged worktree to the wrong repo (or none at all). The absolute-gitdir case (older git and the default config) is unaffected. Mirrors `GIT-3.14`'s same-class fix in `WorktreeMonitor.resolveHeadLogPath`.

**GIT-1.5** When the user selects via Add Repository a folder containing no .git entry up to the filesystem root, the application shall present a three-button choice — Initialize Git Repository, Add Without Git, Cancel — instead of the prior \

**GIT-1.6** When the user chooses Initialize Git Repository at add-time, the application shall run `git init` followed by `git commit --allow-empty -m \

**GIT-1.7** When the user chooses Add Without Git, the application shall register a repository entry whose isGitTracked is false and whose worktree list contains exactly one entry with path equal to the folder path and branch equal to \

### GIT-2.x — Filesystem Monitoring

**GIT-2.1** While a repository is in the sidebar, the application shall watch the repository's `.git/worktrees/` directory for changes using FSEvents.

**GIT-2.2** When a change is detected in `.git/worktrees/`, the application shall re-run `git worktree list --porcelain` and reconcile the results against the current model.

**GIT-2.3** While a repository is in the sidebar, the application shall watch each worktree's directory path for deletion using FSEvents.

**GIT-2.4** While a repository is in the sidebar, the application shall detect every operation that moves a worktree's HEAD — including commits on the current branch, `checkout`, `switch`, `reset`, `merge`, and `rebase` — and surface each as a HEAD-reference change.

**GIT-2.5** While a repository is in the sidebar, the application shall watch `<repoPath>/.git/logs/refs/remotes/origin/` using FSEvents so that any operation which advances a remote-tracking ref — `git push` (the common `gh pr create` path), `git fetch`, and prune — surfaces as an origin-ref change. One watch per repository covers all linked worktrees, since they share the main checkout's git directory.

**GIT-2.6** While a worktree is in the sidebar and non-stale, the application shall recursively watch the worktree's directory with `FSEventStreamCreate` (coalescing latency 0.5s) so that working-tree edits, stages / unstages via `.git/index`, and untracked-file creation surface as content-change events. Events for the worktree root, the bare `.git` directory, and the `.git/objects/` subtree shall be filtered out: the root and `.git` are coarse parent-mtime bumps that fire alongside more specific descendant events and carry no additional signal, and `.git/objects/` is pure pack-churn noise from `git gc` / pack writes. The watched path shall be resolved via `realpath(3)` before use because FSEvents always reports canonical paths (e.g. `/private/var/...` rather than `/var/...`) and an unresolved root makes the filter's `hasPrefix` comparison miss every event. The other watchers in GIT-2.1–GIT-2.5 use kqueue vnode sources (`DispatchSourceFileSystemObject`), which cannot watch a subtree recursively; the real FSEvents API is used here because the working tree is inherently recursive.

**GIT-2.8** While a repository is in the sidebar, the application shall scan local `refs/remotes/origin/*` every 10 seconds without contacting the network, maintaining a repo-scoped set of locally-known remote branch names. The scan shall use local git ref metadata only; it shall not replace the repo-level fetch cadence that discovers branches created from another clone.

**GIT-2.9** When the origin-ref watcher from `GIT-2.5` observes a remote-tracking ref movement, the application shall refresh the repo's local remote-branch set before deciding which worktrees should receive PR/MR polling.

**GIT-2.10** When the application renders a worktree's branch name in the UI (the breadcrumb bar per `LAYOUT-1.3` and the secondary dimmed caption in the sidebar row), it shall read this property rather than `WorktreeEntry.branch`. `displayBranch` strips every Unicode bidirectional-override scalar (same ranges as `PR-5.5`) so a collaborator-controlled branch name like `"feat\u{202E}lanigiro"` — which git accepts and which propagates into `state.json` via `git worktree list --porcelain` — can't render RTL-reversed in the breadcrumb or row. `branch` itself is preserved unchanged so downstream `git` subprocess calls, `gh pr list --head <branch>`, and the `PRStatusStore.isFetchableBranch` gate keep operating on the real ref. This is the same strip-not-reject policy `PR-5.5` uses for externally-sourced text.

### GIT-3.x — Change Handling

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

**GIT-3.16** When a stale worktree is resurrected via user click (`selectWorktree` per `GIT-3.8`) rather than via the reconciler, the application shall re-arm the path / HEAD-reflog watchers for the worktree on the new inode. A user-click resurrection does not fire a `.git/worktrees/` FSEvents tick (no git subprocess ran), so the reconciler's re-register loop in `worktreeMonitorDidDetectChange` never runs — without this, the resurrected worktree has no real-time PR refresh until the polling safety nets catch up or the user triggers a git operation that bumps the `.git/worktrees/` dir.

**GIT-3.17** When a worktree's current branch lacks a local `origin/<branch>` ref, the application shall skip GitHub/GitLab PR/MR host polling for that worktree and shall not mark the worktree as "absent PR" merely because the branch has not been pushed.

**GIT-3.18** When a local `origin/<branch>` ref appears for a non-stale worktree's current branch, the application shall begin PR/MR polling for that worktree on the pushed-branch cadence without requiring the user to select the worktree.

**GIT-3.19** When a local `origin/<branch>` ref disappears for a non-stale worktree's current branch, the application shall clear cached PR/MR status for that worktree so stale PR badges do not remain attached to an unpushed or deleted remote branch.

### GIT-4.x — Deleting a Worktree

**GIT-4.1** While a worktree entry is not in the stale state and is not the repository's main checkout, the context menu shall include a "Delete Worktree" action.

**GIT-4.2** When the user triggers "Delete Worktree", the application shall display a confirmation dialog whose informative text explicitly states "This will delete the worktree but not the branch."

**GIT-4.3** When the user confirms "Delete Worktree", the application shall run `git worktree remove <path>` in the repository, leaving the worktree's branch ref untouched.

**GIT-4.4** If `git worktree remove` fails (e.g., the worktree contains uncommitted changes), then the application shall present an error alert whose informative text leads with git's stderr and, when non-empty, appends the `git status --short` output below a blank-line separator, and whose buttons are "Cancel" (default) and "Force Delete"; the worktree entry and any running terminal surfaces shall remain intact unless the user confirms Force Delete (GIT-4.12).

**GIT-4.5** When `git worktree remove` succeeds on a worktree in the running state, the application shall tear down all terminal surfaces in the worktree's split tree.

**GIT-4.6** When `git worktree remove` succeeds, the application shall remove the worktree entry from the sidebar, and if that worktree was the selected worktree the application shall clear the selected-worktree state so the terminal content area shows the "no worktree selected" placeholder.

**GIT-4.7** When the application first observes a worktree's associated pull request transition into a terminal resolved state — either merged or closed-without-merging, whether from open, from no-PR-cached, or from a different previously-resolved PR number — the application shall present an informational dialog offering to delete the worktree. The dialog's message text shall cite the PR number and the resolution word ("merged" or "closed"). Its informative text shall begin with the PR/MR title on its own line (when non-empty), followed by "Delete the worktree now? This will delete the worktree but not the branch." Its buttons shall be "Delete Worktree" and "Keep".

**GIT-4.8** If the user confirms the offer dialog from GIT-4.7 by clicking "Delete Worktree", the application shall proceed directly to `git worktree remove` without re-prompting — the offer dialog IS the confirmation. The resulting success and failure paths shall be identical to GIT-4.5 and GIT-4.4 (teardown on success, stderr surfaced on failure).

**GIT-4.9** The application shall offer the dialog described in GIT-4.7 at most once per (worktree, PR-number) pair, by persisting the offered PR number on the worktree entry. On a subsequent poll that still reports the same resolved PR (merged or closed), on an app restart that re-resolves the same already-resolved PR, or if the user dismisses the dialog with "Keep", the application shall not re-offer until the worktree's PR number changes. The application shall not present this dialog for the repository's main checkout (GIT-4.1 forbids deleting it) nor for worktrees in the stale state.

**GIT-4.10** When `git worktree remove` succeeds (via either the menu-initiated Delete Worktree path per GIT-4.3 or the PR-merged offer path per GIT-4.8), the application shall drop the worktree's cached entries from every per-path observable store (PR status, divergence stats) before removing the entry from the model. Matches the contract GIT-3.6's Dismiss path already enforces — without it, orphan cache entries survive indefinitely and bleed into a future same-path re-add on its first reconcile tick.

**GIT-4.11** When `performDeleteWorktree` fails with a non-`gitFailed` error (git binary missing, subprocess launch failure, timeout), the application shall surface the error in an `NSAlert` analogous to `GIT-4.4`, not silently return. Without this, the user clicks Delete Worktree and nothing happens — matches the shape of the cycle 101 `addRepoFromPath` (GIT-1.2) silent-failure fix, on the symmetric delete path.

**GIT-4.12** If the user clicks "Force Delete" on the GIT-4.4 failure alert, the application shall re-run `git worktree remove --force <path>` and, on success, proceed through the same teardown path as GIT-4.5 / GIT-4.6 / GIT-4.10. If the forced remove also fails, the application shall surface git's stderr in a single-button error alert without offering Force Delete a second time, so the user is not trapped in a retry loop.

**GIT-4.13** When the user confirms Delete Worktree on a worktree whose directory no longer exists on disk, the application shall run `git worktree prune --expire=now`, drop the worktree entry from the sidebar without prompting the user with a Force Delete alert, and tear down any running terminal surfaces for the entry.

**GIT-4.14** While the GIT-4.7 offer-delete dialog is on screen, the application shall not block the main run loop's default mode. The dialog is presented as a window-attached sheet via `NSAlert.beginSheetModal(for:)` rather than the nested-event-loop `NSAlert.runModal()`, so libghostty's PTY read callbacks — which land on the main thread in the default run-loop mode — keep flowing while the offer awaits a click. Without this, every terminal pane in every visible worktree freezes for as long as the auto-triggered offer stays unanswered.

**GIT-4.15** When `DeleteWorktreeFlow.delete` runs and the early `notFound` / `mainCheckoutRejected` / non-git-repo gates pass, the application shall transition the worktree entry to `.deleting` state synchronously before awaiting `git worktree remove`, so the sidebar row renders a spinner while git runs. On flow failure (forceable or final), the application shall restore the entry's prior state before surfacing the error alert; on success the entry is removed entirely. Mirrors `GIT-5.4` on the symmetric delete path so a long-running `git worktree remove` (which can take seconds when the worktree contains many untracked files or holds a slow lock) produces visible feedback rather than a frozen row.

**GIT-4.16** While a worktree entry is in the `.deleting` state, the sidebar row shall render a `ProgressView` in place of its type icon (`house` / `arrow.triangle.branch` / `arrow.triangle.pull`), shall present an empty right-click context menu (Stop, Delete Worktree, Open in Finder would all either error or race the in-flight remove), shall reject same-repo pane drops (the target worktree is about to disappear), and shall ignore selection clicks — the user keeps their previous worktree focused until the entry is removed or restored. Mirrors `GIT-5.5` for the symmetric delete-in-flight indicator.

**GIT-4.17** When persisting `WorktreeEntry` to `state.json`, the application shall encode `.deleting` as `.closed`. The `.deleting` state is in-memory-only; if the app crashes mid-deletion, the next launch's reconciler classifies the entry from `git worktree list --porcelain` rather than restoring a phantom spinner that would never resolve. Mirrors `GIT-5.9` for `.creating`.

**GIT-4.18** While a worktree entry is in the `.deleting` state, the reconciler (`WorktreeReconciler.reconcile`) shall not transition the entry to `.stale` even when the path is absent from `git worktree list --porcelain` output. The placeholder is in flight by definition — `git worktree remove` is mid-call and the admin entry may disappear from porcelain before `DeleteWorktreeFlow` removes the model entry — and only `DeleteWorktreeFlow` is permitted to clear the placeholder (success → remove from model, failure → restore prior state). Mirrors `GIT-5.8` for `.creating`.

**GIT-4.19** When the user invokes a delete-flow confirmation dialog (GIT-4.2 Delete Worktree, GIT-4.4 force-delete recovery, GIT-4.11 final failure, or the GIT-3.6 Remove Repository menu item), the application shall present it as a window-attached sheet via `NSAlert.beginSheetModal(for:)` rather than `NSAlert.runModal()`. Extends GIT-4.14's policy from the auto-triggered offer dialog to every user-initiated delete dialog — otherwise the nested-event-loop `runModal()` freezes libghostty's PTY callbacks for every embedded terminal pane while the dialog awaits a click.

### GIT-5.x — Creating a Worktree

**GIT-5.1** When the user types or pastes into the "Worktree name" or "Branch" field of the Add Worktree sheet, the application shall replace any character outside the set `A-Z a-z 0-9 . _ - /` with `-`, and shall collapse any run of consecutive `-` (including dashes the user typed directly) into a single `-`. `/` is permitted so branch names can use the conventional namespace separator (`feature/foo`); the resulting worktree path becomes a nested `.worktrees/<ns>/<leaf>` directory that `git worktree add` creates. Ref-format rules git already enforces (`//`, leading/trailing `/`, components beginning with `.`) are not duplicated here — git reports them at submit time. The replacement shall apply live on every edit so the field shows only sanitized content.

**GIT-5.2** While the branch field is still mirroring the worktree name (i.e. the user has not manually diverged the branch field), the sanitized worktree name shall be propagated into the branch field on each edit so both fields stay in sync.

**GIT-5.3** When the user submits the Add Worktree sheet, the application shall additionally strip leading and trailing `-`, `.`, and whitespace from both values before invoking `git worktree add`. Live editing intentionally preserves those characters (trimming them as-you-type would swallow the separator between words); the final submit trim ensures no request ever asks git to create `-foo` or `foo.` as a branch.

**GIT-5.4** When the user submits the Add Worktree sheet and validation passes (the target repository is still tracked and no entry already exists at `<repoPath>/.worktrees/<name>`), the application shall (a) insert a placeholder `WorktreeEntry` for the target path in the `.creating` state, (b) dismiss the sheet immediately, and (c) run `git worktree add` in a detached `Task` so a slow git invocation — typically blocked on `pre-commit` / `post-checkout` hooks that can take seconds — does not hold the sheet open. Without this, the sheet's `ProgressView` would block all sidebar interaction for the duration of the hook chain.

**GIT-5.5** While a worktree entry is in the `.creating` state, the sidebar row shall render a `ProgressView` in place of its type icon (`house` / `arrow.triangle.branch` / `arrow.triangle.pull`), shall suppress the divergence-stats gutter (no on-disk repo to diff against), shall hide pane title rows beneath it (no surfaces exist yet), and shall present an empty right-click context menu (Stop, Delete Worktree, Open in Finder would all either error or race the in-flight create). A click on the row shall be a no-op for selection purposes — the user keeps their previous worktree focused — until the placeholder transitions out of `.creating`.

**GIT-5.6** When `git worktree add` started by `GIT-5.4` succeeds, the application shall (a) adopt git's resolved branch label onto the placeholder, (b) arm the path / HEAD-reflog / content watchers and seed divergence stats for the new path, (c) spawn the first terminal surface, (d) transition the entry from `.creating` to `.running`, and (e) flip `selectedWorktreePath` to the new worktree so the user ends up focused on it (matching the pre-optimistic flow's "submit → ends up on new worktree" outcome).

**GIT-5.7** When `git worktree add` started by `GIT-5.4` fails, the application shall (a) remove the `.creating` placeholder from the sidebar and (b) present an `NSAlert` titled "Could not create worktree" whose informative text shows git's stderr (or "git worktree add failed" when stderr is empty). Inline error display in the sheet is no longer reachable since `GIT-5.4` already dismissed the sheet on submit. Mirrors `GIT-1.2` / `GIT-4.4` / `GIT-4.11`'s alert-not-silent-return policy on the symmetric create path.

**GIT-5.8** While a worktree entry is in the `.creating` state, the reconciler (`WorktreeReconciler.reconcile`) shall not transition the entry to `.stale` even when the path is absent from `git worktree list --porcelain` output. The placeholder is in flight by definition — git hasn't finished writing its admin entry yet — and only `AddWorktreeFlow` is permitted to clear the placeholder (success → `.running`, failure → remove). Without this guard, an FSEvents tick on `.git/worktrees/` that fires before git's admin write completes (or one driven by an unrelated change in another worktree) would briefly flash the spinning placeholder to `.stale`.

**GIT-5.9** When persisting `WorktreeEntry` to `state.json`, the application shall encode `.creating` as `.closed`. The `.creating` state is in-memory-only; if the app crashes mid-creation, the next launch's reconciler classifies the entry from `git worktree list --porcelain` rather than restoring a phantom spinner that would never resolve.

**GIT-5.10** When BranchSelection.useExisting is submitted with a local source, the application shall invoke `git worktree add <path> <name>` (no `-b` flag).

**GIT-5.11** When BranchSelection.useExisting is submitted and the same repo already has the branch mounted in another worktree, the application shall reject the create with branchAlreadyMounted(at:) before invoking git.

**GIT-5.12** When BranchSelection.useExisting is submitted with a remoteOnly source, the application shall invoke `git worktree add --track -b <name> <path> origin/<name>` so a local branch is created and checked out (not detached HEAD).

**GIT-5.13** While the user is in existing-branch mode, the application shall display branches sorted by last-commit date descending in an always-visible list, with branches mounted in another worktree dimmed and unselectable.

**GIT-5.14** When a branch row in the existing-branch picker has an associated open PR/MR, the application shall surface the PR number and title alongside the branch name.

**GIT-5.15** When the user selects a branch from the existing-branch picker, the application shall auto-fill the worktree name with the branch name unless the user has already edited the field.

**GIT-5.16** While the user is in existing-branch mode, the application shall render a filter `TextField` above the branch list whose contents narrow the list to branches whose name contains the typed substring (case-insensitive).

**GIT-5.17** When the filter text changes and the currently selected branch no longer matches the filter (or no branch is selected), the application shall auto-select the first non-mounted branch in the filtered list. When the filter is cleared, the prior selection shall be preserved if it still exists.

**GIT-5.18** While the user is in existing-branch mode, the Create button shall remain disabled until a branch row is selected; the filter `TextField`'s contents shall not be treated as a freeform branch name.

**GIT-5.19** When the user toggles the branch-mode picker between "New branch" and "Existing branch", the application shall preserve each mode's prior input independently — the new-branch name shall not be clobbered by an existing-branch selection, and an existing-branch selection shall not be cleared by a temporary switch to new-branch mode.

**GIT-5.20** While the user is in existing-branch mode, the BranchPicker's branch list shall reserve a fixed vertical height regardless of the parent view's proposed height, so the list never collapses to zero when nested inside a `Grid` cell whose row height is driven by sibling cells' intrinsic content.

## ATTN — Attention Notification System

### ATTN-1.x — CLI Tool

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

**ATTN-1.15** When `pane show <addr>` is invoked against a running pane, the application shall return the last `--lines` lines (default 100) of that pane's `zmx` scrollback as plain text on the CLI's stdout.

**ATTN-1.16** When `pane send <addr> <text>` is invoked, the application shall inject `text` into the addressed pane's PTY via `ghostty_surface_text`, and unless `--no-enter` is set, shall additionally synthesize a Return key event via `ghostty_surface_key` (matching `SurfaceHandle.pressReturn`) so TUI consumers in raw mode (Codex, Claude) treat the input as committed.

**ATTN-1.17** When any `pane` subcommand (`list`/`add`/`close`/`show`/`send`) is invoked with a `<wt>` or `<wt>:<id>` address, the application shall resolve the worktree by branch name (using the same lookup `graftty team msg` uses, against the `team list` registry) and operate on that worktree regardless of the caller's current working directory; an unknown name shall produce a stderr error and a non-zero exit.

**ATTN-1.18** When `pane show` or `pane send` is invoked against a worktree that is not in the `running` state, the application shall fail with a `worktree not running` error rather than auto-launch the worktree's panes.

**ATTN-1.19** When `pane show` or `pane send` is invoked against a worktree that has more than one pane and the address omits the `<id>` part, the application shall print the equivalent of `pane list <wt>` to stderr, append a 'specify a pane' hint, and exit non-zero. With exactly one pane, the bare-worktree form shall target that pane.

**ATTN-1.20** When `pane show` is invoked against a pane whose `--lines` argument is non-positive or exceeds the pane's available scrollback, the application shall clamp non-positive values to the pane's full scrollback and clamp excessive values to the available scrollback length.

**ATTN-1.21** When the CLI is invoked with an unknown subcommand at any level, the application shall append a `Did you mean '<closest>'?` suggestion to the error message whenever a registered subcommand name is within Levenshtein distance 2 of the input.

**ATTN-1.22** When `pane show` or `pane send` errors out due to ambiguity, unknown worktree, or missing-current-worktree, the error text shall include the literal next-step invocation the caller should run.

**ATTN-1.23** When the team session-start hook renders the team protocol primer, the application shall include a brief block describing the `pane list` / `pane show` / `pane send` commands and the `<worktree>:<id>` address grammar, with a pointer to `graftty pane <verb> --help` for full examples.

### ATTN-2.x — Communication Protocol

**ATTN-2.1** The application shall listen on a Unix domain socket at `~/Library/Application Support/Graftty/graftty.sock`.

**ATTN-2.2** The CLI shall communicate with the application by sending JSON messages over the Unix domain socket.

**ATTN-2.4** The application shall set the environment variable `GRAFTTY_SOCK` in each terminal surface's environment, pointing to the socket path.

**ATTN-2.5** The CLI shall read the `GRAFTTY_SOCK` environment variable to locate the socket. If the variable is unset or set to an empty string, the CLI shall fall back to the default path `<Application Support>/Graftty/graftty.sock`. Treating empty as unset prevents a blank `GRAFTTY_SOCK=` line (e.g. from a sourced `.env` file) from redirecting the CLI to a nonexistent socket at the empty path.

**ATTN-2.6** When the application receives a `notify` message over the socket whose text is empty or contains only whitespace characters, the application shall silently drop the message rather than render an invisible attention overlay. This backs up the CLI's ATTN-1.7 validation for non-CLI socket clients.

**ATTN-2.7** When `SocketServer.start()` fails during application startup, the application shall (a) log the error via `NSLog` (surfacing it in Console.app), (b) retain the error in `SocketServer.lastStartError` for in-process introspection, and (c) present a one-time `NotifySocketBanner` alert describing what broke and suggesting recovery steps (quit+relaunch, clear `GRAFTTY_SOCK`). The banner mirrors the `ZmxFallbackBanner` pattern from `ZMX-5.2`. The app shell historically wrapped `start()` in `try?`, producing a running Graftty with a dead control socket and no diagnostic trail — ATTN-3.4 recovers this case at the CLI side, ATTN-2.7 surfaces the root cause at the app side upfront rather than waiting for the user to trip over the CLI.

**ATTN-2.8** The application's Unix-domain socket server shall call `listen(2)` with a backlog of 64, not the historical default of 5. A user scripting parallel `graftty notify` invocations (e.g. from a hook that fans out across a monorepo) can easily exceed 5 pending connections, and the extra backlog entries cost negligible kernel resources while preventing spurious `ECONNREFUSED` for the later clients.

**ATTN-2.9** Each accepted client connection shall have `SO_RCVTIMEO` set to 2 seconds before the server enters its read loop. Without this, a silent peer (a `nc -U` that connects but never writes, a crashed CLI client whose kernel-level connection lingers, etc.) pins the server's serial dispatch queue on a blocking `read(2)` indefinitely — and since `acceptConnection` shares that queue, every subsequent `graftty notify` hangs for the duration. 2 seconds mirrors the CLI's client-side timeout (`ATTN-3.3`); JSON notify/pane messages are ≤~1 KB over a local socket, so any well-behaved client finishes in milliseconds.

**ATTN-2.10** When a request-style socket message (`list_panes`, `add_pane`, `close_pane`) hands its handler to the main queue via `DispatchQueue.main.async`, the server shall wait at most `SocketServer.onRequestTimeout` (5 seconds in production) for the handler to return. If the handler has not completed within that window — main queue stalled by a modal dialog, heavy synchronous work, or a main-actor reentrancy bug — the server shall close the client fd without writing a response rather than pin its serial worker on `semaphore.wait()` indefinitely. The CLI's 2s client-side timeout (`ATTN-3.3`) then surfaces the event as a clean `socketTimeout`. The main-queue closure may still complete and write into the retained response box after the worker has returned; its `signal()` lands on a no-longer-awaited semaphore harmlessly.

**ATTN-2.11** Each accepted client connection's read loop shall cap total accumulated bytes at `SocketServer.maxPerClientBytes` (1 MB in production) before giving up and closing the fd. Without this, a local writer that keeps the pipe continuously full (`cat /dev/urandom | nc -U graftty.sock`) never trips `SO_RCVTIMEO` (which fires only when data STOPS flowing) — the historical unbounded read loop would grow the per-connection buffer until process memory was exhausted. 1 MB is 1000× the ≤~1 KB typical JSON notify/pane message size, so well-behaved clients never hit it. Tests can shrink the cap to bound per-test runtime.

### ATTN-3.x — Error Handling

**ATTN-3.1** If the application is not running, then the CLI shall print "Graftty is not running" and exit with code 1.

**ATTN-3.2** If the current working directory is not inside a tracked worktree, then the CLI shall print "Not inside a tracked worktree" and exit with code 1.

**ATTN-3.3** If the socket is unresponsive, then the CLI shall time out after 2 seconds, print an error, and exit with code 1.

**ATTN-3.4** If the control socket file exists on disk but `connect()` fails with `ECONNREFUSED`, then the CLI shall print "Graftty is running but not listening on `<path>`. Quit and relaunch Graftty to reset the control socket." and exit with code 1, rather than conflating this stale-listener case with `ATTN-3.1`'s "not running" message. The conditions differ: `ENOENT` (file missing) means the app never created the socket, whereas `ECONNREFUSED` on an existing file means a prior Graftty instance crashed without unlinking, or its `SocketServer.start()` failed after the file was created but before listening began.

**ATTN-3.5** When a `pane list`, `pane add`, or `pane close` request targets a tracked worktree that is not in the `.running` state (i.e., no terminals currently alive in it), the server shall respond with `.error("worktree not running")`. `list` in particular shall NOT return an empty `.paneList` — that reads as a silent success to callers scripting `pane list | wc -l` or similar, when in fact the worktree needs to be clicked to start its terminals.

**ATTN-3.6** The CLI's response-read path shall cap total accumulated bytes at 1 MB via `SocketIO.readAll(fd:cap:)`. Mirrors the server-side `ATTN-2.11`: `SO_RCVTIMEO` only fires on idle pipes, so a misbehaving or compromised server that keeps the pipe continuously full would otherwise grow the CLI's per-response buffer without bound. 1 MB is 1000× the typical ≤1 KB response size; a legit server never hits it.

### ATTN-4.x — CLI Distribution

**ATTN-4.1** The application shall provide a menu item (Graftty -> Install CLI Tool...) to create or update a symlink at `/usr/local/bin/graftty` pointing to the CLI binary in the app bundle. CLI installation is opt-in via this menu item; the application shall not auto-prompt for installation on launch.

**ATTN-4.2** When the application creates a terminal pane surface, the application shall override the spawned shell's `PATH` to a sanitized form that removes any entry equal to the bundle's `Contents/MacOS` directory and prepends the bundle's `Contents/Helpers` directory. Without this, the embedded libghostty's bundle-self-locating logic puts `Graftty.app/Contents/MacOS` on PATH, and on macOS's case-insensitive APFS volume `which graftty` resolves the lowercase lookup to the GUI binary `Graftty` (which silently exits `0` on unknown args, so `graftty --help` prints nothing). The override is exact-path equality — unrelated `Contents/MacOS` directories from other apps in the user's PATH are left alone.

## PERSIST — Persistence

### PERSIST-1.x — Storage

**PERSIST-1.1** The application shall store all persistent state in `~/Library/Application Support/Graftty/`.

**PERSIST-1.2** The application shall persist state to a `state.json` file containing: the ordered list of repositories and their worktrees, per-worktree split tree topology and `state` enum (`.closed`, `.running`, `.stale`), selected worktree, window frame, and sidebar width.

### PERSIST-2.x — Save Triggers

**PERSIST-2.1** The application shall save state when any of the following occur: split tree changes, worktree state changes, repository added or removed, selection changes, window resize or move (debounced), app moving to background, or app quit.

**PERSIST-2.2** When a state save fails (full disk, read-only `$HOME`, permissions clash, or any other `FileManager` / `Data.write` throw), the application shall log the error via `NSLog` so it surfaces in Console.app, rather than silently discarding every subsequent persisted mutation. Analogue of `ATTN-2.7` for the `AppState.save(to:)` path. `AppState.save(to:)` shall continue to throw so the caller can surface or recover; the spec pins only that the app-level caller stops using `try?` to mask it.

### PERSIST-3.x — Restore on Launch

**PERSIST-3.1** When the application launches with an existing `state.json`, it shall restore the sidebar with all saved repositories and worktrees.

**PERSIST-3.2** When the application launches, it shall restore the saved split tree topology for each worktree.

**PERSIST-3.3** When the application launches, it shall automatically start fresh terminal surfaces for each worktree whose persisted `state` was `.running`.

**PERSIST-3.4** When the application launches, it shall restore the window frame position, size, and sidebar width.

**PERSIST-3.5** When the application launches, it shall re-select the previously selected worktree.

**PERSIST-3.6** When the application launches, it shall run worktree discovery for each repository to reconcile saved state against current disk state.

**PERSIST-3.7** If `state.json` exists but fails to decode at launch (corruption from a crashed mid-write, hand-edit typo, or schema mismatch across app versions), then the application shall move the file aside to a timestamped backup at `state.json.corrupt.<milliseconds-since-epoch>` and proceed with a fresh `AppState`. The corrupt file shall remain on disk so the user can recover the prior data manually; the application shall not silently overwrite it on the next save.

### PERSIST-4.x — Non-Persisted State

**PERSIST-4.1** The application shall not persist shell scrollback, terminal screen buffer content, or the specific processes that were running.

## PWD — Manual Pane Routing

### PWD-1.x — User-Initiated Move

**PWD-1.1** When the user opens the right-click context menu on a pane in the sidebar, the application shall offer a "Move to <worktree-name>" entry that targets the worktree whose filesystem path is the longest prefix of the pane's inner-shell working directory across all repos. The shell's working directory is resolved by reading the inner-shell PID from the zmx session log at `<ZMX_DIR>/logs/<session>.log` (falling back to the rotated sibling `<ZMX_DIR>/logs/<session>.log.old` when the spawn line is no longer in the current file) and querying its current working directory via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.

**PWD-1.2** If no worktree path is a prefix of the inner-shell working directory, or the matching worktree is the pane's current host, then the application shall render the entry from `PWD-1.1` as a disabled "Move to current worktree" item so the user can see *why* the action is unavailable rather than have it disappear.

**PWD-1.3** When the user opens the right-click context menu on a pane, the application shall additionally offer a "Move to worktree" submenu listing every other worktree in the same repository as the pane's current host. Selecting an entry shall move the pane to that worktree regardless of the pane's current shell working directory. Cross-repository moves are out of scope — the submenu shall not list worktrees from other repos.

**PWD-1.4** While a pane row is rendered in the sidebar (a `running`-state worktree's leaf row per the `STATE` section semantics), the application shall make the row a drag source whose payload identifies the pane. While a worktree row in the same repository is rendered, the application shall make it a drop target that accepts such a payload and route the drop through the same reassignment path as `PWD-1.1` / `PWD-1.3` — i.e. via the manual-routing pipeline in `PWD-2.x`. Drops onto worktree rows in a different repository shall be refused (cross-repo moves are out of scope, matching `PWD-1.3`).

**PWD-1.5** While a drag from a pane row is in flight and the user hovers over a worktree row, the application shall render a visual highlight on that worktree row distinct from the active-worktree highlight defined by `LAYOUT-2.11` so the user can see the row is a possible drop target. The highlight is rendered for any hovered worktree row regardless of repo membership; the cross-repo refusal from `PWD-1.4` happens at drop time so the in-flight visual signal isn't required to peek into the payload's source repo.

### PWD-2.x — Reassignment

**PWD-2.1** When the destination worktree differs from the current worktree, the application shall remove the pane from the source worktree's split tree and insert it into the destination worktree's split tree.

**PWD-2.2** When a reassignment leaves the source worktree with no remaining panes, the application shall transition the source worktree to the closed state.

**PWD-2.3** When a reassignment completes, the application shall set the destination worktree as the selected worktree and focus the moved pane — but only when the reassigned pane was the focused pane of the currently-selected worktree at the moment of the move. For any reassignment of a non-focused pane (a background shell's `cd`, e.g. an autonomous claude-code session in a worktree the user isn't looking at), the sidebar shall reflect the move via `PWD-2.1` / `PWD-2.2` but the user's current selection shall not change. This guards against multiple concurrent agent sessions autonomously yanking the user's view around; without the gate a single background `cd` hijacks the UI mid-typing.

**PWD-2.4** When the destination worktree was previously in the closed state, the application shall transition it to the running state as part of the reassignment.

### PWD-3.x — Position Memory

**PWD-3.1** Before removing a pane from a source worktree, the application shall record its split-tree position — an anchor leaf, split direction, and before/after placement — keyed by `(terminalID, worktreePath)`.

**PWD-3.2** When reinserting a pane into a worktree for which a remembered position exists and whose anchor leaf is still present, the application shall restore the pane adjacent to that anchor with the recorded direction and placement.

**PWD-3.3** If no usable remembered position exists for the destination worktree, the application shall insert the pane at the first available leaf with a horizontal split as a fallback.

**PWD-3.4** Position memory shall be maintained in-process only and not persisted across app restarts.

## KEY — Keyboard, Clipboard, and Mouse Integration

### KEY-1.x — Keyboard Forwarding

**KEY-1.1** The application shall forward all keyboard input, including Command-modified keys, to libghostty so that libghostty's default keybindings (Cmd+C copy, Cmd+V paste, Cmd+A select-all, Cmd+K clear, etc.) take effect.

**KEY-1.2** When libghostty reports that a key was not handled, the application shall allow the event to continue up the responder chain.

**KEY-1.3** Application-level menu keyboard shortcuts (Cmd+D split, Cmd+W close pane, Cmd+O add repository, and pane navigation shortcuts) shall be matched by AppKit's menu `keyEquivalent` interception before the keyDown event reaches the terminal, so menu shortcuts override any conflicting libghostty keybinding.

### KEY-2.x — Clipboard

**KEY-2.1** When libghostty requests a clipboard write (e.g., from `Cmd+C` or the context menu Copy), the application shall write the provided content to `NSPasteboard.general`.

**KEY-2.2** When libghostty requests a clipboard read (e.g., from `Cmd+V` or the context menu Paste), the application shall read from `NSPasteboard.general` and return the text via `ghostty_surface_complete_clipboard_request`.

**KEY-2.3** Selection clipboard requests (X11-style primary selection) shall route to the same general pasteboard, as macOS does not provide a distinct selection clipboard.

**KEY-2.4** OSC 52 read-confirmation prompts shall be declined by default for security; terminal programs requesting OSC 52 reads shall fail silently rather than succeeding without user consent.

### KEY-3.x

**KEY-3.1** When the user presses `⌘T` while `appState.selectedWorktreePath`

**KEY-3.2** While presenting the Add Worktree sheet via `⌘T`, if the

## MOUSE — Keyboard, Clipboard, and Mouse Integration

### MOUSE-1.x — Mouse

**MOUSE-1.1** When libghostty requests a new mouse cursor shape via `MOUSE_SHAPE`, the application shall map the shape to the closest `NSCursor` and apply it to the targeted surface view.

**MOUSE-1.2** When libghostty requests cursor visibility change via `MOUSE_VISIBILITY`, the application shall hide or show the system cursor, using a reference-counted pair of `NSCursor.hide()` / `NSCursor.unhide()` so repeated HIDDEN events do not leak into permanent invisibility.

**MOUSE-1.3** When a terminal pane is destroyed while its cursor is hidden, the application shall unhide the cursor as part of teardown so the destroyed pane cannot leave the cursor invisible.

**MOUSE-1.4** When libghostty fires `OPEN_URL` in response to a user gesture on a detected URL (e.g., Cmd-click), the application shall open the URL using `NSWorkspace.shared.open`.

## BELL — Keyboard, Clipboard, and Mouse Integration

### BELL-1.x — Bell

**BELL-1.1** When libghostty fires `RING_BELL`, the application shall play the system beep sound.

## NOTIF — Desktop Notifications and Shell Integration Signals

### NOTIF-1.x — Desktop Notifications

**NOTIF-1.1** When libghostty fires `DESKTOP_NOTIFICATION` (OSC 9), the application shall post a banner notification via `UNUserNotificationCenter` using the title and body provided.

**NOTIF-1.2** If notification authorization has not yet been determined, the application shall request authorization on the first notification and post once authorization is granted.

**NOTIF-1.3** If the user has denied notification authorization, the application shall silently skip the notification rather than surfacing an error.

### NOTIF-2.x — Attention Badge Auto-Population

**NOTIF-2.1** When libghostty fires `COMMAND_FINISHED` with a zero exit code on a pane, the application shall set *that pane's* pane-scoped attention overlay to a checkmark indicator that auto-clears after 3 seconds. Sibling panes in the same worktree are unaffected.

**NOTIF-2.2** When libghostty fires `COMMAND_FINISHED` with a non-zero exit code on a pane, the application shall set *that pane's* pane-scoped attention overlay to an error indicator that auto-clears after 8 seconds. Sibling panes in the same worktree are unaffected.

**NOTIF-2.3** Auto-populated attention overlays from shell-integration events shall share the clearing semantics defined in STATE-2.x; a subsequent event on the same pane replaces that pane's previous overlay without affecting sibling panes' overlays.

## CONFIG — Shell Integration Configuration

### CONFIG-1.x — Config Loading

**CONFIG-1.1** At startup, the application shall call `ghostty_config_load_default_files` to load the XDG-standard ghostty config paths.

**CONFIG-1.2** In addition to the XDG paths, the application shall load the Ghostty macOS app's config file at `~/Library/Application Support/com.mitchellh.ghostty/config` if the file exists. Values loaded later shall override earlier values.

**CONFIG-1.3** After loading config files, the application shall call `ghostty_config_load_recursive_files` to resolve any `config-file = …` include directives.

### CONFIG-2.x — Shell Integration Script Discovery

**CONFIG-2.1** Before calling `ghostty_init`, the application shall set the `GHOSTTY_RESOURCES_DIR` environment variable so libghostty can locate its per-shell integration scripts.

**CONFIG-2.2** If `GHOSTTY_RESOURCES_DIR` is already set and non-empty in the process environment, the application shall not override it; the user's explicit setting wins.

**CONFIG-2.3** Otherwise, the application shall set `GHOSTTY_RESOURCES_DIR` to the `ghostty` directory vendored in GrafttyKit's resource bundle (per CONFIG-2.5), so shell integration does not depend on a separately installed Ghostty.app.

**CONFIG-2.4** If the vendored ghostty resources are missing from the application bundle, the application shall log a warning identifying the problem and continue with shell-integration features (OSC 7 auto-reporting, OSC 133 prompt marks, `COMMAND_FINISHED`, and `PROGRESS_REPORT`) unavailable; spawned shells shall still function.

**CONFIG-2.5** The application bundle shall include ghostty's per-shell integration scripts and the `xterm-ghostty` terminfo entry as vendored resources, pinned to the ghostty version backing libghostty-spm, with upstream license headers preserved and a provenance record, so shell integration works without a separately installed Ghostty.app.

**CONFIG-2.6** The application shall resolve GrafttyKit's SwiftPM resource bundle from the packaged `.app` layout (`Contents/Resources/`), falling back to `Bundle.module` only for `swift test`/`swift run`, so a distributed app does not trap on SwiftPM's generated accessor (which probes only the `.app` root and the compiling machine's `.build` path — neither present once shipped).

## DIVERGE — Worktree Divergence Indicator

### DIVERGE-1.x — Display

**DIVERGE-1.1** Each worktree entry in the sidebar shall display a trailing-aligned divergence indicator, placed to the left of the attention badge (or at the trailing edge when no attention badge is present).

**DIVERGE-1.2** The indicator shall display zero, one, or both of the following on a single line, separated by a single space when both are present:

**DIVERGE-1.3** On hover, the indicator shall surface a system tooltip containing the insertion/deletion line counts in the form `+<I> -<D> lines` (with zero sides omitted), optionally suffixed with `, uncommitted changes` when the worktree has uncommitted changes. When there are neither line changes nor uncommitted changes, no tooltip is shown.

**DIVERGE-1.4** When the worktree's ahead count, behind count, insertion count, and deletion count are all zero and there are no uncommitted changes, the indicator shall render no text.

**DIVERGE-1.5** When the repository has no `origin` remote or the default branch name cannot be resolved, the indicator shall render no text for any worktree in that repository.

**DIVERGE-1.6** While a worktree is in the stale state, the indicator shall render no text.

### DIVERGE-2.x — Origin Default Branch Resolution

**DIVERGE-2.1** The application shall resolve each repository's default branch name by running `git symbolic-ref --short refs/remotes/origin/HEAD` and stripping the `origin/` prefix from the result.

**DIVERGE-2.2** If `refs/remotes/origin/HEAD` is not set, the application shall probe the refs `origin/main`, `origin/master`, and `origin/develop` in that order via `git show-ref --verify` and use the matching branch name.

**DIVERGE-2.3** The application shall not perform any network operations to resolve the default branch name.

**DIVERGE-2.4** The application shall cache the resolved default branch name per repository for the duration of the session.

### DIVERGE-3.x — Computation

**DIVERGE-3.0** Divergence shall be measured against the union of a worktree's upstream refs:

**DIVERGE-3.1** The application shall compute the behind count by running `git rev-list --count <refs> ^HEAD` and the ahead count by running `git rev-list --count HEAD ^<refs>` (each `<ref>` from `DIVERGE-3.0` prefixed with `^` for the ahead command). `rev-list` natively dedupes, so a commit reachable from both upstream refs is counted once.

**DIVERGE-3.2** The application shall compute insertion and deletion line counts by running `git diff --shortstat <ref>...HEAD` where `<ref>` is `origin/<worktree-branch>` when that tracking ref exists, otherwise `origin/<defaultBranch>`. The diff uses a single ref rather than the full union so the tooltip reports "your commits on this branch" rather than conflating feature-branch work with default-branch churn.

**DIVERGE-3.3** The application shall detect uncommitted changes in each worktree by running `git status --porcelain` and treating any non-empty output (including modified, staged, deleted, or untracked entries) as "has uncommitted changes".

**DIVERGE-3.4** All git computation for divergence indicators shall run off the main thread and shall not block the UI.

**DIVERGE-3.5** Divergence counts and the uncommitted-changes flag shall be held in memory only and shall not be written to `state.json`.

### DIVERGE-4.x — Refresh Triggers

**DIVERGE-4.1** When a repository is added to the sidebar, the application shall compute divergence counts for each of its worktrees.

**DIVERGE-4.2** When a worktree's HEAD reference changes, the application shall recompute that worktree's divergence counts.

**DIVERGE-4.3** The application shall run `git fetch --no-tags --prune origin` (with no refspec, so the remote's configured fetch rules advance every tracked branch) and recompute divergence counts per repository on a 30-second base cadence, doubling the interval for each consecutive fetch failure (capped by `ExponentialBackoff`'s 32× max shift and a 30-minute hard cap, whichever binds first). A fast 5-second polling ticker drives the eligibility check; actual fetches are gated by the per-repo cadence so tracked repositories are not hammered.

**DIVERGE-4.4** While a divergence computation is in flight for a particular worktree, duplicate refresh requests for the same worktree shall be dropped — but only while the in-flight Task is plausibly still running. After 30 seconds (the in-flight abandonment threshold), a subsequent refresh shall supersede the prior Task: the generation counter is bumped so the stuck Task's late `apply` is discarded, and a fresh compute is dispatched. Without the staleness cap, a `git` subprocess blocked on a ref-transaction lock (e.g., during a concurrent `git push`) permanently locks the worktree's divergence gutter at whatever value was observed in the lock window.

**DIVERGE-4.5** When `WorktreeStatsStore.clear(worktreePath:)` is called — whether from a stale transition (GIT-3.13), a Dismiss (GIT-3.6), or a Delete (GIT-4.10) — a fetch that was already in flight at that moment shall not repopulate `stats` after the clear. Each `clear` bumps a per-path generation counter; `apply` captures the generation at refresh time and drops the write if the counter changed during the await. Without this, a `git worktree remove` that fires shortly after the 5s-polling refresh leaves the divergence indicator flashing back onto a cleared row for the duration of the git subprocess (~50–200ms). Mirrors `PRStatusStore`'s pattern (PR status gained this protection earlier; stats store was lagging).

**DIVERGE-4.6** When the divergence-stats polling tick fires, the application shall recompute divergence counts for every running worktree, with no per-worktree throttle beyond the `inFlight` dedup guard from `DIVERGE-4.4` — the local subprocess pipeline (`git rev-list`, `git diff --shortstat`, `git status --porcelain`) is cheap and bounded, so the gutter never stays stale waiting for a per-worktree cooldown to elapse. If the same tick finds a per-repo `git fetch` is due, the per-worktree dispatch shall be skipped for that repo because the fetch handler itself recomputes every running worktree on success.

**DIVERGE-4.8** The polling ticker for divergence stats shall continue to fire while Graftty is not the frontmost application. Users frequently run their editor or Claude session in a different app while the sidebar's divergence indicator tracks their work; pausing on `resignActive` leaves those updates queued until the user clicks back into Graftty, defeating the purpose of the indicator.

**DIVERGE-4.9** When a compute attempt fails transiently (the default branch was resolvable but `git rev-list`/`diff-tree`/etc. threw), the application shall preserve the worktree's last-known `WorktreeStats` rather than clearing the sidebar gutter. Only when the repo has no resolvable default branch at all (origin removed, clone converted to non-origin setup) shall the stats be wiped. Without this, the ↑N ↓M badge flickers off for the polling window whenever git is briefly unhealthy — same UX concern as `PR-7.10`.

**DIVERGE-4.10** When the divergence-stats polling tick visits a repository whose `git fetch` cooldown has elapsed but which currently has no running worktrees, the application shall not mark that repository as having an in-flight fetch. Without this, the empty-worktrees early-return in `maybeDispatchRepoFetch` leaves the repo's path latched in `inFlightRepos` for the lifetime of the session: every subsequent poll short-circuits at the `inFlightRepos.contains` check, Gate B is skipped, and `WorktreeStatsStore.refresh` is never re-invoked from the polling loop. The user-visible shape is a sidebar gutter whose ↓N count is frozen at whatever value the explicit `refresh` on worktree-open captured — merging `origin/<defaultBranch>` into a feature branch fails to drop the red behind-count, because nothing recomputes the stats until the app is relaunched.

**DIVERGE-4.11** If a per-repo `git fetch` dispatched by the divergence-stats polling tick hangs past the in-flight abandonment threshold — `git fetch` is a network subprocess with no timeout, so a socket wedged across a sleep/wake or a dead link can block indefinitely and never run the slot-releasing handler — then the application shall treat the in-flight repo slot as abandoned and let a later tick dispatch a fresh fetch, rather than latching the repo path in `inFlightRepos` for the lifetime of the session. Without this, every later poll short-circuits at the in-flight check, Gate B is skipped, and the divergence gutter freezes at its last value until the app is relaunched — the async-hang sibling of the synchronous latch closed by DIVERGE-4.10.

## TECH — Technology Constraints

### TECH-1.x

**TECH-1** The application shall be built in Swift using SwiftUI for app chrome and AppKit for terminal view hosting.

### TECH-2.x

**TECH-2** The application shall use libghostty (via the libghostty-spm Swift Package) as its terminal engine.

### TECH-3.x

**TECH-3** The application shall target macOS 14 Sonoma as its minimum supported version.

### TECH-4.x

**TECH-4** The application shall reuse the following components from the Ghostty project (MIT-licensed): `SplitTree`, `SplitView`, `Ghostty.Surface`, `Ghostty.App`, `Ghostty.Config`, and `SurfaceView_AppKit`.

### TECH-5.x

**TECH-5** The application shall invoke every external tool (`git`, `gh`, `glab`, `zmx`) with `LC_ALL=C` in the child environment so output parsers written against English strings (e.g. `git diff --shortstat` "insertion"/"deletion" markers, `gh pr checks` bucket names) keep working when the user's shell locale is non-English. This is a forcing function — the alternative (locale-robust parsers across multiple tools) is fragile and brittle.

## ZMX — zmx Session Backing

### ZMX-1.x — Bundling

**ZMX-1.1** The application shall include a `zmx` binary in the app bundle at `Graftty.app/Contents/Helpers/zmx`, mirroring the placement of the `graftty` CLI.

**ZMX-1.2** The bundled `zmx` binary shall be a universal Mach-O containing both `arm64` and `x86_64` slices, produced by `scripts/bump-zmx.sh`.

**ZMX-1.3** The application shall pin the vendored `zmx` version in `Resources/zmx-binary/VERSION` and record its SHA256 in `Resources/zmx-binary/CHECKSUMS`.

### ZMX-2.x — Session Naming

**ZMX-2.1** The application shall derive the zmx session name for each pane as the literal string `"graftty-"` followed by the first 8 lowercase hex characters (i.e., the leading 4 bytes, yielding 32 bits of namespace uniqueness) of the pane's UUID with dashes stripped.

**ZMX-2.2** The session-naming function shall be deterministic and shall not change across releases without an explicit migration step, since changing it orphans every existing user's daemons.

### ZMX-3.x — Sandboxing

**ZMX-3.1** The application shall pass `ZMX_DIR=~/Library/Application Support/Graftty/zmx/` in the environment of every spawned `zmx` invocation, so Graftty-owned daemons live in a private socket directory distinct from any user-personal `zmx` usage.

**ZMX-3.2** The application shall create the `ZMX_DIR` path if it does not exist at launch.

### ZMX-4.x — Lifecycle Mapping

**ZMX-4.1** When the application creates a zmx-backed native terminal pane, it shall create a libghostty surface with `GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED`, leave both `command` and `initial_input` unset, and start a host-owned `zmx attach graftty-<short-id> <user-shell>` PTY client only after `ghostty_surface_new` succeeds and the view's first layout settles (TERM-11.10). This avoids libghostty's automatic `wait-after-command` behavior while keeping shell exit wired to `close_surface_cb` through `ghostty_surface_process_exit`.

**ZMX-4.2** When the application restores a worktree's split tree on launch (per `PERSIST-3.x`), each restored pane's surface shall be created with the same session name derived from the persisted pane UUID, so reattach to a surviving daemon is automatic.

**ZMX-4.3** When the application destroys a terminal surface (user-initiated close, automatic close on shell exit, or worktree stop), it shall asynchronously invoke `zmx kill --force <session>` for the matching session.

**ZMX-4.4** When the application quits, it shall close each native host-managed `zmx attach` client and shall not invoke `zmx kill` — detaching the short-lived client while leaving zmx daemons and their shells alive is the desired survival behavior.

**ZMX-4.5** When the application invokes synchronous zmx maintenance commands such as `zmx list --short` or `zmx kill --force <session>`, the subprocess wrapper shall apply a bounded timeout and terminate the command if it does not exit promptly. Cleanup paths, including test teardown, shall not block indefinitely on a degraded zmx daemon, because a wedged cleanup can leave `zmx attach` clients and their PTYs orphaned.

### ZMX-5.x — Fallback

**ZMX-5.1** If the bundled `zmx` binary is missing or not executable, the application shall fall back to libghostty's default `$SHELL` spawn behavior on a per-pane basis.

**ZMX-5.2** If the bundled `zmx` binary is unavailable at launch, the application shall present a single non-blocking informational alert explaining that terminals will not survive app quit. The alert shall not be re-presented within the same process lifetime.

**ZMX-5.3** Before creating a new terminal surface, the application shall probe whether the OS can allocate, grant, and unlock a PTY. If that probe fails, the application shall skip surface creation for that pane and log the failure rather than calling into libghostty and relying on a lower-level resource-exhaustion failure. This guard is best-effort and race-prone by nature, but it gives Graftty a controlled failure path when the system PTY pool is exhausted.

### ZMX-6.x — Pass-through Guarantees

**ZMX-6.1** Shell-integration OSC sequences (OSC 7 working directory, OSC 9 desktop notification, OSC 133 prompt marks, OSC 9;4 progress reports) shall continue to flow from the inner shell through `zmx` to libghostty unchanged. The `PWD-x.x`, `NOTIF-x.x`, and `KEY-x.x` requirements remain in force regardless of whether `zmx` is mediating the PTY.

**ZMX-6.2** The `GRAFTTY_SOCK` environment variable shall continue to be set in the spawned shell's environment per `ATTN-2.4`. For zmx-backed native panes, this shall be passed in the host-managed `zmx attach` process environment rather than relying on libghostty surface-spawn env.

**ZMX-6.3** If `GHOSTTY_RESOURCES_DIR` is set (per `CONFIG-2.1`) and the user's shell basename is `zsh`, the host-managed `zmx attach` environment shall set `ZDOTDIR=<ghostty-resources>/shell-integration/zsh` so the inner shell zmx spawns sources Ghostty's zsh integration directly. Without this env construction, precmd hooks do not run, no OSC 7 / OSC 133 sequences are emitted, and `PWD-x.x`, the default-command first-PWD trigger, and shell-integration-driven attention badges go silent.

**ZMX-6.4** When agent hooks are enabled for a zsh shell, the host-managed `zmx attach` environment shall set `GHOSTTY_ZSH_ZDOTDIR` to Graftty's agent-hook zsh init directory so Ghostty's zsh integration can restore that directory after loading. When hooks are disabled, `GHOSTTY_ZSH_ZDOTDIR` shall be omitted.

**ZMX-6.5** Host-managed native panes shall synthesize terminal capability environment for the `zmx attach` child when launched from a macOS GUI process that lacks terminal env vars. If Ghostty terminfo is available next to `GHOSTTY_RESOURCES_DIR`, the env shall match Ghostty's local-shell defaults closely enough for color-aware tools such as Claude Code to enable color output.

**ZMX-6.6** When the host-managed `zmx attach` spawn invokes the user's shell, the spawn shall recover login-shell behavior. For non-bash shells (and bash with agent hooks disabled), the argv shall omit the positional shell argument so zmx applies its documented default of spawning `$SHELL` as a login shell, with `env["SHELL"]` set to the resolved user-shell path. For bash with agent hooks enabled (per ZMX-6.7), the spawn shall keep the positional pointing at the bash launcher script because login bash discards `--rcfile`. This restores `~/.zprofile` (via the ZMX-6.3 ZDOTDIR shim for zsh) processing — without it, `eval "$(brew shellenv)"` is skipped and `~/.zshrc` references to Homebrew-installed binaries (rbenv, nvm, etc.) resolve to "command not found", cascading into broken keybindings, missing colors, and shell-init errors.

**ZMX-6.7** When the user's shell is bash and agent hooks are enabled, the launcher script continues to invoke `bash --rcfile <shim>` (non-login, so `--rcfile` is honored), and the shim shall source the system + user profile chain (`/etc/profile`; first existing of `~/.bash_profile`, `~/.bash_login`, `~/.profile`) once per environment via an idempotency guard env variable (`__GRAFTTY_BASH_PROFILE_SOURCED`), before sourcing `~/.bashrc` and re-prepending the agent-hooks bin to PATH. This recovers login-time PATH setup (Homebrew shellenv, etc.) for bash users without losing the agent-hooks injection that depends on `--rcfile`.

**ZMX-6.8** When the host-managed `zmx attach` spawn invokes zsh as a login shell with agent hooks enabled, the application shall install a `_graftty_prepend_wrapper_path` precmd hook that strips any existing `$GRAFTTY_AGENT_HOOKS_BIN` occurrence from `$PATH` and re-prepends a fresh one before every prompt. The hook shall be registered first from the `.zshrc` shim (after sourcing `~/.zshrc`) and re-registered from the `.zlogin` shim (after sourcing `~/.zlogin`) using a strip-then-append pattern, so the hook appears exactly once in `precmd_functions` and runs after any hooks the user's shell init registered. Without this, sourcing the user's `~/.zlogin` (which conventionally loads tools like RVM that prepend gem/ruby paths to `$PATH` at source-time) pushes graftty's wrapper bin off position 1, allowing user-installed `claude` / `codex` binaries in `~/.local/bin` / `~/.bun/bin` / etc. to shadow the wrapper if any user-prepended directory ever contained those names. The before-every-prompt re-prepend also defends against any chpwd / precmd-driven PATH-management tool (asdf, mise, nvm-on-cd, etc.) the user's shell init registers — those would otherwise override a one-shot `.zshrc` prepend.

**ZMX-6.9** If agent hooks are enabled for a zsh shell and `GHOSTTY_RESOURCES_DIR` is unavailable, the host-managed `zmx attach` environment shall set `ZDOTDIR` directly to Graftty's agent-hook zsh init directory (with `GHOSTTY_ZSH_ZDOTDIR` omitted) so the ZMX-6.8 wrapper-bin PATH shim still runs without Ghostty's shell integration. Without this fallback, the spawn-time PATH prepend is the only defense and `/etc/zprofile`'s `path_helper` demotes the wrapper bin to the PATH tail in the login shell zmx spawns, so `claude` / `codex` resolve to the user's unwrapped installs.

### ZMX-7.x — Session-Loss Recovery

**ZMX-7.1** When the application restores a worktree's split tree on launch (per `PERSIST-3.x` and `ZMX-4.2`), it shall, before creating each pane's surface, query the live zmx session set and clear the pane's rehydration label if the expected session name is absent. This ensures a freshly-created daemon (the result of `zmx attach`'s create-on-miss semantics) is not mistaken for a surviving session by `defaultCommandDecision`.

**ZMX-7.2** If `zmx list` fails for any reason at the cold-start query site (per `ZMX-7.1`), the application shall treat the result as "session not missing" and take no recovery action — preferring a missed recovery over a spurious rehydration clear.

**ZMX-7.3** When `close_surface_cb` fires for a pane, the application shall always route to the close-pane path (remove from the split tree, free the surface) regardless of the zmx session's liveness. The mid-flight "rebuild surface in place" recovery explored in an earlier design was withdrawn because the available signals (session-missing + no Graftty-initiated close) cannot distinguish a clean user `exit` from an external daemon kill, and the rebuild path regressed `TERM-5.3`. Recovery from daemon loss while Graftty is running is deferred until a zmx-side signal disambiguates the two cases.

**ZMX-7.4** At application launch, before any terminal surface is spawned, the application shall `unsetenv(...)` inherited process environment variables whose values would hijack downstream spawns into the parent shell's scope. The list shall include at minimum: `ZMX_SESSION`, `GIT_DIR`, and `GIT_WORK_TREE`.

### ZMX-8.x — Manual Restart

**ZMX-8.1** The Settings → General pane shall expose a "Restart ZMX…" button that, after user confirmation, tears down every running pane across every worktree — invoking the same `destroySurface` / `zmx kill --force` path as per-worktree Stop (`TERM-1.2` / `ZMX-4.3`) — and then marks each affected worktree `.closed` via `prepareForStop` (`STATE-2.11`), preserving each worktree's `splitTree` and `focusedPaneSlotID` so re-opening recreates the same layout at the same leaf IDs under freshly-spawned zmx daemons. The confirmation alert (`NSAlert` with `.warning` style) shall name the destructive consequence explicitly — how many sessions across how many worktrees will end, with a "Any unsaved work in those sessions will be lost" warning (pluralization per `ZmxRestartConfirmation.informativeText`) — and shall offer "Restart ZMX" and "Cancel" buttons with Cancel as the default dismissal. If no worktrees are running at click time, the alert shall state that the action will have no effect rather than silently no-op.

### ZMX-9.x — Idle Resize

**ZMX-9.1** The bundled `zmx attach` client shall forward PTY resize events while idle, without requiring a later keystroke or daemon output to wake its poll loop. This protects restored or lazily reattached panes: when Graftty resizes the outer PTY as a pane comes into view, the daemon's inner PTY must receive the new grid immediately so full-screen programs such as Claude Code, vim, and htop repaint at the visible pane size before user input.

## DIST — Distribution

### DIST-1.x — Build Bundle

**DIST-1.1** The build script (`scripts/bundle.sh`) shall produce a self-contained `Graftty.app` bundle in `.build/` containing the SwiftUI application binary at `Contents/MacOS/Graftty`, the CLI helper at `Contents/Helpers/graftty`, and the bundled `zmx` binary at `Contents/Helpers/zmx`.

**DIST-1.2** While the `GRAFTTY_VERSION` environment variable is set, the build script shall write that value into both `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.

**DIST-1.3** If the `GRAFTTY_VERSION` environment variable is not set, then the build script shall use `0.0.0-dev` as the default version.

**DIST-1.4** The build script shall codesign every Mach-O in the bundle in inner-to-outer order: `Contents/Helpers/zmx`, `Contents/Helpers/graftty`, `Contents/MacOS/Graftty`, then the bundle itself, and shall verify the resulting signature with `codesign --verify --strict`. The signing identity is chosen by the `CODESIGN_IDENTITY` environment variable (defaulting to `-` for ad-hoc); when set to a Developer ID Application identity, the script shall additionally enable hardened runtime (`--options runtime`), secure timestamping (`--timestamp`), and apply `scripts/entitlements/Graftty.entitlements` to the main executable.

### DIST-2.x — Release Automation

**DIST-2.1** When a git tag matching `v*` is pushed to origin, the GitHub Actions workflow `.github/workflows/release.yml` shall build the app bundle in release configuration, verify codesigning, zip the bundle as `Graftty-<version>.zip`, ensure a GitHub release tagged `v<version>` has the zip attached, and ensure the `btucker/homebrew-graftty` cask reflects the new version and sha256.

**DIST-2.2** If the pushed tag does not start with `v`, then the release workflow shall fail before building.

**DIST-2.3** If a release for the pushed tag already exists, then the workflow shall re-upload the zip with `--clobber` and continue to the cask update step rather than failing.

**DIST-2.4** The release zip shall be produced with `ditto -c -k --keepParent` (not `zip`) so that codesign-relevant extended attributes survive — `zip` strips them and installs fail with opaque "damaged" errors after reboot.

### DIST-3.x — Homebrew Cask

**DIST-3.1** The Homebrew tap `btucker/homebrew-graftty` shall expose a cask `graftty` that downloads the release zip, installs `Graftty.app` to `/Applications`, and symlinks `Graftty.app/Contents/Helpers/graftty` onto the user's PATH as `graftty`.

**DIST-3.3** When the user runs `brew uninstall --cask --zap graftty`, the cask shall remove `~/Library/Application Support/Graftty`, `~/Library/Preferences/com.graftty.app.plist`, and `~/Library/Caches/com.graftty.app`.

**DIST-3.4** When a tagged release is built in CI, the release workflow shall sign the bundle with the `Developer ID Application: Quotably, LLC (67APXH3J92)` identity, submit it to `xcrun notarytool` using App Store Connect API key credentials, and on success staple the notarization ticket into the bundle with `xcrun stapler staple` before zipping for distribution.

## WEB — Web Access

### WEB-1.x — Binding

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

### WEB-2.x — Authorization

**WEB-2.1** The application shall resolve each incoming peer IP via Tailscale LocalAPI `whois` before serving any content at any path.

**WEB-2.2** The application shall accept a connection only when the resolved `UserProfile.LoginName` equals the current Mac's Tailscale `LoginName`.

**WEB-2.3** When `whois` fails or the resolved LoginName differs, the application shall respond with HTTP `403 Forbidden`.

**WEB-2.4** When Tailscale is not running, the application shall refuse all incoming connections (the server is not bound; connections are refused at TCP).

**WEB-2.5** _(Removed; superseded by WEB-1.1.)_ The prior loopback-bypass carve-out existed because `WEB-1.1` bound `127.0.0.1`; with that bind gone, local connections now arrive as Tailscale peers via the MagicDNS hostname (WEB-8.1) and are accepted under the normal `WEB-2.2` same-user check.

### WEB-3.x — Protocol

**WEB-3.1** The application shall serve a single static page at `/` (and `/index.html`) that bootstraps the bundled web client.

**WEB-3.2** When a client requests any path that does not match a bundled static asset and does not begin with `/ws`, the application shall respond with the bundled `index.html` body and `Content-Type: text/html; charset=utf-8`. This serves the SPA fallback for client-side-routed URLs such as `/session/<name>`.

**WEB-3.3** The application shall upgrade `/ws?session=<name>` to WebSocket after the authorization check passes.

**WEB-3.4** WebSocket binary frames shall carry raw PTY bytes in both directions.

**WEB-3.5** WebSocket text frames shall carry JSON control envelopes. The only Phase 2 envelope shape shall be `{"type":"resize","cols":<uint16>,"rows":<uint16>}`.

**WEB-3.6** When the application responds to an HTTP request with `Connection: close`, it shall transmit exactly the number of body bytes declared in its `Content-Length` header to the client before closing the TCP connection, so clients never observe a truncated response (`ERR_CONTENT_LENGTH_MISMATCH`). This requirement applies even on links (e.g., Tailscale `utun`, MTU ~1280) whose kernel TCP send buffer cannot absorb the full response in a single non-blocking write.

### WEB-4.x — Lifecycle

**WEB-4.1** When the user enables web access in Settings, the application shall probe Tailscale, bind, and transition status to `.listening(...)` or an error status.

**WEB-4.2** When the user disables web access, the application shall close all listening sockets and terminate all in-flight `zmx attach` children spawned for the web.

**WEB-4.3** When the application quits, the application shall stop the server (same tear-down as 15.4.2) as part of normal shutdown.

**WEB-4.4** For each incoming WebSocket, the application shall spawn one child `zmx attach <session>` whose PTY it owns (per §13 naming and ZMX_DIR rules from Phase 1).

**WEB-4.5** When a WebSocket closes, the application shall send SIGTERM to the associated `zmx attach` child, leaving the zmx daemon alive.

**WEB-4.6** When the application forks a `zmx attach` child for a web WebSocket, the child shall close every inherited file descriptor above 2 before `execve`. Rationale: without this, parent-opened sockets (notably the `WebServer` listen socket) without `FD_CLOEXEC` leak into the zmx child and survive the parent. After Graftty quits, the listen port stays bound to an orphan zmx process and the next Graftty launch cannot rebind.

**WEB-4.7** When the application transitions the forked child into `zmx attach`, the final `execve` shall be performed via `posix_spawn` with `POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGMASK` and an empty initial signal mask. `fork(2)` preserves the parent's sigmask and plain `execve(2)` carries it across — and the Swift runtime (GCD/Dispatch) blocks a family of signals on its service threads, so a child inheriting that mask starts with SIGWINCH blocked. `zmx attach` installs a SIGWINCH handler to forward PTY resize events to the daemon; if SIGWINCH is blocked the handler never fires, the kernel sets the signal pending, and WebSocket-sent resize events silently vanish until an unrelated signal or explicit unblock drains them. The spawn-level mask reset is the kernel-boundary fix that guarantees the exec'd image starts with every signal unblocked.

**WEB-4.10** When the WebSocket bridge spawns a `zmx attach` child to back a mobile-client session, the application shall propagate the same shell-integration env (`TERM`, `COLORTERM`, `TERM_PROGRAM`, `TERMINFO` when ghostty-terminfo is available, and `ZDOTDIR` pointing at Ghostty's zsh shell-integration when the user's shell is zsh) that host-managed native panes use (per `ZMX-6.3` / `ZMX-6.5`). Without this, the WS attach can win the create-session race against the Mac surface's attach (which is slow because it follows `git worktree add` + discovery) and spawn the daemon's user shell with no shell integration — silencing the first-PWD trigger (so the host pane never types the user's default command) and leaving the shell without truecolor.

### WEB-5.x — Client

**WEB-5.1** The bundled client shall render a single terminal (ghostty-web, a WASM build of libghostty — the same VT parser as the native app pane) that attaches to the session indicated by the `/session/<name>` URL path. If a client arrives at the root path `/` with a `?session=<name>` query parameter, the client shall redirect to `/session/<name>` (backward compatibility). Sharing a parser with the native pane is what keeps escape-sequence behavior (cursor movement, SGR state, OSC 8 hyperlinks, scrollback) identical across clients.

**WEB-5.2** The client shall send terminal data events as binary WebSocket frames.

**WEB-5.3** The client shall send resize events as JSON control envelopes in text frames, including an initial resize sent on WebSocket open so the server-side PTY is sized to the client's actual viewport rather than the `zmx attach` default.

**WEB-5.4** When a client requests `GET /sessions`, the application shall respond with a JSON array of the currently-running sessions, one entry per live pane across all running worktrees, with fields `name` (the zmx session name derived per `ZMX-2.1`), `worktreePath`, `repoDisplayName`, and `worktreeDisplayName`. The bundled client's root page (`/`) shall fetch this endpoint and render a clickable picker grouped by `repoDisplayName`, so a user who visits the server's root URL without a session query gets a functional entry point rather than a bare "no session" placeholder. Access to `/sessions` shall be gated by the same Tailscale-whois authorization as every other path (`WEB-2.1` / `WEB-2.2`).

**WEB-5.5** The client shall size the terminal grid to fill the host element using the renderer's font metrics (`cols = floor(host.clientWidth / metrics.width)`, `rows = floor(host.clientHeight / metrics.height)`) and shall not reserve any horizontal pixels for a native scrollbar, so the canvas occupies the full viewport width and the PTY column count matches the visible grid. Rationale: ghostty-web's bundled `FitAddon` unconditionally subtracts 15 px from available width for a DOM scrollbar (`proposeDimensions()` in `ghostty-web.js`), but Ghostty renders its scrollback scrollbar as a canvas overlay — using `FitAddon` leaves a ~15 px gap on the right edge and narrows wrapping (e.g., 148 cols instead of 150 on a 1200 px viewport with 8 px cells).

**WEB-5.6** When the client's WebSocket closes for any reason other than a deliberate page unmount (mobile tab suspension, laptop sleep, transient network wobble, Tailscale peer rotation), the client shall automatically attempt to reconnect to the same `/ws?session=<name>` URL with exponential backoff starting at 500 ms and capped at 8 s, with ±25 % jitter per attempt, keeping the `Terminal` instance and its scrollback alive across reconnects; on `visibilitychange` to `visible`, if the socket is not `OPEN` the client shall reset backoff and reconnect immediately rather than wait out any pending timeout. On each successful `open`, the client shall resend the current `(cols, rows)` as a resize envelope so the freshly-spawned `zmx attach` child's PTY matches the terminal grid. Rationale: without this, every transient drop required a full page refresh — a refresh loses the URL-bound session-picker state and visually blanks the terminal for the ~300 ms of wasm re-init. The daemon session surviving per `WEB-4.5` makes reconnection a safe retry rather than a "recreate from scratch" cost.

**WEB-5.7** On mobile browsers the client shall (a) translate a single-finger vertical drag on the terminal host into `term.scrollLines(-deltaLines)` so scrollback is reachable without a hardware wheel (ghostty-web's built-in scrolling is wheel-only and mobile browsers do not synthesize wheel events from single-finger drag); and (b) size the terminal host to `window.visualViewport.{width,height}` (fallback `window.innerWidth/Height`), updating on `visualViewport` `resize` and `scroll` events, so when the software keyboard opens the host shrinks to the remaining visible area and the existing ResizeObserver refits `(cols, rows)` — keeping the cursor row above the keyboard rather than occluded beneath it. Taps shorter than one character-cell of movement shall still reach the terminal's own focus handler (which shows the mobile keyboard); multi-touch gestures (pinch, two-finger pan) shall pass through untouched. The terminal host shall declare `touch-action: none` and `overscroll-behavior: none` so the browser doesn't interpret the drag as page-scroll/pan/zoom or rubber-band the viewport before our handler sees the event.

**WEB-5.8** While the user is viewing scrollback on the normal screen (i.e., `term.viewportY > 0`), incoming PTY output shall not move the viewport: the client shall capture `viewportY` and scrollback length immediately before each `term.write()` call and, after the write, re-apply `viewportY` shifted by the number of lines that scrolled into scrollback so the viewport stays pinned to the same absolute content rather than the same offset-from-bottom. While the alternate screen is active on either side of the write, the viewport shall be left at the library-default bottom position. Rationale: ghostty-web's `Terminal.writeInternal` unconditionally calls `scrollToBottom()` whenever `viewportY !== 0` at write time, so without this wrapper the viewport snaps to the newest output on every WebSocket data frame — making wheel/touch scrollback unusable on any session that is actively producing output. Pinning to absolute content (not offset) is what lets the user read older lines while the shell continues to print.

### WEB-6.x — Security and non-goals

**WEB-6.1** The web server shall bind HTTPS only, using a cert+key pair fetched from Tailscale LocalAPI for the machine's MagicDNS name (WEB-8.2). The application shall not bind any HTTP listener; clients with old `http://` bookmarks will fail to connect until they update the URL.

**WEB-6.2** Phase 2 shall not implement multi-pane layout, mouse events, OSC 52 clipboard sync, or reboot survival. (A minimal session-list picker is provided by `WEB-5.4`; worktree creation is provided by `WEB-7`.)

**WEB-6.3** Phase 2 shall not implement rate limiting, URL tokens, or cookies; authorization shall be via Tailscale WhoIs only.

### WEB-7.x — Adding worktrees from the web client

**WEB-7.1** When a client requests `GET /repos`, the application shall respond with a JSON array of the currently-tracked repositories (one entry per top-level `RepoEntry` in `AppState.repos`) with fields `path` (opaque absolute path round-tripped on `POST /worktrees`) and `displayName` (matching the native sidebar's top-level label). Access is gated by the same Tailscale-whois authorization (`WEB-2.1` / `WEB-2.2`).

**WEB-7.2** When a client sends `POST /worktrees` with a JSON body `{repoPath, worktreeName, branchName}`, the application shall create a new worktree under `<repoPath>/.worktrees/<worktreeName>` on a fresh branch named `<branchName>`, starting from the repo's resolved default branch (same `GitOriginDefaultBranch` resolution the native sheet uses); discover the new worktree into `AppState.repos` so it appears in the sidebar immediately; spawn its first ghostty surface via the same `TerminalManager.createSurfaces` path the native sheet uses; and respond with `200` and `{sessionName, worktreePath}`. The `sessionName` is the `ZMX-2.1`-derived name of the first leaf, suitable for use as `/session/<sessionName>`.

**WEB-7.3** The application shall reject `POST /worktrees` requests with invalid JSON, missing fields, or whitespace-only `worktreeName`/`branchName` with `400 Bad Request` and a JSON `{error: "<message>"}` body. `GET /worktrees` and other verbs shall return `405 Method Not Allowed`. Request bodies exceeding 64 KiB shall return `413 Payload Too Large` before any creator is invoked.

**WEB-7.4** When `git worktree add` fails (branch already exists, path already in use, fatal ref-format rejection, etc.), the application shall respond `409 Conflict` with the captured stderr as `{error: "<stderr>"}`. When post-git discovery or surface creation fails, the application shall respond `500 Internal Server Error` with the underlying message. The web-created worktree shall not leave the Mac's `AppState` holding a half-materialized entry: either the entry appears in `.running` state with a surface, or not at all.

**WEB-7.5** The native Mac window's `selectedWorktreePath` shall not change as a side effect of a web-initiated `POST /worktrees`. Rationale: remote-creating a worktree from an iPad should not yank the local user's Mac window focus away from whatever they are currently doing. The new worktree still appears in the sidebar (via `WEB-7.2`'s discovery step) and a running pane is visible there.

**WEB-7.6** The bundled web client shall expose an "Add worktree" entry point on its root page that routes to `/new`. `/new` shall render a form containing (a) a repository picker populated from `GET /repos` (hidden when only one repo is tracked), (b) a worktree-name field, (c) a branch-name field defaulting to mirror the worktree-name field until the user types a differing branch name. Both name fields shall sanitize input live to the same allowed set as the native sheet (`A-Z a-z 0-9 . _ - /`, consecutive disallowed chars collapsing to a single `-`) and shall trim whitespace plus leading/trailing `-` / `.` at submit time. On successful `POST /worktrees` the client shall navigate to `/session/<sessionName>`; on failure it shall display the server's `error` message inline next to the form.

**WEB-7.7** When `AppState.repos` is empty (no repositories tracked yet), the `/new` route shall render an empty-state message directing the user to open a repository in the native Graftty app first, with a back-link to `/`. The web client shall not implement repository-adding (the Mac-side file dialog + security-scoped bookmark mint has no web equivalent in Phase 2).

**WEB-7.8** When a client sends `POST /worktrees/delete` with `{ "worktreePath": "<abs>", "force": <bool> }`, the application shall route the request through `DeleteWorktreeFlow.delete` and respond `200 { "dismissed": <bool> }` on success. `dismissed` shall be `true` when the flow took the GIT-3.6 / GIT-4.13 prune-on-vanished branch and `false` when `git worktree remove` succeeded. The `/worktrees/delete` endpoint accepts `POST` only; other verbs return `405 Method Not Allowed`.

**WEB-7.9** If the server-side delete flow encounters a git failure that `--force` could resolve, then the application shall respond `409 Conflict` with `{ "error": "<stderr>", "forceAllowed": true, "shortStatus": "<git status --short output>" }`. When `--force` has already been attempted, or the failure class is one `--force` cannot help (e.g. main-checkout rejection), the response shall be `409 Conflict` with `forceAllowed: false` and no `shortStatus` field.

**WEB-7.10** If the server's `worktreeRemover` closure is not injected, then `POST /worktrees/delete` shall respond `503 Service Unavailable` with `{ "error": "worktree deletion not available" }`. This matches the create endpoint's pre-injection contract (WEB-7.4 sibling) so a mobile or web client can distinguish "not supported yet" from "wrong URL".

### WEB-8.x — Web TLS (HTTPS)

**WEB-8.1** When binding the HTTPS server, the application shall read `Self.DNSName` from Tailscale LocalAPI `/status`, strip the trailing dot, and use the resulting FQDN as the TLS SNI name and as the hostname in every composed Base URL / session URL. If `DNSName` is absent or empty, the application shall enter `.magicDNSDisabled` status and not bind. Settings shall render a "MagicDNS must be enabled on your tailnet" message plus a link to `https://login.tailscale.com/admin/dns`.

**WEB-8.2** The application shall fetch the TLS cert+key pair for the MagicDNS FQDN from Tailscale LocalAPI `/localapi/v0/cert/<fqdn>?type=pair`. If the response is classified (HTTP status ≥ 400 + body mentioning "HTTPS" and "enable") as "HTTPS disabled for this tailnet", the application shall enter `.httpsCertsNotEnabled` status and render an admin-console link without attempting to bind. Any other fetch failure shall enter `.certFetchFailed(<message>)` status.

**WEB-8.3** While the server is listening, the application shall re-fetch the cert every 24 hours. If the returned PEM bytes differ from the currently-serving material, the application shall construct a new `NIOSSLContext` and atomically swap the reference read by the per-channel `ChannelInitializer` via `WebTLSContextProvider.swap(_:)`. The application shall not close the listening socket and shall not disturb in-flight connections — existing WebSocket streams keep their prior context for their lifetime.

**WEB-8.4** For `.magicDNSDisabled` and `.httpsCertsNotEnabled`, the Settings pane shall render a human-readable explanation plus a SwiftUI `Link` to the relevant Tailscale admin page (`https://login.tailscale.com/admin/dns`). For `.certFetchFailed`, it shall render the underlying message plus a note that Graftty retries automatically.

**WEB-8.5** While reading a `/localapi/v0/cert/<fqdn>` response, the application shall use a recv timeout sized for first-time Let's Encrypt minting (≥60s), distinct from the 2s timeout used for `whois`/`status`, so a slow ACME exchange does not surface as `.certFetchFailed("malformedResponse")`.

**WEB-8.6** While the cert pair fetch is in flight on "Enable web access", the application shall hold a `.provisioningCert` status, render a `ProgressView` plus "Provisioning certificate from Tailscale…" message in the Settings pane, and shall not block the MainActor for the duration of the fetch. On completion the status shall transition to `.listening` (success), `.httpsCertsNotEnabled` (tailnet-disabled), or `.certFetchFailed(<message>)` (any other error) without leaving the pane stuck on `.provisioningCert`.

## UPDATE — Self-Update

### UPDATE-1.x — Install flow

**UPDATE-1.1** While the user has consented to automatic checks (Sparkle

**UPDATE-1.2** When a scheduled check discovers a newer version, the

**UPDATE-1.3** When the user clicks the titlebar indicator, the

**UPDATE-1.4** While no update is available, the application shall hide

**UPDATE-1.5** When the user selects `Graftty → Check for Updates…`,

**UPDATE-1.6** If the user has not yet chosen a preference for automatic

**UPDATE-1.7** When an update is installed, the application shall

### UPDATE-2.x — Release pipeline

**UPDATE-2.1** When a new version tag is pushed, the release workflow

**UPDATE-2.2** The Homebrew cask shall declare `auto_updates true` so

**UPDATE-2.3** The release workflow shall extract only the base64

**UPDATE-2.4** The `appcast-updater` tool shall reject `--ed-signature`

**UPDATE-2.5** The release workflow shall render the GitHub release

## KBD — Keyboard Shortcuts

### KBD-1.x

**KBD-1.1** When the user presses a chord bound in their Ghostty config

**KBD-1.2** When the user's Ghostty config omits a binding for an action,

### KBD-2.x

**KBD-2.1** When the user presses `toggle_split_zoom` on a focused pane

**KBD-2.2** When the user presses `toggle_split_zoom` on a lone pane

**KBD-2.3** When the user presses a `goto_split:*` chord while a pane is

### KBD-3.x

**KBD-3.1** When the user presses a `resize_split:<direction>` chord,

**KBD-3.2** When no matching-orientation ancestor exists, the

### KBD-4.x

**KBD-4.1** When `reload_config` fires, the application shall rebuild

## PR — PR/MR Status Display

### PR-1.x — Branch-to-PR Association

**PR-1.1** When the application resolves the PR for a worktree's branch on a GitHub origin, it shall scope the lookup to PRs whose head ref lives in the same repository as the base so that PRs from forks which happen to share the branch name are not associated with the worktree. Per-repo batched fetching applies the filter post-hoc by comparing each PR's `headRepositoryOwner.login` (case-insensitive) against the origin's owner and dropping PRs from other repositories before they reach the per-worktree distribution.

**PR-1.2** If more than one PR in the same repository matches the worktree's branch and state, the application shall associate the worktree with the most recently created one.

### PR-2.x — Refresh Triggers

**PR-2.1** When a worktree's HEAD reference changes (per GIT-2.4), the application shall drop the worktree's previously cached PR display synchronously and shall trigger a fresh PR resolution for the new branch — rather than waiting for the next polling tick to discover the change. This prevents the previous branch's PR from continuing to display through the polling cadence window after a `git checkout`, rebase, or other HEAD-rewriting operation.

**PR-2.2** When the application observes an origin-ref change for a repository (per GIT-2.5), the application shall trigger a fresh PR resolution for every non-stale worktree in that repository whose branch is fetchable. This catches the `gh pr create` / `git push` flow — neither moves local HEAD, so PR-2.1 doesn't fire, and without this trigger the user would wait up to the full `absent` polling cadence before a newly-opened PR appears in the sidebar.

### PR-3.x — Sidebar Indicator

**PR-3.1** While a worktree has a resolved PR/MR (open or merged), its sidebar row shall use the SF Symbol `arrow.triangle.pull` as its leading icon in place of the default `arrow.triangle.branch` (linked worktree) or `house` (main checkout) glyph. The icon's color shall continue to encode the worktree's running state (closed / running / stale) per existing behavior; the leading-icon change communicates only the PR's existence, while detailed PR state (number, title, check status) remains in the breadcrumb's PR button.

**PR-3.2** While a worktree has a resolved PR/MR, its sidebar row shall display a `#<number>` badge between the leading icon and the branch label. The badge text shall be colored using the PR's state color: green for open, purple for merged. While the PR is open, the CI verdict from `PR-3.5` overrides the open-state green.

**PR-3.3** The `#<number>` sidebar badge shall be a tappable button that opens the PR URL in the system browser when clicked. Clicking the badge shall not trigger the row's worktree-selection action.

**PR-3.4** The `#<number>` sidebar badge shall have an accessibility label of the form "Pull request `<number>`, open/merged[, CI failing|CI running]. Click to open in browser." and a tooltip showing "Open #`<number>` on `<host>`". The CI suffix is appended only when the CI tone is `ciFailure` or `ciPending` per `PR-3.5`.

**PR-3.5** While a worktree's PR/MR is open, the `#<number>` sidebar badge text shall be colored to reflect CI state, overriding the open-state green: red (matching the breadcrumb PR-button failure dot, RGB ~0.97/0.32/0.29) when the latest checks verdict is `failure`, orange (matching the pending dot, RGB ~0.82/0.60/0.13) and pulsing in opacity when the verdict is `pending`. A `success` or absent (`none`) verdict shall keep the open-state green so repos without CI do not lose the open-vs-merged signal. While the PR is merged, the badge shall remain purple regardless of the CI verdict, since CI status on a merged PR is stale and would distract from the actionable signal on still-open PRs.

### PR-4.x — Host Detection

**PR-4.1** The application shall resolve the hosting origin for a repository by running `git remote get-url origin` in the repository's path and parsing the returned URL. Both scp-style (`git@<host>:<owner>/<repo>`) and HTTP(S)/SSH URLs (`https://<host>/<owner>/<repo>`, `ssh://<host>/<owner>/<repo>`) shall be accepted; `file://`, `git://`, and bare local paths shall resolve to no origin.

**PR-4.2** Hosts whose name is `github.com`, ends in `.github.com`, or begins with `github.` shall classify as provider `github`. Hosts whose name is `gitlab.com`, ends in `.gitlab.com`, or begins with `gitlab.` shall classify as provider `gitlab`. Any other host shall classify as `unsupported`.

**PR-4.3** For worktrees belonging to a repository whose origin resolves to an `unsupported` provider or to no origin at all, the application shall not attempt PR fetches and shall not display a PR badge.

**PR-4.4** `GitOriginHost.detect` shall treat a `git remote get-url origin` nonZeroExit as a legitimate "no origin remote" answer (returning nil, cacheable per `PR-7.11`) only when stderr contains "no such remote" (case-insensitive). Every other nonZeroExit shall rethrow so the store's caller-side don't-cache-on-throw safeguard prevents a transient failure — e.g. `.git/config` being rewritten during a concurrent `git worktree add`, brief lock contention under load, an FSEvents-driven re-read mid-pack-operation — from poisoning `hostByRepo` with nil for the remainder of the session. Without this discrimination, a single transient git error at first-poll turns a repo's PR status off until Espalier is relaunched; the symptom is silent (no logs, no badge) because `tick()` skips cached-nil repos and `performFetch` treats the cache as authoritative. `LC_ALL=C` (`TECH-5`) keeps the stderr match locale-stable.

**PR-4.5** When the user adds a repository whose origin's host CLI (`gh` for github, `glab` for gitlab) is not available on the application's PATH, the application shall present an informational nudge with installation guidance. The nudge shall fire at most once per provider per process and shall be permanently suppressible per provider via a "Don't show again" affordance persisted in UserDefaults.

### PR-5.x — PR Fetching

**PR-5.1** For GitHub origins, the application shall fetch open PRs via `gh pr list --repo <owner>/<repo> --head <branch> --state open --limit 5 --json number,title,url,state,headRefName,headRepositoryOwner` and take the first result whose `headRepositoryOwner.login` matches the origin owner. Merged PRs shall use the same shape with `--state merged` and the additional `mergedAt` JSON field. The limit is 5 (rather than 1) so a fork PR returned first by `gh`'s default sort cannot crowd out a same-repo PR that the owner filter would otherwise accept.

**PR-5.2** For GitHub origins, the application shall fetch per-check status via `gh pr checks <number> --repo <owner>/<repo> --json name,state,bucket`. The `bucket` field (values `pass`/`fail`/`pending`/`skipping`/`cancel`) is the canonical verdict; `conclusion` is not a field `gh` emits from this command.

**PR-5.3** For GitLab origins, the application shall fetch merge requests via `glab mr list --repo <path> --source-branch <branch> --per-page 5 -F json` (appending `--merged` for the merged-state sweep; the default list is opened-only) and take the first result whose `source_project_id` equals its `target_project_id`. Pipeline status for an opened MR comes from a separate `glab mr view <iid> --repo <path> -F json` call and is derived from the returned `head_pipeline.status` — the MR list endpoint (backing `glab mr list`) does not populate `head_pipeline`, only the single-MR view does. glab's earlier string-valued `--state <opened|merged>` flag was removed upstream; invocations that still carry it fail with "Unknown flag: --state" and yield no MR at all, which is why the flag-based spelling above is load-bearing. The per-page bound is 5 (rather than 1) so a fork MR returned first by glab's default sort cannot crowd out a same-repo MR that the source/target project-id filter would otherwise accept — parity with the GitHub-side fork defense in `PR-5.1`. An MR whose project IDs cannot be verified (both fields absent in the response) is excluded rather than accepted, for the same reason the GitHub filter excludes PRs with a missing `headRepositoryOwner`. If the `mr view` pipeline-status call fails after `mr list` succeeded, the MR is still surfaced with `.none` checks rather than dropping the whole `PRInfo` — parity with `PR-5.4`.

**PR-5.5** When the application stores a PR/MR title into a `PRInfo` for display (breadcrumb `PRButton`, accessibility label, tooltip), it shall first strip every Unicode bidirectional-override scalar (the embedding, override, and isolate families — the same ranges as `ATTN-1.14`). PR titles are author-controlled, including authors who submit from malicious forks; a poisoned title like `"Fix \u{202E}redli\u{202C} helper"` would otherwise render RTL-reversed in the breadcrumb as `"Fix ildeeper helper"`-style text — the same Trojan Source visual deception (CVE-2021-42574) `ATTN-1.14` and `LAYOUT-2.18` block on self-owned surfaces. Unlike those surfaces, the PR-title path STRIPS rather than REJECTS: a poisoned title shouldn't hide the PR entirely from the user (they still need to see "a PR exists"); stripping yields a legible-ish version and the user can click through to the hosting provider for the raw text. Applies to both `GitHubPRFetcher` and `GitLabPRFetcher`.

**PR-5.6** When `GitOriginHost.parse` normalises a remote URL, it shall strip trailing `/` characters from the repo path segment before stripping the `.git` suffix. Scp-style URLs (`git@host:owner/repo.git/`) don't go through `URL`'s path normalisation, so a configured remote with a stray trailing slash — common on copy-paste from a browser address bar into `git remote set-url` — would otherwise retain `repo.git` as the repo slug. The downstream `gh pr list --repo <owner>/<repo.git>` returns no results and the sidebar silently shows no PR badge for the whole session.

### PR-6.x — Check Rollup

**PR-6.1** A PR's overall check status shall roll up its individual check buckets as follows: any `fail` → `.failure`; any `pending` bucket or any in-flight state (`IN_PROGRESS`, `QUEUED`, `PENDING`) → `.pending`; all-`pass` → `.success`; anything else (including `skipping`, `cancel`, or unclassified) → `.none` (neutral).

**PR-6.2** When a PR has no checks, its overall status shall be `.none`.

### PR-7.x — Polling Cadence and Backoff

**PR-7.3** The application shall not poll worktrees whose branch is a git sentinel value (`(detached)`, `(bare)`, `(unknown)`, any other parenthesized value, or empty / whitespace-only), since none of these correspond to a real ref that a hosting provider can associate with a PR.

**PR-7.4** The application shall not poll stale worktrees.

**PR-7.5** `PRStatusStore.refresh` and `PRStatusStore.branchDidChange` shall also apply the `PR-7.3` sentinel-branch gate, not just the background polling loop. Otherwise an on-demand refresh (sidebar selection, HEAD-change event) against a detached / bare / unknown worktree still fires two wasted `gh pr list --head <sentinel>` invocations per event — the gate belongs at the fetch entry point, not duplicated at every caller.

**PR-7.6** The PR polling ticker shall continue to fire while Graftty is not the frontmost application. `gh pr list` is the only detection channel for an open→merged transition that happens on GitHub without a local `git fetch`; pausing while the app is backgrounded leaves the sidebar's PR badge stuck on "open" until the user clicks back into Graftty, even though the merge may have happened many minutes earlier. The cost (one `gh pr list` per worktree every 10–30 seconds depending on the `PR-7.1` tier) is negligible compared to the staleness it would otherwise produce.

**PR-7.10** When a PR fetch fails (network error, rate limit, expired `gh` auth), the application shall preserve every worktree's last-known `PRInfo` cache entry for that repo rather than removing them. A transient failure is not evidence that any PR stopped existing, and dropping cached info on every failed poll makes the sidebar badge and breadcrumb PR button flicker in and out while the per-repo backoff waits to retry. The next successful fetch either confirms the cached state or updates it.

**PR-7.11** When host detection (`GitOriginHost.detect` or equivalent) throws for a repository — process launch failure, git binary missing from PATH, etc. — the application shall not cache the failure in the `hostByRepo` map. Only successful detections (whether returning a resolved `HostingOrigin` or a legitimate "no origin remote" nil) shall be cached. Otherwise a transient environment glitch at first fetch poisons the repo's PR tracking for the whole session, since the poll tick skips cached-nil repos and no code path re-attempts detection.

**PR-7.12** When the user selects a worktree in the sidebar, the application shall call `PRStatusStore.refresh`, bypassing the per-repo polling cadence. Even with the 60-second cap, a worst-case 60-second wait for a freshly-merged PR to appear in the breadcrumb is longer than the click-to-feedback loop a user expects on selection. Sidebar selection is a strong "user cares about this worktree now" signal, and the existing `refresh` path already short-circuits cadence and resets `failureStreak` on success — wiring it to selection closes the stale-UI escape hatch without any new mechanism.

**PR-7.13** `PRStatusStore` shall time-bound its per-repo `inFlight` refresh guard so a hung `gh pr list` / `glab mr list` subprocess cannot permanently lock out subsequent polls and user-triggered refreshes. A dispatch whose start timestamp is within the inFlight cap (30 seconds) shall suppress a fresh refresh; beyond that cap, the prior dispatch shall be treated as abandoned and superseded, with the per-repo `generation` counter bumped so the abandoned Task's late write is dropped if it ever returns. Without this, a single stuck subprocess (network flake, rate-limit back-off, expired gh auth refresh loop) freezes that repo's worktrees' sidebar badges and breadcrumb PR buttons at their last-cached state until the app is relaunched — the user-observable shape "PR status only updates when I click between worktrees". Mirrors `WorktreeStatsStore`'s `DIVERGE-4.4` recovery pattern for the equivalent stats-store bug.

**PR-7.14** The PR polling tick shall dispatch eligible per-repo fetches and return without awaiting those fetch Tasks. The ticker loop itself must remain live even if a `gh` / `glab` subprocess hangs, otherwise `PR-7.13`'s abandoned-in-flight recovery never gets a later polling tick on which to supersede the stuck fetch. A hung fetch may occupy that repo's `inFlight` slot until the `PR-7.13` 30-second inFlight cap elapses, but it must not stop unrelated repos from polling or require the user to click the sidebar to trigger the separate on-demand refresh path.

**PR-7.15** PRStatusStore.onTransition shall deliver a (RoutableEvent, worktreePath, attrs) tuple on every PR state or CI conclusion transition, so consumers can re-route via TeamEventDispatcher without parsing wire-format event types.

### PR-8.x

**PR-8.10** The polling ticker shall keep firing `onTick` on its configured interval indefinitely, without stalling after one or more sleep / pulse cycles. `pulse()` shall cause the next tick to fire ahead of schedule, with bounded latency, rather than waiting for the full interval.

**PR-8.11**

**PR-8.12**

**PR-8.13**

**PR-8.14** When the application resolves PR status for a repo's worktrees, it shall issue a single `gh pr list --json statusCheckRollup,mergeable,...` call per repo and distribute the resulting snapshot to every worktree whose branch matches a head ref. The previous per-branch fetcher fired two `gh` subprocesses (`pr list` + `pr checks`) per worktree per polling tick; the per-repo batch keeps total CLI invocations linear in the number of repos rather than the number of worktrees.

**PR-8.15** When the application resolves PR/MR status for a GitLab repo's worktrees, it shall issue a single `glab mr list --all` call per repo for the listing and fan out per-MR `glab mr view` calls in parallel only for branches the caller cares about. A repo with 100 MRs and 5 worktrees must produce 1 list call + 5 view calls per tick, not 100 view calls.

**PR-8.16**

**PR-8.17**

**PR-8.18**

**PR-8.19**

**PR-8.20** When the application picks the sidebar `#<number>` badge tone for a worktree's PR, the priority shall be merged/closed > CI failure > CI pending > merge conflict > open. CI signals win over a merge conflict because they're tighter feedback on the user's current change; once CI is clean, the conflict tone surfaces and tells the user to rebase. Terminal states (`.merged` and `.closed`-without-merging) ignore CI entirely — CI on a dead PR is stale. The `.conflicting` tone gives "PR has conflicts but CI is green" a visually distinct signal from "PR is broken in CI".

**PR-8.21**

**PR-8.22**

**PR-8.23** When a worktree's local branch name differs from the remote branch it tracks (via `branch.<name>.merge` / `git push -u`), the application shall associate the worktree with the PR/MR whose head ref equals the tracked remote branch name, not the local branch name. PR fetchers key snapshots by the remote-side head ref (`headRefName` for GitHub, `source_branch` for GitLab), so the previous `prsByBranch[localBranch]` lookup silently dropped the badge whenever the worktree's branch was renamed locally only or its upstream was bound to a differently-named ref.

## IOS — iOS App

### IOS-1.x — Target and platform

**IOS-1.1** The application shall provide a universal iOS app, `GrafttyMobile`, targeting iOS 17 or later, running on both iPhone and iPad form factors with layouts forked on `horizontalSizeClass`. (iOS 17 is the minimum because the app uses Swift's `@Observable` macro, which requires iOS 17 at runtime.)

**IOS-1.2** All iOS business logic (views, stores, session management, terminal bridging) shall live in the SwiftPM library target `GrafttyMobileKit`. The iOS .app bundle shall live in a separate Xcode project at `Apps/GrafttyMobile/GrafttyMobile.xcodeproj` that depends on `GrafttyMobileKit` by local package reference.

**IOS-1.3** Wire-format types shared between `GrafttyMobile` and the `GrafttyKit` web server — `SessionInfo`, `WebControlEnvelope` — shall live in a shared library target `GrafttyProtocol`, imported by both targets. This ensures a breaking JSON-shape change is a compile-time error on both sides.

**IOS-1.4** While the iOS application is installed, it shall appear on the home screen and in the app switcher as "Graftty" (via `CFBundleDisplayName`) and shall use the same app icon as the macOS application, sourced from the shared master `Resources/AppIcon.png`. The Xcode target, `.xcodeproj`, on-disk sources directory, and bundle identifier keep the `GrafttyMobile` name internally so `Bundle.main.bundleIdentifier` checks, keychain service strings, and the `GrafttyMobileKit` SPM target continue to work unchanged — "GrafttyMobile" is the codebase's internal handle, "Graftty" is the user-facing brand on both platforms.

### IOS-2.x — Discovery and host storage

**IOS-2.1** The application shall provide a QR-code scanner (`AVFoundation`) that accepts any URL matching `^(http|https)://<host>(:\d+)?/?$` as a new saved host. A QR payload failing this parse shall keep the scanner open and present a non-dismissing toast `QR did not contain a Graftty URL`.

**IOS-2.2** The application shall provide manual URL entry as an equivalent alternative to the QR scanner, reaching the same `HostStore.add(_:)` entry point.

**IOS-2.3** The application shall persist the saved-host list to a JSON file in `~/Library/Application Support/<bundleID>/hosts.json`, written atomically on each mutation. Each host record shall carry `{id, label, baseURL, lastUsedAt, addedAt}`. Keychain was initially specified here, but a saved host contains no secret (just URL, label, and timestamps), and iOS-simulator Keychain access requires a signing context that ad-hoc-signed Xcode builds without a `DEVELOPMENT_TEAM` cannot obtain (every `SecItemAdd` returns `errSecMissingEntitlement`, -34018). File storage works identically on simulator and device and upgrades cleanly to a per-field Keychain split when we later persist a secret (e.g., a bearer token).

**IOS-2.4** The macOS application's Settings pane shall render the current Base URL (as already composed by `WebURLComposer.baseURL(host:port:)`) as a scannable QR code alongside the existing copy/open actions (`WEB-1.12`). When the server status is not `.listening`, the QR-code area shall render a placeholder explaining why (e.g., "Tailscale unavailable").

**IOS-2.5** `HostStore.init` shall not perform filesystem I/O — neither reading `hosts.json` nor creating its parent directory. The picker view shall populate the store by `await store.loadIfNeeded()` from a SwiftUI `.task` modifier, so the JSON read + decode runs after the first frame commits rather than during view-tree construction on the launch path. While `store.hasLoaded` is false, `HostPickerView` shall suppress the "No saved hosts yet." copy so a user with persisted hosts does not see a flicker of the empty-state text in the brief window between view appearance and the detached read landing back on the main actor. Mutations (`add` / `update` / `delete` / `deleteAll`) shall guard with a synchronous `ensureLoaded()` fallback so a user-initiated mutation that races ahead of the async load cannot overwrite persisted state with an empty `next` list. The `~/Library/Application Support/<bundleID>/` parent directory shall be created lazily on first `write(_:)` (idempotent `createDirectory(withIntermediateDirectories:)`), so a launch that performs no mutation makes no directory-creation syscalls.

### IOS-3.x — Authentication

**IOS-3.1** On cold launch, the application shall display a full-screen lock overlay until `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)` resolves successfully. While locked, no saved hostnames, session names, or terminal contents shall be visible.

**IOS-3.2** When the application enters the background, it shall record the wall-clock timestamp. When it foregrounds, if ≥5 minutes have elapsed since that timestamp, the application shall re-prompt per `IOS-3.1`.

**IOS-3.3** On authentication denial or cancellation, the application shall remain locked with a retry button; no UI behind the lock shall become interactive.

**IOS-3.4** During pre-main launch, the application's `LaunchScreen.storyboard` shall render a uniform `systemGroupedBackgroundColor` background with no foreground image and no branded color, so the visual transition from pre-main into the first frame is seamless. The first visible frame after pre-main is the lock overlay (`IOS-3.1`), which paints `.regularMaterial` over the host picker's `List` (whose default background is `systemGroupedBackground`). Matching the launch backdrop to the post-launch lock state's underlying color eliminates the launch → blur → list color flash that a branded launch image would otherwise introduce. Per Apple's HIG, the launch screen is a shell that resembles the first screen, not a branding splash.

### IOS-4.x — Session fetching and rendering

**IOS-4.1** When the user selects a saved host, the application shall issue `GET <baseURL>/worktrees/panes` and render the response as a **worktree** picker grouped by `WorktreePanes.repoDisplayName` (one row per running worktree, not one row per pane). This differs from the web client's flat session list (`WEB-5.4`) because the mobile flow is drill-down — worktree → pane tree → single pane — rather than flat selection.

**IOS-4.2** When `GET /sessions` returns a non-2xx status or a body that fails to decode as `[SessionInfo]`, the application shall render an error banner displaying the status code (or "malformed response") and a manual retry button. A 403 response shall instead render `Not authorized — is this device on your tailnet?` with a link that opens the Tailscale iOS app.

**IOS-4.3** When the user selects a session, the application shall open a `URLSessionWebSocketTask` at `<ws-or-wss>://<host>:<port>/ws?session=<urlEncoded name>` and attach it to an `InMemoryTerminalSession` from `libghostty-spm` rendered by `GhosttyTerminal.TerminalView`.

**IOS-4.4** On WebSocket open, the application shall send an initial `{"type":"resize","cols":<n>,"rows":<m>}` text frame derived from the terminal view's first-layout viewport, before forwarding any user input. This mirrors `WEB-5.3`.

**IOS-4.5** Server-sent binary WebSocket frames shall be forwarded to `InMemoryTerminalSession.receive(_:)` unmodified. User input emitted by libghostty via the `writeHandler` callback shall be sent as a binary WebSocket frame, mirroring `WEB-3.4` and `WEB-5.2`.

**IOS-4.6** On subsequent terminal resizes (viewport change, keyboard appearance, rotation), the application shall send a `{"type":"resize",...}` text frame matching the new viewport, mirroring `WEB-5.3`.

**IOS-4.7** When the user selects a saved host, the application shall issue `GET <baseURL>/ghostty-config` and, if the response is a non-empty 2xx body, pass it to `TerminalController.shared.updateConfigSource(.generated(text))` before mounting any `TerminalPaneView`. A missing or empty response is a non-fatal condition — the client shall fall back to `libghostty-spm`'s default configuration. The endpoint is a concatenation of the user's on-disk Ghostty configs (`$XDG_CONFIG_HOME/ghostty/config`, then `~/Library/Application Support/com.mitchellh.ghostty/config`) in the same priority order the Mac app applies them at launch, so terminals render with the same fonts, theme, and colors as the desktop.

**IOS-4.8** While a pane is mounted, the application shall hide the navigation bar (`.toolbar(.hidden, for: .navigationBar)`) and extend the terminal beneath every safe-area edge (`.ignoresSafeArea()`) — top (under the notch), bottom (under the home indicator), and the left/right safe-area strips in landscape. libghostty renders its configured background color to the full view bounds, so the unsafe regions pick up the terminal's own background rather than the SwiftUI default. The user returns to the worktree detail via the system edge-swipe-back gesture rather than an explicit button.

**IOS-4.9** The application shall display a floating keyboard button at the bottom-trailing corner of the pane view with three states:

**IOS-4.10** When the user selects a worktree from the picker (`IOS-4.1`), the application shall present a second screen rendering the worktree's pane split tree faithfully to the Mac sidebar's layout: each split respects its `direction` (horizontal/vertical) and `ratio`; each leaf is a tappable tile labelled with the pane's current title (or the session name when no title has been set yet). Tapping a tile pushes the fullscreen terminal for that session.

**IOS-4.11** When the user taps a pane tile, the application shall open a fullscreen terminal view for that session — a single `TerminalPaneView` with the navigation bar hidden and the terminal extending beneath the top safe area (`IOS-4.8`). The WebSocket is opened on view appear and closed on view disappear; system edge-swipe-back returns to the worktree detail.

**IOS-4.12** While the worktree-detail screen is rendering live pane previews (`IOS-4.10`), each `PaneTile` shall own its own `TerminalController` whose font-size is computed dynamically from the tile's geometry (`tileWidth / serverCols × monospaceAspect`) so the server's grid renders at scale 1 within the tile. The font is updated via `setTerminalConfiguration().fontSize(_)` whenever the tile width or the server's column count changes — including device rotation, since landscape gives each tile a different width. The preview shall not apply a runtime `scaleEffect` driven by libghostty's reported `cellWidthPoints`: that value is shared with the fullscreen view (`IOS-4.11`), which renders at a much larger font, so a feedback-loop safety-net would oscillate or progressively shrink the preview when the user navigates between the tile and fullscreen. Preview legibility is sacrificed for fit: previews communicate pane shape and live activity, not readable text. The fullscreen view (`IOS-4.11`) keeps the iOS-scaled font as it remains the primary read surface.

**IOS-4.13** When GrafttyMobile constructs a `TerminalController` from the Mac-provided Ghostty config (`IOS-4.7`), it shall not install libghostty-spm's built-in light/dark `TerminalTheme` overlay. UIKit trait changes may still report the phone's `.light` or `.dark` color scheme to libghostty, but the rendered config shall continue to use the Mac config's background, foreground, palette, and theme-derived colors rather than switching to GhosttyTerminal's default Alabaster/Afterglow themes.

**IOS-4.14** When a worktree's pane layout is a single leaf, the worktree-detail screen shall render a static labeled tile rather than a live terminal preview, and shall not open a preview WebSocket for that pane.

**IOS-4.15** When the fetched Ghostty config specifies a single `theme =` value (not a `light:X,dark:Y` pair), the application shall force `overrideUserInterfaceStyle` on the terminal container view to match that theme's appearance so that libghostty-spm's `traitCollectionDidChange` → `setColorScheme` path never substitutes the system-default appearance over the user's explicit choice.

**IOS-4.16** When the mobile client decodes a `WorktreePanes` payload from a server that predates the sidebar-mirror fields (state, branch, isMainCheckout, prBadge, stats, attentionText), the application shall fall back to safe defaults — empty branch, `.running` state, no PR badge, no stats, no attention — rather than fail decoding, so a version mismatch in either direction keeps the mobile picker functional.

**IOS-4.17** When the user selects a worktree from the picker (`IOS-4.1`) and that worktree's pane layout is a single leaf, the application shall push the fullscreen terminal for that pane directly onto the navigation stack, bypassing the worktree-detail screen (`IOS-4.10`). The system edge-swipe-back gesture and the in-app back button (`IOS-5.5`) shall return the user to the worktree picker.

**IOS-4.18** While a `SessionClient` is operating as a worktree-detail pane preview (`IOS-4.10`, `IOS-4.12`), the application shall not claim PTY size-leadership. Bytes emitted by libghostty in the preview controller shall be discarded rather than forwarded to the server, and layout-driven resize callbacks shall not produce `WebControlEnvelope.resize` frames. Size-leadership remains a property exclusive to the focused fullscreen pane (`IOS-6.5`).

**IOS-4.19** While a `PaneTile` already has a `TerminalController` whose font was last sized from a real `serverGrid.cols`, the application shall not re-apply a font computed from the `PanePreviewFontSizing.defaultColumns` fallback when the underlying `SessionClient` is replaced and its new `serverGrid` is briefly nil (background↔foreground, navigate-away-and-back, or any pool rebuild). The previously-applied font shall be preserved until the new client's first `grid` envelope arrives, so the preview does not visibly grow on every refresh before the server's size-poller (`WebSession.startSizePoller`) emits the first `grid`.

**IOS-4.20** While the user pull-to-refreshes the worktree picker (`IOS-4.1`), the application shall not blank the already-loaded list to a loading placeholder; the refresh shall re-fetch in place so the SwiftUI `.refreshable` host view remains mounted and the gesture completes without error.

**IOS-4.21** When the user taps a pane child row beneath a multi-leaf worktree in the worktree picker (`IOS-4.1`), the application shall push the fullscreen terminal for that pane directly onto the navigation stack, bypassing the worktree-detail screen (`IOS-4.10`). The system edge-swipe-back gesture returns the user to the worktree picker.

### IOS-5.x — Multi-pane layout

**IOS-5.4** When multiple panes exist, only one pane shall be focused at a time. The keyboard accessory bar and hardware keyboard routing shall deliver input only to the focused pane.

**IOS-5.5** While a session's terminal is rendered full-screen (navigation bar hidden per the fullscreen layout), the application shall overlay a translucent back-button in the top-left that pops the current session off the `NavigationPath`, returning the user to the worktree detail they drilled in from. The button shall be rendered as a chevron inside an `.ultraThinMaterial` circle at a fixed 44×44pt tap target, padded 12pt from the top and leading edges so it floats above the terminal content without being clipped by the device's notch / rounded corners. The system edge-swipe gesture remains available but is not discoverable, so this overlay is the primary affordance.

**IOS-5.6** While the iOS client is not the size-leader (before the first leadership-claim event per `IOS-6.5`) and the server-announced grid's column count exceeds what fits in the device's container at the configured (iOS-scaled) font size, the application shall override the terminal controller's font size so that `serverCols × cellWidth ≤ containerWidth`, render the pane at the full container width with no horizontal `ScrollView`, and never wrap a line. The override font size shall be computed as `(containerWidth / serverCols) × safetyScale / monospaceAspect`, mirroring `PanePreviewFontSizing`. When `serverCols` is not yet known, the application shall leave the base config font in place.

### IOS-6.x — Input

**IOS-6.1** While the software keyboard is visible, the application shall render a compact terminal control bar above the keyboard. The v1 bar shall expose, at minimum: Esc, Tab, Ctrl-C, Ctrl-D, ↑, ↓, ←, →, submit Return, insert literal LF, and Hide Keyboard. These controls shall send explicit PTY bytes through `SessionClient` rather than relying on UIKit text entry: Esc=`0x1B`, Tab=`0x09`, Ctrl-C=`0x03`, Ctrl-D=`0x04`, arrows=`ESC [ A/B/D/C`, submit Return=`0x0D`, and literal LF=`0x0A`.

**IOS-6.2** libghostty-spm's `TerminalView` shall remain the primary owner of terminal rendering and hardware-keyboard key-event translation for every pane. Ordinary software-keyboard text shall use the app-owned `UIKeyInput` path in `IOS-6.6` so committed text is sent as raw PTY input instead of paste text. The application shall additionally publish a `UIKeyCommand` table solely for **application-level** shortcuts that must be intercepted before the terminal sees them (e.g., Cmd-\\ to split on iPad, Cmd-1…9 to switch visible sessions). `UIKeyCommand` shall not be used to re-implement general terminal chord translation.

**IOS-6.3** When the outbound keystroke pipe (`SessionClient.box.onBytes`) receives a payload consisting of exactly one LF byte (`0x0A`), the application shall translate it to a single CR byte (`0x0D`) before sending it to the server. This reconciles iOS's soft-keyboard Return — which UIKit delivers as LF via `UIKeyInput.insertText("\n")` — with the CR convention that physical terminals send on Return and that TUIs (Claude Code, readline, etc.) interpret as "submit." Without this translation, tapping Return on the iOS keyboard inserts a literal newline into the TUI's input buffer instead of submitting the current line, and there is no way to produce a submit keystroke from the soft keyboard. The rule is narrowed to a *standalone* single-byte LF so that multi-byte payloads with embedded newlines (pastes from the clipboard, programmatic text insertion) pass through unchanged and preserve their own line structure.

**IOS-6.4** When the user taps the terminal control bar's "Insert newline" control, the application shall send a single literal LF byte (`0x0A`) to the remote session, bypassing the `IOS-6.3` LF→CR rule via `SessionClient.insertNewline()`. This is the only way to insert a multi-line boundary into a TUI prompt from the iOS soft keyboard after Return has been reserved for submission.

**IOS-6.5** When the iOS client receives a leadership-claim event (the first keystroke, the first pinch-begin gesture above the IOS-6.11 scale threshold, or the first long-press-begin gesture on the terminal pane), the client shall set `isSizeLeader = true` and send a `WebControlEnvelope.resize(cols, rows)` to the server with its last-measured viewport. Subsequent libghostty-reported layout changes shall be forwarded to the server. A passive tap shall not claim leadership.

**IOS-6.6** While a terminal pane is focused on iOS, ordinary software-keyboard text shall be captured by GrafttyMobile's own `UIKeyInput` responder and forwarded to the remote PTY as raw UTF-8 bytes via `SessionClient.sendSoftwareKeyboardText(_:)`, rather than through libghostty's `TerminalSurface.sendText(_:)` path. A single software-keyboard newline shall be translated to CR (`0x0D`) per `IOS-6.3`, and software-keyboard delete shall send DEL (`0x7F`). This prevents normal typing from being wrapped in bracketed-paste delimiters (`ESC [ 200 ~` / `ESC [ 201 ~`) that prompt-driven TUIs can display as stray `[200~` text.

**IOS-6.7** While a terminal pane is rendered in the iOS app, GrafttyMobile shall prevent libghostty-spm's built-in `TerminalInputAccessoryView` from appearing by suppressing both `UITerminalView.inputAccessoryView` and `UITerminalView.canBecomeFirstResponder` at the UIKit ObjC dispatch path. With `canBecomeFirstResponder` returning false, libghostty's `touchesBegan`-driven `becomeFirstResponder()` is a no-op, so GrafttyMobile's `UIKeyInput` proxy wins the keyboard responder race and the GhosttyKit accessory bar never mounts. The only visible software-keyboard accessory row shall be GrafttyMobile's terminal control bar (`IOS-6.1`).

**IOS-6.8** While a terminal pane is rendered in the iOS app, libghostty-spm's built-in pan-to-scroll and pinch-to-zoom gestures on `UITerminalView` shall remain functional. The iOS scaffolding shall not place an interaction-blocking overlay above `UITerminalView`: the `UIKeyInput` proxy responsible for software-keyboard text (`IOS-6.6`) shall be hit-test transparent so touches reach `UITerminalView`'s gesture recognizers underneath.

**IOS-6.9** While the iOS software keyboard is visible, the application shall raise the fullscreen terminal layout so its bottom edge sits at or above the keyboard's top edge rather than under it. SwiftUI's automatic `.keyboard` safe-area avoidance does not engage reliably while the first responder is the `UIViewRepresentable`-wrapped `UIKeyInput` proxy from `IOS-6.6` — SwiftUI's focus system is unaware of the proxy, so the avoidance machinery skips the layout. The application shall instead observe `UIResponder.keyboardWillChangeFrameNotification`, compute the keyboard end-frame's vertical intersection with the screen, and apply that height as an explicit `.padding(.bottom, …)` on the fullscreen layout so the terminal — and the `IOS-6.1` control bar overlaid at the bottom — both ride above the keyboard's top edge.

**IOS-6.10** When the iOS client claims size-leadership (per `IOS-6.5`), the font size currently applied to the terminal controller shall remain in effect as the new baseline — including any active auto-fit override from `IOS-5.6` / `IPAD-2.5`. The application shall stop driving the font from `TerminalWidthLayout.decide` for that session from that point forward; libghostty's pinch-to-zoom (`IOS-6.8`) shall mutate font from this baseline.

**IOS-6.11** The pinch-driven leadership claim from `IOS-6.5` shall fire only on pinch gestures whose scale departure from 1.0 exceeds a small threshold (~5%), so accidental two-finger touches (during scroll, near-tap) do not silently claim leadership.

**IOS-6.12** while a pane is in selection mode (IOS-11.4 pan-extends a live selection), the leadership-claim pinch recognizer shall be disabled — a mid-selection pinch shall not flip the server's PTY dims out from under the selection geometry.

**IOS-6.13** (first-frame claim resilience): when a gesture fires `claimLeadershipIfNeeded` before any viewport callback has populated `lastIOSViewport`, the claim shall be retained and re-attempted at the next viewport so the user's intentional gesture is not silently dropped.

**IOS-6.14** (gesture wiring): the `onLeadershipClaimGesture` callback shall fire when the pinch recognizer transitions to `.began` with a scale departure above the gate threshold — verifies the handler→callback plumbing that the unit tests for `LeadershipPinchGate` and `SessionClient.claimLeadershipIfNeeded` do not cover.

### IOS-7.x — Lifecycle

**IOS-7.1** When the application enters the background, it shall close every active `URLSessionWebSocketTask` with WebSocket close code 1000 (normal closure) and tear down every `InMemoryTerminalSession`. The server's response (SIGTERM to each `zmx attach` child per `WEB-4.5`) leaves the zmx daemon alive per `ZMX-4.4`, so reconnect picks up the same session.

**IOS-7.2** When the application foregrounds and the biometric gate is satisfied (either the ≥5 min path with re-prompt per `IOS-3.2` or the within-5-min fast path), the application shall re-fetch `/sessions` for each host whose panes were previously active and then re-dial every pane whose session name is still present in the response, re-mounting its `TerminalView`. Per `PERSIST-4.1` the application does not persist scrollback itself; whatever the zmx daemon still has is what the user sees.

**IOS-7.3** When a previously active pane's session name is absent from the fresh `/sessions` response (e.g., the worktree was stopped on the Mac while the iOS app was backgrounded), the application shall mark that pane as `sessionEnded` with a non-retryable banner and shall not open a WebSocket for it. The banner shall offer "Back to sessions" as the only action.

**IOS-7.4** On WebSocket failure (upgrade failure, read/write error, or close frame not initiated by the app) for a pane whose session name is still listed in `/sessions`, the application shall display a per-pane "disconnected" banner with "Reconnect" and "Back to sessions" buttons. While the host view is visible, the application shall retry automatically with exponential backoff: the delay starts at 1 second, doubles after each successive failure, and is capped at 30 seconds. Each successful connect resets the delay to 1 second. When the host view is not visible, no automatic retry shall occur.

### IOS-8.x — Non-goals (recorded for future specs)

**IOS-8.1** The v1 iOS app shall not support connecting to non-Graftty SSH/mosh hosts.

**IOS-8.2** The v1 iOS app shall not forward terminal mouse events, OSC 52 clipboard reads, or Kitty graphics/keyboard-protocol sequences. (Mirrors `WEB-6.2`.)

**IOS-8.4** The v1 iOS app shall not persist terminal scrollback on the device. On reconnect, it renders whatever the zmx daemon's buffer still contains.

**IOS-8.5** The v1 iOS app shall not use push notifications for PR status, build completions, or session events.

### IOS-9.x — Creating worktrees from the iOS client

**IOS-9.1** The worktree-picker screen (`IOS-4.1`) shall display an "Add Worktree" action as a primary toolbar item. Tapping it shall present a modal sheet collecting the fields required by `POST /worktrees` (`WEB-7.2`): a repository picker populated from `GET /repos` (hidden when only one repo is tracked), a worktree-name field, and a branch-name field.

**IOS-9.2** Both the worktree-name and branch-name fields shall sanitize input live with `WorktreeNameSanitizer` (same allowed set as the Mac sheet and the web client: `A-Z a-z 0-9 . _ - /`, consecutive disallowed chars collapsing to a single `-`). The branch field shall auto-mirror the worktree-name field until the user types a branch that differs, at which point the mirror breaks and further edits to the worktree field stop overwriting the branch. On submit, both fields shall be trimmed of leading/trailing whitespace plus `-` and `.` (matching the macOS sheet's `submitTrimSet` and the web client's `trimForSubmit`). The sheet's Create button shall be disabled while either field is empty after trim.

**IOS-9.3** On submit, the application shall issue `POST <baseURL>/worktrees` with `{repoPath, worktreeName, branchName}` and handle the response per the server's status-code contract (`WEB-7.3` / `WEB-7.4`):

**IOS-9.4** When `GET /repos` returns an empty list, the sheet shall render an empty-state "No repositories tracked — open a repository in Graftty on the Mac first." and shall not show the input fields. The iOS app shall not implement repository-adding (the Mac-side file-picker + security-scoped bookmark mint has no iOS equivalent, same stance as `WEB-7.7`).

**IOS-9.5** While a `POST /worktrees` call is in flight, the Create button shall be replaced by an in-flight indicator, the Cancel button and both input fields shall be disabled, and the repository picker shall be disabled. Once the call resolves (success or failure) all controls shall re-enable.

**IOS-9.6** When the user swipes a worktree row in `WorktreePickerView` that is neither the repo's main checkout nor in an in-flight state (`.creating` / `.deleting`), the application shall reveal a trailing destructive action labeled "Delete" for non-stale rows and "Dismiss" for `.stale` rows. Rows for the main checkout or for in-flight worktrees shall expose no swipe action.

**IOS-9.7** When the user taps the trailing destructive action revealed by `IOS-9.6`, the application shall present a SwiftUI confirmation dialog before any HTTP call. The dialog title shall be "Delete Worktree?" for non-stale rows and "Dismiss Worktree?" for `.stale` rows; the dialog body shall mirror the Mac's NSAlert copy ("This will delete the worktree but not the branch." / "This will remove this stale entry from Graftty."). On cancel, no request shall be issued.

**IOS-9.8** If `POST /worktrees/delete` returns 409 with `forceAllowed: true`, then the application shall present a Force Delete confirmation surfacing the `shortStatus` field as the dialog body, and shall retry the request with `force: true` only on user confirmation. A 409 with `forceAllowed: false` (or 4xx/5xx of any other shape) shall present a non-retryable error toast and shall not loop.

**IOS-9.9** While rendering grouped worktrees in `WorktreePickerView`, the application shall preserve the order of `repoDisplayName` first-occurrences in the `GET /worktrees/panes` response rather than sort the group keys alphabetically, so the mobile picker's repo order matches the user's Mac sidebar order.

### IOS-10.x

**IOS-10.1** While `scenePhase` is `.inactive` or `.background`, the application shall tear down active WebSocket connections and unmount live `TerminalPaneView` instances so libghostty's display link stops.

**IOS-10.2** When `WorktreeDetailView` is active with a multi-leaf layout, the application shall create a live preview `SessionClient` for every leaf so each pane tile renders a real-time preview rather than a static title.

**IOS-10.3** When a `SessionClient` has received no PTY bytes and processed no user input for ≥ `idleThreshold` (default 30s), the application shall transition its `renderActivity` to `.idle`.

**IOS-10.4** While a `SessionClient` is in `.idle`, the corresponding view shall display a static snapshot of the last live frame in place of `TerminalPaneView`, with a tap target that resumes `.active`.

**IOS-10.5** When a `SessionClient` is `.idle` and a new PTY byte is received, the application shall transition its `renderActivity` to `.active` and remount `TerminalPaneView` within one runloop tick.

**IOS-10.6** When `SessionClient.live` is constructed with role `.preview`, the application shall set the client's `idleThreshold` shorter than the fullscreen default so off-input preview panes flip to the static-snapshot state and free libghostty's display link, while still letting fresh PTY bytes wake the live renderer per IOS-10.5.

### IOS-11.x

**IOS-11.1** When the user long-presses a focused terminal pane, the application shall present a `UIEditMenuInteraction` menu at the touch point containing **Select**, **Select All**, and (when `UIPasteboard.general.hasStrings` is true at menu-build time) **Paste**.

**IOS-11.2** When the user taps **Select** in the long-press menu, the application shall ask libghostty to word-select the cell under the long-press point by synthesizing a LEFT mouse-down/up pair plus a second click within libghostty's double-click window, and shall enter selection mode for that pane.

**IOS-11.3** When the user taps **Select All** in the long-press menu, the application shall invoke libghostty's `select_all` binding action via `surface.performAction("select_all")` and shall enter selection mode for that pane with the visible viewport highlighted.

**IOS-11.4** While in selection mode, the application shall extend the live selection by forwarding pan-gesture positions to `surface.sendMousePos(...)`, and libghostty's built-in pan-to-scroll recognizer on the underlying `UITerminalView` shall be disabled until selection mode exits.

**IOS-11.5** When selection mode is active and the user lifts their finger after Select / Select All / extend, the application shall present a second `UIEditMenuInteraction` menu anchored near the selection rect containing **Copy** and **Cancel**.

**IOS-11.6** When the user taps **Copy**, the application shall extract the active selection via `surface.readSelection()`, write the result to `UIPasteboard.general.string`, clear libghostty's selection, and exit selection mode. If `readSelection()` returns nil or empty, the pasteboard shall not be modified.

**IOS-11.7** When the user taps **Cancel**, taps outside the highlighted selection, or presses a key on the terminal control bar while in selection mode, the application shall clear libghostty's selection and exit selection mode without modifying the pasteboard.

**IOS-11.8** When the user taps **Paste** in the long-press menu, the application shall read `UIPasteboard.general.string` and, when non-empty, send it via `SessionClient.sendPaste(_:)`. An empty or absent clipboard string shall be a silent no-op.

**IOS-11.9** `SessionClient.sendPaste(_:)` shall wrap the payload in `ESC [ 200 ~` and `ESC [ 201 ~` and emit the wrapped sequence as a single binary WebSocket frame. The single-byte LF→CR translation of `IOS-6.3` shall not apply to this path; the payload's own line endings shall be preserved verbatim.

**IOS-11.10** Selection mode shall be per-pane state owned by the focused pane's `TerminalSelectionController`. Selection in one pane shall not affect the selection state of any other pane.

**IOS-11.11** While a pane is rendered as a worktree-detail preview tile (`IOS-4.10`), the long-press selection menu shall not be installed; tapping the tile shall continue to open the fullscreen pane per `IOS-4.21`. Guaranteed by `.allowsHitTesting(false)` applied to the inner `TerminalPaneView` in `paneContent` — `TerminalInputContainerView`'s long-press gesture recogniser never receives touches. The `onPasteRequested` closure is also left `nil` at the `TerminalPaneView` call site.

### IOS-12.x

**IOS-12.1** While a remote client is attached to the zmx session, a fresh attach with a libghostty viewport callback but no user input shall not resize the zmx PTY. This is the Mac mirror of IOS-6.5 — the PTY cols/rows persist until the Mac user engages or the last remote client detaches.

## IPAD — iPad Layout

### IPAD-1.x — Root Layout and Sidebar

**IPAD-1.1** When `horizontalSizeClass == .regular`, the iPad application shall render `IPadRootLayout` (NavigationSplitView, 2-column) in place of the compact-width `NavigationStack`.

**IPAD-1.2** While `IPadRootLayout` is presented, the sidebar shall display a host-switcher `Menu` in its system navigation bar's `.topBarLeading` placement (not as a row beneath the nav bar) adjacent to the system sidebar-toggle button, showing the selected host's label and a trailing chevron, and tapping it shall present an anchored dropdown containing each saved host (with a checkmark on the currently-selected one) and an "Add Host…" action. Anchoring at the leading edge keeps the menu out of the trailing `+` action item's space even at narrow column widths, and living in the toolbar avoids the column-gesture conflict the previous row-with-Menu had — tapping a Menu wrapped in a tappable row could collapse the sidebar.

**IPAD-1.3** While `IPadRootLayout` is presented, the sidebar shall render `WorktreeListContent` extracted from `WorktreePickerView`, preserving `WorktreePickerGrouping`, swipe actions, PR badges, attention pills, and divergence gutter.

**IPAD-1.4** When the user taps a pane child row in the sidebar at iPad regular width, the application shall set `IPadAppState.focusedPaneId` to that leaf's `sessionName` without pushing a new navigation stack frame.

**IPAD-1.5** While `IPadRootLayout` is presented, the sidebar's row text (worktree name, secondary branch label, type icon for closed/creating/deleting states, pane `↳` arrow and pane title, divergence-gutter ahead side, and the Section repository header) shall be colored from `appState.theme` rather than system label colors, sharing the same opacity ladder the Mac sidebar applies via `GhosttyThemeColors.sidebarPrimaryText`/`sidebarSecondaryText`/`sidebarDimIcon`/`sidebarStaleText`/`paneArrow`/`paneTitle`.

**IPAD-1.6** While `IPadRootLayout` is presented, the sidebar and detail shall render side-by-side as a permanent two-column layout (NavigationSplitView with `.balanced` style and an initial `columnVisibility` of `.all`) rather than the system's overlay default, mirroring the Mac sidebar's always-visible behavior.

**IPAD-1.7** While `IPadRootLayout`'s detail column is rendering a session via `SingleSessionView`, the application shall keep the terminal edge-to-edge (`.ignoresSafeArea()`) but render the navigation bar with a transparent background (`.toolbarBackground(.hidden, for: .navigationBar)`) instead of hiding it. The system-provided sidebar-toggle button then floats over the terminal — preserving full terminal height while keeping a way to re-show a collapsed sidebar. The iPhone compact path keeps the existing fullscreen chrome (hidden navigation bar).

**IPAD-1.8** While `IPadRootLayout` is presented, the application shall apply the shared `themedSidebarSurface(_:)` view modifier (defined in `GrafttyProtocol`) to the sidebar container so the host's ghostty `sidebarBackground` (a ±6% luminance shift of the terminal background) reads through a transparent `List`, and shall apply `.preferredColorScheme(theme.isDark ? .dark : .light)` to the layout so the system-rendered sidebar-toggle button picks contrast that matches the sidebar's text color. The Mac sidebar consumes the same `themedSidebarSurface` helper, single-sourcing the surface treatment.

**IPAD-1.9** The sidebar row contract shall be the cross-platform `WorktreePanes` (in GrafttyProtocol): both the Mac sidebar (via the server-side projection in `GrafttyApp.swift`'s `setWorktreePanesProvider`) and the iPad sidebar (decoded from `GET /worktrees/panes`) flatten onto the same shape — state, displayName, displayBranch, isMainCheckout, prBadge, stats (with baseRef), attentionText, pane layout. The state-icon mapping (`running=green`, `stale=yellow`, otherwise `sidebarDimIcon`) is single-sourced as `GhosttyThemeColors.worktreeStateIcon(_:)` and consumed by both targets. `WorktreeWireState.hasOnDiskWorktree` mirrors the Mac `WorktreeState.hasOnDiskWorktree` so cross-platform sidebar code can gate on-disk-only behavior without referring to the server-only enum.

**IPAD-1.10** While `IPadRootLayout` is presented, the detail column's `.ignoresSafeArea(...)` shall be restricted to `[.top, .bottom]` edges so the terminal extends under the navigation bar and home indicator but never bleeds across the leading column boundary into the sidebar's region — the sidebar shifts the terminal horizontally rather than overlapping it.

**IPAD-1.11** When the sidebar is collapsed (`IPadAppState.columnVisibility != .all`) and any worktree carries attention (worktree-scoped `attentionText`, or any pane leaf with `attentionText`), the application shall surface a red attention dot in the detail column's leading toolbar position next to the system sidebar-toggle button — so a user with a hidden sidebar sees something needs review without re-opening it. The dot is derived from `IPadAppState.anyWorktreeHasAttention`, which `onWorktreeListChanged` maintains from each `GET /worktrees/panes` snapshot.

**IPAD-1.12** While `IPadRootLayout` is presented, the sidebar shall render a 1pt trailing border at `appState.theme.foreground.opacity(0.15)` along its leading-of-detail edge so the column boundary reads as a thin divider, matching the Mac sidebar's automatic `NSSplitView` divider. The overlay ignores safe areas so the border runs the full sidebar height including under the nav bar and home indicator.

**IPAD-1.13** While `IPadRootLayout` is presented, each worktree's row + its pane child rows shall be packed into a single `List` row (`VStack(spacing: 0)`) with `.listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))` and `.listRowSeparator(.hidden)`, so the iOS sidebar-list style's default per-row padding doesn't compound between panes — the vertical spacing between pane rows is controlled entirely by the outer block's insets, not by accumulating list-row defaults on every leaf.

**IPAD-1.14** While `IPadRootLayout` renders a worktree's pane rows, the worktree-scoped `attentionText` (from `graftty notify`) shall be displayed on the worktree's first pane row when that leaf has no pane-scoped `attentionText` of its own; the worktree title row never displays an attention pill on iPad. Pane-scoped `attentionText` (from shell-integration `COMMAND_FINISHED` events) stays on its own pane row as before.

**IPAD-1.15** While `IPadRootLayout` renders a worktree row whose `displayBranch` differs from its `displayName`, the branch label shall appear on a second line directly beneath the display name (caption font, dimmed via `theme.sidebarSecondaryText`) rather than running inline on the same row — so a long worktree name + long branch name don't squish each other or push the trailing divergence gutter off the edge at narrow sidebar widths. When `displayBranch` equals `displayName` (or is empty), the secondary line is omitted and the row stays single-line.

**IPAD-1.16** While `IPadRootLayout` is presented, the worktree row whose `path == appState.selectedWorktreePath` shall render with a rounded-rectangle highlight at `theme.foreground.opacity(0.16)` spanning the worktree row and its pane rows (Mac-parity active-block treatment), and the pane row whose `leaf.sessionName == appState.focusedPaneId` shall use the brightest brightness bucket via `theme.paneTitle(isFocusedPane: true, isActiveWorktree: true, …)` plus a bolded arrow + semibold title. Non-focused panes in the active worktree use the active-worktree bucket; panes in other worktrees use the inactive bucket.

**IPAD-1.17** When a `GET /worktrees/panes` snapshot still contains the selected worktree but its layout no longer includes `IPadAppState.focusedPaneId`'s session name, the application shall reset `focusedPaneId` to the first leaf of the worktree's current layout (or nil if the worktree has no panes).

### IPAD-2.x — Multi-Pane Detail View

**IPAD-2.1** While a worktree is selected and the iPad layout is regular-width, the detail column shall render `MultiPaneDetailView` over the worktree's `PaneLayoutNode`.

**IPAD-2.2** When `MultiPaneDetailView` renders a `.split(.horizontal, ratio, left, right)`, the application shall render an `HStack` with the two children proportionally sized by `ratio` and a draggable `Divider` between them.

**IPAD-2.3** When `MultiPaneDetailView` renders a `.split(.vertical, ratio, left, right)`, the application shall render a `VStack` with the two children proportionally sized by `ratio` and a draggable `Divider` between them.

**IPAD-2.4** When `MultiPaneDetailView` renders a `.leaf(sessionName, …)`, the application shall render a `PaneLeafView` that owns its own `terminal` channel via `TerminalChannelPool`.

**IPAD-2.5** While an iPad pane-layout leaf is not the size-leader and the server-announced grid's column count exceeds the leaf's allotted width at the configured (iOS-scaled) font size, the application shall apply the same font-fit policy as `IOS-5.6` (per-leaf), rendering each leaf's pane at the full leaf width with no horizontal `ScrollView`.

**IPAD-2.6** When `IPadAppState.focusedPaneId == leaf.sessionName`, the application shall render a 2pt focus ring around the corresponding `PaneLeafView`.

**IPAD-2.7** When the user drags a split's divider, the application shall update a per-iPad-client divider-ratio override map keyed by the tree path to that split, without sending any RPC to the host.

### IPAD-3.x — Focused-Pane Toolbar

**IPAD-3.1** When `MultiPaneDetailView` has a focused leaf and the soft keyboard is hidden, the application shall overlay a `FocusedPaneToolbar` on the focused leaf containing Split Right, Split Down, Swap, and Close icons.

**IPAD-3.2** When the soft keyboard becomes visible, the application shall hide the `FocusedPaneToolbar` and yield its position to the terminal control bar.

**IPAD-3.3** When the user taps Split Right or Split Down in the toolbar, the application shall send a `pane_control` RPC with `type: "split"`, `target` set to the focused leaf's `sessionName`, and `direction` set to `"horizontal"` or `"vertical"` respectively.

**IPAD-3.4** When the user taps Close in the toolbar, the application shall send a `pane_control` RPC with `type: "close"` and `target` set to the focused leaf's `sessionName`.

**IPAD-3.5** When the user taps Swap in the toolbar, the application shall send a `pane_control` RPC with `type: "swap"`, `source` set to the focused leaf's `sessionName`, and `target` selected per the swap-target policy resolved in milestone M7 (see design doc §12 Open Question #3).

**IPAD-3.6** When a `pane_control` RPC returns `409 Conflict`, the application shall not present an error toast and shall rely on the next `panes_state` snapshot to reflect actual server state.

### IPAD-4.x — Live-Channel Budget

**IPAD-4.1** While the iPad layout is presented, the application shall cap concurrent open `terminal` channels at 8 leaves across all visible panes.

**IPAD-4.2** When opening a new `terminal` channel would exceed the IPAD-4.1 cap, the application shall close the least-recently-focused open `terminal` channel and render its leaf as an `IdleSnapshotView` from the last frame the channel held.

**IPAD-4.3** When the user taps an `IdleSnapshotView` placeholder leaf, the application shall open a fresh `terminal` channel for that leaf, potentially evicting a different least-recently-focused leaf per IPAD-4.2.

**IPAD-4.4** When a leaf is closed (via `pane_control: close` or removed from a `panes_state` snapshot), the application shall close its `terminal` channel and drop it from the LRU budget.

### IPAD-5.x — Background and Foreground Lifecycle

**IPAD-5.1** When the application enters the background, the application shall close all `terminal` channels, close the `panes_state` channel, close the DataChannel, and tear down the `RemoteHostConnection`.

**IPAD-5.2** When the application foregrounds and the biometric gate is satisfied, the application shall rebuild the `RemoteHostConnection` from signaling onward, completing a fresh Noise handshake before opening any channel.

**IPAD-5.3** When the application foregrounds, the application shall re-open the `panes_state` channel before re-opening any `terminal` channel, so the splittree shape is current before deciding which leaves to attach.

**IPAD-5.4** When a previously-focused leaf is no longer present in the foreground-fresh `panes_state` snapshot, the application shall surface a "Pane no longer running" banner on the detail column with a "Back to sidebar" action.

### IPAD-6.x — Host Switching

**IPAD-6.1** When the user selects a different host from the host-switcher menu, the application shall reset `selectedWorktreePath` and `focusedPaneId`, dismiss the menu, and re-fetch worktrees and theme for the new host.

**IPAD-6.2** While the new host's worktree fetch is in progress, the sidebar shall show ProgressView and the detail column shall show `ContentUnavailableView`.

### IPAD-7.x — Compact-Width Fallback

**IPAD-7.1** When `horizontalSizeClass == .compact`, the application shall render the existing compact `RootView` flow (NavigationStack: HostPicker → WorktreePicker → SingleSessionView) without any iPad layout components.

**IPAD-7.2** When `horizontalSizeClass` transitions between `.regular` and `.compact`, the application shall preserve `selectedHostId`, `selectedWorktreePath`, and `focusedPaneId` so the user lands on the equivalent leaf in the new layout.

## TEAM — Agent Teams

### TEAM-1.x — Settings & Enablement

**TEAM-1.1** The application shall provide a Settings tab named "Agent Teams" containing one boolean toggle, *Enable agent teams*, persisted via `@AppStorage("agentTeamsEnabled")` (Bool, default false).

**TEAM-1.2** While `agentTeamsEnabled` is false, the application shall not write any team event rows to the inbox and `graftty team hook` shall return no-op responses; the agent team feature is fully gated by this flag.

**TEAM-1.5** `agentTeamsEnabled` plus the `teamEventRoutingPreferences` JSON struct (see TEAM-1.8) supersede the previous coupled `teamPRNotificationsEnabled` flag. Inbox events are written only when `agentTeamsEnabled` is true; per-event recipient sets are taken from the matrix in `teamEventRoutingPreferences`.

**TEAM-1.6** The Agent Teams Settings pane shall expose **two** user-editable Stencil-templated text areas, each pre-populated with a non-empty default (`DefaultPrompts.sessionPrompt` and `DefaultPrompts.eventPrompt`) registered into `UserDefaults.standard` at app startup so non-binding readers see the same default until the user overrides. Clearing a field to the empty string disables that prompt. The first, `teamSessionPrompt` (`@AppStorage("teamSessionPrompt")`, String) — rendered once at session start against the `agent` context; only `agent.branch` and `agent.lead` are meaningful at session start (`agent.this_worktree` and `agent.other_worktree` are always `false`), and the pane's variable-list disclosure deliberately omits the latter two. The rendered text is appended after a blank line to the auto-generated team-aware instructions text returned by `graftty team hook`. The second, `teamPrompt` (`@AppStorage("teamPrompt")`, String) — rendered per inbox-row write against the full four-field `agent` context evaluated against the recipient agent, plus a top-level `body` variable carrying the original event body and a top-level `event` object exposing `event.type` (the wire-format event-type string, e.g. `"merge_state_changed"`), `event.attrs` (the event's attribute dictionary), and `event.body` (a duplicate of the top-level `body`). The rendered output is stored in the inbox row's `agent_prompt` field. If the template does not reference `{{ body }}` the renderer appends `\n\n{{ body }}` to the template before rendering, so templates that pre-date the `body` variable continue to surface the event content to the agent. Hook-context delivery (via `TeamHookRenderer.format`) emits `agent_prompt` when present and falls through to `body` otherwise; the inbox row's `body` field stores the event content unchanged so consumers other than the agent (activity log, `graftty team inbox`, watcher wake summaries) read it without the template prelude. Both templates use the same `agent` struct shape: `branch` (String), `lead` (Bool), `this_worktree` (Bool), `other_worktree` (Bool). The previously-defined `teamLeadPrompt` and `teamCoworkerPrompt` AppStorage keys are removed.

**TEAM-1.8** The Agent Teams Settings pane shall render a 4×3 matrix of toggles (rows: PR state changed / PR merged / CI conclusion changed / Mergability changed; columns: Root agent / Worktree agent / Other worktree agents). Each cell binds to one bit of a `RecipientSet` field on the persisted `TeamEventRoutingPreferences` `Codable` struct. Defaults: state-changed/CI/mergability → worktree only; merged → root only. The matrix is rendered as its own Section between the main toggle and the prompt sections.

**TEAM-1.9** When `PRStatusStore` fires a transition that produces a routable team event (`pr_state_changed`, `ci_conclusion_changed`, `merge_state_changed`), the application shall consult `teamEventRoutingPreferences` for the corresponding row and write one inbox row per recipient resolved by `TeamEventRouter.recipients`. The router classifies `pr_state_changed` events with `attrs.to == "merged"` as the *PR merged* row; all other `pr_state_changed` events are the *PR state changed* row. Single-worktree repos (no team) receive the event only when the relevant row's `Worktree agent` cell is set; root and other-worktree cells are no-ops there.

**TEAM-1.10** When the application starts, the application shall migrate any legacy `channelRoutingPreferences` UserDefaults string into `teamEventRoutingPreferences` and clear the old key. The migration is idempotent: if `teamEventRoutingPreferences` is already populated, the migration leaves the new value alone and only clears the old key. If neither key is present the migration is a no-op.

**TEAM-1.11** When `EventBodyRenderer.split` renders the per-event `teamPrompt` template, the application shall expose a top-level `event` object on the render context with `event.type` (wire-format event-type string), `event.attrs` (the event's attribute dictionary), and `event.body` (the original event body) — letting templates branch on the event type via a chained `{% if event.type == "…" %} … {% elif … %}` block (Stencil has no `case`/`switch` tag).

### TEAM-2.x — Team Identity & Membership

**TEAM-2.1** A *team* is implicit in any `RepoEntry` with two or more `WorktreeEntry` children, while `agentTeamsEnabled` is true. A repo with one worktree (or with team mode off) has no team and no team-aware behavior.

**TEAM-2.2** A team's *member name* for a given worktree shall be `WorktreeNameSanitizer(worktree.branch)`, the same sanitization rule used for new worktree names per `GIT-5.1`.

**TEAM-2.3** A team's *lead* shall be the worktree where `worktree.path == repo.path` (the repository's main checkout per `LAYOUT-2.3`). All other worktrees of the team are *coworkers*.

**TEAM-2.4** Team identity, membership, and lead designation are derived live from `AppState`. The application shall not persist any team-specific data beyond `agentTeamsEnabled` itself.

**TEAM-2.5** TeamMembershipEvents.fireJoined writes a team_member_joined inbox row through the dispatcher.

### TEAM-3.x — Team-Aware Hook Instructions

**TEAM-3.2** The application shall render the *lead variant* of the team-aware instructions when the viewer's worktree is the team's lead (per TEAM-2.3), and the *coworker variant* otherwise. Both variants name the team (by repo display name), the agent (by member name), and list the team's other members by name and worktree.

**TEAM-3.3** Two separate user templates contribute to what each agent sees. **Hook session-start instructions**: the auto-generated team-aware text from `TeamInstructionsRenderer` is followed (after a blank line) by the rendered `teamSessionPrompt` template, evaluated against the agent's session-start context. If the template is empty, whitespace-only after render, or fails to render (Stencil throws), the appended portion is omitted and a render-failure error is logged via `os_log`. **Per inbox-row delivery**: the rendered `teamPrompt` template is rendered into each inbox row's body at write time per recipient (followed by a blank line, prepended to the event body). The same render/empty/failure rules apply. This covers every team event written via `TeamEventDispatcher.dispatchRoutableEvent` — PR/CI/merge events as routed by the matrix, plus `team_message`, `team_member_joined`, and `team_member_left`.

### TEAM-4.x — `graftty team` CLI

**TEAM-4.1** The application shall provide a CLI subcommand group `graftty team` with two subcommands: `msg <member-name> "<text>"` and `list`.

**TEAM-4.2** `graftty team msg <member-name> "<text>"` shall resolve the calling process's worktree via `WorktreeResolver.resolve()`, look up the team for that worktree, find a teammate matching `<member-name>`, and write a `team_message` inbox row addressed to that teammate's worktree with `from.member = <calling-worktree's member name>` and body `<text>`. The CLI shall exit non-zero with a stderr message if (a) team mode is disabled, (b) the calling worktree has no team, or (c) `<member-name>` is not a teammate of the caller. In case (c) the error shall list the current teammates' member names.

**TEAM-4.3** `graftty team list` shall print one line per team member of the caller's team to stdout: `<member-name>  branch=<branch>  worktree=<path>  role=<lead|coworker>  running=<true|false>`. The first printed line shall be a header `team=<repo-display-name>  members=<count>`. The CLI shall exit non-zero with a stderr message if team mode is disabled or the calling worktree has no team.

### TEAM-5.x — `team_*` Inbox Events

**TEAM-5.1** When team_message is dispatched, the application shall append exactly one inbox row addressed to the named recipient.

**TEAM-5.2** The application shall write a `team_member_joined` inbox row when a worktree is added to a team (a new worktree appears in a team-enabled repo, or a single-worktree repo gains a second worktree). Routing: addressed to the team's lead's worktree only. Attributes: `team`, `member` (joiner's member name), `branch`, `worktree` (joiner's path).

**TEAM-5.3** The application shall write a `team_member_left` inbox row when a worktree is removed from a team (the worktree is deleted, or the team-enabled repo collapses to one worktree). Routing: addressed to the team's lead's worktree only. Attributes: `team`, `member` (departing member's name), `reason` (`removed` or `exited`).

**TEAM-5.4** When constructing a system endpoint, the application shall produce an endpoint with member='system', worktree=<repoPath>, and runtime=nil.

**TEAM-5.5** When PRStatusStore fires pr_state_changed (non-merged), the dispatcher shall write one inbox row per recipient resolved via the prStateChanged matrix row.

**TEAM-5.6** When pr_state_changed has attrs.to == 'merged', the dispatcher shall use the prMerged matrix row.

**TEAM-5.7** When a worktree joins a team-enabled repo, the dispatcher shall append one team_member_joined inbox row addressed to the lead.

**TEAM-5.8** When a worktree is removed from a team-enabled repo (collapsing to one worktree), the dispatcher shall still append one team_member_left inbox row addressed to the lead.

**TEAM-5.9** When pr_state_changed fires in a single-worktree repo, the dispatcher shall write the row to the subject worktree iff .worktree is in the matrix row.

**TEAM-5.10** When team_message is dispatched and the user's teamPrompt template is non-empty, the dispatcher shall write the inbox row with the original event body and the rendered per-recipient prompt stored separately as agentPrompt.

**TEAM-5.11** When team_broadcast is dispatched, the dispatcher shall write one team_message inbox row per non-sender team member, each rendered against that recipient's agent context.

**TEAM-5.12** When a routable event is dispatched and the user's teamPrompt template is non-empty, the dispatcher shall write the inbox row with the original event body intact and the rendered per-recipient prompt stored separately as agentPrompt.

### TEAM-7.x — Team Activity Log Window

**TEAM-7.1** When the user invokes the *Window → Team Activity Log* command, the application shall open the Team Activity Log window for the focused worktree's team — and shall disable the command when the focused selection has no team (single-worktree repo, no selection, or `agentTeamsEnabled` off).

**TEAM-7.2** Right-clicking a team-enabled worktree row in the sidebar shall include a *Show Team Activity…* item that opens the activity-log window for that team. The routing key derives from the same `(teamID, teamName)` pair the Window menu command uses, so both entry points target the same per-team `WindowGroup` instance.

**TEAM-7.3** While the Team Activity Log window is open for a team, the application shall display every `TeamInboxMessage` for that team in chronological order, refreshing live as new rows land in the inbox.

**TEAM-7.4** When the messages.jsonl file appended-to is the team's inbox, the application shall emit the parsed message list to the registered observer callback within one second of the append, including when the file is created after the observer started watching.

**TEAM-7.6** While the Team Activity Log window is open, the application shall expose a "Reveal in Finder" affordance whose target is the team's `messages.jsonl` file.

### TEAM-8.x — Legacy Channel Cleanup

**TEAM-8.1** When the application starts, the application shall best-effort run `claude mcp remove graftty-channel`, ignoring non-zero exit and logging failure.

**TEAM-8.2** When the application starts, the application shall delete `~/.claude/.mcp.json` if it exists and contains no MCP server entries other than `graftty-channel`.

**TEAM-8.3** When the application starts, the application shall delete `~/.claude/plugins/graftty-channel` if present.

**TEAM-8.4** When the application starts, if `defaultCommand` contains `--dangerously-load-development-channels server:graftty-channel`, the application shall strip the substring (with any adjacent leading whitespace), write the cleaned value back to `defaultCommand`, and present a one-shot informational `NSAlert` describing the change.

### TEAM-9.x — Stop Hook Filtering

**TEAM-9.1** When a Stop-event hook command (`graftty team hook <runtime> stop` or the async `graftty team watch-inbox <runtime>`) is invoked and the JSON the runtime wrote to the hook's stdin contains an `agent_id` string — Claude Code's marker that this Stop fired inside a Task subagent context rather than for a top-level agent turn — the CLI shall short-circuit before doing any per-Stop work: no `teamHook` socket message is sent, no `InboxWatcher` is spawned, and neither the worktree's `"<Agent> needs input"` attention overlay nor the macOS user notification fires. Without this filter, every Task subagent end both produces a spurious 'needs attention' alert and leaks a long-running watcher process while the top-level agent is still working.

## EDITOR — Editor Integration

### EDITOR-1.x

**EDITOR-1.1** When the user cmd-clicks a file path in a terminal pane, the application shall open the file via the configured editor.

**EDITOR-1.2** If the configured editor is a known CLI editor, the application shall split the source pane to the right and run the editor in the new pane.

**EDITOR-1.3** If the configured editor is a GUI app, the application shall dispatch the file to the app via NSWorkspace, without creating a new pane.

**EDITOR-1.4** If the cmd-clicked target carries a `:line(:col)` suffix, the application shall strip the suffix before resolving the path, and shall pass the line number to known CLI editors using `+<line>`.

**EDITOR-1.5** If the cmd-clicked target is not a file path, the application shall open it via NSWorkspace (preserving existing handling for `http(s)`, `mailto:`, `ssh:`, and other URL schemes).

**EDITOR-1.6** If the cmd-clicked target resolves to a path that does not exist on disk, the application shall emit a system beep and not open anything.

**EDITOR-1.7** When no editor is explicitly configured in Settings, the application shall use the value of `$EDITOR` as defined by the user's login shell.

**EDITOR-1.8** If `$EDITOR` is unset, the application shall fall back to `vi`.

## REMOTE — Secure Remote Access

### REMOTE-1.x — Identity and Pairing

**REMOTE-1.1** When a host starts remote access for the first time, the application shall generate and persist a host identity key before accepting pairing requests.

**REMOTE-1.2** When a client pairs with a host, the application shall require a matching verification code and host-side confirmation before storing the client as a trusted peer.

### REMOTE-2.x — Authenticated Attach

**REMOTE-2.1** When a remote transport reconnects, the host shall require a fresh authenticated attach handshake before writing any bytes to the PTY.

### REMOTE-3.x — Revocation

**REMOTE-3.1** If a trusted peer is revoked on the host, then all active secure channels from that peer shall close and future attach requests from that peer shall be rejected.

### REMOTE-4.x — Port Tunnels

**REMOTE-4.1** If a client requests a port tunnel without host approval under the default ask-each-time policy, then the host shall reject the channel open request before connecting to the target port.

**REMOTE-4.2** If a client requests a port tunnel to a non-loopback target under the default policy, then the host shall reject the channel open request.

### REMOTE-5.x — Retired Endpoints

**REMOTE-5.1** When a client attempts to use the retired `/ws` terminal endpoint, the host shall reject the request without attaching to a PTY.

### REMOTE-6.x — panes_state Channel

**REMOTE-6.1** A trusted peer with `terminalControl: .allowed` authenticates successfully.

**REMOTE-6.2** Immediately after accepting a `panes-state@graftty.dev` channel, the host shall send a `{"type":"snapshot","worktrees":[…]}` frame containing the current `[WorktreePanes]` array.

**REMOTE-6.3** While a `panes-state@graftty.dev` channel is open, on any change to the host's `AppState.repos[*].worktrees`, splittree, attention state, or PR status, the host shall send a fresh `{"type":"snapshot","worktrees":[…]}` frame.

**REMOTE-6.4** When the channel closes (channelInactive), the handler shall cancel the subscription so the snapshot pipeline stops firing.

### REMOTE-7.x — pane_control Channel

**REMOTE-7.1** When a client opens a channel with `channel_type: "pane_control"` over an authenticated `RemoteHostConnection`, the host shall accept the channel only when the requesting trusted peer holds the `terminal_control` capability. (Enforced at userauth: a peer with `terminalControl: .disabled` is rejected.)

**REMOTE-7.2** When the host receives a `pane_control` request `{"type":"split","target":<sessionName>,"direction":<axis>}`, the host shall replace the leaf whose `sessionName == target` with a new split node of the requested `direction` whose left/top child is the original leaf and whose right/bottom child is a freshly-spawned leaf, applied on the main actor, and reply `{"ok":true}` on success.

**REMOTE-7.3** When the host receives a `pane_control` request `{"type":"close","target":<sessionName>}`, the host shall destroy the surface for the leaf whose `sessionName == target` and reply `{"ok":true}` on success.

**REMOTE-7.4** When two `pane_control` requests target the same leaf concurrently, the host shall immediately reply to the second request with `{"ok":false,"code":"conflict","message":<human-readable>}` and continue processing only the first request. The conflict window for a target leaf ends once the first request's resulting `panes_state` snapshot has been emitted.

**REMOTE-7.5** While the host services `pane_control` requests, the application shall route mutations through an injected mutator callback without giving `PaneControlHandler` a reference to `AppState`, enforcing per-client focus sovereignty by construction.

**REMOTE-7.6** If a trusted peer is revoked while a `pane_control` channel is open, the channel shall close and subsequent open requests from the revoked peer shall be rejected.

### REMOTE-8.x — SSH session layer

**REMOTE-8.1** While accepting a remote attach, the host shall negotiate SSH KEX restricted to the `curve25519-sha256` algorithm and reject any other KEX proposal.

**REMOTE-8.2** When the host receives a userauth request, the host shall accept only the `publickey` method and reject `password` and `keyboard-interactive` immediately.

**REMOTE-8.3** When the host receives a userauth request, the host shall identify the peer solely by the offered public key against `TrustedPeerStore` and shall ignore the username field.

**REMOTE-8.4** When the client receives a host key during SSH KEX, the client shall verify the key against `PinnedHostStore` and abort the connection on mismatch.

**REMOTE-8.5** While accepting a remote attach, the host shall negotiate SSH transport protection from swift-nio-ssh's bundled AEAD ciphers (`aes256-gcm@openssh.com`, `aes128-gcm@openssh.com`) and shall not negotiate any weak or legacy cipher.

## URL — Worktree URL Handler

### URL-1.x

**URL-1.0** A deep-link target parsed from a `graftty://open` URL: either a specific pane session (which implies its worktree and pane) or a repo+worktree pair (worktree-level, pane-agnostic).

**URL-1.1** The application shall parse a graftty://open URL into a worktree-or-session deep-link target, accepting a session name, a repo+worktree pair, and preferring the session when both are present.

**URL-1.2** Given a worktree-panes snapshot, the application shall resolve a deep-link target to a worktree path (and, for a session target, the matching pane session name), or report which part was unknown.

**URL-1.3** Given the tracked repos, the application shall resolve a deep-link target to a worktree path (and, for a session target, the owning pane slot), or report which part was unknown.

### URL-2.x

**URL-2.1** When the macOS app opens a `graftty://open` URL that resolves to a tracked worktree, the application shall select that worktree, focus the resolved pane when one is present and the worktree is running, and bring the app to the foreground.

### URL-3.x

**URL-3.1** When the iOS app opens a graftty://open URL that resolves against the connected host's worktree-panes snapshot, the application shall select that worktree and focus the resolved pane session.

## AGENT — AGENT

### AGENT-1.x

**AGENT-1.0** Liveness of a claude agent session as reported by `claude agents --json`. The JSON exposes exactly two states; richer "needs input"/"completed" states live only in the interactive Agent View, not the JSON.

**AGENT-1.1** When the registry refreshes, the application shall key each claude session's busy/idle status by the `ZMX_SESSION` it inherited from its Graftty pane.

**AGENT-1.2** If a claude session reports no `ZMX_SESSION` (it is not running inside a Graftty pane), then the application shall omit it from the liveness map.

**AGENT-1.3** paneSlot(forSessionName:) resolves a zmx session name to its pane slot or nil when unmatched.

**AGENT-1.4** When multiple claude sessions resolve to the same pane, the application shall report that pane as busy if any of its sessions is busy.

### AGENT-2.x

**AGENT-2.1** While a pane has a live notify attention ping, the application shall render that ping in preference to any derived busy/idle status.

**AGENT-2.2** While a pane has no live attention ping, the application shall surface a busy claude session by rendering the pane title in italic (not a capsule), and render the title upright when idle.

**AGENT-2.3** If the `claude agents --json` invocation fails or returns unparseable output, then the application shall produce an empty liveness map without crashing.

**AGENT-2.4** When a slow poll is superseded by a newer refresh, the application shall drop the stale poll's late write so the newer result wins.

### AGENT-3.x

**AGENT-3.1** When an agent-stop event carries a `paneSessionName` resolving to a live pane, the application shall attach the "needs input" attention to that pane rather than the worktree.

**AGENT-3.2** If an agent-stop event has no pane session (the agent is not in a Graftty pane), then the application shall fall back to worktree-scoped "needs input" attention.

**AGENT-3.3** When the user activates an agent-stop desktop notification, the application shall focus the pane whose session produced it, falling back to the worktree's first pane when the session no longer resolves.

**AGENT-3.4** When a pane's agent transitions to busy, the application shall clear that pane's agent-stop "needs input" attention (leaving user notify pings and command-finished markers), so busy and needs-input are mutually exclusive.

### AGENT-4.x

**AGENT-4.1** When `graftty notify` is given `--session <zmx-session>`, the application shall target that pane's attention overlay.

**AGENT-4.2** When `graftty notify` is given no target and `$ZMX_SESSION` is set, the application shall target the caller's pane.

**AGENT-4.3** When `graftty notify` is given no target and `$ZMX_SESSION` is unset, the application shall target the current worktree (unchanged behavior).

**AGENT-4.4** If `graftty notify` is given both `--session` and `--worktree`, then the application shall reject the invocation with a validation error.

## MEM — MEM

### MEM-1.x

**MEM-1.1** While more than 4 worktrees have live surfaces, the application shall evict the least-recently-selected worktree's surfaces.

**MEM-1.2** When a worktree's surfaces are evicted via the LRU budget, the application shall preserve its zmx sessions, pane-to-session mapping, titles, PWDs, and rehydration state so re-selection re-attaches transparently.

**MEM-1.3** When a worktree is stopped, removed, has its repo removed, or transitions to stale, the application shall drop it from the LRU budget.

**MEM-1.4** When a worktree whose surfaces were evicted is re-selected, the application shall re-create its surfaces via the same rehydration path used at cold launch.

**MEM-1.5** When the LRU budget evicts a worktree, the application shall not kill its zmx sessions or fire `paneClosed` callbacks.

**MEM-1.6** When the LRU budget evicts a worktree's surfaces, the application shall capture each evicted pane's current grid size (columns, rows, pixel width, pixel height) for use on subsequent re-attach.

**MEM-1.7** When a previously-evicted pane is re-attached via the rehydration path, the application shall spawn its outer `zmx attach` PTY with `initialSize` equal to the captured grid size, so the underlying shell PTY winsize remains stable across the evict / re-attach cycle.

**MEM-1.8** When a previously-evicted pane is re-attached via the rehydration path, the application shall pre-size the new libghostty surface to the captured pixel dimensions before starting its host-managed backend, so the first post-layout resize event is a no-op when the layout container has not changed.

**MEM-1.9** When a previously-evicted pane is destroyed (rather than re-attached), the application shall drop its captured grid size from the cache.

## PERF — PERF

### PERF-1.x

**PERF-1.1** The window chrome tint bridge shall not reapply AppKit `NSWindow` chrome mutations when SwiftUI re-runs `updateNSView` for the same window and unchanged Ghostty theme; repeated no-op application can feed a SwiftUI/AppKit transaction loop while a terminal is otherwise idle.

**PERF-1.2** The window chrome tint bridge shall reapply AppKit `NSWindow` chrome mutations when either the Ghostty theme changes or SwiftUI moves the bridge view to a different host window.

**PERF-1.3** The stats polling loop shall skip closed worktrees during its recurring local recompute cadence; a closed worktree exists on disk but has no live terminal surface, and repeatedly running local git scans for every tracked-but-closed row makes CPU scale with sidebar history rather than active work.

**PERF-1.4** When macOS hides the app, the selected worktree's terminal surfaces shall be marked not visible so libghostty can stop repaint work that is not reaching the screen.

**PERF-1.5** When macOS unhides the app, the selected worktree's terminal surfaces shall be marked visible again so the terminal gets a clean repaint.

**PERF-1.6** Pane title metadata changes shall not publish through TerminalManager itself, so title churn does not invalidate MainWindow observers.

**PERF-1.7** Multiple rendered pane-title changes in one debounce window shall coalesce into one sidebar invalidation.

## PORTS — PORTS

### PORTS-1.x

**PORTS-1.1** When a pane's foreground process is non-shell, the application shall scan that process subtree's TCP listening sockets every 2 seconds.

**PORTS-1.2** While a pane's foreground process is the shell, the application shall not invoke `lsof` for that pane.

**PORTS-1.3** Tick during in-flight scan is dropped (single-flight invariant)

**PORTS-1.4** Lsof failure leaves snapshot empty

### PORTS-2.x

**PORTS-2.1** Same PID with IPv4 + IPv6 binds on same port collapses to one binding

**PORTS-2.2** Single IPv4 loopback listener becomes one .loopback binding

**PORTS-2.3** Forked workers collapse to one binding with lowest PID

### PORTS-3.x

**PORTS-3.1** While a pane has at least one `PortBinding`, the application shall render one `PortChip` per binding inline with the pane title.

**PORTS-3.2** PortChip icon name is `personalhotspot` for .loopback, `globe` for .lan

**PORTS-3.3** FlowLayout configuration drives wrap-with-indent layout

**PORTS-3.4** When a pane has an active `AttentionCapsule`, the application shall hide port chips for that pane until the capsule clears.

**PORTS-3.5** When the user clicks a `PortChip`, the application shall open `http://localhost:<port>/` via `NSWorkspace.shared.open`.

**PORTS-3.6** When a `PortChip` is hovered, the application shall display a tooltip reading `Open http://localhost:<port>/`.

**PORTS-3.7** When a `PortChip` renders a port number, the application shall display the digits without locale grouping separators (e.g., `:8080`, not `:8,080`).

### PORTS-4.x

**PORTS-4.1** Registered pane with no listeners produces empty bindings

**PORTS-4.2** Unregister drops the snapshot

**PORTS-4.3** When a pane is dragged to another worktree, the application shall preserve its registration and binding snapshot (`PaneSlotID` is stable).

**PORTS-4.4** Tick clears bindings when previous scan had them but new scan has none

**PORTS-4.5** When a pane is registered before its shell PID can be resolved (e.g., the zmx daemon log has not yet written the `pty spawned` line), the application shall record the pane as pending and re-attempt resolution on each scan tick until it succeeds; once resolved, the pane shall begin participating in scans.

## PROJECT — PROJECT

### PROJECT-1.x

**PROJECT-1.0** Each repository entry shall record whether its on-disk path is tracked by git.

**PROJECT-1.1** While a repository is not git-tracked, the application shall hide Add Worktree, Delete Worktree, and the PR-merged delete-offer affordance from its context menus.

**PROJECT-1.2** While a repository is not git-tracked, the application shall skip PR-status, remote-branch, and git-status polling for it.

**PROJECT-1.3** When the user selects Initialize Git Repository on a non-git repo's row, the application shall run `git init` + `git commit --allow-empty`, set `isGitTracked` to true, and rediscover its worktrees via `git worktree list --porcelain`.

**PROJECT-1.4** When WorktreeDiscovery.discover is invoked with a non-git-tracked repository, the application shall return exactly one synthesized DiscoveredWorktree with path equal to the repo path and branch \

**PROJECT-1.5** When decoding a repository entry that lacks the isGitTracked key, the application shall default it to true so pre-feature state.json blobs load unchanged.

### PROJECT-2.x

**PROJECT-2.1** When the Open on GitHub…/Open on GitLab… context-menu item is chosen, the application shall open https://<host>/<owner>/<repo> in the default browser.

**PROJECT-2.2** If a repo has no origin remote or the origin's provider is unsupported, then the application shall omit the forge item from the repo context menu.

**PROJECT-2.3** While a repo's origin resolves to a supported forge, the repo context menu shall include an Open on GitHub…/Open on GitLab… item opening the project URL.

**PROJECT-2.4** When origin detection resolves a repo's origin remote, the application shall publish the resolved HostingOrigin in PRStatusStore.originByRepo, omit repos whose detection returns nil, and prune entries for repos removed from the model.

## SSH — SSH

### SSH-1.x

**SSH-1.1** When `RTCDataChannel.sendData` returns false mid-loop in `OutboundRelayHandler.write` (SCTP backpressure on a multi-slice write), the handler shall close both the DataChannel AND the NIO embedded channel — the peer cannot safely continue interpreting bytes after a partial SSH frame.

**SSH-1.2** When `pendingInbound` accumulates more than 1 MiB without the embedded channel becoming active, `SSHNIOTransport` shall close the underlying DataChannel and transition to closed — bounding memory under a flooding peer.
