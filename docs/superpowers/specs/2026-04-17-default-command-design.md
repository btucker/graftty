# Default Command Setting — Design Specification

A user-configurable "default command" that runs automatically the first time a worktree is opened. Example: set the default command to `claude` and every freshly-opened worktree spawns a shell with Claude Code running on top of it.

## Goal

After this ships, this user story works:

> I set "Default command" to `claude` in Settings. I click Open on a closed worktree in the sidebar. A pane appears, zsh starts, and a moment later `claude` is running inside it. If I Ctrl-D out of `claude`, I'm at a normal shell prompt — I can hit `↑ Enter` to restart it. If I quit Espalier and relaunch, `claude` is still running (zmx kept the shell alive) — it is **not** re-invoked on top of itself. If I explicitly Stop the worktree and reopen it, `claude` launches again.

## Scope

This spec covers **v1 only**: a single global setting with first-pane-only as the recommended mode. Per-worktree and per-repo overrides are out of scope — they are additive later (see "Future extensions" below).

## Architecture

### Storage

Two `UserDefaults` keys, accessed via SwiftUI's `@AppStorage`:

| Key                              | Type   | Default | Meaning                                                            |
| -------------------------------- | ------ | ------- | ------------------------------------------------------------------ |
| `defaultCommand`                 | String | `""`    | Command to run. Empty string = feature disabled.                   |
| `defaultCommandFirstPaneOnly`    | Bool   | `true`  | If true, only the first pane of a worktree runs the command.       |

Why UserDefaults (plist at `~/Library/Preferences/com.espalier.app.plist`) rather than extending `AppState` (`state.json`):

- Preferences are user-scoped; `AppState` is workspace-scoped (open repos, window frame, selected worktree). Keeping them separate matches Apple conventions and keeps each store focused.
- `@AppStorage` is write-through and KVO-observed, so every SwiftUI view reads a live value without any glue.
- No JSON schema migration needed. Adding/removing settings later is free.

### Settings UI

A new SwiftUI `Settings` scene attached to `EspalierApp.body`:

```swift
Settings {
    SettingsView()
}
```

Declaring the `Settings` scene is what causes macOS to:

- add a **Settings…** item to the app menu under "About Espalier", and
- wire the standard `⌘,` keyboard shortcut to it.

No `CommandGroup` modifications are needed; SwiftUI handles this automatically.

`SettingsView` is a single-tab preferences window:

```
┌─ Espalier Settings ────────────────────────────┐
│                                                │
│   General   ← (only tab; TabView anticipates   │
│               future additions)                │
│   ─────────                                    │
│                                                │
│   Default command:  [ claude              ]    │
│                                                │
│   ☑ Run in first pane only                     │
│                                                │
│   Runs automatically when a worktree opens.    │
│   Leave empty to disable.                      │
│                                                │
└────────────────────────────────────────────────┘
```

- No Apply/Cancel buttons — `@AppStorage` is live. This matches System Settings, Xcode Preferences, and other first-party macOS apps.
- The checkbox label reads "Run in first pane only" (positive phrasing, no double negative).

### Trigger: when the command fires

The injection point is the first **`GHOSTTY_ACTION_PWD`** event received for a pane. libghostty does not expose an explicit "prompt ready" action in its public API (`ghostty.h` action enum exposes `PWD` and `COMMAND_FINISHED` for shell-integration events, but no prompt-start equivalent). However, Ghostty's shell integration emits OSC 7 from its `precmd` hook, which fires *before every prompt* — including the very first one. So the first `PWD` event arriving for a newly-spawned pane is a reliable "shell is ready to accept input" signal.

A new callback is added to `TerminalManager`:

```swift
var onShellReady: ((TerminalID) -> Void)?
```

It fires at most once per `TerminalID`, on the first `GHOSTTY_ACTION_PWD` event for that pane. `TerminalManager` tracks which IDs have already fired in a `Set<TerminalID>`. The existing `onPWDChange` callback continues to fire on *every* PWD event (first and subsequent) — `onShellReady` is a separate, first-only signal derived from the same source.

**Why derive from PWD instead of adding a new action upstream:** adding a new `GHOSTTY_ACTION_PROMPT_START` would require patching libghostty and carrying a downstream fork, which is disproportionate for this feature. The PWD-based signal is functionally equivalent — Ghostty's zsh integration always emits OSC 7 from `precmd`, so "first PWD" and "first prompt" are the same event in practice.

`EspalierApp.startup()` wires it:

```swift
terminalManager.onShellReady = { [appState = $appState, tm = terminalManager] terminalID in
    MainActor.assumeIsolated {
        Self.maybeRunDefaultCommand(
            appState: appState,
            terminalManager: tm,
            terminalID: terminalID
        )
    }
}
```

`maybeRunDefaultCommand` logic (in order):

1. Read `defaultCommand` and `firstPaneOnly` from UserDefaults. If `defaultCommand` is empty, return.
2. Locate the worktree that owns `terminalID`. If none (pane is an orphan), return.
3. If this pane was created by `restoreRunningWorktrees()` at app launch (rehydration path), return. This is the "don't re-invoke on top of an already-running `claude`" guarantee.
4. If `firstPaneOnly == true`, return unless this pane is the first pane of its worktree (see "First-pane identity" below).
5. Type `defaultCommand + "\r"` into the surface via libghostty's text-input API, as if the user had typed it at the prompt.

### First-pane identity

A worktree's "first pane" is the pane whose creation caused the worktree to transition from `.closed → .running`. This is determined at creation time, not at run time: when `createSurfaces` (or `createSurface`) is called as part of the open-worktree action in the sidebar / CLI `espalier open`, the resulting pane is marked as first-pane for that worktree.

Concretely, `TerminalManager` gains a map:

```swift
private var firstPaneMarkers: [TerminalID: Bool] = [:]
```

Callers that are opening a worktree (not rehydrating, not splitting) set the flag at surface-creation time. The two call sites are:

- `MainWindow` / sidebar open-worktree action — the pane it creates is a first pane.
- `handleNotification(.notify)` path for CLI `espalier open` when it causes a `.closed → .running` transition (if that code path exists; if not, no-op).

Splits (Cmd+D, context menu, `splitPane`) never mark first-pane. PWD migration (`reassignPaneByPWD`) never marks first-pane — a pane that *moves* into a worktree is not a first-pane event.

### Rehydration marker

Panes recreated by `restoreRunningWorktrees()` at app launch are tagged so step 3 of `maybeRunDefaultCommand` can distinguish them from user-initiated opens. `TerminalManager` gains:

```swift
private var rehydratedSurfaces: Set<TerminalID> = []
```

`restoreRunningWorktrees()` populates this set before calling `createSurfaces`. Entries are cleared when the surface is destroyed.

An alternative considered: adding a parameter `rehydrated: Bool` to `createSurfaces` / `createSurface`. Rejected because it pushes the distinction into every caller that doesn't care — the shared side-set is less invasive.

### Typing the command into the surface

libghostty exposes `ghostty_surface_text` for programmatically injecting text into a surface's PTY (confirmed at `SurfaceHandle.swift:205`, where it already handles user keyboard input). `SurfaceHandle` is the natural place for a new `typeText(_:)` method that forwards to the same C API.

We type `defaultCommand + "\r"` — carriage return, not newline, matching what a terminal emulator sends when the user presses Enter. zsh's line editor consumes this exactly as if the user typed it: it enters command history, supports `↑` recall, and its exit returns the user to the shell. This is the mechanism that implements Q3 answer A.

### What does NOT change

- `AppState`, `WorktreeEntry`, and `state.json` schema are untouched.
- `ZmxLauncher` and the zmx integration are untouched. The feature is entirely above the zmx layer.
- Existing callbacks (`onCloseRequest`, `onSplitRequest`, `onPWDChange`, `onCommandFinished`) are untouched.
- Pane lifetime semantics are unchanged: the default command runs inside the shell, not in place of it, so when the command exits the pane stays open.

## Components

### Modified — `Sources/Espalier/EspalierApp.swift`

- Add the `Settings { SettingsView() }` scene to `body`.
- Add a static `maybeRunDefaultCommand(appState:terminalManager:terminalID:)` that implements the gating logic.
- Wire `terminalManager.onShellReady` in `startup()`.

### Modified — `Sources/Espalier/Terminal/TerminalManager.swift`

- New public callback: `var onShellReady: ((TerminalID) -> Void)?` — fired on first PWD event per `TerminalID`.
- Private state: `shellReadyFired: Set<TerminalID>`, `firstPaneMarkers: [TerminalID: Bool]`, `rehydratedSurfaces: Set<TerminalID>`.
- Modification to `GHOSTTY_ACTION_PWD` handler (line 360): after invoking `onPWDChange`, check `shellReadyFired` and if this is the first PWD for this ID, add to the set and invoke `onShellReady`.
- New public methods:
  - `markFirstPane(_ terminalID: TerminalID)` — called by sidebar/CLI on worktree open.
  - `markRehydrated(_ terminalID: TerminalID)` — called by `restoreRunningWorktrees`.
  - `isFirstPane(_ terminalID: TerminalID) -> Bool`.
  - `wasRehydrated(_ terminalID: TerminalID) -> Bool`.
- Internal: dispatch `onShellReady` on the first prompt-ready event per ID. Gate via `shellReadyFired`.
- Cleanup: when a surface is destroyed, remove its entries from all three tracking sets.

### Modified — `Sources/Espalier/Terminal/SurfaceHandle.swift`

- New method `typeText(_ text: String)` that forwards to libghostty's text-input API.

### New — `Sources/EspalierKit/DefaultCommandDecision.swift`

Pure decision function extracted from `maybeRunDefaultCommand` so it can be unit-tested without a running `NSApplication` or libghostty surface. See "Testing" below for the exact signature. `EspalierApp.maybeRunDefaultCommand` becomes a thin wrapper: gather inputs from UserDefaults / TerminalManager, call the pure function, act on the result.

### New — `Sources/Espalier/Views/SettingsView.swift`

- A `TabView` with one tab ("General") containing:
  - `TextField` bound to `@AppStorage("defaultCommand")`.
  - `Toggle` bound to `@AppStorage("defaultCommandFirstPaneOnly")`.
  - Footer text describing behavior.
- Frame hint (`.frame(width: 420)`) sized for two controls + some breathing room.

### Modified — caller sites that open a worktree

Identify every path that transitions a worktree from `.closed → .running` and, after calling `createSurfaces`, call `terminalManager.markFirstPane(<first-terminal-id>)`. This is expected to be exactly two sites: the sidebar "Open" action in `MainWindow` / `SidebarView`, and CLI-driven opens in `handleNotification`.

### Modified — `restoreRunningWorktrees()`

Before invoking `createSurfaces`, call `terminalManager.markRehydrated(...)` for each leaf in the restored tree. This ensures rehydrated surfaces are flagged before their first prompt-ready event could possibly fire.

## Edge cases

**Shell integration disabled.** If the user's shell is not set up with Ghostty shell integration (or they're using an unsupported shell), no `PWD` event is emitted, `onShellReady` never fires, and the default command never runs. This is an intentional no-op — it's strictly better than a time-based fallback that would race unpredictably. If a user reports this as a problem, we can add a timer-based fallback later.

**Command contains special characters.** `defaultCommand` is typed literally, followed by `\r`. Quoting is the user's responsibility, same as if they typed it at the prompt. `claude --model opus` works. `some script with "quotes"` works. Multi-line commands are not supported — the `\r` is treated as command termination.

**Worktree re-opened after explicit Stop.** Stop tears down zmx sessions. The next Open is a fresh `.closed → .running` transition. The command fires again. Correct.

**Pane migrates in via OSC 7.** A shell that `cd`s into a different worktree triggers `reassignPaneByPWD` (EspalierApp.swift:174), which moves the pane's ownership in the sidebar. The migrated pane is not a "first pane" of the destination worktree — `firstPaneMarkers` for its `TerminalID` was never set. Correct.

**Worktree is `.stale`.** Stale worktrees cannot be opened (the sidebar prevents it). N/A.

**User changes the default command while a pane is open.** The new value takes effect on the next `.closed → .running` transition. Existing panes are not affected — we do not type into live panes when settings change.

**User sets `defaultCommand` to empty while `firstPaneOnly` is true.** The empty-string check happens first, so the feature is disabled regardless of the checkbox state. No surprise behavior.

## Testing

Scope: EspalierKit has unit tests; `Espalier` (UI target) has no test target today. This feature's core logic is a gating function — `maybeRunDefaultCommand` — that consumes a snapshot of (UserDefaults values, `firstPaneMarkers`, `rehydratedSurfaces`, worktree lookup) and emits a "type this string" decision. That is pure enough to test.

Plan:

- Extract the decision into a pure function in `EspalierKit`:
  ```swift
  public enum DefaultCommandDecision: Equatable {
      case skip
      case type(String)
  }

  public func defaultCommandDecision(
      defaultCommand: String,
      firstPaneOnly: Bool,
      isFirstPane: Bool,
      wasRehydrated: Bool
  ) -> DefaultCommandDecision
  ```
- Write unit tests in `EspalierKitTests` covering:
  - empty command → `.skip`
  - rehydrated pane → `.skip` (regardless of other inputs)
  - non-first-pane + `firstPaneOnly == true` → `.skip`
  - non-first-pane + `firstPaneOnly == false` → `.type(command)`
  - first-pane + any `firstPaneOnly` → `.type(command)`
- The UI-side test (actually typing into a libghostty surface) is manual: set a default command, open a closed worktree, observe.

## Future extensions (out of scope)

- Per-worktree override: add `defaultCommandOverride: String??` to `WorktreeEntry` (double-optional distinguishes "inherit global" from "explicitly no command"). Add a right-click sidebar item or detail inspector to set it. The gating function gains a `worktreeOverride: String??` parameter; the decision changes trivially.
- Per-repo override: same shape, on `RepoEntry`. Resolution order: worktree → repo → global.
- Additional settings tabs: "Appearance," "Advanced," etc. Adding tabs is mechanical once the `TabView` scaffolding exists.
- Timer-based fallback for when shell integration is absent. Only if users ask.
