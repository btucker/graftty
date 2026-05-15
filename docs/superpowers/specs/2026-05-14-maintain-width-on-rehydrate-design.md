# Maintain Width on LRU Re-attach — Design Specification

Preserve a hibernated worktree's terminal column count across the LRU evict / re-attach cycle so that re-selecting an evicted worktree does not reflow its scrollback at the default 80-column PTY winsize.

## Goal

After `WorktreeSurfaceBudget` evicts a worktree's surfaces (MEM-1.1), re-selecting that worktree shall produce a re-attached pane whose underlying shell PTY winsize equals the winsize it had at eviction time. The user sees scrollback laid out at the same width as before, not reflowed at 80 columns followed by a snap-back to the layout width.

The fix only acts on the **re-attach path** (`rehydratedSurfaces.contains(id)`). Cold-launch first-open and freshly-created panes are unaffected — they have no prior width to preserve, and their early scrollback is short enough that the spawn-time default size is not visible to the user.

## Background

Today's evict → re-attach chain corrupts scrollback width because the outer PTY between Graftty and `zmx attach` is spawned at macOS's default 80×24:

1. `WorktreeSurfaceBudget.noteSelected` evicts the LRU worktree's leaves via `TerminalManager.evictSurface` (`Sources/Graftty/Terminal/TerminalManager.swift:725`). The libghostty surface, the `HostManagedZmxBackend`, and its `NativePtySession` all tear down. The zmx daemon and its inner shell PTY keep running with the user's scrollback intact at whatever width was active at eviction time.
2. The user re-selects the worktree. `MainWindow`'s missing-surface check (`MainWindow.swift:354-366`) calls `TerminalManager.createSurfaces`, which constructs a new `SurfaceHandle`.
3. `SurfaceHandle.init` builds a new `HostManagedZmxBackend` whose default `sessionFactory` (`Sources/Graftty/Terminal/HostManagedZmxBackend.swift:67-75`) constructs `NativePtySession` **without** passing `initialSize`.
4. `NativePtySession.start()` calls `PtyProcess.spawn(initialSize: nil)`. With `nil`, the spawn helper skips the pre-fork `TIOCSWINSZ` (`Sources/GrafttyKit/Web/PtyProcess.swift:92-99`). The outer PTY is born at the macOS default 80×24.
5. `zmx attach` runs inside that 80×24 PTY, reads its winsize, and propagates it to the zmx daemon via the daemon's resize protocol. The daemon resizes the inner shell PTY to 80×24 — **this is the reflow event that corrupts scrollback width.**
6. SwiftUI lays out the new `SurfaceNSView`. `setFrameSize` fires (`Sources/Graftty/Terminal/SurfaceHandle.swift:536-553`), which calls `ghostty_surface_set_size`, which fires `receive_resize_cb`, which calls `NativePtySession.resize(cols, rows)`. The outer PTY snaps to the layout's real winsize. `zmx attach` propagates that to the daemon. The shell PTY resizes again — but the scrollback was already reflowed at 80 in step 5, so the user sees lines stuck at the narrow width.

The libghostty C ABI already exposes the data we need: `ghostty_surface_size(surface) → ghostty_surface_size_s { columns, rows, width_px, height_px, cell_width_px, cell_height_px }` (`ghostty.h:1106-1107`). `PtyProcess.spawn` already accepts and applies `initialSize` pre-fork; the parameter is plumbed through `NativePtySession.init` and its `Spawner` typedef. The only missing link is that `HostManagedZmxBackend` drops the value on the floor when constructing the session.

## Architecture

A new `TerminalManager` map, `evictedGridSizes: [PaneSlotID: GridSize]`, captures each pane's grid right before its surface is destroyed by `evictSurface`. On the next `createSurfaces` / `createSurface` call for that pane, the cached size is consumed: it is passed as `initialSize` to the `HostManagedZmxBackend`'s session factory, and the new libghostty surface is pre-sized via `ghostty_surface_set_size` before `backend.start()` runs, so the surface's own grid matches the outer PTY's winsize from the moment the first byte arrives.

```
WorktreeSurfaceBudget eviction tick
    │
    └─ for leaf in tree.allLeaves:
          evictSurface(terminalID: leaf)
            │
            ├─ NEW: query ghostty_surface_size(surface) → (cols, rows, w_px, h_px)
            ├─ NEW: evictedGridSizes[id] = GridSize(cols, rows, w_px, h_px)
            ├─ existing: surfaces[id]?.requestClose()
            ├─ existing: surfaces.removeValue(forKey: id)
            └─ existing: rehydratedSurfaces.insert(id)

user re-selects worktree
    │
    └─ MainWindow missing-surface check
          │
          └─ createSurfaces(for: tree, …, worktreePath: path)
                │
                └─ for leaf in tree.allLeaves where surfaces[leaf] == nil:
                      │
                      └─ NEW: let cached = evictedGridSizes.removeValue(forKey: leaf)
                            │
                            └─ SurfaceHandle(
                                  …,
                                  initialGridSize: cached,
                                  zmxBackendFactory: { spawn in
                                      HostManagedZmxBackend(
                                          spawnConfiguration: spawn,
                                          initialSize: cached.map { ($0.cols, $0.rows) }
                                      )
                                  }
                              )
                                │
                                ├─ NEW: if let cached, call ghostty_surface_set_size(newSurface, w_px, h_px)
                                │     before backend.start() — pre-sizes the libghostty surface
                                │     so its first receive_resize_cb is a no-op against an already-
                                │     correct winsize, instead of a 80×24-to-real corrective resize.
                                └─ existing: backend.start(surface: newSurface) →
                                       NativePtySession.start() →
                                       PtyProcess.spawn(initialSize: (cols, rows))
                                       → outer PTY born at cached size
                                       → zmx attach inherits, propagates to daemon
                                       → no reflow event
```

The cache is keyed by `PaneSlotID`, not worktree path, because the LRU budget operates per-leaf. A multi-pane worktree's panes can have distinct grid sizes (split fractions); each must be preserved independently.

## Capture semantics

`evictSurface` captures the size **before** calling `requestClose()`:

```swift
func evictSurface(terminalID: PaneSlotID) {
    if let handle = surfaces.removeValue(forKey: terminalID) {
        evictedGridSizes[terminalID] = GridSize(from: ghostty_surface_size(handle.surface))
        handle.requestClose()
    }
    rehydratedSurfaces.insert(terminalID)
    if let scanner = portScanner {
        Task { await scanner.unregisterPane(terminalID) }
    }
}
```

`ghostty_surface_size` is read-only and safe to call any time the surface pointer is valid. `requestClose` schedules surface teardown but the C surface pointer remains valid until `SurfaceHandle.deinit` calls `ghostty_surface_free`; querying before `requestClose` keeps the capture before any teardown side effect can mutate the size.

A captured size of `(0, 0)` is treated as "no useful data" and discarded — happens if the surface was evicted before SwiftUI ever laid out the view (extremely rare; e.g. a programmatic selection change before the first frame). The cache entry is not written in that case, so the re-attach path falls back to today's behavior.

## Apply semantics

`createSurfaces` consumes the cached size when re-creating a surface for a leaf that has a cache entry:

```swift
for terminalID in splitTree.allLeaves where surfaces[terminalID] == nil {
    let cachedGrid = evictedGridSizes.removeValue(forKey: terminalID)
    …
    guard let handle = SurfaceHandle(
        terminalID: terminalID,
        app: app,
        worktreePath: worktreePath,
        socketPath: socketPath,
        zmxSpawnConfiguration: zmxSpawnConfiguration,
        terminalManager: self,
        inputActivityObserver: inputActivityObserver,
        initialGridSize: cachedGrid
    ) else { … }
    …
}
```

The `removeValue` is intentional — the cached size is single-use. If a re-attached pane is later evicted again, a fresh capture replaces it. This prevents stale sizes from outliving multiple resize cycles.

`SurfaceHandle.init` threads the cached size into two places:

1. **The `HostManagedZmxBackend`'s session factory**, so `NativePtySession.initialSize` becomes `(cols, rows)`. `PtyProcess.spawn` issues the pre-fork `TIOCSWINSZ` and the outer PTY is born at the cached size. This is the load-bearing change — it prevents step 5 of the reflow chain.

2. **A `ghostty_surface_set_size(newSurface, width_px, height_px)` call** between `surfaceFactory.create(...)` returning successfully and `backend.start(...)` running. The pre-set takes the libghostty surface to the cached pixel dimensions so its first `setFrameSize`-driven `ghostty_surface_set_size` call (after SwiftUI lays out) is a no-op when the layout container has not changed. This prevents step 6 from generating a redundant resize event.

If the user resized the Graftty window while the worktree was evicted, the post-layout `setFrameSize` will compute different (cols, rows) than the cache, and a single intentional resize will fire — that's correct behavior, not a regression.

## Lifecycle and cleanup

The cache is bounded by the LRU budget — at most `capacity × max_panes_per_worktree` entries can be live at once. Even with extreme multi-pane usage, that's tens of entries (16 bytes each). No timer-based cleanup is needed.

Explicit drop sites:

- **On consume** (`createSurfaces` / `createSurface`): the entry is removed via `removeValue` once handed to `SurfaceHandle.init`.
- **On destroy** (`forgetTrackingState`): the entry is removed alongside other per-pane state. Covers the case where a user stops the worktree before re-selecting it — the eviction cache must not survive the destroy.
- **No-op cases**: an entry that was never consumed and never explicitly dropped lives until the pane is destroyed via `destroySurface`. Bounded and harmless.

## Specs

Extends prefix `MEM-1`:

- **MEM-1.6**: When the LRU budget evicts a worktree's surfaces, the application shall capture each evicted pane's current grid size (columns, rows, pixel width, pixel height) for use on subsequent re-attach.
- **MEM-1.7**: When a previously-evicted pane is re-attached via the rehydration path, the application shall spawn its outer `zmx attach` PTY with `initialSize` equal to the captured grid size, so the underlying shell PTY winsize remains stable across the evict / re-attach cycle.
- **MEM-1.8**: When a previously-evicted pane is re-attached via the rehydration path, the application shall pre-size the new libghostty surface to the captured pixel dimensions before starting its host-managed backend, so the first post-layout resize event is a no-op when the layout container has not changed.
- **MEM-1.9**: When a previously-evicted pane is destroyed (rather than re-attached), the application shall drop its captured grid size from the cache.

## Tests

Three test layers, matching the MEM-1 surface-budget design's layering.

### `TerminalManagerEvictionTests.swift` (extend existing)

Real `TerminalManager` with a stubbed grid-size probe. `SurfaceHandleGhosttySurfaceFactory` gains a `size:` closure (next to its existing `create` / `free` / `text` / `writeBuffer` / `processExit` closures) that defaults to `ghostty_surface_size` and is overridden in tests to return a deterministic `ghostty_surface_size_s`. `TerminalManager` exposes a test-only accessor `evictedGridSize(for: id) -> GridSize?`. Covers:

- **MEM-1.6 capture**: after `evictSurface(id)`, `evictedGridSize(for: id)` returns the size the stub reported.
- **MEM-1.6 zero-size discard**: when the stub returns `(0, 0)`, no cache entry is written.
- **MEM-1.9 destroy clears cache**: after `evictSurface(id)` followed by `destroySurface(id)`, `evictedGridSize(for: id)` returns nil.

### `SurfaceBudgetIntegrationTests.swift` (extend existing)

End-to-end through the eviction → re-attach path with a recording `HostManagedZmxBackend` factory. Covers:

- **MEM-1.7 plumbing**: trigger an eviction that captures a known size, trigger a re-attach, assert the recorded backend was constructed with that `initialSize`.
- **MEM-1.8 pre-size**: same flow, assert `ghostty_surface_set_size` was called with the captured pixel dimensions before `backend.start()`.
- **MEM-1.7 single-use**: re-attach consumes the cache entry; a second re-attach without re-eviction passes `initialSize = nil`.
- **First-evict-then-replace**: after evict→re-attach→evict, the second capture replaces the first; the third re-attach uses the second capture's size.

### `HostManagedZmxBackendTests.swift` (extend existing if present, or new)

Pure backend-level test. Construct `HostManagedZmxBackend(spawnConfiguration:, initialSize:)`, call `start(surface:)`, assert the synthesized `NativePtySession` was given the matching `initialSize`. Uses the same session-factory injection seam as MEM-1.

## Files

- Modified: `Sources/Graftty/Terminal/TerminalManager.swift` — add `evictedGridSizes` map, `GridSize` type, capture in `evictSurface`, consume in `createSurfaces` / `createSurface`, drop in `forgetTrackingState`, test-only accessor `evictedGridSize(for:)`.
- Modified: `Sources/Graftty/Terminal/SurfaceHandle.swift` — accept `initialGridSize:` parameter on `init`, plumb to `HostManagedZmxBackend` factory, call `ghostty_surface_set_size` between create and `backend.start`; add `size:` closure to `SurfaceHandleGhosttySurfaceFactory` (default `ghostty_surface_size`) so the size probe is injectable in tests.
- Modified: `Sources/Graftty/Terminal/HostManagedZmxBackend.swift` — accept and store `initialSize`, pass to the default `sessionFactory`.
- Modified: `Tests/GrafttyTests/Terminal/TerminalManagerEvictionTests.swift` — three new spec tests.
- Modified: `Tests/GrafttyTests/Terminal/SurfaceBudgetIntegrationTests.swift` — three new spec tests.
- Modified (or new): `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift` — one new spec test for the backend-level plumbing.
- Modified: `SPECS.md` — regenerated by `scripts/generate-specs.py`.

## Non-goals

- **Cold-launch initial sizing.** First-open of a worktree at cold launch still spawns the outer PTY at 80×24 and then resizes to the layout size. The user has no prior width to preserve in that case, and the freshly-restored shell's scrollback is short, so the reflow is not visible. A future enhancement could pre-compute the launch size from saved layout metadata, but that's a different scope (`MEM-2` or similar) and would interact with `restoreRunningWorktrees`.
- **Cross-launch persistence.** The cache lives in process memory only. After a Graftty restart, the very first surface for each worktree spawns at 80×24 and resizes once — same behavior as today. Persisting last-known sizes to disk is out of scope.
- **Aggressive layout pre-computation.** The design does not attempt to mirror SwiftUI's layout math to compute the size before SwiftUI runs. It relies on the captured-at-eviction size, which is correct by construction.
- **Suppression of post-spawn resize.** When the user resized the Graftty window while the worktree was evicted, the post-layout resize event will fire and reflow at the new width. This is the intended UX — a window resize *should* reflow.
- **iOS / web client width preservation.** Those paths already have their own mechanisms (`IOS-5.6`, `IOS-6.5`, `WEB-5.5`); this design is desktop-only.
