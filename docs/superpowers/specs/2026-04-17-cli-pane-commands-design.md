# CLI Pane Commands — Design

**Status:** Approved (2026-04-17)

## Problem

The `espalier` CLI currently has one subcommand, `notify`. Users have no way to add, remove, or enumerate panes from the shell. Everything goes through the UI (Cmd+D, context menu, Cmd+W). We want shell-driven pane management so users can script pane layouts, launch tools into fresh panes from a shell alias, etc.

## Scope

Three new subcommands, grouped under `pane`:

```
espalier pane list
espalier pane add   [--direction right|left|up|down]  [--command "..."]
espalier pane close <id>
```

All three resolve the target worktree from the current working directory, same rule `notify` uses. If PWD is not inside a tracked worktree, they exit 1 with the existing error message.

Out of scope:
- Pane focus/navigation from the CLI (no `pane focus`).
- Cross-worktree operations (no `--worktree PATH` override — PWD only).
- Stable pane IDs across add/close operations (see "Pane IDs" below).
- Structured layout files / layout presets.

## CLI Shape

### `pane add`

- `--direction` (default `right`) accepts `right | left | up | down`, matching the four `PaneSplit` cases already used by the context menu.
- `--command` is optional. When present, the text is typed into the new pane followed by `\n`, so `--command "claude"` launches a CLI tool in the new pane.
- The target pane (what gets split) is the currently-focused pane in the worktree. If no pane is focused yet (edge case — empty worktree in `running` state), fall back to the first leaf in `splitTree.allLeaves`.
- Fire-and-forget from the CLI's perspective, but the server responds with `{ "ok": true }` / error so the CLI exits non-zero on failure (e.g., worktree not running).

### `pane close`

- Takes a required integer `<id>` as returned by `pane list`.
- Server validates the id against the current `splitTree.allLeaves` of the PWD's worktree. Invalid id → non-zero exit + stderr message (`no pane with id N in this worktree`).
- Internally routes through the existing `closePane` helper, same path Cmd+W uses.

### `pane list`

- Prints one line per pane in `splitTree.allLeaves` order. 1-based IDs. Format:

  ```
  * 1  zsh — /repo
    2  claude
    3  logs
  ```

- `*` marks the focused pane (matches `wt.focusedTerminalID`).
- Title column is the value `TerminalManager.titles[terminalID]` if set, else empty. No trailing padding on an empty title.
- Exits 0 even if the worktree has zero panes (just prints nothing).

## Pane IDs

**Per-worktree, 1-based, assigned on each `list` call by traversing `splitTree.allLeaves`.** Not persisted. Not stable across add/close operations.

Rationale:
- Matches how tmux numbers panes — users familiar with tmux will expect this.
- Alternative (stable IDs for the session) means we'd need a monotonic counter per worktree and have to expose gaps ("pane 2 was closed, now you have 1 and 3"). Not worth the complexity.
- The UUID `TerminalID` is the internal stable identity; IDs are a presentation concern only.

Implication for scripts: if you're closing multiple panes, do it high-to-low (`close 3` then `close 2`), or re-run `list` between each close. Documented in `--help`.

## Wire Protocol

### Three new `NotificationMessage` cases

Added to `Sources/EspalierKit/Notification/NotificationMessage.swift`:

```swift
case listPanes(path: String)
case addPane(path: String, direction: PaneSplitWire, command: String?)
case closePane(path: String, index: Int)
```

`PaneSplitWire` is a `String`-backed `Codable` enum (`"right" | "left" | "up" | "down"`) living in `EspalierKit` so the CLI can encode it without depending on the app-layer `PaneSplit` enum. The app maps it to `PaneSplit` when handling.

Codable `type` keys: `"list_panes"`, `"add_pane"`, `"close_pane"` — snake_case, matching the existing `"notify"` / `"clear"` convention.

### Socket contract change: responses allowed

Today the server reads JSON, dispatches to `onMessage`, closes the connection. No reply. For `list` and any error reporting, we need bidirectional messages.

Minimal change:

- `SocketServer` gains a new callback: `onRequest: ((NotificationMessage) -> ResponseMessage?)?`. When set, after `onMessage` fires, the server calls `onRequest` and, if it returns non-nil, writes the encoded JSON + `\n` to the client before closing.
- `SocketClient.send(_:)` grows a `sendExpectingResponse(_:) -> ResponseMessage?` variant. For `notify` / `clear`, the CLI keeps using the existing fire-and-forget `send`.
- `ResponseMessage` is a new `Codable` enum in `EspalierKit`:

  ```swift
  enum ResponseMessage: Codable {
      case ok
      case error(String)
      case paneList([PaneInfo])
  }

  struct PaneInfo: Codable {
      let id: Int          // 1-based
      let title: String?
      let focused: Bool
  }
  ```

The CLI prints `paneList` in the format above, prints `.error` to stderr and exits 1, treats `.ok` as success.

## In-App Execution

In `EspalierApp.handleNotification`, add three branches (pattern-match on the new cases). Each finds the target worktree via the existing path (scan `appState.repos[*].worktrees` for one matching `path`).

### `.listPanes`

- If worktree not found, respond `.error("not tracked")`.
- Otherwise enumerate `wt.splitTree.allLeaves`, build a `PaneInfo` for each (index i+1, `terminalManager.titles[leafID]`, `leafID == wt.focusedTerminalID`).
- Respond `.paneList(...)`.

### `.addPane`

- If worktree not `running`, respond `.error("worktree not running")`.
- Resolve target `TerminalID`: `wt.focusedTerminalID ?? wt.splitTree.allLeaves.first`. If both nil, respond `.error("no panes to split")`.
- Map wire direction to `PaneSplit` and call the existing `splitPane(appState:terminalManager:targetID:split:)` static helper. It already creates the leaf, updates `AppState`, spawns the surface, and focuses.
- If `command` is present, after `splitPane` returns, fetch the new surface's `SurfaceHandle` via `terminalManager.handle(for: newID)` and call `ghostty_surface_text` with the command bytes followed by `\n`. The new `TerminalID` isn't returned by `splitPane` today; we refactor it to return `TerminalID?` (nil if it no-opped). Caller sites are: this new branch, the Cmd+D handler, and the context-menu handler. The latter two ignore the return value.
- Respond `.ok`.

### `.closePane`

- If worktree not found, respond `.error("not tracked")`.
- Look up `wt.splitTree.allLeaves` and validate `1 <= index <= count`. Out of range → `.error("no pane with id N in this worktree")`.
- Translate `index` → `TerminalID` and call the existing `closePane(appState:terminalManager:targetID:)` static helper.
- Respond `.ok`.

## Command Injection via `ghostty_surface_text`

Rationale for typing-in rather than plumbing libghostty's `command` config field:
- libghostty does accept an initial command, but wiring it through `ghostty_surface_config_s` touches surface-creation code and requires a new plumb from `TerminalManager.createSurface` down to `SurfaceHandle`. Not hard, but touches core paths.
- `ghostty_surface_text` is the API libghostty exposes for sending text to the PTY — same function the upstream `paste_from_clipboard` action uses. Proven path.
- Timing caveat: the shell needs to have drawn its prompt before the text arrives, otherwise the first characters get eaten by the shell's startup. In practice, even a fresh zsh on macOS is ready within milliseconds. If this turns out to be flaky, the fallback is the libghostty-config path — we can switch later without changing the CLI shape.
- No delay/retry logic. If it's unreliable, we'll know quickly and do the proper thing. Don't build speculative robustness.

## File Changes

New files:
- None.

Modified files:
- `Sources/EspalierKit/Notification/NotificationMessage.swift` — add three cases, codable encoding. `ResponseMessage` + `PaneInfo` live in this same file to keep the wire protocol co-located.
- `Sources/EspalierKit/Notification/SocketServer.swift` — add `onRequest` callback, write response before close.
- `Sources/EspalierCLI/SocketClient.swift` — add `sendExpectingResponse`.
- `Sources/EspalierCLI/CLI.swift` — add `Pane` parent command with three subcommands.
- `Sources/Espalier/EspalierApp.swift` — wire `onRequest` in `startup()`, add the three branches to `handleNotification` (or split it into a dispatcher + per-case helpers — file is 745 lines already, worth keeping tidy). `splitPane` gains a `TerminalID?` return value.

## Testing

Unit tests (in `Tests/EspalierKitTests`):
- `NotificationMessage` round-trip encoding/decoding for each new case, including the `command: nil` vs `command: "x"` branches.
- `ResponseMessage` round-trip encoding/decoding.
- Index-to-leaf resolution: given a `SplitTree` with N leaves, index 0 / N+1 / negative return nil; valid indices return the expected `TerminalID`.

Integration test (in `Tests/EspalierKitTests`):
- Spin up a `SocketServer` with a stub `onRequest` that returns `.paneList([...])`, write a `listPanes` request from a test client, assert the decoded response.

No integration tests for `addPane` / `closePane` — they require a live `TerminalManager` and libghostty surfaces, which the existing test harness doesn't set up. The risk surface is covered by the unit tests on the message plumbing + the reused `splitPane`/`closePane` helpers that have existing coverage via the UI paths.

## Open Questions

None — all raised questions were resolved during brainstorming (B for pane IDs, approved overall design).
