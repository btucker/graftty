# LRU Surface Eviction Budget — Design Specification

Cap the number of worktrees with live Ghostty surfaces, evicting the least-recently-selected worktree when the cap is exceeded. Frees scrollback buffers, Metal layers, and per-surface grid state for hibernated worktrees while preserving the zmx daemon and pane metadata so re-selection re-attaches transparently.

## Goal

Reduce steady-state memory usage by ensuring at most **4** worktrees hold live `ghostty_surface_t` instances at any time. The 5th-most-recently-selected worktree is hibernated: its surfaces are freed but its zmx sessions, pane-to-session mapping, titles, and PWDs are preserved. Re-selecting a hibernated worktree re-creates its surfaces via the existing rehydration path used at cold launch.

The user-visible behavior stays the same for the four most recent worktrees. For hibernated worktrees, switching to one shows a brief reconnect (the same behavior they already see when relaunching the app), and any output the agent produced while hibernated is still in scrollback because zmx kept the session alive.

## Background

Today, every `.running` worktree's surfaces stay alive for the lifetime of the app. `TerminalManager.destroySurfaces` is only called from six user-initiated paths:

- `MainWindow.swift:303` — stale-worktree resurrection (orphan leaves only)
- `MainWindow.swift:616` — repo removal
- `MainWindow.swift:721` — worktree delete
- `MainWindow.swift:797` — Stop Worktree menu action
- `SidebarView.swift:403` — Dismiss on stale worktree (orphan leaves only)
- `GrafttyApp.swift:2817` — ZMX restart

Switching the sidebar selection does **not** destroy any surfaces. With N running worktrees × M panes each, RAM grows linearly: ~10 MB libghostty scrollback + ~16 MB Metal layer drawables per surface. Ten panes consume ~250 MB of terminal-only state before AppKit, Sparkle, NIO, and the rest of the app contribute their share.

The lazy-create-on-select path already works. At cold launch (`GrafttyApp.swift:1540`):

- All running worktrees get `markRehydrated(leafID)` for each leaf.
- Surfaces are only created for the currently-selected worktree.
- Selecting another running worktree triggers a `missingSurface` check in `MainWindow.swift:354-366`, which calls `createSurfaces` and re-attaches each pane to its existing zmx session.

This proves the round-trip works for hibernation triggered at app boundaries. The new design extends the same invariant to mid-session selection changes.

## Architecture

A new MainActor type, `WorktreeSurfaceBudget`, owns an ordered list of worktree paths whose surfaces are live. Capacity is hardcoded to 4. The budget is owned by `TerminalManager` and queried/updated from `MainWindow`'s selection handler.

```
appState.selectedWorktreePath changes
    │
    ├─ existing path-specific logic (user-click only):
    │     selectWorktree(path) → createSurfaces (if missing),
    │                            setWorktreeSurfacesVisible toggle
    │
    └─ NEW: .onChange observer in MainWindow fires for ALL setters
          │
          └─ terminalManager.surfaceBudget.noteSelected(
                 worktreePath: newPath,
                 splitTreesByPath: appState.runningSplitTreesByPath()
             )
               │
               ├─ Prune any LRU entries whose path is not in splitTreesByPath
               ├─ Move `newPath` to head of LRU list
               ├─ If count > 4, take tail paths
               └─ For each evicted path:
                    for leaf in splitTreesByPath[evictedPath].allLeaves:
                        terminalManager.evictSurface(terminalID: leaf)
```

The budget is purely reactive: it only acts during `noteSelected`. There is no timer, no background poll, no notification subscription. Given a sequence of `noteSelected` calls, the set of evicted paths is a pure function of input order — trivially testable.

## Eviction semantics

A new `TerminalManager.evictSurface(terminalID:)` is the "soft destroy" path. It is intentionally much narrower than `destroySurface`:

```swift
func evictSurface(terminalID: PaneSlotID) {
    guard surfaces[terminalID] != nil else { return }
    surfaces[terminalID]?.requestClose()
    surfaces.removeValue(forKey: terminalID)
    rehydratedSurfaces.insert(terminalID)
    if let scanner = portScanner {
        Task { await scanner.unregisterPane(terminalID) }
    }
}
```

What `evictSurface` does **not** do (compared to `destroySurface` at `TerminalManager.swift:702`):

| State | `destroySurface` | `evictSurface` |
|---|---|---|
| `surfaces[id]` | removed | removed |
| `SurfaceHandle.deinit` | fires | fires |
| `paneSessions[id]` | cleared | **preserved** |
| `titles[id]` | cleared | **preserved** |
| `pwds[id]` | cleared | **preserved** |
| `renderedTitles[id]` | cleared | **preserved** |
| `shellReadyFired` | cleared | **preserved** |
| `cachedShellPIDs[id]` | cleared | **preserved** |
| `firstPaneMarkers` | cleared | **preserved** |
| `rehydratedSurfaces` | cleared | **inserted** |
| `paneClosed` callback | fires | does not fire |
| zmx session | killed | **preserved (still running)** |
| `portScanner.unregisterPane` | yes | yes (snapshot is process-tied) |

The `rehydratedSurfaces.insert(...)` line is the critical addition. It is exactly the same flag set on cold-launch rehydration (`GrafttyApp.swift:1559`) and gates `maybeRunDefaultCommand`. Without it, a re-attached agent pane would have `claude` re-typed on top of an already-running session.

The zmx daemon for each evicted pane keeps running with its on-disk scrollback intact. When the worktree is re-selected and `createSurfaces` runs, the new `SurfaceHandle` attaches to the live zmx session and replays its scrollback — the same path used at cold launch.

## Wiring

### Selection handler

`selectedWorktreePath` is set from five distinct sites today (`MainWindow.swift:285` user click, `MainWindow.swift:850` already-added-repo early return, `GrafttyApp.swift:1468` repo relocate, `GrafttyApp.swift:2471` pane drag-move with follow, `SidebarView.swift:419` clear-to-nil). Only the user-click path runs the visibility / create-missing-surfaces logic today. To make eviction robust against all paths uniformly, the budget hooks into selection changes through SwiftUI's `.onChange` observer rather than being wired at each setter site.

In `MainWindow.swift`, attach to the existing view that owns the selection:

```swift
.onChange(of: appState.selectedWorktreePath, initial: true) { _, newPath in
    guard let newPath else { return }
    terminalManager.surfaceBudget.noteSelected(
        worktreePath: newPath,
        splitTreesByPath: appState.runningSplitTreesByPath()
    )
}
```

`initial: true` (macOS 14+) seeds the LRU with the restored selection at launch so the worktree whose surfaces were already created by `restoreRunningWorktrees` is correctly registered as the most-recently-used entry.

`AppState.runningSplitTreesByPath()` is a new helper that returns `[String: SplitTree]` keyed by worktree path, including only `.running` worktrees. The budget needs the split trees to enumerate which leaves to evict for each path it decides to drop.

`.onChange` fires once after a property mutation regardless of which source set it, which means the four "bypass" paths automatically get LRU bookkeeping without needing edits. A `nil` selection is ignored — the LRU keeps its current entries and the next non-nil selection acts normally (see the matching edge case below).

### Coordination with Stop/Delete/Remove/Stale

The budget self-prunes against `splitTreesByPath` on every `noteSelected`: any LRU entry whose path is not in the running map is dropped before the new selection is appended and the capacity check runs.

`splitTreesByPath` is built from `appState.repos[*].worktrees[*]` filtered to `state == .running`. A worktree in `.closed` (Stop, ZMX restart), `.stale` (directory deleted on disk), removed from `appState` entirely (worktree delete, repo removal), or otherwise no-longer-`.running` is automatically dropped from the LRU on the next selection event. This means no `destroySurfaces` call site needs to be modified — none of the six existing call sites need to know about the budget.

The trade-off: the LRU list may briefly contain entries for non-running worktrees between a state transition and the next `noteSelected` call. This is harmless: those entries are not selected (so they cannot become head), they will be pruned on the next selection, and even if eviction were attempted on a non-running entry, `evictSurface`'s `surfaces[id] != nil` guard makes the call a no-op for any leaf whose surface has already been destroyed.

### Launch behavior

`restoreRunningWorktrees` (`GrafttyApp.swift:1540`) already creates surfaces only for the selected worktree. The `.onChange(of: ..., initial: true)` observer fires once on view appearance with the restored selection, seeding the LRU with one entry that matches the worktree whose surfaces actually exist. No changes to `restoreRunningWorktrees` are needed.

### New worktree creation

`AddWorktreeFlow` sets `selectedWorktreePath` to the new worktree's path after creation, which routes through the same `noteSelected` call site. The new worktree becomes the LRU head; if this pushes the list over 4, the oldest is evicted.

## Edge cases

- **Selection cleared.** When `selectedWorktreePath` becomes nil (no row selected), no `noteSelected` fires. The LRU list keeps its current entries. The next non-nil selection acts normally.
- **Worktree transitions to .closed mid-session.** Stop / Delete remove the worktree from `.running` state. The next `noteSelected` self-prunes the entry from the LRU.
- **Worktree transitions to .stale.** Stale transitions leave surfaces alive but flip the state out of `.running`. The next `noteSelected` self-prunes the entry. Stale surfaces continue holding memory until the user takes a follow-up action (Dismiss, or click-to-resurrect) — out of scope for this spec to evict them automatically.
- **Already-evicted re-evict.** `evictSurface` guards on `surfaces[id] != nil`, so re-calling on an already-evicted pane is a no-op.
- **Eviction during pane drag.** `PaneSlotID` is stable across worktree moves (PORTS-4.3). If a pane is dragged from worktree A to worktree B, and A is later evicted, the pane's surface lives under B's split tree now and is not affected. The budget operates on worktree paths, not pane IDs.
- **Multi-pane worktree.** A worktree with 6 panes evicts all 6 surfaces in one budget tick. The loop is sub-millisecond; no batching needed.
- **`surfaces` contains panes from `splitTree.allLeaves` that have no live surface.** `evictSurface`'s nil guard handles this — no-op for leaves that were never created.

## Specs

New prefix `MEM-1`:

- **MEM-1.1**: While more than 4 worktrees have live surfaces, the application shall evict the least-recently-selected worktree's surfaces.
- **MEM-1.2**: When a worktree's surfaces are evicted via the LRU budget, the application shall preserve its zmx sessions, pane-to-session mapping, titles, PWDs, and rehydration state so re-selection re-attaches transparently.
- **MEM-1.3**: When a worktree is stopped, removed, has its repo removed, or transitions to stale, the application shall drop it from the LRU budget.
- **MEM-1.4**: When a worktree whose surfaces were evicted is re-selected, the application shall re-create its surfaces via the same rehydration path used at cold launch.
- **MEM-1.5**: When the LRU budget evicts a worktree, the application shall not kill its zmx sessions or fire `paneClosed` callbacks.

## Tests

Three test layers:

### `WorktreeSurfaceBudgetTests.swift`

Pure unit tests against the budget type alone. No `TerminalManager`; the budget's eviction callback is a closure passed in at init, so the test injects a recording closure. Covers:

- `noteSelected` on a fresh budget: head only; nothing evicted.
- `noteSelected` 4 times with distinct paths: 4 entries, nothing evicted.
- `noteSelected` 5 times with distinct paths: the oldest is evicted.
- `noteSelected` 5 times where the 5th repeats the 1st: nothing evicted; LRU order updates.
- Sequence A→B→C→D→A→E evicts B (oldest after A jumped to head), not A.
- Self-prune at head: A→B→C→D, then `noteSelected(E, splitTreesByPath without A)` drops A and admits E without evicting B/C/D.
- Self-prune in middle: A→B→C→D, then `noteSelected(E, splitTreesByPath without B)` drops B and admits E.
- Self-prune at tail: A→B→C→D, then `noteSelected(E, splitTreesByPath without D)` drops D and admits E.
- Self-prune all: A→B→C→D, then `noteSelected(E, splitTreesByPath = {E})` leaves only E.

### `TerminalManagerEvictionTests.swift`

Exercises `evictSurface` against a real `TerminalManager` with a stubbed ghostty app (the same harness used elsewhere in `Tests/GrafttyTests/`). Covers:

- After `evictSurface(id)`: `handle(for: id)` returns nil.
- After `evictSurface(id)`: `paneSessions[id]` is still present.
- After `evictSurface(id)`: `titles[id]` is still present.
- After `evictSurface(id)`: `wasRehydrated(id)` returns true.
- After `evictSurface(id)`: `firstPaneMarkers.contains(id)` is preserved.
- `zmxLauncher.kill` is not invoked.
- A subsequent `createSurface(id, …)` succeeds and returns a fresh handle.

### Integration test in `GrafttyTests`

End-to-end through the selection handler. Covers:

- Five running worktrees, select all five in sequence: the first-selected has its surfaces gone, its `paneSessions` intact, and re-selecting it triggers `createSurfaces` and produces a live handle again.
- After Stop on a worktree that's in the LRU list, the next `noteSelected` self-prunes that path and counts only `.running` worktrees toward the budget.
- After a stale transition on a worktree that's in the LRU list, the next `noteSelected` self-prunes that path.

## Files

- New: `Sources/Graftty/Terminal/WorktreeSurfaceBudget.swift`
- New: `Tests/GrafttyTests/Terminal/WorktreeSurfaceBudgetTests.swift`
- New: `Tests/GrafttyTests/Terminal/TerminalManagerEvictionTests.swift`
- Modified: `Sources/Graftty/Terminal/TerminalManager.swift` (add `evictSurface`, add `surfaceBudget` property)
- Modified: `Sources/Graftty/Views/MainWindow.swift` (add the `.onChange(of: appState.selectedWorktreePath, initial: true)` observer that calls `surfaceBudget.noteSelected`)
- Modified: `Sources/Graftty/Model/AppState+SplitTrees.swift` (new helper `runningSplitTreesByPath()`) — or extend an existing `AppState` extension file if one fits
- Modified: `SPECS.md` (regenerated by `scripts/generate-specs.py`)

The six existing `destroySurfaces` call sites (`MainWindow.swift:303`, `:616`, `:721`, `:797`, `SidebarView.swift:403`, `GrafttyApp.swift:2817`) are **not** modified — the budget self-prunes against the live `runningSplitTreesByPath()` snapshot.

## Non-goals

- A user-facing Settings control for budget size. Hardcode 4 for v1; revisit after real-world memory measurements.
- A grace timer that delays eviction. Pure LRU is sufficient because eviction is invisible during forward navigation — the user only notices when they return to a recently-pushed-out worktree, which is the same UX as relaunching the app.
- Reducing libghostty `scrollback-limit` per surface. A separate optimization that stacks with this one but is out of scope for this spec.
- Pausing the `PortScanner` ticker for hibernated worktrees. `unregisterPane` is called on eviction so hibernated panes already drop out of the scan set.
- Compressing or persisting any extra state. zmx already persists the live shell and scrollback; nothing new needs to be written to disk.
