# Graftty — Design Specification

A macOS app built on libghostty that provides a persistent, worktree-aware terminal multiplexer. Users add git repositories to a sidebar, Graftty discovers all associated worktrees, and each worktree gets its own set of always-alive, splittable terminal sessions. A CLI tool enables processes running inside terminals to signal "attention needed" back to the sidebar.

## 1. App Layout

### Main Window

Single-window app (designed so multi-window can be added later without architectural changes).

Two regions:

- **Sidebar (left):** A tree of repositories, each expandable to show its worktrees. Resizable via drag handle. "Add Repository" button at the bottom.
- **Terminal area (right):** The split terminal layout for the currently selected worktree. A breadcrumb bar at the top shows context: repo name / worktree branch / filesystem path.

### Sidebar Structure

Each repository appears as a collapsible header. Beneath it:

1. The repo's own working directory (labeled by its current branch, e.g., "main") — this is a terminal target just like worktrees.
2. Each worktree, listed by branch name.

Sidebar supports:
- Expand/collapse repos
- Click any entry to switch the terminal area
- Right-click for context menu (Stop, Dismiss, etc.)
- Drag & drop directories onto the sidebar to add repos
- File picker via "Add Repository" button

### Adding Repositories

- **File picker:** Standard macOS open panel, select a directory.
- **Drag & drop:** Drop a directory onto the sidebar.
- **Smart detection:** If the user adds a worktree directory (rather than a repo root), Graftty traces back to the parent repository and adds the full repo with all its worktrees. The dropped worktree is auto-selected.

### Worktree Entry States

Each worktree entry in the sidebar has one of three states plus an optional attention overlay:

| State | Visual | Meaning |
|-------|--------|---------|
| **Closed** | Hollow dot (○) | No terminals running. Click to start fresh sessions. |
| **Running** | Green dot (●) | Terminals alive, processes running. Switching away just hides the view. |
| **Stale** | Warning icon (⚠), strikethrough, grayed out | Worktree deleted from disk. Terminals may still be alive. User dismisses manually. |
| **Attention** (overlay) | Red badge with custom text | A process signaled attention via the CLI. Clears on focus, on CLI clear, or on auto-timer. |

## 2. Architecture

Three-layer architecture: Model, Terminal Manager, UI.

### Model Layer (pure Swift, no UI dependencies)

- **`AppState`** — Root object. Holds an ordered list of `RepoEntry` objects and app-level state (selected worktree, window geometry, sidebar width). Handles persistence to disk.
- **`RepoEntry`** — One repository. Contains: filesystem path, display name, collapsed state, and an ordered list of `WorktreeEntry` objects (including one for the repo's own working directory).
- **`WorktreeEntry`** — One worktree. Contains: filesystem path, branch name, state enum (`closed | running | stale`), optional `Attention` info, and a `SplitTree<TerminalID>` describing the terminal layout topology.
- **`SplitTree<T>`** — Generic immutable value type representing a binary tree of splits. Borrowed from Ghostty's implementation. Nodes are either `.leaf(T)` or `.split(direction, ratio, left, right)`. Supports insert, remove, replace, spatial focus navigation, and equalize operations.
- **`TerminalID`** — A UUID identifying a terminal pane. The split tree holds these; the terminal manager maps them to live surfaces.
- **`Attention`** — Struct with `text: String`, `timestamp: Date`, and optional `clearAfter: TimeInterval`.

### Terminal Manager Layer (bridges model to libghostty)

- **`TerminalManager`** — Owns the single `ghostty_app_t` instance and a dictionary mapping `TerminalID` to `SurfaceHandle`.
- **`SurfaceHandle`** — Wraps a `ghostty_surface_t` and its backing `NSView`. Created when a worktree transitions from closed to running. Destroyed only when explicitly stopped or the app quits.
- Responsibilities:
  - Calling `ghostty_app_tick()` on wakeup (dispatched to main thread)
  - Handling libghostty's action callback (split requests, title changes, etc.)
  - Creating surfaces with `working_directory` set to the worktree path
  - Setting `GRAFTTY_SOCK` environment variable on each surface for CLI discoverability
  - Managing surface focus state

### UI Layer (SwiftUI + AppKit hosting)

- **`SidebarView`** (SwiftUI) — Renders the repo/worktree tree from `AppState`. Handles selection, drag & drop, context menus.
- **`TerminalContentView`** (SwiftUI) — Recursively renders the active worktree's `SplitTree`. For each `TerminalID` leaf, wraps the corresponding `NSView` from `TerminalManager` in an `NSViewRepresentable`.
- **`SplitView`** (SwiftUI) — Borrowed from Ghostty. Renders two children with a draggable divider. Supports horizontal and vertical orientations.
- **Breadcrumb bar** — Shows repo name, worktree branch, and filesystem path for the current selection.

### Data Flow

1. User clicks worktree in sidebar -> `AppState` updates selection.
2. UI reads the selected worktree's `SplitTree<TerminalID>`.
3. For each leaf, UI asks `TerminalManager` for the corresponding `NSView`.
4. If the worktree is `closed`, transitioning to `running` tells `TerminalManager` to create surfaces for every leaf in the split tree.
5. Switching away from a worktree does NOT destroy surfaces — the views are simply removed from the visible hierarchy while the surfaces continue running.

## 3. Worktree Discovery & Monitoring

### Initial Discovery

When a repo is added, Graftty runs `git worktree list --porcelain` against the repo's git directory. This returns every worktree's path, HEAD commit, and branch name in a machine-parseable format. The repo's own working directory is the first entry.

### Ongoing Monitoring

Three categories of FSEvents watchers:

1. **`.git/worktrees/` directory watcher (one per repo)** — Detects `git worktree add` and `git worktree remove` operations. When a change fires, re-run `git worktree list --porcelain` and diff against the current model.

2. **Per-worktree path watcher** — Detects when a worktree directory is deleted externally (e.g., `rm -rf`). If the directory disappears, the entry transitions to `stale`.

3. **Per-worktree HEAD ref watcher** — Watches each worktree's HEAD reference (`.git/worktrees/<name>/HEAD` for linked worktrees, `.git/HEAD` for the main working tree) to detect branch changes and update the sidebar label.

`git worktree list --porcelain` is always the source of truth. FSEvents watchers are triggers, not parsers.

### Change Handling

- **New worktree detected:** New `WorktreeEntry` added in `closed` state. The new entry briefly flashes its background highlight to draw the user's eye.
- **Worktree removed via git:** Entry transitions to `stale`. If it was `running`, surfaces stay alive — the sidebar shows the stale indicator. User stops and dismisses manually.
- **Worktree directory deleted externally:** Same as above — detected by path watcher, marked stale.
- **Branch name changes:** The HEAD ref watcher detects when a worktree checks out a different branch, updating the sidebar label.

## 4. Terminal Lifecycle & Split Management

### Starting Terminals

When a user clicks a `closed` worktree:

1. If no saved split tree exists, create a default `SplitTree` with a single leaf (`TerminalID`).
2. If a saved split tree exists (from a previous stop), reuse its topology.
3. `TerminalManager` creates a `ghostty_surface_t` for each leaf, configured with `working_directory` set to the worktree's path.
4. State transitions to `running`.

### Splitting

When the user triggers a split (keyboard shortcut or menu):

1. A new `TerminalID` leaf is inserted into the `SplitTree` adjacent to the focused pane, with the requested direction and a 50/50 ratio.
2. `TerminalManager` creates a new surface for the new ID, with `working_directory` set to the worktree root.
3. The UI re-renders the tree. The existing surface stays alive in place.

### Resizing Splits

Dragging a divider updates the `ratio` on the parent `.split` node. libghostty surfaces receive a `ghostty_surface_set_size` call when their containing view resizes.

### Closing a Single Pane

Removes the leaf from the `SplitTree` and calls `ghostty_surface_request_close`. The sibling takes the parent's place in the tree. If it was the last pane, the worktree transitions to `closed`.

### Stopping a Worktree

Right-click -> Stop (or keyboard shortcut):

1. If any surface reports a running process (`ghostty_surface_needs_confirm_quit`), show a confirmation dialog.
2. On confirm, every surface in the split tree is closed and freed.
3. The `SplitTree` topology is preserved in the model so reopening restores the same layout.
4. State transitions to `closed`.

### Focus Management

- Clicking a pane sets focus on that surface and removes it from the previous one.
- Keyboard navigation between panes (e.g., Cmd+Opt+Arrow) uses `SplitTree`'s spatial navigation, matching Ghostty's `focusTarget(for:from:)` pattern.
- When switching worktrees, the previously focused pane in each worktree is remembered and restored.

## 5. Attention Notification System

### CLI Tool: `graftty`

A small standalone binary distributed inside the app bundle at `Graftty.app/Contents/MacOS/graftty`.

```
graftty notify "Build failed"          # set attention on current worktree
graftty notify --clear                  # clear attention on current worktree
graftty notify "Done" --clear-after 10  # auto-clear after 10 seconds
```

### Worktree Resolution

The CLI walks up from `$PWD` looking for a `.git` file (worktrees have a `.git` file pointing to the main repo) or a `.git` directory (main working tree). It sends the resolved path to the app, which matches it against known entries.

### Communication Protocol

- **Transport:** Unix domain socket at `~/Library/Application Support/Graftty/graftty.sock`.
- **Messages:** JSON, one per line.
- **Notify:** `{"type": "notify", "path": "/path/to/worktree", "text": "Build failed"}`
- **Notify with auto-clear:** `{"type": "notify", "path": "/path/to/worktree", "text": "Done", "clearAfter": 10}`
- **Clear:** `{"type": "clear", "path": "/path/to/worktree"}`

### Environment Variable

`TerminalManager` sets `GRAFTTY_SOCK` in each terminal's environment, pointing to the socket path. The CLI reads this variable. Other tools can also write directly to the socket without using the CLI.

### Attention Lifecycle

Attention clears in three ways:

1. **User clicks into the worktree** — clears on focus.
2. **CLI sends a clear message.**
3. **Auto-clear timer** expires (if `--clear-after` was specified).

### CLI Distribution

On first launch (or via menu: Graftty -> Install CLI Tool...), the app offers to create a symlink at `/usr/local/bin/graftty` pointing into the app bundle.

### Error Cases

- App not running: CLI prints "Graftty is not running", exits 1.
- Not inside a tracked worktree: CLI prints "Not inside a tracked worktree", exits 1.
- Socket unresponsive: 2-second timeout, prints error, exits 1.

## 6. Persistence

### Storage Location

`~/Library/Application Support/Graftty/`

### State File: `state.json`

Contains:
- Ordered list of repos, each with their worktrees
- Per-worktree: path, branch, split tree topology, `wasRunning` flag
- Selected repo and worktree
- Window frame (position and size)
- Sidebar width

### When State Is Saved

- Split tree changes (add/remove/resize pane)
- Worktree state changes (started, stopped, attention)
- Repo added/removed
- Selection changes
- Window resize/move (debounced)
- App moving to background
- App quit

### Restore on Launch

1. Load `state.json`.
2. Repos and worktrees reappear in the sidebar.
3. Split tree topologies are restored.
4. Worktrees with `wasRunning: true` automatically start fresh terminal surfaces in their saved layout.
5. Window position and sidebar width are restored.
6. The previously selected worktree is re-selected.
7. Worktree discovery runs immediately, reconciling saved state against current disk state (detecting adds/removes that happened while the app was closed).

### What Does NOT Persist

- Shell scrollback or command history (the shell's responsibility)
- Terminal screen buffer content
- The specific processes that were running

## 7. Code Reuse from Ghostty

Ghostty (MIT-licensed) provides several Swift components that map directly to Graftty's needs.

### Direct Reuse

| Ghostty Source | Graftty Usage |
|----------------|----------------|
| `macos/Sources/Features/Splits/SplitTree.swift` | `SplitTree<TerminalID>` — generic split tree data structure with insert, remove, spatial navigation, equalize |
| `macos/Sources/Features/Splits/SplitView.swift` | SwiftUI split view with draggable divider, horizontal/vertical |
| `macos/Sources/Ghostty/Ghostty.Surface.swift` | Swift wrapper around `ghostty_surface_t` — lifecycle, input forwarding |
| `macos/Sources/Ghostty/Ghostty.App.swift` | Swift wrapper around `ghostty_app_t` — runtime config, callback registration, wakeup/tick |
| `macos/Sources/Ghostty/Ghostty.Config.swift` | Config wrapper around `ghostty_config_t` |
| `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` | NSView subclass hosting a terminal surface — NSTextInputClient, keyboard/mouse forwarding, resize |

### Adapt

| Ghostty Source | Adaptation |
|----------------|------------|
| `macos/Sources/Features/Splits/TerminalSplitTreeView.swift` | Adapt recursive renderer — our tree holds `TerminalID` resolved through `TerminalManager`, not direct view references |
| `macos/Sources/Features/Terminal/BaseTerminalController.swift` | Extract split-handling patterns; our window structure (sidebar + content) differs from Ghostty's (tabs) |

### Dependency

For libghostty itself, use the `libghostty-spm` Swift Package (prebuilt GhosttyKit binaries) to avoid building from Zig source initially.

## 8. Technology Stack

- **Language:** Swift
- **UI framework:** SwiftUI for app chrome (sidebar, breadcrumbs, layout), AppKit for terminal view hosting
- **Terminal engine:** libghostty via libghostty-spm Swift Package
- **Rendering:** Metal (managed by libghostty, no Metal code in Graftty)
- **File watching:** FSEvents via `DispatchSource.makeFileSystemObjectSource`
- **IPC:** Unix domain socket (app listens, CLI connects)
- **Persistence:** JSON file in `~/Library/Application Support/Graftty/`
- **Build system:** Xcode / Swift Package Manager
- **Minimum macOS version:** macOS 14 Sonoma (for latest SwiftUI features including `NavigationSplitView` refinements)
