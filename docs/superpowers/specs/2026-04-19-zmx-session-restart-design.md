# zmx Session Restart Recovery — Design Specification

How Espalier detects and recovers from a zmx session that no longer exists at the moment Espalier touches it. Covers two scenarios — cold-start with a missing daemon, and mid-flight daemon death — using one detection mechanism and one recovery shape.

## Goal

After this ships, these user stories work:

> **Cold-start, daemon missing.** I quit Espalier. While Espalier is closed, my Mac reboots (or I delete `~/Library/Application Support/Espalier/zmx`, or zmx itself crashes — anything that loses the daemons). I relaunch Espalier. The worktree that was open before relaunches with its panes restored, and the panes work. Because the underlying session is fresh, my configured **default command** runs in those panes, just as if I had freshly opened the worktree.

> **Mid-flight, daemon dies.** I'm using Espalier with a worktree open and an active pane. Something kills the zmx daemon backing that pane (manual `zmx kill` from another terminal, OOM, zmx crash, `ZMX_DIR` wiped). My pane does not silently disappear. Instead, the pane stays in its split-tree slot, a banner line `— session restarted at HH:MM —` is printed, and a fresh shell appears in the same pane.

## Scope

This spec covers the recovery-on-detection behavior. It does **not** address:

- Notifying the user out-of-band (no menu-bar badge, no Notification Center alert) — recovery is silent except for the in-pane banner.
- Preserving any pre-restart shell state — scrollback, cwd, env, jobs are all gone with the daemon (we verified `zmx history` returns nothing across daemon restarts; see **Background** below).
- Heuristics for "is the daemon healthy right now" — we only check at moments where Espalier is already touching zmx (create, close).

## Background

Two relevant facts gathered before writing this spec:

1. **`zmx attach <name>` is idempotent-or-create.** From `zmx --help`: "Attach to session, creating if needed." If the daemon for `<name>` exists, `attach` reattaches and replays scrollback. If it does not, `attach` spawns a new daemon under that name and starts a fresh shell in it. There is no "session not found" failure path when the name is simply absent.
2. **Scrollback does not survive daemon death.** Verified empirically: `zmx run name echo X` → `zmx history name` shows X → `zmx kill --force name` → `zmx run name echo Y` → `zmx history name` shows only Y. zmx keeps scrollback in the daemon's in-memory ring buffer; there is no on-disk WAL.

The first fact means cold-start recovery is largely automatic at the libghostty/zmx layer: a restored pane that points at a dead daemon will quietly get a fresh daemon and a fresh shell with no errors. The user-visible problem is purely Espalier-layer state — specifically the **rehydration label** described next.

## The bug being fixed

`Sources/EspalierKit/DefaultCommandDecision.swift:32` short-circuits on `wasRehydrated`:

```swift
if wasRehydrated { return .skip }
```

The accompanying comment reads: *"Rehydrated panes never auto-run — the command is already presumed running under zmx."* That presumption holds **only when the daemon survived**. When the daemon is dead, the pane is fresh-but-labeled-rehydrated, the default command is silently suppressed, and the user sees a bare shell where they expected (e.g.) `claude` running.

## Architecture

### One detection function

A new `EspalierKit` helper:

```swift
/// True when the zmx daemon for the given session name is not currently
/// alive in our `ZMX_DIR`. Returns `false` (no loss detected) on any
/// query failure — we prefer false-negatives over false-positives so a
/// transient `zmx list` failure does not cause spurious "session
/// restarted" banners.
public extension ZmxLauncher {
    func isSessionMissing(_ sessionName: String) -> Bool { ... }
}
```

Implementation: wraps the existing `listSessions()` in a do/catch; returns `!sessions.contains(name)` on success, returns `false` on throw. The fail-safe direction (treat unknown as "not missing") is deliberate — `listSessions()` itself throws on subprocess launch failure, which would also break every other zmx interaction; we don't want that to cascade into rebuilding every pane on screen.

### Two call sites

The detection function is called from exactly two places, each handling one of the two scenarios:

**Site 1 — cold-start, in `TerminalManager.createSurface(s)`.** Just before invoking `ghostty_surface_new`, if the pane is in `rehydratedSurfaces`, call `isSessionMissing` for the pane's session name. If the session is missing, remove the pane from `rehydratedSurfaces`. This makes the rehydration label reflect post-spawn truth: a pane is only "rehydrated" if there was actually something to rehydrate to.

**Site 2 — mid-flight, in `TerminalManager`'s close-surface handling.** When `close_surface_cb` fires (today this destroys the surface and emits `onCloseRequest`), check `isSessionMissing` for the pane's session. If the session is missing **and** Espalier did not initiate the close, route to the recovery path instead of destroying.

"Espalier did not initiate the close" needs a small piece of state to disambiguate — the user typing `exit` triggers our `zmx kill --force`, and the subsequent close should not be treated as session-loss. A `Set<TerminalID>` named `intentionalCloses` populated by `requestClose`/the Cmd+W path covers it. Membership is consumed by the close handler.

### One recovery shape

**For Site 1 (cold-start)** there is no rebuild — `zmx attach`'s create-on-miss already handed us a working surface. The only effect is the rehydration-label clear, which lets `maybeRunDefaultCommand` fire normally on the first PWD event. No banner is printed because, from the user's perspective, this is the same as opening the worktree fresh — they already know the app was closed, and the default command running is itself the "you have a fresh session" signal.

**For Site 2 (mid-flight)** we rebuild the surface in place:

1. Destroy the dead `SurfaceHandle` (libghostty surface free, userdata box release).
2. Create a new `SurfaceHandle` with the same `TerminalID`, the same worktree path, the same `ESPALIER_SOCK`, and the same `ZMX_DIR`. Same session name (deterministic from `TerminalID.id`), so `zmx attach` self-creates the daemon under the expected name.
3. Prepend a banner line to `initial_input` ahead of the `exec zmx attach …`:
   ```
   printf '\n\033[2m— session restarted at <HH:MM> —\033[0m\n'
   ```
   followed by a literal newline. `<HH:MM>` is computed in Swift and embedded as a string literal — we do not use `$(date …)` because the surrounding pipeline must work for bash, zsh, and fish, and command-substitution syntax differs across them. `printf` itself is portable. ANSI dim (`\033[2m` … `\033[0m`) visually distinguishes the banner from real shell output. The banner is executed by the outer shell *before* the `exec`, so the user sees it for an instant before the new inner shell takes over.
4. Update `surfaces[terminalID]` to point at the new handle. The split-tree references this slot by `TerminalID`, which is unchanged, so SwiftUI re-renders the pane without any tree mutation.

The pane never leaves the tree, no `onCloseRequest` fires, no rehydration label is set or cleared (mid-flight panes were never rehydrated to begin with).

### Why the same code, said precisely

The two sites share `isSessionMissing(_:)` and the rule "session-missing → don't take the default destroy path." They diverge on what they do instead, because they're at different points in the surface lifecycle:

- Site 1 is *before* the surface exists — there's nothing to rebuild, only a label to correct.
- Site 2 is *after* the surface has died — the only repair is in-place rebuild.

Trying to force a single recovery routine across both would require either deferring the rehydration check to after-spawn (adding a race against the first PWD event) or pretending the cold-start surface "died" and rebuilding it (a wasted libghostty allocation cycle). The shared piece is detection + decision; the divergent piece is the consequence.

## Component interfaces

```swift
// EspalierKit
public extension ZmxLauncher {
    func isSessionMissing(_ sessionName: String) -> Bool
}

// TerminalManager (Sources/Espalier/Terminal/TerminalManager.swift)
@MainActor
final class TerminalManager: ObservableObject {
    // existing surface map, rehydratedSurfaces, etc.

    // NEW: panes whose close was initiated by Espalier (user Cmd+W,
    // shell exit propagation, Stop-worktree). Consulted by the close
    // handler to distinguish intentional closes from session-loss.
    private var intentionalCloses: Set<TerminalID> = []

    // NEW: clear the rehydration label for one pane. Called from
    // createSurface(s) when isSessionMissing is true.
    func clearRehydrated(_ terminalID: TerminalID)

    // NEW: rebuild a surface in place for the same TerminalID, with a
    // restart banner prepended to initial_input. Called from the close
    // handler in the session-loss branch.
    func restartSurface(for terminalID: TerminalID)
}
```

## Data flow

### Cold-start, dead daemon

```
restoreRunningWorktrees
  → markRehydrated(leafID)
  → createSurfaces(for: tree, worktreePath:)
       → for each leaf:
          if rehydratedSurfaces.contains(leafID):
              if zmxLauncher.isSessionMissing(sessionName(leafID)):
                  clearRehydrated(leafID)        // ← new
          ghostty_surface_new(...)               // existing path
                                                  // zmx attach creates fresh daemon
       → first PWD event fires
       → maybeRunDefaultCommand(leafID)
          decision: wasRehydrated == false → .type("claude")
          → command runs                         // ← user-visible fix
```

### Cold-start, live daemon

Identical flow, but `isSessionMissing` returns false → `clearRehydrated` is not called → `wasRehydrated == true` → default command does not re-fire on top of the existing shell. (Unchanged behavior.)

### Mid-flight, daemon dies

```
zmx daemon for espalier-deadbeef dies
  → zmx attach client loses connection, exits
  → libghostty close_surface_cb fires
  → TerminalManager close handler:
       if intentionalCloses.contains(leafID):
           remove from intentionalCloses
           proceed with destroy + onCloseRequest    // existing path
       else if zmxLauncher.isSessionMissing(name):
           restartSurface(for: leafID)              // ← new
       else:
           proceed with destroy + onCloseRequest    // existing path (real shell exit)
```

### Mid-flight, user typed `exit`

User exit → outer shell's exec'd zmx attach exits cleanly → our `ZMX-4.3` `zmx kill --force` fires asynchronously. Two orderings are possible:

- **Kill races ahead of close handler:** `isSessionMissing` returns true, but `intentionalCloses` is empty (we didn't populate it for shell-driven exits — only for explicit user actions like Cmd+W). False-positive: we'd rebuild a pane the user just exited.
- **Close handler races ahead of kill:** `isSessionMissing` returns false (daemon still alive), close proceeds normally.

Resolution: populate `intentionalCloses` from the same place that calls `killZmxSession(for:)` — every Espalier-initiated close already goes through `forgetTrackingState`, which is the natural place to also stamp the intent. Shell-driven exit goes through `requestClose` → the Cmd+W path. So the rule is "if we're about to kill the session, we are also intentionally closing the pane."

This means one of two equivalent invariants must hold:

1. Every site that calls `killZmxSession(for:)` first inserts into `intentionalCloses`, **or**
2. `killZmxSession(for:)` itself inserts into `intentionalCloses` as its first line.

Option 2 is one place to maintain. Use it.

## Error handling

- **`isSessionMissing` itself fails** (subprocess can't launch, parse fails): returns `false`. We bias toward "do nothing different from today" rather than fabricating a session-loss event.
- **Rebuilt surface itself dies during creation** (mid-flight rebuild path): proceed to destroy + `onCloseRequest`, same as today's behavior. We do not loop trying to recover repeatedly — one shot is enough; if rebuild fails, the pane is gone and the user can reopen.
- **`zmx attach` after rebuild also fails** (e.g., `zmx` binary became unavailable between create and close): the pane will close normally. The fallback banner from `ZMX-5.x` handles the broader "zmx unavailable" story; we don't add a second alert.

## Testing

### Pure logic — `EspalierKitTests`

`DefaultCommandDecisionTests` already covers the four `wasRehydrated × isFirstPane × firstPaneOnly × command` permutations. **Unchanged.** The pure decision function does not need to know about session-loss; the relabel happens at the call site.

New `ZmxLauncherTests` cases for `isSessionMissing`:

- session present in `listSessions()` output → returns `false`.
- session absent → returns `true`.
- `listSessions()` throws (executable missing) → returns `false`.

### Integration — `EspalierKitTests/Zmx`

Two new tests in `ZmxSurvivalIntegrationTests`:

1. **Cold-start dead-daemon test.** Build a `ZmxLauncher` against a real bundled `zmx`. Spawn a session, verify it's listed. `zmx kill --force` it. Call `isSessionMissing(name)` → expect true.
2. **Mid-flight detection ordering test.** Spawn a session. In a tight loop of `isSessionMissing` polls, kill the session externally. Verify `isSessionMissing` flips from false to true within one poll cycle.

### UI-coupled — manual (documented in PR)

Two manual checks for the PR description:

1. **Cold-start with default command.** Set default command to `echo HELLO`. Open a worktree. Verify HELLO appears. Quit Espalier. Run `rm -rf ~/Library/Application\ Support/Espalier/zmx`. Relaunch. Verify HELLO appears again in the restored pane.
2. **Mid-flight kill.** Open a worktree, type some output. From another terminal, `ZMX_DIR=~/Library/Application\ Support/Espalier/zmx zmx kill --force espalier-<id>`. Verify the pane stays in place, banner appears, fresh prompt is usable.

## SPECS.md updates

New requirements under `## 13. zmx Session Backing`:

### 13.7 Session-Loss Recovery (new subsection)

**ZMX-7.1** When the application restores a worktree's split tree on launch (per `PERSIST-3.x` and `ZMX-4.2`), it shall, before creating each pane's surface, query the live zmx session set and clear the pane's rehydration label if the expected session name is absent. This ensures a freshly-created daemon (the result of `zmx attach`'s create-on-miss semantics) is not mistaken for a surviving session by `defaultCommandDecision`.

**ZMX-7.2** When `close_surface_cb` fires for a pane and Espalier did not initiate the close, the application shall query the live zmx session set; if the expected session name is absent, the application shall rebuild the pane's libghostty surface in place — same `TerminalID`, same split-tree position, fresh `zmx attach` — instead of removing the pane from the tree.

**ZMX-7.3** While rebuilding a surface per `ZMX-7.2`, the application shall prepend a single visually-distinct banner line ("`— session restarted at HH:MM —`", ANSI dim) to the new pane's `initial_input` so the user can recognize that the underlying session has been replaced.

**ZMX-7.4** If `zmx list` fails for any reason at either query site (per `ZMX-7.1` or `ZMX-7.2`), the application shall treat the result as "session not missing" and take no recovery action — preferring a missed recovery over a spurious rebuild.

### Existing requirement amendments

**ZMX-4.3 (amend)** Append: "Every site that initiates `zmx kill --force` shall also mark the pane as an intentional close, so the subsequent `close_surface_cb` is not misclassified as session-loss per `ZMX-7.2`."

## Open questions

None. Behaviour, detection points, recovery shape, error handling, and test surface are all settled. Proceed to plan.

## Future extensions

- **Banner customization.** Currently hard-coded to `— session restarted at HH:MM —`. Could become a `@AppStorage("zmxRestartBanner")` later if users want to disable it or change the format.
- **Out-of-band notification.** A "session restarted" Notification Center alert for users running with the Espalier window backgrounded. Deliberately deferred — the in-pane banner is the minimum viable signal.
- **Daemon-presence health monitor.** A periodic (e.g., 5s) `zmx list` poll that detects daemon death between events. Deferred because the `close_surface_cb` path already catches every observable death; a poll would only matter for daemons whose client connection is still alive but daemon-side state is corrupt — a scenario zmx's protocol does not currently expose.
