# Espalier — EARS Requirements Specification

Requirements for a macOS worktree-aware terminal multiplexer built on libghostty.

## 1. App Layout

### 1.1 Window Structure

**LAYOUT-1.1** The application shall display a single main window with a resizable sidebar on the left and a terminal content area on the right.

**LAYOUT-1.2** The sidebar shall be resizable via a drag handle between the sidebar and the terminal content area.

**LAYOUT-1.3** The terminal content area shall display a breadcrumb bar showing the selected repository name, worktree branch, and filesystem path above the terminal split layout.

### 1.2 Sidebar — Repository List

**LAYOUT-2.1** The sidebar shall display an ordered list of repositories, each expandable to show its worktrees.

**LAYOUT-2.2** Each repository entry shall be collapsible and expandable by clicking its disclosure indicator.

**LAYOUT-2.3** When a repository is expanded, the sidebar shall display the repository's own working directory as the first child entry, labeled by its current branch name.

**LAYOUT-2.4** When a repository is expanded, the sidebar shall display each linked worktree as a child entry beneath the repository's own working directory, labeled by branch name.

**LAYOUT-2.5** The sidebar shall display an "Add Repository" button at the bottom.

**LAYOUT-2.6** When the user clicks a worktree or repository working directory entry, the terminal content area shall switch to display that entry's terminal layout.

**LAYOUT-2.7** When the user right-clicks a sidebar entry, the application shall display a context menu with actions appropriate to the entry's current state.

**LAYOUT-2.8** While a worktree is in the running state, the sidebar shall display one indented child row per terminal pane beneath the worktree entry, each labeled by that pane's current title.

**LAYOUT-2.9** If a terminal pane has no program-set title, then the pane's row shall display the fallback label "shell".

**LAYOUT-2.10** When the user clicks a pane row, the application shall select that pane's worktree and focus that specific pane.

**LAYOUT-2.11** The sidebar shall display the active worktree row and all its pane rows inside a single unified highlighted block; within that block, the focused pane's row shall additionally be emphasized via text weight and color (no secondary background).

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

**STATE-2.1** A worktree entry in any state may additionally have an attention overlay.

**STATE-2.2** While a worktree entry has an attention overlay and one or more pane rows are visible beneath it, the sidebar shall replace each pane row's title text with the attention text rendered in a red capsule. Non-running worktrees (no pane rows) display no attention indicator.

**STATE-2.3** When the user clicks a worktree entry that has an attention overlay, the application shall clear the attention overlay.

**STATE-2.4** When the CLI sends a clear message for a worktree, the application shall clear the attention overlay.

**STATE-2.5** When an attention overlay was set with an auto-clear duration, the application shall clear the attention overlay after that duration elapses.

## 3. Terminal Lifecycle

### 3.1 Starting Terminals

**TERM-1.1** When the user clicks a worktree entry in the closed state that has no saved split tree, the application shall create a single terminal pane with its working directory set to the worktree path and transition the entry to the running state.

**TERM-1.2** When the user clicks a worktree entry in the closed state that has a saved split tree, the application shall recreate terminal panes matching the saved split tree topology, each with its working directory set to the worktree path, and transition the entry to the running state.

### 3.2 Switching Between Worktrees

**TERM-2.1** When the user switches from one running worktree to another, the application shall hide the previous worktree's terminal views without destroying the terminal surfaces or their running processes.

**TERM-2.2** When the user switches back to a previously running worktree, the application shall restore the terminal views with all processes still running.

**TERM-2.3** When the user switches back to a running worktree, the application shall restore keyboard focus to the pane that was focused when the user last switched away.

### 3.3 Splitting

**TERM-3.1** When the user triggers a horizontal split, the application shall insert a new terminal pane to the right of the focused pane with a 50/50 ratio.

**TERM-3.2** When the user triggers a vertical split, the application shall insert a new terminal pane below the focused pane with a 50/50 ratio.

**TERM-3.3** The new terminal pane created by a split shall have its working directory set to the worktree root path.

### 3.4 Resizing Splits

**TERM-4.1** The application shall display a draggable divider between split panes.

**TERM-4.2** When the user drags a divider, the application shall resize the adjacent panes proportionally.

**TERM-4.3** When the user drags a divider to a new ratio, the application shall persist the new ratio in the worktree's split tree so that the layout survives app restarts.

**TERM-4.4** When a pane is removed from the split tree, the application shall forward the new layout size to libghostty so remaining panes reflow to fill the vacated space.

### 3.5 Closing a Pane

**TERM-5.1** When the user closes a terminal pane, the application shall remove it from the split tree and allow the sibling pane to fill the vacated space.

**TERM-5.2** When the user closes the last terminal pane in a worktree, the application shall transition the worktree entry to the closed state.

**TERM-5.3** When a terminal pane's child process exits, the application shall automatically remove the pane from the split tree and free its surface without requiring user action.

**TERM-5.4** When an auto-closed pane was the last pane in its worktree, the application shall transition the worktree entry to the closed state, matching the user-initiated close behavior.

### 3.6 Stopping a Worktree

**TERM-6.1** When the user triggers "Stop" on a running worktree, if any terminal surface has a running process, then the application shall display a confirmation dialog before proceeding.

**TERM-6.2** When the user confirms stopping a worktree, the application shall close and free all terminal surfaces in the worktree's split tree, preserve the split tree topology, and transition the entry to the closed state.

### 3.7 Focus Management

**TERM-7.1** When the user clicks a terminal pane, the application shall set keyboard focus to that pane.

**TERM-7.2** The application shall support keyboard navigation between panes using directional shortcuts (e.g., Cmd+Opt+Arrow).

**TERM-7.3** When the user navigates between panes via keyboard, the application shall use the split tree's spatial layout to determine the target pane.

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

### 4.2 Filesystem Monitoring

**GIT-2.1** While a repository is in the sidebar, the application shall watch the repository's `.git/worktrees/` directory for changes using FSEvents.

**GIT-2.2** When a change is detected in `.git/worktrees/`, the application shall re-run `git worktree list --porcelain` and reconcile the results against the current model.

**GIT-2.3** While a repository is in the sidebar, the application shall watch each worktree's directory path for deletion using FSEvents.

**GIT-2.4** While a repository is in the sidebar, the application shall watch each worktree's HEAD reference for changes using FSEvents to detect branch switches.

### 4.3 Change Handling

**GIT-3.1** When a new worktree is detected, the application shall add a new entry in the closed state and briefly flash its background highlight.

**GIT-3.2** When a worktree is removed via `git worktree remove`, the application shall transition the entry to the stale state.

**GIT-3.3** When a worktree's directory is deleted externally, the application shall transition the entry to the stale state.

**GIT-3.4** While a worktree entry is in the stale state and was running, the application shall keep terminal surfaces alive until the user explicitly stops the entry.

**GIT-3.5** When a worktree's HEAD reference changes, the application shall update the entry's branch label in the sidebar.

**GIT-3.6** While a worktree entry is in the stale state, the context menu shall include a "Dismiss" action that removes the entry from the sidebar.

## 5. Attention Notification System

### 5.1 CLI Tool

**ATTN-1.1** The application shall include a CLI binary (`espalier`) in the app bundle at `Espalier.app/Contents/Helpers/espalier`. The CLI is placed in `Contents/Helpers/` (not `Contents/MacOS/`) because on macOS's default case-insensitive APFS, the binary name `espalier` collides with the app's main executable `Espalier` if both are in the same directory. The Swift Package Manager product that builds this binary is named `espalier-cli` for the same reason; it is renamed to `espalier` when installed into the app bundle.

**ATTN-1.2** The CLI shall support the command `espalier notify "<text>"` to set attention on the worktree containing the current working directory.

**ATTN-1.3** The CLI shall support the flag `--clear-after <seconds>` to auto-clear the attention after a specified duration.

**ATTN-1.4** The CLI shall support the command `espalier notify --clear` to clear attention on the current worktree.

**ATTN-1.5** The CLI shall resolve the current worktree by walking up from `$PWD` looking for a `.git` file (linked worktree) or `.git` directory (main working tree).

### 5.2 Communication Protocol

**ATTN-2.1** The application shall listen on a Unix domain socket at `~/Library/Application Support/Espalier/espalier.sock`.

**ATTN-2.2** The CLI shall communicate with the application by sending JSON messages over the Unix domain socket.

**ATTN-2.3** The application shall support the following message types over the socket:
- Notify: `{"type": "notify", "path": "<worktree-path>", "text": "<text>"}`
- Notify with auto-clear: `{"type": "notify", "path": "<worktree-path>", "text": "<text>", "clearAfter": <seconds>}`
- Clear: `{"type": "clear", "path": "<worktree-path>"}`

**ATTN-2.4** The application shall set the environment variable `ESPALIER_SOCK` in each terminal surface's environment, pointing to the socket path.

**ATTN-2.5** The CLI shall read the `ESPALIER_SOCK` environment variable to locate the socket.

### 5.3 Error Handling

**ATTN-3.1** If the application is not running, then the CLI shall print "Espalier is not running" and exit with code 1.

**ATTN-3.2** If the current working directory is not inside a tracked worktree, then the CLI shall print "Not inside a tracked worktree" and exit with code 1.

**ATTN-3.3** If the socket is unresponsive, then the CLI shall time out after 2 seconds, print an error, and exit with code 1.

### 5.4 CLI Distribution

**ATTN-4.1** The application shall provide a menu item (Espalier -> Install CLI Tool...) to create or update a symlink at `/usr/local/bin/espalier` pointing to the CLI binary in the app bundle. CLI installation is opt-in via this menu item; the application shall not auto-prompt for installation on launch.

## 6. Persistence

### 6.1 Storage

**PERSIST-1.1** The application shall store all persistent state in `~/Library/Application Support/Espalier/`.

**PERSIST-1.2** The application shall persist state to a `state.json` file containing: the ordered list of repositories and their worktrees, per-worktree split tree topology and `wasRunning` flag, selected worktree, window frame, and sidebar width.

### 6.2 Save Triggers

**PERSIST-2.1** The application shall save state when any of the following occur: split tree changes, worktree state changes, repository added or removed, selection changes, window resize or move (debounced), app moving to background, or app quit.

### 6.3 Restore on Launch

**PERSIST-3.1** When the application launches with an existing `state.json`, it shall restore the sidebar with all saved repositories and worktrees.

**PERSIST-3.2** When the application launches, it shall restore the saved split tree topology for each worktree.

**PERSIST-3.3** When the application launches, it shall automatically start fresh terminal surfaces for each worktree that had `wasRunning: true`.

**PERSIST-3.4** When the application launches, it shall restore the window frame position, size, and sidebar width.

**PERSIST-3.5** When the application launches, it shall re-select the previously selected worktree.

**PERSIST-3.6** When the application launches, it shall run worktree discovery for each repository to reconcile saved state against current disk state.

### 6.4 Non-Persisted State

**PERSIST-4.1** The application shall not persist shell scrollback, terminal screen buffer content, or the specific processes that were running.

## 7. PWD-Aware Pane Routing

### 7.1 Detection

**PWD-1.1** When a terminal shell reports a new working directory via OSC 7, the application shall evaluate whether the pane belongs under a different worktree in the sidebar.

**PWD-1.2** The application shall select the destination worktree as the one whose filesystem path is the longest prefix of the reported PWD across all repos. If no worktree path is a prefix of the PWD, the pane shall remain in its current worktree.

### 7.2 Reassignment

**PWD-2.1** When the destination worktree differs from the current worktree, the application shall remove the pane from the source worktree's split tree and insert it into the destination worktree's split tree.

**PWD-2.2** When a reassignment leaves the source worktree with no remaining panes, the application shall transition the source worktree to the closed state.

**PWD-2.3** When a reassignment completes, the application shall set the destination worktree as the selected worktree and focus the moved pane so the UI follows the pane the user is actively typing into.

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

**NOTIF-2.1** When libghostty fires `COMMAND_FINISHED` with a zero exit code, the application shall set the owning worktree's attention overlay to a checkmark indicator that auto-clears after 3 seconds.

**NOTIF-2.2** When libghostty fires `COMMAND_FINISHED` with a non-zero exit code, the application shall set the owning worktree's attention overlay to an error indicator that auto-clears after 8 seconds.

**NOTIF-2.3** Auto-populated attention badges from shell-integration events shall share the existing clearing semantics defined in STATE-2.x; a subsequent event on the same worktree replaces the previous badge.

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

**DIVERGE-4.3** The application shall poll every 60 seconds to recompute divergence counts for all worktrees across all repositories, to catch changes to the origin default branch that occur outside the current worktree (e.g., after `git fetch` runs in another terminal).

**DIVERGE-4.4** While a divergence computation is in flight for a particular worktree, duplicate refresh requests for the same worktree shall be dropped.

## 12. Technology Constraints

**TECH-1** The application shall be built in Swift using SwiftUI for app chrome and AppKit for terminal view hosting.

**TECH-2** The application shall use libghostty (via the libghostty-spm Swift Package) as its terminal engine.

**TECH-3** The application shall target macOS 14 Sonoma as its minimum supported version.

**TECH-4** The application shall reuse the following components from the Ghostty project (MIT-licensed): `SplitTree`, `SplitView`, `Ghostty.Surface`, `Ghostty.App`, `Ghostty.Config`, and `SurfaceView_AppKit`.
