# Busy-title style + attention pill beside the title

**Date:** 2026-06-02
**Status:** Implemented
**Branch:** `dont-show-working`

> **Update (during implementation):** the busy cue is **italic**, not a
> green tint. Green read as too aggressive in the running app, so the busy
> pane title is now rendered *italic* (the title already animates, so a
> quiet style shift is enough). Everywhere this doc says "green tint" below,
> read "italic style" — the mechanism is otherwise identical: the busy
> signal still flows through `isPaneBusy` + the wire `isBusy` field, the
> ping-supersedes-busy precedence still lives in the shared helper (now
> `PaneTitleBusyStyle.applies`), and `paneTitle(…)` stays color-only.

Two related sidebar pane-row changes:

1. Replace the busy `working…` red pill with an italic style on the (still
   visible, already animating) pane title.
2. Render the attention pill ("Claude needs input" and other notify pings)
   **to the right of** the pane title rather than in place of it; the title
   truncates as needed to make room for the pill.

## Problem

`AgentLivenessMerge.effectivePaneText` merges two semantically unrelated
signals into a single optional string, and both render through the same
red `AttentionCapsule` that **replaces** the pane title:

1. A real **notify ping** (`graftty notify` / shell-integration) — "come
   look at this," legitimately an alarm. Red is right.
2. **Derived busy liveness** — claude's session is merely running. This is
   *not* an alarm. Rendering it red borrows the attention color for a
   non-attention state, and replacing the title with a `working…` pill
   hides the very thing that already communicates "working": claude
   continuously rewrites the terminal title (spinner + elapsed time), so
   the pane title is already animating.

The result is redundant and miscolored. We want the animated title to stay
visible and carry the "working" signal, with a subtle color tint to make an
actively-working pane scannable in a long sidebar — without stealing the
alarm color.

## Decision

- **Drop** the busy → `working…` capsule entirely.
- **Keep** the title visible while busy and **tint it green**. Green
  already reads as "live/active" in this sidebar: `worktreeStateIcon`
  returns `.green` for a running worktree (`GhosttyThemeCore.swift:167`).
  Extending that language (busy pane title = green, idle = normal dim) is
  consistent rather than a new invention.
- **Apply on both surfaces** (Mac sidebar + iPad/web), single-sourced
  through the shared theme helper so the two cannot drift.
- Notify pings are **untouched** — they still render as the red capsule.
- **No animation/pulse.** The title already animates; a static color shift
  is all that is needed.

## Design

### 1. `AgentLivenessMerge` — split the two signals

`Sources/GrafttyKit/AgentLiveness/AgentLivenessMerge.swift`

- `effectivePaneText(paneAttentionText:sessionName:liveness:)` returns
  **only** `paneAttentionText`. The busy branch and the
  `busyText = "working…"` constant are deleted.
- Add `isPaneBusy(sessionName:liveness:) -> Bool` returning
  `sessionName != nil && liveness[sessionName] == .busy`. Pure,
  single-purpose, trivially testable.

The two signals are now independent: notify → red pill; busy → title tint.
They render in different places (capsule *replaces* title; tint *colors*
title), so there is no conflict to arbitrate — `isPaneBusy` is purely
liveness-derived and does not need to know about the ping.

### 2. Shared theme helper — the tint lives in one place

`Sources/GrafttyProtocol/UI/GhosttyThemeCore.swift`

Extend the single-sourced
`paneTitle(isFocusedPane:isActiveWorktree:hasTitle:)` with an
`isBusy: Bool` parameter:

- When `isBusy`, the base color is `.green` (matching
  `worktreeStateIcon`'s running-green) instead of `foreground`.
- The existing `paneTitleOpacity` ladder (1.0 / 0.75 / 0.55 / 0.35 across
  focused → inactive, empty-title dimmer) is preserved, so focus hierarchy
  still reads under the tint.
- Idle (`isBusy == false`) is unchanged.

One edit; both renderers inherit it.

### 3. Wire model — carry the busy flag to iPad/web

`Sources/GrafttyProtocol/WorktreePanes.swift`

Add `isBusy: Bool` to the `PaneLayoutNode.leaf` case and the `Leaf`
struct. Thread it through `collectLeaves`, `CodingKeys`, `init(from:)`,
and `encode(to:)`. Encode/decode it backward-compatibly:
`decodeIfPresent(Bool.self, forKey: .isBusy) ?? false`, so a leaf without
the field (older peer) is treated as not-busy rather than failing to
decode.

### 4. Renderers — both already structurally identical

Both `PaneTitleRow` views share the same shape:
`if attentionText { AttentionCapsule } else { Text(title).foregroundStyle(theme.paneTitle(…)) }`.

- **Mac** — `Sources/Graftty/Views/WorktreeRow.swift`: add an `isBusy`
  parameter to `PaneTitleRow`; pass it into `theme.paneTitle(…, isBusy:)`
  on the title `Text`. `SidebarView` computes it via
  `AgentLivenessMerge.isPaneBusy(sessionName:liveness:)` (the same
  `sessionName` / `liveness` it already passes to `effectivePaneText`).
- **iPad/web** — `Sources/GrafttyMobileKit/UI/WorktreeListContent.swift`:
  pass `leaf.isBusy` into the same helper.
- `Sources/Graftty/GrafttyApp.swift` `paneLayoutNode(…)` populates
  `isBusy` on each leaf using `AgentLivenessMerge.isPaneBusy(…)`.

### 5. Attention pill — beside the title, not replacing it

Today both `PaneTitleRow`s branch `if attentionText { AttentionCapsule }
else { title }`, so an active ping *replaces* the title. Change this to
render the title **and** the pill, with the title truncating to make room:

- **Layout:** title (`lineLimit(1)`, `truncationMode(.tail)`,
  `layoutPriority(0)`) followed by the `AttentionCapsule`
  (`layoutPriority(1)`) in a plain `HStack`, trailed by the existing
  `Spacer`. The pill keeps its intrinsic width; the title yields first and
  truncates. The pill therefore sits immediately to the right of the
  (possibly shortened) title.
- **Mac (`WorktreeRow.swift`):** the no-pill case keeps `FlowLayout` (so
  port chips still wrap under the title). The pill case must *not* use
  `FlowLayout` — a wrapping layout proposes full width to the title and
  pushes the pill onto the next line instead of truncating the title. So
  the pill case uses a plain `HStack`. Factor the styled title into a small
  shared `@ViewBuilder` so both branches spell the font/weight/color once.
- **iPad (`WorktreeListContent.swift`):** already a plain `HStack` with no
  port chips; just move the title out of the `else` so it always renders,
  and append the pill (with `layoutPriority(1)`) when present.
- **LAYOUT-2.22 must still hold:** the row's intrinsic width stays bounded
  by the row width because the title truncates. Extend the LAYOUT-2.22 test
  to also cover the pill-present case (long title + pill → bounded width).
- **PORTS-3.4 unchanged:** port chips stay hidden while a pill is active
  (`shouldRenderPortChips` keeps its `attentionText == nil` guard) — the
  pill owns the row's secondary surface; only the title joins it now.

### Tint × pill precedence

A needs-input ping means claude has *stopped and is waiting* — the opposite
of busy — so a ping supersedes the busy tint. The title is green-tinted only
when busy **and** no pill is present:

```
let tintBusy = isBusy && attentionText == nil
```

| State                         | Title          | Pill |
|-------------------------------|----------------|------|
| idle, no ping                 | normal dim     | —    |
| busy, no ping                 | **green**      | —    |
| ping present (busy or not)    | normal (truncated) | red, right of title |

## Specs (per CLAUDE.md)

- **AGENT-2.2** reworded to match the new behavior:
  > While a pane has no live attention ping, the application shall surface
  > a busy claude session by tinting the pane title with the running/active
  > color (not a capsule), and render the title unchanged when idle.
- **AGENT-2.1** (notify-ping-wins) is unchanged in intent; its assertion
  stays green because `effectivePaneText` still returns the ping verbatim.
- **New LAYOUT-2.30:**
  > While a pane has an active attention capsule, the application shall
  > render the capsule to the right of the pane title (not in place of it),
  > truncating the title as needed so the capsule keeps its intrinsic width.
- **LAYOUT-2.22** EARS text unchanged; its test gains a pill-present case.
- **PORTS-3.4** unchanged.
- The `PaneTitleRow.attentionText` doc comment is updated: the title is no
  longer "replaced by" the capsule — the capsule renders to its right.
- No sibling specs are renumbered.

## Testing (TDD, RED → GREEN)

- `Tests/GrafttyTests/AgentLivenessMergeTests.swift`:
  - Rewrite `busyRendersWorkingWhenNoPing`: busy now yields `nil` from
    `effectivePaneText` **and** `isPaneBusy(…) == true`.
  - Keep `notifyPingWinsOverBusy`, `idleRendersNothing`,
    `unknownSessionRendersNothing` (the latter two also assert
    `isPaneBusy == false`).
  - Update the `@Suite` summary line.
- Theme: a pure assertion that for the same bucket,
  `paneTitle(…, isBusy: true) != paneTitle(…, isBusy: false)` — the tint
  actually changes the rendered color.
- `PaneLayoutNode` Codable round-trip covering the new `isBusy` field,
  including the default-`false`-on-absent path for backward compatibility.
- `PaneTitleRowPortsTests`:
  - New LAYOUT-2.30 assertion: with `attentionText` non-nil, the row still
    exposes the title (not just the capsule) — e.g. via a render-tree probe
    or by asserting both subviews are present.
  - Extend the LAYOUT-2.22 `sizeThatFits` test with an `attentionText`
    non-nil + long-title case; width stays bounded by the container.
  - PORTS-3.4 (`attentionHidesChips`) stays green.

## Scope guard / non-goals

- No animation or pulsing — the title's own animation is the motion.
- Notify pings (worktree- and pane-scoped) are not modified.
- No renumbering of existing specs.
- No change to how busy/idle liveness is *computed* (ClaudeSessionRegistry,
  AgentLivenessParsing) — only how it is *rendered*.
