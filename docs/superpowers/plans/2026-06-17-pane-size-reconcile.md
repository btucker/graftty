# Pane-size reconcile — delete the fake-bounce re-anchor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the fake-resize (`rows→rows-1→rows`) TUI re-anchor band-aids and rely solely on the authoritative "visible grid == daemon grid" size-sync that `resyncVisibleGrid` / the engagement flush already implement.

**Architecture:** zmx is raw PTY passthrough with one per-session (leader) grid; correct rendering requires only that the Mac's libghostty grid equals the daemon grid. The existing size-sync (`resyncVisibleGrid` on every show via `setVisible`, plus the settle/engage/remote-detach flushes) already maintains that. The `TERM-11.11`/`TERM-11.14` fake rows-bounce was compensating for cases the size-sync handles directly (a real size delta produces a real SIGWINCH); it is deleted. Category-B (equal-size, app-stranded) recovery is deferred to a future zmx `kill(child, SIGWINCH)` command — not in this plan.

**Tech Stack:** Swift 6, Swift Testing, AppKit, libghostty (`ghostty_surface_*`), `NativePtySession` (PTY `TIOCSWINSZ`).

## Global Constraints

- Spec annotations use `@spec <ID>: <EARS text>` in Swift Testing test titles / `@Suite` titles / `///` doc comments. `grep -rn "@spec"` finds all. A spec ID lives in at most one behavioral location and one type location. (CLAUDE.md)
- No literal `"` characters inside `@spec` test titles — they truncate `SPECS.md` silently. Use backticks. (project memory)
- TDD: write failing test → confirm fail → minimal implement → confirm pass → commit. For a *deletion*, the inverse: write/adjust the test asserting the new (absence-of-bounce) behavior first.
- Run `scripts/generate-specs.py` and commit the regenerated `SPECS.md` alongside code.
- Build/test: `swift build`, `swift test --filter <name>`; full suite `swift test`.
- Keep every legitimate constraint and its test: pre-layout withhold (`TERM-11.7`/`11.10`), remote-leader gate (`TERM-11.2`/`11.4`/`11.8`/IOS-12.1), coalescing (`TERM-11.9`), pre-start write queue (`TERM-11.12`), and the show-time size-sync (`TERM-11.13`). Only the fake-bounce (`TERM-11.11`/`11.14`) is removed.

---

### Task 1: Delete the backend fake-bounce machinery

**Files:**
- Modify: `Sources/Graftty/Terminal/HostManagedZmxBackend.swift`
- Test: `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift`

**Interfaces:**
- Consumes: `Self.makeBackend(session:hasRemoteClient:coalescer:)`, `FakeHostManagedSession.resizes() -> [Resize]`, `backend.bindSurfaceSync(currentGridSize:requestRefresh:)`, `backend.markLayoutSettled()`, `backend.resyncVisibleGrid()`, `Self.fakeSurface()`, `backend.releaseReceiveUserdataAfterSurfaceFree()`.
- Produces: `HostManagedZmxBackend` with NO `reanchorOnShow`, `setAnchorHealOnAttach`, or heal/bounce methods. `markLayoutSettled` and `resyncVisibleGrid` keep their size-sync behavior unchanged.

- [ ] **Step 1: Replace the four bounce tests with no-bounce assertions.** In `HostManagedZmxBackendTests.swift`, DELETE the tests at (current) lines 689 (`@spec TERM-11.11` rehydrated bounce), 715 (echo-survives-bounce), 742 (bounce-abandoned-on-resize), 768 (no-bounce-with-remote), 792 (`@spec TERM-11.14` re-show bounce), 817 (no-bounce-remote), 835 (bounce-withheld-pre-layout). Replace with these two tests (they assert the size-sync stays and the bounce is gone):

```swift
@Test("@spec TERM-11.11: When a pane's attach settles or it is switched back to with the live libghostty grid already equal to the size the PTY last received, the application shall not perturb the PTY — no synthetic rows bounce — because zmx renders the child's bytes verbatim and an in-agreement grid already renders correctly; only a genuine grid delta (a real resize) forwards a SIGWINCH.")
func settleAndReShowAtAgreeingGridDoNotPerturbThePty() throws {
    let session = FakeHostManagedSession()
    let coalescer = ManualResizeCoalescer()
    let backend = Self.makeBackend(session: session, coalescer: coalescer)
    defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
    backend.bindSurfaceSync(currentGridSize: { (cols: 108, rows: 90) }, requestRefresh: {})
    try backend.start(surface: Self.fakeSurface())

    backend.markLayoutSettled()
    #expect(session.resizes() == [Resize(cols: 108, rows: 90)])

    // Re-show with the grid unchanged: no resize at all (no bounce). Any
    // scheduled work must also produce nothing.
    backend.resyncVisibleGrid()
    coalescer.fireAll()
    #expect(session.resizes() == [Resize(cols: 108, rows: 90)])
}

@Test("@spec TERM-11.14: When a kept-alive pane is switched back to and the live grid differs from the PTY, the application shall forward exactly that live grid once (a single real resize / SIGWINCH) and never a synthetic rows-1/rows bounce.")
func reShowAtDriftedGridForwardsOneRealResizeNoBounce() throws {
    let session = FakeHostManagedSession()
    let coalescer = ManualResizeCoalescer()
    let drifted = LockedFlag(false)
    let backend = Self.makeBackend(session: session, coalescer: coalescer)
    defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
    backend.bindSurfaceSync(
        currentGridSize: { drifted.value() ? (cols: 108, rows: 88) : (cols: 108, rows: 90) },
        requestRefresh: {}
    )
    try backend.start(surface: Self.fakeSurface())
    backend.markLayoutSettled()
    drifted.set(true)

    backend.resyncVisibleGrid()
    coalescer.fireAll()
    // Exactly one real resize to the drifted grid; no rows-1 leg ever.
    #expect(session.resizes() == [Resize(cols: 108, rows: 90), Resize(cols: 108, rows: 88)])
    #expect(!session.resizes().contains(Resize(cols: 108, rows: 87)))
}
```

- [ ] **Step 2: Run the two new tests — confirm they FAIL to compile** (they reference no deleted symbols, but the suite still references `setAnchorHealOnAttach`/`reanchorOnShow` via other deleted tests; after Step 1 the suite should compile). Run: `swift test --filter "settleAndReShowAtAgreeingGridDoNotPerturbThePty"`. Expected: build error or FAIL only if bounce still fires. If the bounce machinery still schedules on `markLayoutSettled` for a rehydrated/healed backend, these pass already because the new tests never arm the heal — that's fine; proceed to delete the machinery so nothing CAN arm it.

- [ ] **Step 3: Delete the bounce machinery from `HostManagedZmxBackend.swift`.** Remove: the `healAnchorOnAttach` property (line ~146); `anchorHealShrinkDelay` / `anchorHealRestoreDelay` constants (lines ~154, ~160); `setAnchorHealOnAttach(_:)` (~462); `performAnchorHealLocked()` (~476); `scheduleAnchorHealBounceLocked()` (~488); `reanchorOnShow()` (~511); `anchorHealShrink(from:)` (~526); `anchorHealRestore(to:)` (~547). In `markLayoutSettled()` (~445) delete the trailing `performAnchorHealLocked()` call (keep the `flushSizeToPtyLocked` call). Leave `resyncVisibleGrid`, `flushSizeToPtyLocked`, coalescing, `shouldWithholdResizeLocked`, the engagement machinery, and the pre-start queue untouched.

- [ ] **Step 4: Run the full backend suite.** Run: `swift test --filter "HostManagedZmxBackend"`. Expected: PASS (the two new tests pass; all kept-behavior tests — TERM-11.1/2/3/4/6/7/8/9/13, IOS-12.1, coalescing — still pass).

- [ ] **Step 5: Commit.**

```bash
git add Sources/Graftty/Terminal/HostManagedZmxBackend.swift Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift
git commit -m "refactor(TERM-11.11/11.14): delete fake rows-bounce re-anchor from backend"
```

---

### Task 2: Delete the bounce wiring (SurfaceHandle / TerminalManager / MainWindow)

**Files:**
- Modify: `Sources/Graftty/Terminal/SurfaceHandle.swift` (protocol decls ~60/68, impls ~373/513, the `healZmxAnchorOnAttach` usage ~373)
- Modify: `Sources/Graftty/Terminal/TerminalManager.swift` (`reanchorWorktreeOnShow` ~773)
- Modify: `Sources/Graftty/Views/MainWindow.swift` (call site ~168)
- Test: `Tests/GrafttyTests/Terminal/SurfaceHandleHostManagedTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: the `setVisible`→`resyncVisibleGrid` size-sync remains the only show-time reconcile. No `reanchorOnShow`/`reanchorWorktreeOnShow`/`setAnchorHealOnAttach` anywhere.

- [ ] **Step 1: Inspect the wiring.** Run: `grep -rn "reanchorOnShow\|setAnchorHealOnAttach\|reanchorWorktreeOnShow\|healZmxAnchorOnAttach\|healAnchorOnAttach" Sources/` and read each site (`SurfaceHandle.swift:60,68,373,513`; `TerminalManager.swift:773-777`; `MainWindow.swift:168`). Confirm `TerminalManager.setVisible` (~733-740) still calls `handle.resyncVisibleGrid()` — that is the retained reconcile that worktree-switch, focus, foreground, and onAppear all funnel through.

- [ ] **Step 2: Delete the protocol requirements and impls in `SurfaceHandle.swift`.** Remove `func setAnchorHealOnAttach(_:)` and `func reanchorOnShow()` from the protocol (lines ~60, ~68) and their implementations (~513-515 for `reanchorOnShow`; the `backend.setAnchorHealOnAttach(healZmxAnchorOnAttach)` call ~373 and any `healZmxAnchorOnAttach` parameter/field feeding it). Keep `resyncVisibleGrid()` (~505-507). If `healZmxAnchorOnAttach` was a parameter to `SurfaceHandle.init`/a factory, remove it and its call sites (grep to confirm none remain).

- [ ] **Step 3: Delete `reanchorWorktreeOnShow` in `TerminalManager.swift`** (~773-777) and the `MainWindow.swift:168` call to it. Worktree-switch retains its size-sync because `MainWindow.onChange(selectedWorktreePath)` already drives `setWorktreeSurfacesVisible(true)` → `setVisible` → `resyncVisibleGrid` for the shown worktree. Verify that path exists; if the only show-trigger for a worktree switch was `reanchorWorktreeOnShow`, replace the deleted call with the `setVisible(true)`/`resyncVisibleGrid` path instead of nothing.

- [ ] **Step 4: Update `SurfaceHandleHostManagedTests.swift`.** Run `grep -n "reanchorOnShow\|setAnchorHealOnAttach\|heal" Tests/GrafttyTests/Terminal/SurfaceHandleHostManagedTests.swift`; delete or rewrite any test that asserts the deleted wiring (e.g. "SurfaceHandle forwards reanchorOnShow to backend"). For each deleted forwarding test, if a `resyncVisibleGrid` forwarding test does not already exist, add one:

```swift
@Test("SurfaceHandle.resyncVisibleGrid forwards to the zmx backend so a shown pane reconciles its PTY to the live grid.")
func resyncVisibleGridForwardsToBackend() throws {
    // Mirror the existing forwarding-test setup in this file (fake backend
    // recording calls); assert the fake backend saw exactly one
    // resyncVisibleGrid() after handle.resyncVisibleGrid().
}
```
(Fill the body using this file's existing fake-backend forwarding-test pattern — read a neighboring forwarding test first.)

- [ ] **Step 5: Build + run terminal tests.** Run: `swift build && swift test --filter "SurfaceHandleHostManaged"`. Expected: PASS, no unresolved symbols.

- [ ] **Step 6: Commit.**

```bash
git add Sources/Graftty/Terminal/SurfaceHandle.swift Sources/Graftty/Terminal/TerminalManager.swift Sources/Graftty/Views/MainWindow.swift Tests/GrafttyTests/Terminal/SurfaceHandleHostManagedTests.swift
git commit -m "refactor(TERM-11.11/11.14): delete fake-bounce wiring; show-time size-sync is the sole reconcile"
```

---

### Task 3: Generalize / verify all show triggers reconcile

**Files:**
- Modify (if a gap is found): `Sources/Graftty/Terminal/TerminalManager.swift`, `Sources/Graftty/Views/MainWindow.swift`
- Test: `Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift`

**Interfaces:**
- Consumes: `resyncVisibleGrid()`.
- Produces: every "pane became visible" path (focus click, `onAppear`, app-foreground, worktree-switch) reaches `resyncVisibleGrid`.

- [ ] **Step 1: Audit show triggers.** Run: `grep -rn "setVisible\|resyncVisibleGrid\|setWorktreeSurfacesVisible\|applyAppVisibility\|didBecomeActive\|didUnhide" Sources/Graftty/`. Trace each to confirm it funnels into `TerminalManager.setVisible(true,…)` → `handle.resyncVisibleGrid()`. The user's bug was a desync that the bounce (worktree-switch-only) never covered; the fix is that the size-sync now fires on ALL show paths. List any show path that does NOT call `resyncVisibleGrid`.

- [ ] **Step 2: If a gap exists, add the `resyncVisibleGrid` call** at that show site (matching the `setVisible(true)` pattern). If no gap exists, record that in the commit message and skip to Step 4.

- [ ] **Step 3: Add a regression test** asserting the show-time reconcile fires for a drifted grid (this generalizes the retained `TERM-11.13` test). Reuse the `reShowAtDriftedGridForwardsOneRealResizeNoBounce` shape from Task 1 — it already proves a drifted grid forwards on `resyncVisibleGrid`. If Step 2 added a new code path, add a TerminalManager-level test exercising that path through to a recorded `resyncVisibleGrid`.

- [ ] **Step 4: Run terminal tests + commit.** Run: `swift test --filter "HostManagedZmxBackend|TerminalManager|SurfaceHandleHostManaged"`. Expected: PASS.

```bash
git add -A
git commit -m "fix(TERM-11.13): reconcile PTY to live grid on every show trigger, not just worktree-switch"
```

---

### Task 4: Specs + SPECS.md

**Files:**
- Modify: `HostManagedZmxBackendTests.swift` (the `@spec` titles already updated in Tasks 1/3)
- Modify: any `///` doc-comment `@spec TERM-11.11`/`TERM-11.14` on types in `HostManagedZmxBackend.swift` (grep)
- Generated: `SPECS.md`

- [ ] **Step 1: Confirm `@spec` coverage.** Run: `grep -rn "@spec TERM-11.11\|@spec TERM-11.14" Sources/ Tests/`. The only remaining occurrences should be the two REWORDED titles added in Task 1 (now describing the no-bounce / single-real-resize behavior). Delete any leftover `///` doc-comment `@spec TERM-11.11`/`11.14` describing the bounce.

- [ ] **Step 2: Regenerate specs.** Run: `python3 scripts/generate-specs.py`. Then `python3 scripts/generate-specs.py --check`; Expected: exit 0.

- [ ] **Step 3: Verify the EARS text in `SPECS.md`** for `TERM-11.11`/`11.14` now reads as the no-bounce behavior, and `TERM-11.13`/the kept specs are intact.

- [ ] **Step 4: Commit.**

```bash
git add SPECS.md Sources/Graftty/Terminal/HostManagedZmxBackend.swift Tests/GrafttyTests/Terminal/HostManagedZmxBackendTests.swift
git commit -m "docs(specs): reword TERM-11.11/11.14 to the no-bounce size-sync contract; regen SPECS.md"
```

---

### Task 5: Full verification + review

- [ ] **Step 1: Full test suite.** Run: `swift test 2>&1 | tail -5`. Expected: all pass.
- [ ] **Step 2: Grep for orphans.** Run: `grep -rn "anchorHeal\|reanchorOnShow\|setAnchorHealOnAttach\|reanchorWorktreeOnShow\|healAnchorOnAttach\|healZmxAnchorOnAttach\|anchorHealShrinkDelay\|anchorHealRestoreDelay" Sources/ Tests/`. Expected: no matches (all deleted).
- [ ] **Step 3: `/code-review xhigh --fix`** over the diff; apply findings.
- [ ] **Step 4: Re-run full suite after fixes.** Run: `swift test 2>&1 | tail -5`. Expected: pass.
- [ ] **Step 5: Push + open PR** (base `main`), body summarizing the root cause (raw-passthrough/size-invariant), the deletion, the kept constraints, and the explicit **manual-verification ask** (the visual desync can only be confirmed by running the app; category-B residual, if any, is a deferred zmx `kill(child,SIGWINCH)` follow-up).
