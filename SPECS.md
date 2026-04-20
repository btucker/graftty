# Espalier — EARS Requirements Specification

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

**LAYOUT-2.13** The application shall reject incoming OSC 2 titles that match either of two shapes: (a) trimmed value matching `^[A-Z_][A-Z0-9_]*=` (an uppercase identifier followed by `=`), or (b) containing the literal substring `GHOSTTY_ZSH_ZDOTDIR` anywhere in the title. Both shapes are command-echo leaks produced by ghostty's shell-integration `preexec` hook when the outer shell runs Espalier's injected `exec zmx attach …` bootstrap line; propagating them to the sidebar would display a 200+ character shell-command string as the pane's title until the inner shell's first prompt overwrites it. Shape (a) catches the pre-`ZMX-6.4` naked-env-assignment form; shape (b) catches the post-`ZMX-6.4` conditional form (`if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR=…; fi; ZDOTDIR=… exec zmx attach …`) and guards against any future bootstrap reshape that preserves the `GHOSTTY_ZSH_ZDOTDIR` marker. The previously stored title (if any) is retained; if none, the pane falls back to the LAYOUT-2.9 chain.

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

## 2. Worktree Entry States

### 2.1 State Definitions

**STATE-1.1** Each worktree entry shall have one of three states: closed, running, or stale.

**STATE-1.2** While a worktree entry is in the closed state, the sidebar shall display its type icon (house for the main checkout, branch for linked worktrees) in a dimmed foreground color.

**STATE-1.3** While a worktree entry is in the running state, the sidebar shall display its type icon tinted green.

**STATE-1.4** While a worktree entry is in the stale state, the sidebar shall display its type icon tinted yellow, with strikethrough text and grayed-out appearance on the label.

### 2.2 Attention Overlay

**STATE-2.1** A worktree entry in any state may additionally have a worktree-scoped attention overlay, and each of its panes may additionally have a pane-scoped attention overlay keyed by pane. Worktree-scoped overlays are driven by the CLI (`ATTN-1.x`); pane-scoped overlays are driven by per-pane shell-integration events (`NOTIF-2.x`).

**STATE-2.2** While a pane row has a pane-scoped attention overlay, the sidebar shall replace *that pane's* title text with the overlay's text rendered in a red capsule. Sibling pane rows are unaffected.

**STATE-2.3** While a worktree entry has a worktree-scoped attention overlay, the sidebar shall render its text in a red capsule on every pane row beneath the worktree that does not already have a pane-scoped overlay. Non-running worktrees (no pane rows) display no attention indicator.

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

**TERM-5.5** If `ghostty_surface_new` returns null (libghostty resource exhaustion, malformed config, or any internal rejection) when the application tries to create a terminal surface, the application shall skip the failed leaf and propagate a nil result to the caller rather than trap via `fatalError`. Callers shall treat nil as "surface creation failed": `splitPane` shall roll back its split-tree mutation so no dangling leaf is left behind; `addPane` (CLI `espalier pane add`) shall return a socket `.error("split failed")`; `createSurfaces` (worktree open) shall leave the leaf's surface dict entry empty so the view renders the `Color.black + ProgressView` fallback without crashing the app. Observed pre-fix: `espalier pane add --command ...` triggered a SIGTRAP inside `SurfaceHandle.init` whenever libghostty couldn't build the surface.

**TERM-5.6** When a terminal pane is removed (user close via Cmd+W, shell exit, CLI `espalier pane close`), the application shall promote `focusedTerminalID` to `remainingTree.allLeaves.first` ONLY if the removed pane was the currently-focused one. If a different pane was focused, `focusedTerminalID` shall stay on that pane — it's still present in the remaining tree, and the user's keystrokes should continue to route there. Pre-fix behavior (unconditional promotion to the first leaf) silently jumped focus whenever the user closed a pane other than their focused one, mirroring Andy's "furious when any tool kills a long-running shell unexpectedly" pain point in the focus-redirection dimension.

**TERM-5.7** When libghostty's `close_surface_cb` fires for a pane whose `SurfaceHandle` has already been torn down by Espalier (e.g. via `terminalManager.destroySurfaces(...)` during a `Stop Worktree` action), the application's close-event handler shall observe the missing surface handle and no-op rather than modifying the worktree's `splitTree`. Without this guard, the async close-event cascade that follows `Stop` would re-enter `closePane` for each leaf and strip them from the preserved split tree, emptying `splitTree` and violating `TERM-1.2`'s "re-open recreates the saved layout" contract. The guard applies only to library-initiated close events; user-initiated closes are covered by `TERM-5.8`.

**TERM-5.8** When the user explicitly invokes a pane close (`Cmd+W`, CLI `espalier pane close <id>`, or a context-menu Close action) against a leaf whose `SurfaceHandle` is absent — i.e. a phantom pane whose surface never created successfully because libghostty refused (OOM / resource pressure, `TERM-5.5`) — the application shall still remove the leaf from the worktree's `splitTree`. Without this, a phantom leaf is uncloseable: the sidebar renders a black / progress placeholder, `pane list` reports it, but every close path silently no-ops via `TERM-5.7`'s guard. The implementation seam is a `userInitiated` parameter on `closePane`: user paths pass `true` to bypass the handle guard; libghostty's async `close_surface_cb` passes `false` (default) so Stop cascades continue to preserve the tree.

**TERM-5.9** When `SurfaceHandle.setFrameSize` forwards a backing-pixel dimension to `ghostty_surface_set_size`, the conversion from `CGFloat` to `UInt32` shall be performed via a defensive clamp that maps `NaN` and values `≤ 1` to `1`, `+∞` and values `≥ UInt32.max` to `UInt32.max`, and all other finite values to their truncated `UInt32` representation. Naive `UInt32(max(1, Int(dim)))` traps on `NaN` and on out-of-`Int`-range values; SwiftUI `GeometryReader` has been observed to emit `.infinity` transiently during certain rebinding flows, and a trap on the view's layout pass crashes the whole process (every open pane dies). The helper is `SurfacePixelDimension.clamp(_:)` in EspalierKit so the rule is unit-testable without an NSView host.

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

### 4.2 Filesystem Monitoring

**GIT-2.1** While a repository is in the sidebar, the application shall watch the repository's `.git/worktrees/` directory for changes using FSEvents.

**GIT-2.2** When a change is detected in `.git/worktrees/`, the application shall re-run `git worktree list --porcelain` and reconcile the results against the current model.

**GIT-2.3** While a repository is in the sidebar, the application shall watch each worktree's directory path for deletion using FSEvents.

**GIT-2.4** While a repository is in the sidebar, the application shall detect every operation that moves a worktree's HEAD — including commits on the current branch, `checkout`, `switch`, `reset`, `merge`, and `rebase` — and surface each as a HEAD-reference change.

**GIT-2.5** While a repository is in the sidebar, the application shall watch `<repoPath>/.git/logs/refs/remotes/origin/` using FSEvents so that any operation which advances a remote-tracking ref — `git push` (the common `gh pr create` path), `git fetch`, and prune — surfaces as an origin-ref change. One watch per repository covers all linked worktrees, since they share the main checkout's git directory.

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

**GIT-3.12** When `GitWorktreeDiscovery.discover(repoPath:)` throws (missing `git` binary, non-repo path passed due to a stale state.json entry, subprocess exceeding the timeout, transient FS glitch), the application shall log the failure via `NSLog` at every call site in `EspalierApp` — `reconcileOnLaunch`, `worktreeMonitorDidDetectChange`, and `worktreeMonitorDidDetectBranchChange` — rather than swallow via `try?`. Analogue of `ATTN-2.7` / `PERSIST-2.2`. Without this, a transient discovery failure silently skips that repo's reconcile tick: Andy creates a new worktree, FSEvents fires, discover throws once, and the worktree never appears in the sidebar with no trail of why.

**GIT-3.13** When a worktree transitions to the `.stale` state — regardless of which FSEvents channel observed the disappearance (`worktreeMonitorDidDetectDeletion` for the worktree-directory watcher, or the reconcile-driven transitions in `reconcileOnLaunch` / `worktreeMonitorDidDetectChange` when `git worktree list --porcelain` stops listing the entry) — the application shall call `statsStore.clear(worktreePath:)` and `prStatusStore.clear(worktreePath:)` so the cached stats and PR status don't linger on the stale entry. Matches `GIT-4.10`'s rule for the explicit-remove path; the three stale-transition paths must be symmetric, otherwise a worktree made stale by reconcile keeps rendering its old PR badge until a Dismiss or Delete fires.

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

**ATTN-1.1** The application shall include a CLI binary (`espalier`) in the app bundle at `Espalier.app/Contents/Helpers/espalier`. The CLI is placed in `Contents/Helpers/` (not `Contents/MacOS/`) because on macOS's default case-insensitive APFS, the binary name `espalier` collides with the app's main executable `Espalier` if both are in the same directory. The Swift Package Manager product that builds this binary is named `espalier-cli` for the same reason; it is renamed to `espalier` when installed into the app bundle.

**ATTN-1.2** The CLI shall support the command `espalier notify "<text>"` to set attention on the worktree containing the current working directory.

**ATTN-1.3** The CLI shall support the flag `--clear-after <seconds>` to auto-clear the attention after a specified duration.

**ATTN-1.4** The CLI shall support the command `espalier notify --clear` to clear attention on the current worktree.

**ATTN-1.5** The CLI shall resolve the current worktree by walking up from `$PWD` looking for a `.git` file (linked worktree) or `.git` directory (main working tree). When normalizing `$PWD` before the walk, the CLI shall use POSIX `realpath(3)` semantics (physical path, `/tmp` → `/private/tmp`) rather than Foundation's `URL.resolvingSymlinksInPath` (logical path, which collapses the other direction). This must match the path form that `git worktree list --porcelain` emits — the same form the app's `state.json` stores — so the tracked-worktree lookup matches when the user's `$PWD` traverses a private-root symlink. Without this, `espalier notify` fails `"Not inside a tracked worktree"` from any `/tmp/*` or `/var/*` worktree even when the worktree is tracked.

**ATTN-1.6** If `espalier notify` is invoked with both a `<text>` argument and the `--clear` flag, then the CLI shall exit non-zero with a usage error rather than silently dropping the text and performing a clear.

**ATTN-1.7** If `espalier notify` is invoked with text that is empty or contains only whitespace characters (including tabs and newlines), then the CLI shall exit non-zero with a usage error rather than sending a visually-empty attention badge.

**ATTN-1.8** If `espalier notify` is invoked with `--clear-after` greater than 86400 seconds (24 hours), then the CLI shall exit non-zero with a usage error. Values at or below 86400 are accepted; values at or below zero are handled server-side per `STATE-2.8`.

**ATTN-1.9** If `espalier notify` is invoked with both `--clear` and `--clear-after`, then the CLI shall exit non-zero with a usage error. `--clear-after` applies only to notify messages; combining it with `--clear` is ambiguous and previously resulted in the `--clear-after` value being silently dropped.

**ATTN-1.10** If `espalier notify` is invoked with text longer than 200 Character (grapheme cluster) units, then the CLI shall exit non-zero with a usage error. Attention overlays are designed for short status pings rendered in a narrow sidebar capsule; large inputs (e.g. a piped `git log` or `ls -la`) blow up layout and drown the intended signal.

**ATTN-1.11** Each row of `espalier pane list` output shall be formatted as `<marker> <id><padding> <title?>` where `marker` is `*` for the focused pane or a space otherwise, `id` is right-padded to at least width 3 for typical layouts (so ids 1–99 align their titles at the same column), and exactly one space separates the id from the title regardless of id width — so ids ≥ 100 don't collide visually with their title. Panes with no title render without trailing whitespace. A whitespace-only title is treated the same as nil / empty (same blank-vs-content rule as `LAYOUT-2.14`) so the row clips cleanly rather than rendering `*  3      ` with trailing spaces where a label should be.

**ATTN-1.12** If `espalier notify` is invoked with text containing any Unicode Cc (control) scalar — line feed, carriage return, tab, bell, ANSI escape, DEL, null byte, or any other C0/C1 control — then the CLI shall exit non-zero with a usage error reading "Notification text cannot contain control characters (newlines, tabs, ANSI escapes, or other non-printable characters)". The sidebar capsule renders `Text(attentionText)` with `.lineLimit(1)` + `.truncationMode(.tail)`; newlines clip to the first line, tabs render at implementation-defined width, and ANSI escape sequences like `\e[31m` show up as literal glyphs (the ESC byte is invisible in SwiftUI Text, producing strings like `[31mred[0m`). All of those are data loss or visual garbage from the user's perspective. The server-side `Attention.isValidText` applies the same rejection (silently drops) as a backstop for raw socket clients (`nc -U`, web surface, custom scripts) bypassing the CLI.

**ATTN-1.13** If `espalier notify` is invoked with text whose scalars are entirely Unicode Format-category (Cf) and/or whitespace — e.g., `"\u{FEFF}"` (BOM), `"\u{200B}\u{200C}\u{FEFF}"` (mixed zero-width scalars) — then the CLI shall reject the message as `emptyText`. Swift's `whitespacesAndNewlines` trim strips some Cf scalars (ZWSP U+200B) but not others (BOM U+FEFF), producing a would-be zero-width badge; the extra allSatisfy check closes the gap. Mixed content that still carries at least one visible scalar (including ZWJ-joined emoji sequences like `👨‍👩‍👧`) remains valid. `Attention.isValidText` applies the same rejection server-side.

**ATTN-1.14** If `espalier notify` is invoked with text containing any Unicode bidirectional-override scalar — the embedding family (`U+202A`–`U+202C`), the override family (`U+202D`–`U+202E`), or the isolate family (`U+2066`–`U+2069`) — then the CLI shall reject the message as `bidiControlInText` with the user-visible error "Notification text cannot contain bidirectional-override characters (U+202A-U+202E, U+2066-U+2069) — they visually reverse the text in the sidebar". These scalars are Unicode Format (Cf) so they slip past both `ATTN-1.12`'s Cc-control check and `ATTN-1.13`'s all-Cf-invisible check when mixed with visible content; a notify like `"\u{202E}evil"` renders RTL-reversed in the sidebar capsule (the "Trojan Source" class of visual deception, CVE-2021-42574). RTL-natural text (Arabic, Hebrew) uses character-intrinsic directionality and does not use these override scalars, so it still validates cleanly. `Attention.isValidText` applies the same rejection server-side for raw socket clients that bypass the CLI.

### 5.2 Communication Protocol

**ATTN-2.1** The application shall listen on a Unix domain socket at `~/Library/Application Support/Espalier/espalier.sock`.

**ATTN-2.2** The CLI shall communicate with the application by sending JSON messages over the Unix domain socket.

**ATTN-2.3** The application shall support the following message types over the socket:
- Notify: `{"type": "notify", "path": "<worktree-path>", "text": "<text>"}`
- Notify with auto-clear: `{"type": "notify", "path": "<worktree-path>", "text": "<text>", "clearAfter": <seconds>}`
- Clear: `{"type": "clear", "path": "<worktree-path>"}`

**ATTN-2.4** The application shall set the environment variable `ESPALIER_SOCK` in each terminal surface's environment, pointing to the socket path.

**ATTN-2.5** The CLI shall read the `ESPALIER_SOCK` environment variable to locate the socket. If the variable is unset or set to an empty string, the CLI shall fall back to the default path `<Application Support>/Espalier/espalier.sock`. Treating empty as unset prevents a blank `ESPALIER_SOCK=` line (e.g. from a sourced `.env` file) from redirecting the CLI to a nonexistent socket at the empty path.

**ATTN-2.6** When the application receives a `notify` message over the socket whose text is empty or contains only whitespace characters, the application shall silently drop the message rather than render an invisible attention overlay. This backs up the CLI's ATTN-1.7 validation for non-CLI socket clients.

**ATTN-2.7** When `SocketServer.start()` fails during application startup, the application shall (a) log the error via `NSLog` (surfacing it in Console.app), (b) retain the error in `SocketServer.lastStartError` for in-process introspection, and (c) present a one-time `NotifySocketBanner` alert describing what broke and suggesting recovery steps (quit+relaunch, clear `ESPALIER_SOCK`). The banner mirrors the `ZmxFallbackBanner` pattern from `ZMX-5.2`. The app shell historically wrapped `start()` in `try?`, producing a running Espalier with a dead control socket and no diagnostic trail — ATTN-3.4 recovers this case at the CLI side, ATTN-2.7 surfaces the root cause at the app side upfront rather than waiting for the user to trip over the CLI.

**ATTN-2.8** The application's Unix-domain socket server shall call `listen(2)` with a backlog of 64, not the historical default of 5. A user scripting parallel `espalier notify` invocations (e.g. from a hook that fans out across a monorepo) can easily exceed 5 pending connections, and the extra backlog entries cost negligible kernel resources while preventing spurious `ECONNREFUSED` for the later clients.

**ATTN-2.9** Each accepted client connection shall have `SO_RCVTIMEO` set to 2 seconds before the server enters its read loop. Without this, a silent peer (a `nc -U` that connects but never writes, a crashed CLI client whose kernel-level connection lingers, etc.) pins the server's serial dispatch queue on a blocking `read(2)` indefinitely — and since `acceptConnection` shares that queue, every subsequent `espalier notify` hangs for the duration. 2 seconds mirrors the CLI's client-side timeout (`ATTN-3.3`); JSON notify/pane messages are ≤~1 KB over a local socket, so any well-behaved client finishes in milliseconds.

**ATTN-2.10** When a request-style socket message (`list_panes`, `add_pane`, `close_pane`) hands its handler to the main queue via `DispatchQueue.main.async`, the server shall wait at most `SocketServer.onRequestTimeout` (5 seconds in production) for the handler to return. If the handler has not completed within that window — main queue stalled by a modal dialog, heavy synchronous work, or a main-actor reentrancy bug — the server shall close the client fd without writing a response rather than pin its serial worker on `semaphore.wait()` indefinitely. The CLI's 2s client-side timeout (`ATTN-3.3`) then surfaces the event as a clean `socketTimeout`. The main-queue closure may still complete and write into the retained response box after the worker has returned; its `signal()` lands on a no-longer-awaited semaphore harmlessly.

### 5.3 Error Handling

**ATTN-3.1** If the application is not running, then the CLI shall print "Espalier is not running" and exit with code 1.

**ATTN-3.2** If the current working directory is not inside a tracked worktree, then the CLI shall print "Not inside a tracked worktree" and exit with code 1.

**ATTN-3.3** If the socket is unresponsive, then the CLI shall time out after 2 seconds, print an error, and exit with code 1.

**ATTN-3.4** If the control socket file exists on disk but `connect()` fails with `ECONNREFUSED`, then the CLI shall print "Espalier is running but not listening on `<path>`. Quit and relaunch Espalier to reset the control socket." and exit with code 1, rather than conflating this stale-listener case with `ATTN-3.1`'s "not running" message. The conditions differ: `ENOENT` (file missing) means the app never created the socket, whereas `ECONNREFUSED` on an existing file means a prior Espalier instance crashed without unlinking, or its `SocketServer.start()` failed after the file was created but before listening began.

**ATTN-3.5** When a `pane list`, `pane add`, or `pane close` request targets a tracked worktree that is not in the `.running` state (i.e., no terminals currently alive in it), the server shall respond with `.error("worktree not running")`. `list` in particular shall NOT return an empty `.paneList` — that reads as a silent success to callers scripting `pane list | wc -l` or similar, when in fact the worktree needs to be clicked to start its terminals.

### 5.4 CLI Distribution

**ATTN-4.1** The application shall provide a menu item (Espalier -> Install CLI Tool...) to create or update a symlink at `/usr/local/bin/espalier` pointing to the CLI binary in the app bundle. CLI installation is opt-in via this menu item; the application shall not auto-prompt for installation on launch.

## 6. Persistence

### 6.1 Storage

**PERSIST-1.1** The application shall store all persistent state in `~/Library/Application Support/Espalier/`.

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

## 7. PWD-Aware Pane Routing

### 7.1 Detection

**PWD-1.1** When a terminal shell reports a new working directory via OSC 7, the application shall evaluate whether the pane belongs under a different worktree in the sidebar.

**PWD-1.2** The application shall select the destination worktree as the one whose filesystem path is the longest prefix of the reported PWD across all repos. If no worktree path is a prefix of the PWD, the pane shall remain in its current worktree.

**PWD-1.3** If a pane's inner shell does not emit OSC 7 (e.g. a `zmx` session whose inner shell predates `ZMX-6.3` and therefore has no Ghostty zsh integration loaded, or a shell for which Espalier does not install integration), the application shall poll that pane's inner-shell working directory at least every 3 seconds and, when the polled value differs from the last known PWD for that pane, invoke the same reassignment-evaluation flow required by `PWD-1.1` using the polled value. Espalier resolves the inner-shell PID by reading the zmx session log at `<ZMX_DIR>/logs/<session>.log` for the most recent `pty spawned session=<session> pid=<N>` line and, if no such line is present in the current file, falling back to the rotated sibling `<ZMX_DIR>/logs/<session>.log.old` — zmx rotates its per-session log once it reaches its internal size threshold, so for long-lived sessions the spawn line that identifies the live PID often sits in the rotated file. Once resolved, the PID's current working directory is queried via `proc_pidinfo(PROC_PIDVNODEPATHINFO)`. When no PID is discoverable (both files missing, no `pty spawned` line in either, cached PID no longer responds), the poll shall skip that pane for the current tick. OSC 7 events and polled values share one last-known-PWD memory per pane so a cd observed by one source does not re-fire via the other.

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
- `↑<N>` when the worktree's HEAD has N commits not reachable from the base ref (ahead). Additionally, when the worktree has uncommitted changes, a `+` shall be appended, yielding `↑<N>+`. When N is zero, the ahead segment shall be rendered (as `↑0+`) only if uncommitted changes exist; otherwise the ahead segment shall be omitted.
- `↓<N>` when the base ref has N commits not reachable from the worktree's HEAD (behind). Omitted when N is zero.

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

**DIVERGE-3.0** The base ref for divergence computation shall depend on the worktree's role in the repository:
- For the main checkout (the worktree whose path equals the repository's path), the base ref shall be `origin/<name>`, where `<name>` is the resolved default branch name. This surfaces unpushed work on the main checkout.
- For linked worktrees (every other worktree), the base ref shall be the local `<name>` branch. This shows how far a feature branch has diverged from the point it was branched off rather than double-counting commits already on local main.

**DIVERGE-3.1** The application shall compute ahead and behind commit counts by running `git rev-list --left-right --count <base-ref>...HEAD` in the worktree directory, interpreting the left count as behind and the right count as ahead. `<base-ref>` is determined per DIVERGE-3.0.

**DIVERGE-3.2** The application shall compute insertion and deletion line counts by running `git diff --shortstat <base-ref>...HEAD` in the worktree directory, with `<base-ref>` per DIVERGE-3.0.

**DIVERGE-3.3** The application shall detect uncommitted changes in each worktree by running `git status --porcelain` and treating any non-empty output (including modified, staged, deleted, or untracked entries) as "has uncommitted changes".

**DIVERGE-3.4** All git computation for divergence indicators shall run off the main thread and shall not block the UI.

**DIVERGE-3.5** Divergence counts and the uncommitted-changes flag shall be held in memory only and shall not be written to `state.json`.

### 11.4 Refresh Triggers

**DIVERGE-4.1** When a repository is added to the sidebar, the application shall compute divergence counts for each of its worktrees.

**DIVERGE-4.2** When a worktree's HEAD reference changes, the application shall recompute that worktree's divergence counts.

**DIVERGE-4.3** The application shall run `git fetch --no-tags --prune origin <defaultBranch>` and recompute divergence counts per repository on a 5-minute base cadence, doubling the interval for each consecutive fetch failure up to a 30-minute cap, to catch changes to the origin default branch that occur outside the current worktree (e.g., after `git fetch` runs in another terminal). A fast 5-second polling ticker drives the eligibility check; actual fetches are gated by the per-repo cadence so tracked repositories are not hammered.

**DIVERGE-4.4** While a divergence computation is in flight for a particular worktree, duplicate refresh requests for the same worktree shall be dropped.

**DIVERGE-4.5** When `WorktreeStatsStore.clear(worktreePath:)` is called — whether from a stale transition (GIT-3.13), a Dismiss (GIT-3.6), or a Delete (GIT-4.10) — a fetch that was already in flight at that moment shall not repopulate `stats` after the clear. Each `clear` bumps a per-path generation counter; `apply` captures the generation at refresh time and drops the write if the counter changed during the await. Without this, a `git worktree remove` that fires shortly after the 5s-polling refresh leaves the divergence indicator flashing back onto a cleared row for the duration of the git subprocess (~50–200ms). Mirrors `PRStatusStore`'s pattern (PR status gained this protection earlier; stats store was lagging).

## 12. Technology Constraints

**TECH-1** The application shall be built in Swift using SwiftUI for app chrome and AppKit for terminal view hosting.

**TECH-2** The application shall use libghostty (via the libghostty-spm Swift Package) as its terminal engine.

**TECH-3** The application shall target macOS 14 Sonoma as its minimum supported version.

**TECH-4** The application shall reuse the following components from the Ghostty project (MIT-licensed): `SplitTree`, `SplitView`, `Ghostty.Surface`, `Ghostty.App`, `Ghostty.Config`, and `SurfaceView_AppKit`.

**TECH-5** The application shall invoke every external tool (`git`, `gh`, `glab`, `zmx`) with `LC_ALL=C` in the child environment so output parsers written against English strings (e.g. `git diff --shortstat` "insertion"/"deletion" markers, `gh pr checks` bucket names) keep working when the user's shell locale is non-English. This is a forcing function — the alternative (locale-robust parsers across multiple tools) is fragile and brittle.

## 13. zmx Session Backing

### 13.1 Bundling

**ZMX-1.1** The application shall include a `zmx` binary in the app bundle at `Espalier.app/Contents/Helpers/zmx`, mirroring the placement of the `espalier` CLI.

**ZMX-1.2** The bundled `zmx` binary shall be a universal Mach-O containing both `arm64` and `x86_64` slices, produced by `scripts/bump-zmx.sh`.

**ZMX-1.3** The application shall pin the vendored `zmx` version in `Resources/zmx-binary/VERSION` and record its SHA256 in `Resources/zmx-binary/CHECKSUMS`.

### 13.2 Session Naming

**ZMX-2.1** The application shall derive the zmx session name for each pane as the literal string `"espalier-"` followed by the first 8 lowercase hex characters (i.e., the leading 4 bytes, yielding 32 bits of namespace uniqueness) of the pane's UUID with dashes stripped.

**ZMX-2.2** The session-naming function shall be deterministic and shall not change across releases without an explicit migration step, since changing it orphans every existing user's daemons.

### 13.3 Sandboxing

**ZMX-3.1** The application shall pass `ZMX_DIR=~/Library/Application Support/Espalier/zmx/` in the environment of every spawned `zmx` invocation, so Espalier-owned daemons live in a private socket directory distinct from any user-personal `zmx` usage.

**ZMX-3.2** The application shall create the `ZMX_DIR` path if it does not exist at launch.

### 13.4 Lifecycle Mapping

**ZMX-4.1** When the application creates a new terminal pane, it shall leave the libghostty surface configuration's `command` field unset and instead write `exec '<bundled-zmx-path>' attach espalier-<short-id> '<user-shell>'\n` into the surface's `initial_input` field, with each substituted path single-quoted to defend against spaces. The leading `exec` replaces the default shell with `zmx attach` so that when the inner shell ends, the PTY child dies and libghostty's `close_surface_cb` fires. Setting `command` instead would trigger libghostty's automatic `wait-after-command` enablement (see upstream `src/apprt/embedded.zig`), which would keep panes open after `exit` and show a "Press any key to close" overlay.

**ZMX-4.2** When the application restores a worktree's split tree on launch (per `PERSIST-3.x`), each restored pane's surface shall be created with the same session name derived from the persisted pane UUID, so reattach to a surviving daemon is automatic.

**ZMX-4.3** When the application destroys a terminal surface (user-initiated close, automatic close on shell exit, or worktree stop), it shall asynchronously invoke `zmx kill --force <session>` for the matching session.

**ZMX-4.4** When the application quits, it shall not invoke `zmx kill` — pending PTY teardown by the OS is the desired detach signal that lets daemons survive.

### 13.5 Fallback

**ZMX-5.1** If the bundled `zmx` binary is missing or not executable, the application shall fall back to libghostty's default `$SHELL` spawn behavior on a per-pane basis.

**ZMX-5.2** If the bundled `zmx` binary is unavailable at launch, the application shall present a single non-blocking informational alert explaining that terminals will not survive app quit. The alert shall not be re-presented within the same process lifetime.

### 13.6 Pass-through Guarantees

**ZMX-6.1** Shell-integration OSC sequences (OSC 7 working directory, OSC 9 desktop notification, OSC 133 prompt marks, OSC 9;4 progress reports) shall continue to flow from the inner shell through `zmx` to libghostty unchanged. The `PWD-x.x`, `NOTIF-x.x`, and `KEY-x.x` requirements remain in force regardless of whether `zmx` is mediating the PTY.

**ZMX-6.2** The `ESPALIER_SOCK` environment variable shall continue to be set in the spawned shell's environment per `ATTN-2.4`. Because `zmx` inherits its child shell's env from the spawning process, this is satisfied by setting it on the libghostty surface as today.

**ZMX-6.3** If `GHOSTTY_RESOURCES_DIR` is set (per `CONFIG-2.1`) and the user's shell basename is `zsh`, the `initial_input` written per `ZMX-4.1` shall prefix the `exec` line with `if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; fi; ZDOTDIR='<ghostty-resources>/shell-integration/zsh'` so the inner shell zmx spawns re-sources Ghostty's zsh integration. Without this re-injection, Ghostty's integration `.zshenv` in the outer shell has already restored `ZDOTDIR` to the user's original value, so the post-`exec` inner shell sources only the user's plain rc files — precmd hooks do not run, no OSC 7 / OSC 133 sequences are emitted, and `PWD-x.x`, the default-command first-PWD trigger, and shell-integration-driven attention badges all go silent.

**ZMX-6.4** If the outer shell's `ZDOTDIR` is unset or empty, the `GHOSTTY_ZSH_ZDOTDIR` assignment in `ZMX-6.3` shall not execute. Ghostty's integration `.zshenv` gates its restore branch on `${GHOSTTY_ZSH_ZDOTDIR+X}` (which matches empty-string-set), and zsh's dotfile lookup uses `${ZDOTDIR-$HOME}` (falls back to `$HOME` only when *unset*, not when empty) — so an unguarded assignment would export `ZDOTDIR=""` into the inner shell and cause it to silently skip the user's `.zshenv`/`.zprofile`/`.zshrc`/`.zlogin`. Guarding keeps `GHOSTTY_ZSH_ZDOTDIR` unset so the integration's `else: unset ZDOTDIR` branch fires and dotfile lookup defaults to `$HOME`.

### 13.7 Session-Loss Recovery

**ZMX-7.1** When the application restores a worktree's split tree on launch (per `PERSIST-3.x` and `ZMX-4.2`), it shall, before creating each pane's surface, query the live zmx session set and clear the pane's rehydration label if the expected session name is absent. This ensures a freshly-created daemon (the result of `zmx attach`'s create-on-miss semantics) is not mistaken for a surviving session by `defaultCommandDecision`.

**ZMX-7.2** If `zmx list` fails for any reason at the cold-start query site (per `ZMX-7.1`), the application shall treat the result as "session not missing" and take no recovery action — preferring a missed recovery over a spurious rehydration clear.

**ZMX-7.3** When `close_surface_cb` fires for a pane, the application shall always route to the close-pane path (remove from the split tree, free the surface) regardless of the zmx session's liveness. The mid-flight "rebuild surface in place" recovery explored in an earlier design was withdrawn because the available signals (session-missing + no Espalier-initiated close) cannot distinguish a clean user `exit` from an external daemon kill, and the rebuild path regressed `TERM-5.3`. Recovery from daemon loss while Espalier is running is deferred until a zmx-side signal disambiguates the two cases.

**ZMX-7.4** At application launch, before any terminal surface is spawned, the application shall `unsetenv(...)` a known list of "leaky" environment variables from its own process so every downstream spawn (libghostty surface shells, CLIRunner subprocesses, zmx attach) sees a clean env regardless of the shell Espalier was launched from. The list shall include at minimum:

- `ZMX_SESSION` — zmx's `attach <positional>` silently prefers `$ZMX_SESSION` over its positional argument. A parent shell that itself lived inside a zmx session would otherwise hijack every new pane's attach to the parent's session. User-visible as "created a new worktree, its Claude swapped out for an older worktree's Claude".
- `GIT_DIR` and `GIT_WORK_TREE` — git's env-var-wins rule trumps `currentDirectoryURL`. A parent shell with either set would redirect every `GitRunner.run(at: repoPath)` invocation (worktree discovery, stats, PR resolution) to the parent shell's `.git` dir instead of the target repo.

The sweep runs once at `EspalierApp.init()`. `ZmxLauncher.subprocessEnv` additionally strips `ZMX_SESSION` from inline subprocess envs as belt-and-suspenders, but the process-level sweep is the primary defense — it also covers libghostty's surface env overlay, which cannot be routed through `subprocessEnv` before the spawn.

## 14. Distribution

### 14.1 Build Bundle

**DIST-1.1** The build script (`scripts/bundle.sh`) shall produce a self-contained `Espalier.app` bundle in `.build/` containing the SwiftUI application binary at `Contents/MacOS/Espalier`, the CLI helper at `Contents/Helpers/espalier`, and the bundled `zmx` binary at `Contents/Helpers/zmx`.

**DIST-1.2** While the `ESPALIER_VERSION` environment variable is set, the build script shall write that value into both `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`.

**DIST-1.3** If the `ESPALIER_VERSION` environment variable is not set, then the build script shall use `0.0.0-dev` as the default version.

**DIST-1.4** The build script shall ad-hoc codesign every Mach-O in the bundle in inner-to-outer order: `Contents/Helpers/zmx`, `Contents/Helpers/espalier`, `Contents/MacOS/Espalier`, then the bundle itself, and shall verify the resulting signature with `codesign --verify --strict`.

### 14.2 Release Automation

**DIST-2.1** When a git tag matching `v*` is pushed to origin, the GitHub Actions workflow `.github/workflows/release.yml` shall build the app bundle in release configuration, verify codesigning, zip the bundle as `Espalier-<version>.zip`, ensure a GitHub release tagged `v<version>` has the zip attached, and ensure the `btucker/homebrew-espalier` cask reflects the new version and sha256.

**DIST-2.2** If the pushed tag does not start with `v`, then the release workflow shall fail before building.

**DIST-2.3** If a release for the pushed tag already exists, then the workflow shall re-upload the zip with `--clobber` and continue to the cask update step rather than failing.

**DIST-2.4** The release zip shall be produced with `ditto -c -k --keepParent` (not `zip`) so that codesign-relevant extended attributes survive — `zip` strips them and installs fail with opaque "damaged" errors after reboot.

### 14.3 Homebrew Cask

**DIST-3.1** The Homebrew tap `btucker/homebrew-espalier` shall expose a cask `espalier` that downloads the release zip, installs `Espalier.app` to `/Applications`, and symlinks `Espalier.app/Contents/Helpers/espalier` onto the user's PATH as `espalier`.

**DIST-3.2** While the application is ad-hoc signed (not Developer ID notarized), the cask shall display a `caveats` notice explaining that macOS will refuse to open the app on first launch and providing the steps to bypass Gatekeeper.

**DIST-3.3** When the user runs `brew uninstall --cask --zap espalier`, the cask shall remove `~/Library/Application Support/Espalier`, `~/Library/Preferences/com.espalier.app.plist`, and `~/Library/Caches/com.espalier.app`.

## 15. Web Access

### 15.1 Binding

**WEB-1.1** When web access is enabled, the application shall bind a local HTTP server to each Tailscale IPv4 and IPv6 address reported by the Tailscale LocalAPI, and to `127.0.0.1`, on the user-configured port (default 8799).

**WEB-1.2** The application shall not bind to `0.0.0.0`.

**WEB-1.3** If no Tailscale addresses are available, the application shall not bind the server and shall surface a "Tailscale unavailable" status in the Settings pane.

**WEB-1.4** The feature shall be off by default.

**WEB-1.5** If the user-configured port is outside the 0–65535 range NIO will accept (e.g., the Settings TextField lets the user type any integer, including "99999" or a negative number), the application shall surface a readable "Port must be 0–65535 (got N)" error in the Settings status row rather than attempting to bind and surfacing an opaque `NIOBindError`, and shall not start the server until the value is corrected.

**WEB-1.6** When resolving the Tailscale LocalAPI, the application shall try Unix domain socket endpoints first (OSS / sandboxed App Store installs) and, if none are reachable, shall fall back to the macsys DMG's TCP endpoint by reading the port from `/Library/Tailscale/ipnport` (file or symlink) and the auth token from `/Library/Tailscale/sameuserproof-<port>`.

**WEB-1.7** While web access is listening, the Settings pane status row shall render the listening address and port without locale grouping separators (e.g., `Listening on 100.64.0.5:49161`, never `49,161`).

**WEB-1.8** Any URL the application composes for display or clipboard copy — the Settings pane's `currentURL`, the sidebar "Copy web URL" action — shall bracket an IPv6 host per RFC 3986 authority syntax (e.g., `http://[fd7a:115c::5]:8799/`). Applies whether the URL includes a session path or is the server's root. Without bracketing, an IPv6-only Tailscale setup produces `http://fd7a:115c::5:8799/` which is a malformed URI. `WebURLComposer.baseURL(host:port:)` and `WebURLComposer.url(session:host:port:)` share the same bracket logic.

**WEB-1.9** When `WebURLComposer.url(session:host:port:)` percent-encodes the session name for interpolation into the URL path, it shall use `CharacterSet.urlPathAllowed` rather than `urlQueryAllowed`. The latter leaves reserved path/query/fragment separators (`?`, `#`) unescaped, so a session name containing `?` would cause the browser to parse the URL as path-and-query and the client router would see only the prefix. Espalier's own session names per `ZMX-2.1` never include such characters, but socket clients producing custom session names would otherwise silently break.

**WEB-1.10** The Settings pane status row ("Listening on …") shall render each listening address with its port individually (via `WebURLComposer.authority(host:port:)`), bracketing IPv6 hosts. The prior format `addrs.joined(", "):port` rendered `Listening on fd7a:115c::5, 127.0.0.1:49161` — ambiguous whether the port attaches to the IPv6 or only the trailing IPv4, and the IPv6 itself unbracketed. New format: `Listening on [fd7a:115c::5]:49161, 127.0.0.1:49161`.

### 15.2 Authorization

**WEB-2.1** The application shall resolve each incoming peer IP via Tailscale LocalAPI `whois` before serving any content at any path.

**WEB-2.2** The application shall accept a connection only when the resolved `UserProfile.LoginName` equals the current Mac's Tailscale `LoginName`.

**WEB-2.3** When `whois` fails or the resolved LoginName differs, the application shall respond with HTTP `403 Forbidden`.

**WEB-2.4** When Tailscale is not running, the application shall refuse all incoming connections (the server is not bound; connections are refused at TCP).

**WEB-2.5** When the peer IP is a loopback address (`127.0.0.1` or `::1`), the application shall bypass the Tailscale-whois check and serve the request as if authorized. Rationale: the local user has direct access to the machine (nothing crosses the network); `whois` returns "peer not found" for loopback so without the bypass the `127.0.0.1` bind required by `WEB-1.1` would be dead, and `http://127.0.0.1:<port>/` would always 403.

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

### 15.4 Lifecycle

**WEB-4.1** When the user enables web access in Settings, the application shall probe Tailscale, bind, and transition status to `.listening(...)` or an error status.

**WEB-4.2** When the user disables web access, the application shall close all listening sockets and terminate all in-flight `zmx attach` children spawned for the web.

**WEB-4.3** When the application quits, the application shall stop the server (same tear-down as 15.4.2) as part of normal shutdown.

**WEB-4.4** For each incoming WebSocket, the application shall spawn one child `zmx attach <session>` whose PTY it owns (per §13 naming and ZMX_DIR rules from Phase 1).

**WEB-4.5** When a WebSocket closes, the application shall send SIGTERM to the associated `zmx attach` child, leaving the zmx daemon alive.

**WEB-4.6** When the application forks a `zmx attach` child for a web WebSocket, the child shall close every inherited file descriptor above 2 before `execve`. Rationale: without this, parent-opened sockets (notably the `WebServer` listen socket) without `FD_CLOEXEC` leak into the zmx child and survive the parent. After Espalier quits, the listen port stays bound to an orphan zmx process and the next Espalier launch cannot rebind.

### 15.5 Client

**WEB-5.1** The bundled client shall render a single terminal (ghostty-web, a WASM build of libghostty — the same VT parser as the native app pane) that attaches to the session indicated by the `/session/<name>` URL path. If a client arrives at the root path `/` with a `?session=<name>` query parameter, the client shall redirect to `/session/<name>` (backward compatibility). Sharing a parser with the native pane is what keeps escape-sequence behavior (cursor movement, SGR state, OSC 8 hyperlinks, scrollback) identical across clients.

**WEB-5.4** When a client requests `GET /sessions`, the application shall respond with a JSON array of the currently-running sessions, one entry per live pane across all running worktrees, with fields `name` (the zmx session name derived per `ZMX-2.1`), `worktreePath`, `repoDisplayName`, and `worktreeDisplayName`. The bundled client's root page (`/`) shall fetch this endpoint and render a clickable picker grouped by `repoDisplayName`, so a user who visits the server's root URL without a session query gets a functional entry point rather than a bare "no session" placeholder. Access to `/sessions` shall be gated by the same Tailscale-whois authorization as every other path (`WEB-2.1` / `WEB-2.2`).

**WEB-5.2** The client shall send terminal data events as binary WebSocket frames.

**WEB-5.3** The client shall send resize events as JSON control envelopes in text frames, including an initial resize sent on WebSocket open so the server-side PTY is sized to the client's actual viewport rather than the `zmx attach` default.

### 15.6 Non-goals

**WEB-6.1** Phase 2 shall not implement TLS at the application level; the application shall rely on Tailscale transport encryption.

**WEB-6.2** Phase 2 shall not implement multi-pane layout, mouse events, OSC 52 clipboard sync, or reboot survival. (A minimal session-list picker is provided by `WEB-5.4`.)

**WEB-6.3** Phase 2 shall not implement rate limiting, URL tokens, or cookies; authorization shall be via Tailscale WhoIs only.

### 15.7 Cross-references to §13

The web access path uses Phase 1's session-naming and sandbox requirements unchanged. See §13.2 (session naming), §13.3 (`ZMX_DIR` sandbox), §13.4 (lifecycle mapping), and §13.6 (pass-through guarantees).

## 16. Keyboard Shortcuts

**KBD-1.1** When the user presses a chord bound in their Ghostty config
to an apprt action Espalier supports, the application shall dispatch
that action.

**KBD-1.2** When the user's Ghostty config omits a binding for an action,
the corresponding Espalier menu item shall render without a shortcut hint
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
(either via the Espalier menu or via a Ghostty keybinding mapped to
the `reload_config` action), the application shall construct a fresh
`GhosttyConfig` — re-walking the XDG default paths, `com.mitchellh.ghostty/config`,
and recursive `config-file =` includes — and push it into the live
`ghostty_app_t` via `ghostty_app_update_config`, so subsequent key
presses and theme reads reflect edits to the on-disk config without
a restart. A stale earlier comment claimed libghostty-spm lacked a
reload C API; `ghostty_app_update_config` has been available on the
vendored surface and is what this spec pins.

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

### 17.5 PR Fetching

**PR-5.1** For GitHub origins, the application shall fetch open PRs via `gh pr list --repo <owner>/<repo> --head <branch> --state open --limit 5 --json number,title,url,state,headRefName,headRepositoryOwner` and take the first result whose `headRepositoryOwner.login` matches the origin owner. Merged PRs shall use the same shape with `--state merged` and the additional `mergedAt` JSON field. The limit is 5 (rather than 1) so a fork PR returned first by `gh`'s default sort cannot crowd out a same-repo PR that the owner filter would otherwise accept.

**PR-5.2** For GitHub origins, the application shall fetch per-check status via `gh pr checks <number> --repo <owner>/<repo> --json name,state,bucket`. The `bucket` field (values `pass`/`fail`/`pending`/`skipping`/`cancel`) is the canonical verdict; `conclusion` is not a field `gh` emits from this command.

**PR-5.4** When `gh pr list` succeeds but the subsequent `gh pr checks` call for the resolved PR fails (auth hiccup, rate limit, subcommand regression, network blip), the application shall still surface the PR's identity with `.none` check status rather than propagating the checks error out of the fetch. The `#<number>` sidebar badge (`PR-3.2`) and the breadcrumb PR button shall remain visible — losing them because checks couldn't be resolved produces worse UX than displaying them with neutral check state.

**PR-5.3** For GitLab origins, the application shall fetch merge requests via `glab mr list --repo <path> --source-branch <branch> --state <opened|merged> --per-page 1 -F json`. Per-pipeline status is derived from the MR's `head_pipeline.status` field in the same response.

**PR-5.5** When the application stores a PR/MR title into a `PRInfo` for display (breadcrumb `PRButton`, accessibility label, tooltip), it shall first strip every Unicode bidirectional-override scalar (the embedding, override, and isolate families — the same ranges as `ATTN-1.14`). PR titles are author-controlled, including authors who submit from malicious forks; a poisoned title like `"Fix \u{202E}redli\u{202C} helper"` would otherwise render RTL-reversed in the breadcrumb as `"Fix ildeeper helper"`-style text — the same Trojan Source visual deception (CVE-2021-42574) `ATTN-1.14` and `LAYOUT-2.18` block on self-owned surfaces. Unlike those surfaces, the PR-title path STRIPS rather than REJECTS: a poisoned title shouldn't hide the PR entirely from the user (they still need to see "a PR exists"); stripping yields a legible-ish version and the user can click through to the hosting provider for the raw text. Applies to both `GitHubPRFetcher` and `GitLabPRFetcher`.

**GIT-2.6** When the application renders a worktree's branch name in the UI (the breadcrumb bar per `LAYOUT-1.3` and the secondary label in the sidebar row), it shall read `WorktreeEntry.displayBranch` rather than `WorktreeEntry.branch`. `displayBranch` strips every Unicode bidirectional-override scalar (same ranges as `PR-5.5`) so a collaborator-controlled branch name like `"feat\u{202E}lanigiro"` — which git accepts and which propagates into `state.json` via `git worktree list --porcelain` — can't render RTL-reversed in the breadcrumb or row. `branch` itself is preserved unchanged so downstream `git` subprocess calls, `gh pr list --head <branch>`, and the `PRStatusStore.isFetchableBranch` gate keep operating on the real ref. This is the same strip-not-reject policy `PR-5.5` uses for externally-sourced text.

### 17.6 Check Rollup

**PR-6.1** A PR's overall check status shall roll up its individual check buckets as follows: any `fail` → `.failure`; any `pending` bucket or any in-flight state (`IN_PROGRESS`, `QUEUED`, `PENDING`) → `.pending`; all-`pass` → `.success`; anything else (including `skipping`, `cancel`, or unclassified) → `.none` (neutral).

**PR-6.2** When a PR has no checks, its overall status shall be `.none`.

### 17.7 Polling Cadence and Backoff

**PR-7.1** The application shall poll a worktree's PR status on a base cadence of 30 seconds whenever a PR is known (open or merged) or the worktree has been observed to have no associated PR (absent). A faster or tiered cadence is not applied, because `watchOriginRefs` (per GIT-2.5) catches local push/fetch but is blind to a merge landing on the hosting provider without a local `git fetch` — polling is therefore the sole detection channel for that event, and a slower cadence directly surfaces as user-visible staleness in the sidebar badge and breadcrumb PR button.

**PR-7.2** When a fetch for a worktree fails, the application shall apply exponential backoff to its cadence: the base interval (or 60s if the base is zero) shall be doubled for each consecutive failure up to a shift of 5 (32×), capped at 30 minutes.

**PR-7.3** The application shall not poll worktrees whose branch is a git sentinel value (`(detached)`, `(bare)`, `(unknown)`, any other parenthesized value, or empty / whitespace-only), since none of these correspond to a real ref that a hosting provider can associate with a PR.

**PR-7.4** The application shall not poll stale worktrees.

**PR-7.5** `PRStatusStore.refresh` and `PRStatusStore.branchDidChange` shall also apply the `PR-7.3` sentinel-branch gate, not just the background polling loop. Otherwise an on-demand refresh (sidebar selection, HEAD-change event) against a detached / bare / unknown worktree still fires two wasted `gh pr list --head <sentinel>` invocations per event — the gate belongs at the fetch entry point, not duplicated at every caller.
