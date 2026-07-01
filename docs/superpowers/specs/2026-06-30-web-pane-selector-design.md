# Web pane selector — bringing the web UI into line with Mac & GrafttyMobile

**Date:** 2026-06-30
**Branch:** `web-pane-selector`
**Status:** Approved design, ready for implementation plan

## Problem

The web UI is far simpler than the Mac and GrafttyMobile apps. Today:

- `web-client/src/routes/index.tsx` fetches `GET /sessions` — a *flat* list of individual
  sessions/panes, grouped only by repo. Panes are shown separately, not grouped under their
  worktree.
- `web-client/src/routes/session.$name.tsx` renders a single fullscreen terminal.
- There is **no sidebar, no worktree-grouped selector, and no pane-layout overview**.
- There is no desktop-width layout — it is always a single fullscreen terminal once in a session.

We want the web UI to match the two native clients:

1. **Worktree selector groups panes under worktrees** (like the Mac `SidebarView`), rather than
   listing every pane separately.
2. **Clicking a worktree shows a pane-layout overview** the same way GrafttyMobile does
   (proportional split tiles with live previews, tap a tile to go fullscreen).
3. **At desktop width, a persistent sidebar** (the worktree selector) is shown, like Graftty Mac
   and iPad — and the main content area renders the selected worktree's panes **in their actual
   split layout, as fully interactive terminals**, just like Graftty Mac.

## Key enabling fact: zero backend change required

The server already exposes everything this feature needs; the web client simply never consumed it:

- `GET /worktrees/panes` returns `[WorktreePanes]` — including the full `PaneLayoutNode` split tree
  (with `sessionName` per leaf). This is the *same wire model GrafttyMobile already consumes*
  (`Sources/GrafttyProtocol/WorktreePanes.swift`).
- `/ws?session=<name>` plus the **DisplayOwnership handshake** (`hello` / `ownership` /
  `ownerResize`, defined in `Sources/GrafttyProtocol/DisplayOwnership.swift` and
  `SessionDisplayOwnershipStore.swift`) already exist, and
  `web-client/src/components/TerminalPane.tsx` **already implements the full client side**:
  ownership claim, owner-gated input, and grid negotiation.

Because v1 uses **read-only (non-draggable) dividers** (see Decisions), no web→Mac layout-control
message is needed. The Mac remains the single source of truth for split ratios. The entire feature
is therefore a **web-client-only (React / TanStack Router) build**.

## Decisions (settled during brainstorming)

- **Overview tiles render live terminal previews** (not static title tiles), matching GrafttyMobile
  multi-pane tiles. This requires a preview-role WebSocket per visible pane and font-fit scaling.
- **Desktop content is a fully interactive Mac-style split layout** — each pane in the split is a
  live, typeable terminal; keyboard routes to the clicked/focused pane.
- **Split dividers are a read-only mirror in v1** — panes render at exactly the ratios the Mac
  reports; dividers are not draggable. This keeps the Mac as the single source of truth, adds no new
  protocol and no web-side layout state, and avoids the "ephemeral local drag that resets on reload"
  trap. Resize-from-web can be added later as a self-contained increment.
- **Responsive structure = width-branched component tree** (Approach A), mirroring GrafttyMobile's
  `RootView` branch on `horizontalSizeClass`. Routes still back every state for deep-linking/reload.

## Architecture

A responsive root branches on viewport width via `useIsDesktop()`
(`matchMedia`, `DESKTOP_MIN_WIDTH = 900px`). Routes back every state so URLs, reload, and
deep-links continue to work.

| State (route) | Compact (`< 900px`) | Desktop (`≥ 900px`) |
|---|---|---|
| `/` home | full-screen grouped `WorktreeList` | sidebar + empty "select a worktree" content |
| `/worktree/$path` | `PaneOverview` (live preview tiles) | sidebar + interactive `SplitLayout` for that worktree |
| `/session/$name` | `FullscreenPane` (single terminal) | sidebar + that pane's worktree `SplitLayout`, that pane focused |

### Components

- **`AppRoot`** — reads `useIsDesktop()`, renders `<DesktopShell>` or `<CompactNav>`.
- **`Sidebar`** (desktop, always visible) — grouped worktree list mirroring Mac `SidebarView`.
- **`WorktreeList`** (compact) — the same grouped list as a full-screen page.
- **`SplitLayout`** — a shared recursive renderer over `PaneLayoutNode`, parameterized by a
  `renderLeaf` callback. This is the key reuse: one geometry component, two leaf renderers —
  the same pattern as GrafttyMobile's `PaneLayoutView.render` + `PaneTile`.
- **`InteractivePane`** — the existing `TerminalPane`, reused as-is (already does ownership/grid).
- **`PanePreview`** — `TerminalPane` in `role: 'preview'`, font-fit-scaled, input suppressed;
  tapping navigates to `/session/$name`.
- **`PaneOverview`** (compact) — `SplitLayout` with `renderLeaf = PanePreview`. A single-pane
  worktree skips the overview and goes straight to fullscreen (GrafttyMobile parity, IOS-4.17).
- **`FullscreenPane`** (compact) — the existing single-terminal session view.

### Data flow

A single `useWorktreePanes()` hook polls `GET /worktrees/panes` → `[WorktreePanes]`, grouped by
`repoDisplayName`. Both the sidebar and the content area read from it; the `layout` tree drives both
the `↳` pane child-rows and the split geometry. Polling (rather than a push channel) is chosen for
v1 simplicity; a reasonable interval keeps the layout fresh as the Mac changes it.

### Shared `SplitLayout` renderer

Recursive over `PaneLayoutNode`:

- `split` → a flexbox container: `flex-direction: row` for `horizontal`, `column` for `vertical`.
  The two children get `flex-grow: ratio` (left/top) and `flex-grow: 1 - ratio` (right/bottom). A
  **fixed, non-draggable** divider element sits between them. Ratios come straight from the Mac's
  tree.
- `leaf` → calls `renderLeaf(leaf, { width, height })`.

The ratio→size math is extracted into a **pure function module** (`splitGeometry.ts`:
`flexBasisForRatio`, axis selection) so it is unit-testable without a DOM — the natural TDD seam.

### Two leaf renderers over the same geometry

- *Desktop, interactive* → `InteractivePane` (existing `TerminalPane`), `role: 'interactive'`. Each
  leaf opens its own `/ws?session=` and runs the existing ownership handshake. Nothing new.
- *Compact, preview* → `PanePreview` = `TerminalPane` with `role: 'preview'`, font-fit-scaled so
  `cols × cellWidth ≈ tileWidth` (mirrors `PanePreviewFontSizing.fontSize()`), input suppressed.

### Ownership correctness

Previews must **never** disrupt the real owner. The merged protocol already provides
`DisplayClientRole.preview` and `claimOwnerIfOwnerlessOrCurrent` (non-disruptive claim). So
`PanePreview` connects as `role: 'preview'` and **never claims ownership** — the Mac/desktop keep
driving the PTY grid and the preview renders whatever the owner's grid produces. Interactive desktop
panes use the existing claim-on-type flow already in `TerminalPane.tsx`. This "a preview-role pane
never emits an ownership claim" property is a required, explicitly-tested invariant.

### Focus model (desktop) — local to the browser

`DesktopShell` holds a `focusedSessionName` state. Clicking a pane sets it; that pane's
`TerminalPane` takes DOM focus and shows an active border; keystrokes route to that terminal's own
WebSocket. There is no cross-device focus coordination — the Mac's focus is independent, and the
layout wire model does not carry Mac focus, so web focus is deliberately a purely local concern.

### Preview pooling (compact overview)

Mirror GrafttyMobile's `PanePreviewClientPool`: open one preview socket per visible leaf while
`PaneOverview` is mounted, and tear them all down on unmount/navigation. v1 imposes no hard cap
(worktrees have few panes); a first-N cap can be added later like mobile if needed. Single-pane
worktrees never enter the overview, so they cost zero preview sockets.

### Sidebar details (desktop) — mirror Mac `SidebarView`

Grouped by `repoDisplayName` into sections. Each worktree row is rendered entirely from existing
`WorktreePanes` fields:

- type icon (main checkout vs linked branch), `prBadge` chip, `displayName` + dimmed `displayBranch`
- divergence gutter from `stats` (ahead/behind), `attentionText` capsule
- when running and selected, child `↳` pane rows from `layout.leaves` (`title`, `isBusy`, per-pane
  `attentionText`)
- an active-worktree rounded highlight around the block

Clicking a worktree navigates to `/worktree/$path` (selecting it); clicking a pane row sets
`focusedSessionName`.

### Styling

Reuse the existing `/ghostty-config` fetch (already used to theme the terminal) to theme the sidebar
surface (background/foreground), so it matches the Mac/iPad themed sidebar rather than introducing a
separate palette. Status is conveyed with subtle cues (dim / italic / capsule), not saturated
tints, consistent with the project's status-cue convention.

## Testing (TDD, RED → GREEN)

Two layers:

- **Web behavior (vitest, alongside `TerminalPane.test.tsx`)** — the units with real logic:
  - `flexBasisForRatio` / axis-selection math in `splitGeometry.ts`
  - repo-grouping of `[WorktreePanes]`
  - the width-branch decision (`useIsDesktop` threshold behavior)
  - single-pane worktree skips the overview and routes straight to fullscreen
  - **the ownership guard: a `preview`-role pane never emits an ownership claim** (the key
    correctness invariant)
- **`@spec` requirements** — add `WEB-` EARS entries (the project records web requirements under the
  `WEB-` prefix; `Tests/GrafttyTests/Specs/WebTodo.swift` is the inventory). Each new behavior gets a
  spec ID cited in the vitest test name, promoted from `WebTodo.swift` as it is implemented, and
  `SPECS.md` regenerated via `scripts/generate-specs.py`. Note the project rule: no literal quotes in
  `@spec` titles (they silently truncate `SPECS.md`).

## File plan (web-client only — zero backend change)

```
web-client/src/
  hooks/useWorktreePanes.ts        poll /worktrees/panes, group by repo
  hooks/useIsDesktop.ts            matchMedia(DESKTOP_MIN_WIDTH = 900)
  layout/AppRoot.tsx               width branch → DesktopShell | CompactNav
  layout/DesktopShell.tsx          Sidebar + content, focusedSessionName
  layout/Sidebar.tsx               grouped worktree list (Mac parity)
  layout/CompactNav.tsx            list → overview → fullscreen routing
  panes/SplitLayout.tsx            recursive geometry, renderLeaf param
  panes/splitGeometry.ts           pure ratio→size fns (unit-tested)
  panes/PaneOverview.tsx           SplitLayout + PanePreview leaves
  panes/PanePreview.tsx            TerminalPane role=preview, font-fit
  paneTypes.ts                     TS mirror of WorktreePanes / PaneLayoutNode
  routes/  index / worktree.$path / session.$name   (re-pointed to above)
  components/TerminalPane.tsx      reused as-is (interactive)
```

The existing `/sessions`-based index is replaced by the `/worktrees/panes`-driven grouped list; the
`/sessions` endpoint remains untouched server-side.

## Out of scope (v1)

- Draggable / resizable dividers and any web→Mac split-ratio control message.
- A push channel for worktree-list updates (polling is used instead).
- A hard cap on concurrent preview sockets (worktrees have few panes; add later if needed).
- Mirroring the Mac's focused-pane state onto the web (web focus is local-only).
