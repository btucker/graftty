// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("LAYOUT — pending specs")
struct LayoutTodo {
    @Test("""
@spec LAYOUT-1.1: The application shall display a single main window with a resizable sidebar on the left and a terminal content area on the right.
""", .disabled("not yet implemented"))
    func layout_1_1() async throws { }

    @Test("""
@spec LAYOUT-1.2: The sidebar shall be resizable via a drag handle between the sidebar and the terminal content area.
""", .disabled("not yet implemented"))
    func layout_1_2() async throws { }

    @Test("""
@spec LAYOUT-1.3: The terminal content area shall display a breadcrumb bar above the terminal split layout showing, in order: the selected repository's display name, a `/` separator, the worktree's display name (rendered italic as `root` for the repository's main checkout, otherwise the sibling-disambiguated name per `LAYOUT-2.15`), and the branch name in parentheses at caption weight. The worktree's full filesystem path shall be available as a hover tooltip on the worktree-name element rather than rendered inline. When the worktree has a resolved PR/MR, the trailing edge of the breadcrumb shall additionally show the PR button per `PR-3.x`.
""", .disabled("not yet implemented"))
    func layout_1_3() async throws { }

    @Test("""
@spec LAYOUT-1.4: While the sidebar is hidden (`NavigationSplitViewVisibility.detailOnly`), the breadcrumb bar shall apply a leading inset wide enough to clear the window's traffic-light buttons and the sidebar-toggle button so its text remains legible at the window's left edge. While the sidebar is visible, the breadcrumb shall use its standard 12pt leading padding because the sidebar column already offsets the detail content past the traffic lights.
""", .disabled("not yet implemented"))
    func layout_1_4() async throws { }

    @Test("""
@spec LAYOUT-2.1: The sidebar shall display an ordered list of repositories, each expandable to show its worktrees.
""", .disabled("not yet implemented"))
    func layout_2_1() async throws { }

    @Test("""
@spec LAYOUT-2.2: Each repository entry shall be collapsible and expandable by clicking its disclosure indicator.
""", .disabled("not yet implemented"))
    func layout_2_2() async throws { }

    @Test("""
@spec LAYOUT-2.3: When a repository is expanded, the sidebar shall display the repository's own working directory as the first child entry, labeled by its current branch name.
""", .disabled("not yet implemented"))
    func layout_2_3() async throws { }

    @Test("""
@spec LAYOUT-2.4: When a repository is expanded, the sidebar shall display each linked worktree as a child entry beneath the repository's own working directory, labeled by branch name.
""", .disabled("not yet implemented"))
    func layout_2_4() async throws { }

    @Test("""
@spec LAYOUT-2.5: The sidebar shall display an "Add Repository" button at the bottom.
""", .disabled("not yet implemented"))
    func layout_2_5() async throws { }

    @Test("""
@spec LAYOUT-2.6: When the user clicks a worktree or repository working directory entry, the terminal content area shall switch to display that entry's terminal layout.
""", .disabled("not yet implemented"))
    func layout_2_6() async throws { }

    @Test("""
@spec LAYOUT-2.7: When the user right-clicks a sidebar entry, the application shall display a context menu with actions appropriate to the entry's current state.
""", .disabled("not yet implemented"))
    func layout_2_7() async throws { }

    @Test("""
@spec LAYOUT-2.8: While a worktree is in the running state, the sidebar shall display one indented child row per terminal pane beneath the worktree entry, each labeled by that pane's current title.
""", .disabled("not yet implemented"))
    func layout_2_8() async throws { }

    @Test("""
@spec LAYOUT-2.9: If a terminal pane has no program-set title, then the pane's row shall display its last-known working directory's basename as the label. If the working directory is also unknown (root `/`, empty, or never reported), then the pane's row shall display the fallback label "shell".
""", .disabled("not yet implemented"))
    func layout_2_9() async throws { }

    @Test("""
@spec LAYOUT-2.10: When the user clicks a pane row, the application shall select that pane's worktree and focus that specific pane.
""", .disabled("not yet implemented"))
    func layout_2_10() async throws { }

    @Test("""
@spec LAYOUT-2.11: The sidebar shall display the active worktree row and all its pane rows inside a single unified highlighted block; within that block, the focused pane's row shall additionally be emphasized via text weight and color (no secondary background).
""", .disabled("not yet implemented"))
    func layout_2_11() async throws { }

    @Test("""
@spec LAYOUT-2.12: While a worktree entry is not in the stale state, its context menu shall include an "Open Worktree in Finder..." action that opens the worktree's filesystem path in the system file browser via `NSWorkspace.shared.open`.
""", .disabled("not yet implemented"))
    func layout_2_12() async throws { }

    @Test("""
@spec LAYOUT-2.13: The application shall reject incoming OSC 2 titles that match either of two shapes: (a) trimmed value matching `^[A-Z_][A-Z0-9_]*=` (an uppercase identifier followed by `=`), or (b) containing the literal substring `GHOSTTY_ZSH_ZDOTDIR` anywhere in the title. Both shapes are command-echo leaks produced by ghostty's shell-integration `preexec` hook when the outer shell runs Graftty's injected `exec zmx attach …` bootstrap line; propagating them to the sidebar would display a 200+ character shell-command string as the pane's title until the inner shell's first prompt overwrites it. Shape (a) catches the pre-`ZMX-6.4` naked-env-assignment form; shape (b) catches the post-`ZMX-6.4` conditional form (`if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR=…; fi; ZDOTDIR=… exec zmx attach …`) and guards against any future bootstrap reshape that preserves the `GHOSTTY_ZSH_ZDOTDIR` marker. The previously stored title (if any) is retained; if none, the pane falls back to the LAYOUT-2.9 chain.
""", .disabled("not yet implemented"))
    func layout_2_13() async throws { }

    @Test("""
@spec LAYOUT-2.14: When `PaneTitle.display` is asked to render a stored title consisting of only whitespace (spaces, tabs), the application shall fall through to the PWD basename (or the "shell" view-level fallback) rather than rendering visible blank space as the pane label. Real content with surrounding whitespace (e.g., `" claude "`) is preserved verbatim — the check is whitespace-only-vs-content, not a trimming operation.
""", .disabled("not yet implemented"))
    func layout_2_14() async throws { }

    @Test("""
@spec LAYOUT-2.15: `WorktreeEntry.displayName(amongSiblingPaths:)` shall grow its disambiguation suffix one path component at a time until the candidate is unique amongst siblings, rather than stopping at a single `<parent>/<leaf>` level. Previous behavior: two siblings like `/repo/.worktrees/deep/ns/feature` and `/repo/.worktrees/other/ns/feature` both rendered as `ns/feature` because the algorithm didn't grow past one parent. With `WorktreeNameSanitizer` now permitting `/` in worktree names (`GIT-5.1`), deeply nested worktrees that share both leaf and immediate parent are plausible. The new algorithm returns `deep/ns/feature` vs `other/ns/feature`; if a sibling's path is a strict suffix of another's (pathological), falls back to the full path so something still distinguishes them.
""", .disabled("not yet implemented"))
    func layout_2_15() async throws { }

    @Test("""
@spec LAYOUT-2.16: The application shall also reject incoming OSC 2 titles whose grapheme-cluster length exceeds `PaneTitle.maxStoredLength` (200), bounding the transient heap cost of the `titles[TerminalID: String]` dict against a misbehaving program that pushes a multi-kilobyte payload. The cap matches `Attention.textMaxLength` so the pane-title and notify-text surfaces share the same limit. Rejection semantics match `LAYOUT-2.13`: the previously stored title (if any) is retained; if none, the pane falls back to the `LAYOUT-2.9` chain.
""", .disabled("not yet implemented"))
    func layout_2_16() async throws { }

    @Test("""
@spec LAYOUT-2.17: The application shall also reject incoming OSC 2 titles containing any Unicode Cc (control) scalar — line feed, carriage return, tab, bell, ANSI escape (`\\e`), DEL, or any other C0/C1 control. SwiftUI `Text` with `.lineLimit(1)` clips newlines but renders escape sequences like `\\e[31m` as literal `[31m` glyphs (the ESC byte is invisible), producing sidebar strings like `[31mred[0m`. This is the same visual-garbage class as CLI's `ATTN-1.12` for notify text; the server-side OSC 2 surface was previously unchecked. Rejection semantics match `LAYOUT-2.13` / `LAYOUT-2.16`: the previously stored title (if any) is retained; if none, the pane falls back to the `LAYOUT-2.9` chain.
""", .disabled("not yet implemented"))
    func layout_2_17() async throws { }

    @Test("""
@spec LAYOUT-2.18: The application shall also reject incoming OSC 2 titles containing any Unicode bidirectional-override scalar — the embedding family (`U+202A`–`U+202C`), the override family (`U+202D`–`U+202E`), or the isolate family (`U+2066`–`U+2069`). These are Cf-category so `LAYOUT-2.17`'s Cc gate misses them, but they reverse surrounding text at render time — a rogue inner-shell program can push `printf '\\e]0;\\u202Edecoy\\u202C\\a'` and have the title display RTL-reversed in the pane row, the same "Trojan Source" visual deception (CVE-2021-42574) that `ATTN-1.14` blocks on the notify surface. Natural RTL text (Arabic, Hebrew, Persian) uses character-intrinsic directionality rather than these override scalars and still passes. Rejection semantics match `LAYOUT-2.13` / `LAYOUT-2.16` / `LAYOUT-2.17`.
""", .disabled("not yet implemented"))
    func layout_2_18() async throws { }

    @Test("""
@spec LAYOUT-3.1: When the user clicks "Add Repository", the application shall present a standard macOS open panel for selecting a directory.
""", .disabled("not yet implemented"))
    func layout_3_1() async throws { }

    @Test("""
@spec LAYOUT-3.2: When the user drops a directory onto the sidebar, the application shall add it as a repository.
""", .disabled("not yet implemented"))
    func layout_3_2() async throws { }

    @Test("""
@spec LAYOUT-3.3: When the user adds a directory that is a git worktree (rather than a repository root), the application shall trace back to the parent repository, add the full repository with all its worktrees, and auto-select the added worktree.
""", .disabled("not yet implemented"))
    func layout_3_3() async throws { }

    @Test("""
@spec LAYOUT-3.4: If the user adds a directory that is not a git repository or worktree, then the application shall display an error message and not add the directory.
""", .disabled("not yet implemented"))
    func layout_3_4() async throws { }

    @Test("""
@spec LAYOUT-3.5: If the user adds a repository that is already in the sidebar, then the application shall not create a duplicate and shall select the existing entry.
""", .disabled("not yet implemented"))
    func layout_3_5() async throws { }

    @Test("""
@spec LAYOUT-4.1: When the user right-clicks a repository header row in the sidebar, the application shall display a context menu containing a "Remove Repository" action.
""", .disabled("not yet implemented"))
    func layout_4_1() async throws { }

    @Test("""
@spec LAYOUT-4.2: When the user triggers "Remove Repository", the application shall display a confirmation dialog whose informative text explicitly states "This removes the repository from Graftty but does not delete any files from disk."
""", .disabled("not yet implemented"))
    func layout_4_2() async throws { }

    @Test("""
@spec LAYOUT-4.3: When the user confirms "Remove Repository", the application shall (a) tear down all terminal surfaces in every worktree of the repository whose `state == .running`, (b) stop the repository-level FSEvents watchers (`.git/worktrees/` and origin refs) and each worktree's per-path, HEAD-reflog, and content watchers, (c) clear the cached PR status and divergence stats for every worktree of the repository, (d) clear `selectedWorktreePath` if it pointed to any worktree in the repository, and (e) remove the repository entry from `AppState`. Steps (a)–(d) must precede (e) for the same orphan-surfaces / orphan-caches reasons as GIT-3.10 / GIT-4.10 / GIT-3.13 and the watcher-fd-lifetime reason as GIT-3.11.
""", .disabled("not yet implemented"))
    func layout_4_3() async throws { }

    @Test("""
@spec LAYOUT-4.4: The "Remove Repository" action shall not invoke `git` and shall not modify any files on disk. Worktree directories, branches, and git metadata remain untouched; the operation affects only Graftty's in-memory model and persisted `state.json`.
""", .disabled("not yet implemented"))
    func layout_4_4() async throws { }

    @Test("""
@spec LAYOUT-4.5: When the user adds a repository, the application shall record a `URL` bookmark (`URL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)`) for the repository folder and persist it on the `RepoEntry` alongside the path. Bookmark minting failures shall be non-fatal — the repository entry shall be created with a nil bookmark and forgo auto-recovery.
""", .disabled("not yet implemented"))
    func layout_4_5() async throws { }

    @Test("""
@spec LAYOUT-4.6: On launch, before FSEvents watchers are installed, for each repository entry whose bookmark is non-nil, the application shall resolve the bookmark via `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`. If the resolved path differs from the stored `RepoEntry.path`, the application shall run the relocate cascade described in LAYOUT-4.8. If the bookmark is resolvable but stale (cross-volume move), the application shall re-mint and persist a fresh bookmark from the resolved URL.
""", .disabled("not yet implemented"))
    func layout_4_6() async throws { }

    @Test("""
@spec LAYOUT-4.7: When `WorktreeMonitor` reports a deletion event for a worktree path whose owning repository has a non-nil bookmark, the application shall resolve the bookmark and, if the resolved path differs from the stored `RepoEntry.path`, run the relocate cascade described in LAYOUT-4.8 before applying the existing transition-to-`.stale` path (GIT-3.3). If bookmark resolution fails or the resolved folder is no longer a git repository, the application shall fall through to the existing `.stale` path.
""", .disabled("not yet implemented"))
    func layout_4_7() async throws { }

    @Test("""
@spec LAYOUT-4.8: The relocate cascade for a repository resolved to `newURL` differing from the stored path shall: (a) verify a `.git` entry exists at `newURL.path`, aborting if not, (b) stop all existing watchers tied to old paths, (c) run `GitWorktreeDiscovery.discover(repoPath: newURL.path)`, running `git worktree repair` and re-discovering if any previously-known linked worktree is omitted from the discovery result, (d) update the `RepoEntry`'s `path` and `displayName` to the new location, (e) match each existing `WorktreeEntry` to a discovered worktree by **branch name** and preserve `id`, `splitTree`, `state`, `focusedTerminalID`, `paneAttention`, `attention`, and `offeredDeleteForMergedPR`, updating only `path`, (f) clear per-path PR-status and divergence-stats cache entries for every worktree whose path changed, (g) update `selectedWorktreePath` from its old path to the corresponding new path if applicable, and (h) re-install repository-level and per-worktree FSEvents watchers at the new paths. Steps (a)–(c) shall precede (d) so that a discovery failure leaves the model unchanged.
""", .disabled("not yet implemented"))
    func layout_4_8() async throws { }

    @Test("""
@spec LAYOUT-4.9: For a repository entry loaded from `state.json` without a bookmark (migration from a pre-LAYOUT-4.5 build), the application shall mint a fresh bookmark from the stored `path` if that path still resolves on disk, and persist it.
""", .disabled("not yet implemented"))
    func layout_4_9() async throws { }

    @Test("""
@spec LAYOUT-4.10: The application shall use regular (not security-scoped) bookmarks. Security-scoped bookmarks are unnecessary because Graftty is not sandboxed and `NSOpenPanel` already grants the app arbitrary-path URLs.
""", .disabled("not yet implemented"))
    func layout_4_10() async throws { }

    @Test("""
@spec LAYOUT-5.1: When the user closes the main window (Cmd+W, red traffic-light button, or `File → Close`), the application shall keep running as a foreground app — the Dock icon remains visible, background services (socket listener, channel router, stats/PR pollers, filesystem watchers, web access server) keep running, and any running terminal panes stay attached to their underlying zmx sessions. Closing the window is not a quit; the user explicitly issues `Cmd+Q` or `File → Quit` to terminate the app.
""", .disabled("not yet implemented"))
    func layout_5_1() async throws { }

    @Test("""
@spec LAYOUT-5.2: When the user activates the app from the Dock (click, `Cmd+Tab`, or Spotlight) while no windows are visible, the application shall display the main window again, populated from the already-in-memory `AppState` (repositories, worktrees, selection, and split trees) and with the `WindowFrameTracker` frame-restoration of `PERSIST-3.4` applied to the recreated `NSWindow`. Existing running terminal panes are re-rendered from the persisted `TerminalManager`'s surface map without recreating their underlying libghostty surfaces or zmx sessions.
""", .disabled("not yet implemented"))
    func layout_5_2() async throws { }

    @Test("""
@spec LAYOUT-5.3: The application's one-time startup path (`ghostty_init` and the `ghostty_app_t` construction inside `TerminalManager.initialize()`, the `SocketServer.start()`, the `ChannelRouter.start()`, `reconcileOnLaunch()`, the stats/PR poller `start()` calls, the `restoreRunningWorktrees()` pass, and the `NSApplication.willTerminateNotification` observer registration) shall run exactly once per app-process lifetime, regardless of how many times the root `WindowGroup` scene is instantiated. The SwiftUI reopen flow (`applicationShouldHandleReopen` → `applicationOpenUntitledFile:`) and any future multi-window entry points (`File → New Window`) re-invoke the `WindowGroup` content closure and therefore fire `.onAppear` again; the implementation seam is a `@State` boolean on `GrafttyApp` whose storage persists across scene re-creations. Without this guard, `TerminalManager.initialize()`'s `ghosttyApp == nil` precondition traps the process on the second invocation.
""", .disabled("not yet implemented"))
    func layout_5_3() async throws { }
}
