# iPad M5 — Size-class router + sidebar layout — Design

**Status:** Draft, awaiting user review.
**Authors:** Ben Tucker, with Claude.
**Date:** 2026-05-19.

First user-visible slice of the iPad layout from
[`2026-05-15-ipad-layout-design.md`](2026-05-15-ipad-layout-design.md).
At iPad regular width the app gains a `NavigationSplitView`-based sidebar
that mirrors the Mac sidebar's structure (worktree list with PR badges,
attention pills, divergence gutter, swipe actions); the detail column
auto-focuses the worktree's currently-focused pane via the existing
`SingleSessionView`. Transport stays on the existing HTTPS path —
`WorktreePanesFetcher` and `SessionClient` over `/ws`. No WebRTC,
no pairing prerequisites, no Noise handshake.

## 1. Goal

After this ships, this user story works:

> I open the iPad app at regular width (landscape, or split-view at half
> the screen or wider). The sidebar shows my worktrees grouped by repo
> with PR badges, attention pills, and the same swipe actions as the
> iPhone path. I tap a worktree; the detail column shows the focused
> pane fullscreen — the same terminal experience as the iPhone today.
> I tap a different host from the header dropdown; the sidebar reloads.
> I drag the column divider to widen the sidebar; the width persists
> across launches. Sidebar and host header tint to match the host's
> Ghostty theme, the same way the Mac app's sidebar does.

## 2. Core promise

- **Worktree sidebar with parity to the Mac.** Same row content: type
  icon, PR badge, italic main-checkout, secondary branch label,
  attention pill, divergence gutter. Same swipe actions: delete and
  dismiss. Same pull-to-refresh + auto-load on appear.

- **Theme-tinted chrome.** Sidebar background uses `theme.sidebarBackground`
  (6% shifted from the terminal background — lighter on dark themes,
  darker on light); host header uses `theme.background`. Same algorithm
  the Mac's `SidebarView` and `BreadcrumbBar` apply.

- **Resizable sidebar with persistence.** Column divider drags between
  220–480pt; debounced 250ms write to `UserDefaults`. Same modifier
  the Mac uses (lifted to a shared file in `GrafttyProtocol/UI/`).

- **Existing transport.** All data flows over the existing HTTPS
  endpoints (`/worktrees/panes`, `/ghostty-config`, `/ws`). No new
  network code. WebRTC adoption is a separate, later milestone.

- **iPhone path unchanged.** Compact-width `RootView` continues to
  render today's `NavigationStack` flow. M5 only branches at regular
  width; iPhone users see exactly what they see today.

## 3. Scope

### In scope

- `RootView` becomes a size-class router (regular → `IPadRootLayout`,
  compact → existing NavigationStack).
- `IPadRootLayout` (new) — `NavigationSplitView` with two columns,
  plus inline `HostHeaderRow` and `IPadDetailColumn` subviews.
- `WorktreeListContent` extracted out of `WorktreePickerView` so both
  the compact wrapper and the iPad sidebar reuse the same list +
  swipe + dialogs + load-state code.
- `HostPickerView` gains an optional `onSelect: ((Host) -> Void)?`
  parameter. When non-nil, rows fire the callback on tap instead of
  using `NavigationLink(value:)`. Lets the iPad host-switcher popover
  reuse the entire picker body — Saved-hosts section, empty-state
  copy, "+" toolbar, AddHostView sheet — with zero duplication.
- `IPadAppState` (new) — `@Observable @MainActor` selection state:
  `selectedHostId: UUID?` (UserDefaults), `selectedWorktreePath: String?`
  (in-memory), `focusedPaneId: String?` (in-memory),
  `sidebarWidth: Double` (UserDefaults), `theme: GhosttyThemeColors`
  (in-memory, fetched per host).
- Cross-platform `GhosttyThemeCore.swift` in `GrafttyProtocol/UI/` —
  `GhosttyThemeColors` struct (RGB triples), `sidebarBackground`
  shift, `isDark` luminance, SwiftUI `Color` builder. Mac's existing
  `GhosttyTheme` becomes a thin wrapper.
- `SidebarWidthPreference.swift` moved from `Sources/Graftty/Views/`
  to `Sources/GrafttyProtocol/UI/`. New `persistSidebarWidth(to:)`
  modifier bundles the 250ms debounce. Mac's `MainWindow.swift`
  adopts the shared file.
- Spec promotions for IPAD-1.1, 1.2, 1.3, 1.4, 6.2, 7.1 (with EARS
  amendments where M5 scope differs from the original transport plan).

### Out of scope

- **WebRTC transport** — `panes_state`, `pane_control`, terminal
  channels. M5 stays on HTTPS. Migration is a later milestone.
- **Multi-pane split rendering in detail** (M6, IPAD-2.x).
- **Focused-pane toolbar with split/close/swap RPCs** (M7, IPAD-3.x).
- **Live-channel budget** (M8, IPAD-4.x).
- **Full background/foreground re-establish** (M9, IPAD-5.x).
- **State preservation across size-class transitions** — IPAD-7.2
  stays disabled. `IPadAppState` is lifted to `RootView` so the
  values survive a Split View resize, but the compact path doesn't
  read them.
- **Attention dismissal on worktree select** — Mac mutates
  `appState.repos[...].attention` directly. iPad would need a server
  round-trip the server doesn't expose. Skipped; refresh polling
  picks up Mac-side attention changes.
- **Auto-pick first host on launch.** Mac doesn't auto-select a
  worktree on first launch (line 161 of `MainWindow.swift` —
  `.onChange(...initial: true)` guards on nil). iPad mirrors: show
  "No host selected" via `HostHeaderRow` if `selectedHostId` is nil
  or stale; user picks explicitly.

## 4. Architecture

### 4.1 Client side

```
GrafttyMobileApp
└── RootView                                 (size-class router — IPAD-1.1)
    ├── (compact)  → existing NavigationStack flow            (unchanged)
    │                HostPicker → WorktreePicker → SingleSession
    │
    └── (regular)  → IPadRootLayout                           (new)
                     ├── NavigationSplitView (2-column)
                     │   ├── Sidebar
                     │   │   ├── HostHeaderRow                (private subview)
                     │   │   │   └── tap → .popover { HostPickerView(onSelect:) }
                     │   │   └── WorktreeListContent          (extracted)
                     │   │
                     │   └── Detail
                     │       └── IPadDetailColumn             (private subview)
                     │           ├── (no host)     → ContentUnavailableView
                     │           ├── (no worktree) → ContentUnavailableView
                     │           └── (worktree)    → SingleSessionView for focused pane
                     │
                     └── (LockOverlay preserved from existing RootView)

IPadAppState (@Observable, owned at RootView level)
├── selectedHostId: UUID?            ← UserDefaults
├── selectedWorktreePath: String?    ← in-memory
├── focusedPaneId: String?           ← in-memory
├── sidebarWidth: Double = 320       ← UserDefaults
└── theme: GhosttyThemeColors        ← in-memory, refetched per host
```

### 4.2 Shared additions in `GrafttyProtocol`

```
Sources/GrafttyProtocol/UI/
├── GhosttyThemeCore.swift              (new — cross-platform color logic)
│   ├── GhosttyThemeColors (struct)
│   │   ├── backgroundRGB / foregroundRGB
│   │   ├── background: Color
│   │   ├── foreground: Color
│   │   ├── sidebarBackground: Color   ← +/-6% shift
│   │   ├── isDark: Bool               ← luminance threshold
│   │   └── .fallback                  ← dark-mode defaults
│   └── (no AppKit/UIKit dependencies)
│
└── SidebarWidthPreference.swift        (moved from Sources/Graftty/Views/)
    ├── SidebarWidthKey: PreferenceKey
    ├── View.publishSidebarWidth() -> some View
    └── View.persistSidebarWidth(to: Binding<Double>) -> some View   (new)
                                         ↑ 250ms debounce, shared by Mac + iPad
```

### 4.3 Mac side (minor refactor)

- `Sources/Graftty/Terminal/GhosttyBridge.swift` — `GhosttyTheme`
  becomes a wrapper around the shared `GhosttyThemeColors`. Keeps
  `NSColor` / `NSAppearance` extensions Mac-specific.
- `Sources/Graftty/Views/MainWindow.swift` — imports
  `SidebarWidthPreference` from the shared module; replaces the
  ~12-line `.onPreferenceChange` debounce block with one
  `.persistSidebarWidth(to: $appState.sidebarWidth)` modifier call.

### 4.4 Data flow

**Launch (regular width):**

```
RootView
  .task { hostStore.loadIfNeeded() }
  .task { appState.restoreFromDefaults() }

IPadRootLayout resolves selectedHost from selectedHostId + hostStore.hosts.

Two concurrent .task(id: host.id) fetches:
  (a) WorktreePanesFetcher.fetch(baseURL:) → WorktreeListContent.state
  (b) GhosttyConfigFetcher.fetch(baseURL:) → IPadAppState.theme
```

**Worktree tap:**

```
WorktreeListContent.onSelectWorktree(wt)
  → IPadAppState.selectedWorktreePath = wt.path
  → IPadAppState.focusedPaneId = wt.layout?.leaves.first?.sessionName
                                  // wire model has no focused-pane
                                  // marker; M5 picks the first leaf.
                                  // Mac's `focusedPaneSlotID` lives on
                                  // `WorktreeEntry`, not on the wire
                                  // `WorktreePanes`. Future milestone
                                  // can extend the wire model if
                                  // restoring Mac-side focus becomes
                                  // necessary.

IPadDetailColumn:
  if focusedPaneId != nil → SingleSessionView(...)
  else                    → ContentUnavailableView
```

**Pane child row tap (IPAD-1.4):**

```
WorktreeListContent.onSelectPane(leaf)
  → IPadAppState.focusedPaneId = leaf.sessionName
  (selectedWorktreePath stays — same worktree, different pane)
```

**Host switch:**

```
HostHeaderRow tap
  → .popover { HostPickerView(onSelect: { newHost in ... }) }
HostPickerView callback:
  → IPadAppState.selectedHostId = newHost.id
  → IPadAppState.selectedWorktreePath = nil
  → IPadAppState.focusedPaneId = nil
  → dismiss popover
```

**Sidebar resize:**

```
Drag column divider → SwiftUI internal layout updates
  → publishSidebarWidth() GeometryReader emits new width
  → persistSidebarWidth(to: $appState.sidebarWidth) — 250ms debounce
  → UserDefaults write
```

### 4.5 Error handling

| Failure | Behavior |
|---|---|
| `WorktreePanesFetcher` 403 | `WorktreeListContent.state = .error("Not authorized — is this device on your tailnet?")` (existing copy). |
| `WorktreePanesFetcher` HTTP 4xx/5xx | `.error("HTTP \(code)")` (existing). |
| `WorktreePanesFetcher` decode error | `.error("The server sent a response this version can't read.")` (existing). |
| Transport error | `.error("Couldn't reach the server.")` (existing). |
| `GhosttyConfigFetcher` returns nil | `IPadAppState.theme = .fallback`. No user-visible error; theme is polish. |
| Config text has no hex bg/fg | Same — `.fallback`. Hex parser returns nil for non-hex values. |
| Stale `selectedHostId` on launch | `selectedHost` is nil → `HostHeaderRow` in "No host selected" state. |
| Stale `selectedWorktreePath` after worktree load | `onListChanged` fires from `WorktreeListContent` on every `.loaded(list)` transition; the iPad layout clears `selectedWorktreePath` and `focusedPaneId` when `list.contains { $0.path == selectedWorktreePath }` is false. Mirrors the Mac's `AppState.removeWorktree(atPath:)` self-clear (`Sources/GrafttyKit/Model/AppState.swift:136`). |
| Host switch mid-fetch | `guard host.id == capturedHostID` check on response side before writing state. Mirrors `WorktreeStatsStore`'s generation pattern (DIVERGE-4.5). |

## 5. UI design

### 5.1 Sidebar

- **HostHeaderRow** (private subview in `IPadRootLayout.swift`,
  ~25 lines): selected host's `label` + base URL stacked, chevron
  trailing. Tap → `.popover`. When no host selected, shows "No host
  selected — tap to pick" with chevron.
- **HostSwitcherPopover** is just `HostPickerView(store: hostStore,
  onSelect: { ... })` — no new view. The picker's existing body
  renders rows + add-button + AddHostView sheet.
- **`WorktreeListContent`** (new file, extracted): the entire
  `WorktreePickerView` body — sectioned list with
  `WorktreePickerGrouping`, swipe-to-delete with confirmation,
  PR badges via `PRBadgeLabel`, attention capsules,
  `DivergenceGutter`, pull-to-refresh, AddWorktree sheet,
  error toasts. Accepts:
  ```swift
  init(
    host: Host,
    onSelectWorktree: @escaping (WorktreePanes) -> Void,
    onSelectPane: @escaping (PaneLayoutNode.Leaf) -> Void,
    onListChanged: @escaping ([WorktreePanes]) -> Void = { _ in }
  )
  ```
  `onListChanged` fires on every transition into `.loaded([WorktreePanes])`
  — initial load, manual refresh, post-add, post-delete. The iPad layout
  uses it to detect a stale `selectedWorktreePath` (path no longer in the
  list, e.g., deleted out-of-band or in-band) and clear selection. The
  compact wrapper ignores it (NavigationStack pops naturally).

### 5.2 Detail column

- **`IPadDetailColumn`** (private subview, ~30 lines): tri-state.
  - No host → `ContentUnavailableView("Pick a host", systemImage:
    "server.rack", description: "Tap the chevron at the top of the
    sidebar.")`
  - No worktree → `ContentUnavailableView("Pick a worktree",
    systemImage: "list.bullet.indent")`
  - Focused pane → `SingleSessionView(step: SessionStep(host:,
    sessionName:, title:))` — the existing iPhone view.

### 5.3 Theme tinting

- Sidebar column → `.background(appState.theme.sidebarBackground)`
- Host header tile → `.background(appState.theme.background)`
- Detail column → `.background(appState.theme.background)` (the
  embedded `SingleSessionView` paints its own terminal scheme over it).
- Text + dividers → derived from `theme.foreground` at varying opacity.
- PR badges, attention pills → keep semantic system colors
  (green/red/yellow/purple), readable on both light and dark.

### 5.4 Sidebar width

- `.navigationSplitViewColumnWidth(min: 220, ideal:
  appState.sidebarWidth, max: 480)`. Bounds adjusted from Mac's
  180–400: touch breathing room at the low end, iPad screen budget
  at the high end.
- `.publishSidebarWidth()` + `.persistSidebarWidth(to:
  $appState.sidebarWidth)` — same modifier the Mac uses.

## 6. Spec ID plan

### 6.1 Promotions (RED → GREEN)

| ID | Status | Notes |
|---|---|---|
| `IPAD-1.1` | Promote | Size-class router. |
| `IPAD-1.2` | Promote | HostHeaderRow + popover trigger. |
| `IPAD-1.3` | Amend EARS + promote | Drops the "bound to `WorktreePanesStore`" clause. Reads: "*While `IPadRootLayout` is presented, the sidebar shall render `WorktreeListContent` extracted from `WorktreePickerView`, preserving `WorktreePickerGrouping`, swipe actions, PR badges, attention pills, and divergence gutter.*" |
| `IPAD-1.4` | Promote | Sidebar pane row tap → `focusedPaneId`, no nav push. |
| `IPAD-6.1` | Amend EARS + promote | Drops `RemoteHostConnection` language. Reads: "*When the user selects a different host from the host-switcher popover, the application shall reset `selectedWorktreePath` and `focusedPaneId`, dismiss the popover, and re-fetch worktrees and theme for the new host.*" |
| `IPAD-6.2` | Promote | "*While the new host's worktree fetch is in progress, the sidebar shall show ProgressView and the detail column shall show `ContentUnavailableView`.*" |
| `IPAD-7.1` | Promote | "*When `horizontalSizeClass == .compact`, the application shall render the existing compact `RootView` flow without any iPad layout components.*" |

### 6.2 Inventory deletions

| ID | Status | Notes |
|---|---|---|
| `IPAD-6.3` | Delete from inventory | Per Mac alignment: no auto-select on launch or host switch. Detail stays at `ContentUnavailableView` until the user picks. |

### 6.3 Deferred (stays disabled)

| ID | Why deferred |
|---|---|
| `IPAD-7.2` | Cross-size-class state preservation. `IPadAppState` is lifted so values survive, but the compact path's `NavigationStack` doesn't read them. Adds risk for a layout-only PR. M5+ task. |

## 7. Testing strategy

### 7.1 Layer 1 — cross-platform unit tests (macOS `swift test` + iOS CI)

- `Tests/GrafttyProtocolTests/UI/GhosttyThemeCoreTests.swift` —
  RGB equality, `sidebarBackground` shift (+/-6% clamped), `isDark`
  luminance edge cases.
- `Tests/GrafttyProtocolTests/UI/GhosttyThemeMobileParseTests.swift` —
  `GhosttyThemeColors.init(parsingConfigText:)` covering hex with/without
  `#`, casing, partial keys, commented lines, garbage lines, theme refs
  ignored.
- `Tests/GrafttyProtocolTests/UI/SidebarWidthPreferenceTests.swift` —
  `SidebarWidthKey.reduce` ignores zero, `persistSidebarWidth(to:)`
  debounce coalesces consecutive writes within 250ms.

### 7.2 Layer 2 — UIKit-guarded tests (iOS CI only)

- `Tests/GrafttyMobileKitTests/App/IPadAppStateTests.swift` —
  UserDefaults round-trip for `selectedHostId` and `sidebarWidth`,
  default values, `restoreFromDefaults()` idempotency.
- `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift` —
  `selectedHost` resolution (match, nil, stale), stale-`selectedWorktreePath`
  cleanup on fresh load, pane child row tap → `focusedPaneId` without
  nav push.
- `Tests/GrafttyMobileKitTests/Hosts/HostPickerViewCallbackTests.swift` —
  `onSelect: nil` keeps today's push behavior; `onSelect: non-nil`
  fires the callback. Regression guard for the new mode parameter.
- `Tests/GrafttyMobileKitTests/UI/WorktreeListContentTests.swift` —
  `WorktreePickerGrouping` invariants preserved across the extract,
  swipe actions render, PR badges + attention + gutter render,
  AddWorktree sheet flow, DeleteWorktreeClient invocation.
- `Tests/GrafttyMobileKitTests/App/RootViewSizeClassTests.swift` —
  `.compact` → existing NavigationStack body; `.regular` →
  `IPadRootLayout`. `IPadAppState` survives transitions (lifted
  to RootView).

### 7.3 Layer 3 — structural `@spec` doc comments

- `IPadAppState` carries `@spec IPAD-1.1` documenting the
  observable selection contract + UserDefaults persistence.
- `GhosttyThemeColors` carries an `@spec` documenting the
  shared color/shift contract. Mirrors the dual-enforcement
  pattern used on `PaneControlHandler` for REMOTE-7.5.

### 7.4 Layer 4 — manual smoke checklist

`docs/IpadLayoutSmokeChecklist.md` (new) — modeled on
`docs/ZmxWebAccessSmokeChecklist.md`. Covers:

1. Regular-width sidebar + detail render.
2. Add host → pick worktree → terminal renders.
3. Sidebar resize → divider drags, width persists across relaunch.
4. Host theme — light vs dark → sidebar tints accordingly.
5. Compact-width fallback (Split View) → existing iPhone flow,
   no crashes.

## 8. Implementation milestones

M5 is a single PR. Sub-tasks for the implementation plan (see
`docs/superpowers/plans/2026-05-19-ipad-m5-sidebar.md`):

1. `GhosttyThemeCore.swift` — shared cross-platform theme.
2. Mac refactor — `GhosttyTheme` wraps `GhosttyThemeColors`.
3. `SidebarWidthPreference.swift` move + `persistSidebarWidth(to:)`.
4. Mac refactor — `MainWindow.swift` adopts shared modifier.
5. `IPadAppState.swift` — selection state + UserDefaults.
6. `WorktreeListContent.swift` — extract from `WorktreePickerView`.
7. `WorktreePickerView.swift` — collapse to thin wrapper.
8. `HostPickerView.swift` — add `onSelect` callback mode.
9. `IPadRootLayout.swift` — NavigationSplitView with private
   `HostHeaderRow` + `IPadDetailColumn`.
10. `RootView.swift` — size-class branch.
11. Spec promotions and amendments in `IpadTodo.swift` →
    new `*Tests.swift` files.
12. `IpadLayoutSmokeChecklist.md`.
13. Regenerate `SPECS.md`.

## 9. Risks

**Sidebar extract regression.** Moving `WorktreePickerView`'s body
into `WorktreeListContent` is the highest-risk change. iPhone users
get the same code path — a bug here is P0 for the existing user
base. The `WorktreeListContentTests` are explicitly modeled around
preserving every invariant (`WorktreePickerGrouping`, swipe actions,
PR badges, attention pills, divergence gutter, AddWorktree sheet,
DeleteWorktreeClient).

**`HostPickerView` mode parameter.** Adding an optional `onSelect`
parameter flips a critical behavior. Mismatch could mean iPhone host
picks become silent no-ops. `HostPickerViewCallbackTests` covers both
modes.

**Mac refactor scope creep.** Moving `SidebarWidthPreference.swift`
out of `Sources/Graftty/Views/` and into shared touches Mac code.
The change is mechanical (one import edit + a 12-to-1-line modifier
collapse in `MainWindow.swift`), but a slip there is a Mac
regression. CI's `macos-build-and-test` job is the gate.

**Theme parser limitations.** Mobile-side hex parser handles
`background = #RRGGBB` but not Ghostty's full color grammar
(named colors, palette refs, theme refs). Mac returns the
*resolved* config, so bg/fg are hex in 99% of real configs;
edge cases fall back to `.fallback`. Acceptable.

**Size-class transition state loss.** `IPadAppState` is lifted to
`RootView` so values survive a Split View resize, but the compact
path doesn't read them. A user resizing to compact lands at the
host picker, not mid-stack. IPAD-7.2 explicitly stays disabled;
documented as M5+ work.

## 10. Non-goals

- New transport (WebRTC). M5 is HTTPS-only.
- New pairing requirements. Existing `HostStore` URL list works.
- Multi-pane split rendering. Detail is single-pane fullscreen.
- Auto-pick host or worktree on first launch.
- Compact-width state restore from `IPadAppState` (IPAD-7.2).
- Attention dismissal on worktree select (needs server endpoint).
- iPad-specific pane preview UI (existing `WorktreeDetailView` is
  iPhone-only; iPad goes straight to focused pane).

## 11. Decisions summary

| Decision | Choice |
|---|---|
| Transport for M5 | Existing HTTPS — `WorktreePanesFetcher`, `/ws`. No WebRTC. |
| Detail column default when only worktree selected | Auto-focus the worktree's focused-or-first pane. |
| First-launch host selection | No auto-pick. Restore from UserDefaults; otherwise "No host selected" via HostHeaderRow. |
| Delete-the-selected-worktree | Clear selection; detail shows `ContentUnavailableView`. Mirrors `AppState.removeWorktree`. |
| Pane child row at compact width | Existing `IOS-4.21` push behavior; `IPadAppState.focusedPaneId` is regular-only. |
| Sidebar bounds | 220–480pt (Mac uses 180–400). |
| Sidebar width persistence | UserDefaults via shared `.persistSidebarWidth(to:)` modifier. |
| Theme parsing | Mobile-side hex parser for `background`/`foreground`; fallback for unparseable values. |
| Shared theme code location | `Sources/GrafttyProtocol/UI/` — Mac refactors to consume the same file. |
| `HostPickerView` reuse | Add optional `onSelect` callback parameter; iPad popover uses the same view. |
| `WorktreeListContent` extraction | New file; `WorktreePickerView` becomes a thin wrapper. |
| IPAD-6.3 (auto-select first worktree) | **Removed from inventory.** No auto-pick anywhere. |
| IPAD-7.2 (compact transition state restore) | Stays disabled; M5+ work. |
