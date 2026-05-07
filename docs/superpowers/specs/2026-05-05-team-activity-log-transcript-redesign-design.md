# Team Activity Log — Slack-Inspired Transcript Redesign

**Date:** 2026-05-05
**Status:** Design approved; ready for implementation planning
**Visual reference:** `.superpowers/brainstorm/<session>/content/worktree-as-actor.html`

## Motivation

The Team Activity Log window today renders each `TeamInboxMessage` as either a small chat bubble (for `team_message`) or a system entry (an SF Symbol + headline + body block) per `TeamActivityLogRow.style`. The two visual modes don't share a baseline grid, system events for routed PR/CI/merge transitions don't surface the worktree they're scoped to, and member-join/leave entries render as full system-block rows even though they're really transient state markers.

The window is graftty's primary surface for "what's been happening across the team" and now also for the new `events.jsonl` observability stream. As that stream gets denser, the existing row layout — variable-width bubbles, mixed alignment, no shared timestamp axis — becomes hard to scan.

The redesign aligns every row on a single transcript grid (Slack compact mode, with the timestamp gutter on the left), drops decorative chrome that doesn't carry information (avatars, role-classification badges), and treats every row's "actor" as the worktree it's scoped to — including PR / CI / merge events, which then read as if the worktree itself reported the state change.

## Scope

### In scope

- Replace the rendering inside `TeamActivityLogRow` with a single transcript-style row layout.
- Drop the avatar concept and the `lead` / `coworker` role badges from the rendered output (the underlying model fields stay; the UI just doesn't surface them here).
- Re-frame PR / CI / merge events as worktree-attributed transcript rows with a dim body, a leading icon, and code-style pills for state values.
- Render `team_member_joined` / `team_member_left` as centered horizontal-rule markers (no timestamp gutter, no row body).
- Day-divider markers at midnight boundaries (`Today`, `Yesterday`, `Mar 5`).
- Continuation-row collapsing for consecutive messages from the same worktree within a short window: suppress the header and dim/hide the timestamp.

### Out of scope

- Reactions, threads, or message editing.
- Avatar circles, presence dots, or any other identity decoration.
- Filtering / search UI in the activity log window.
- New event kinds (the existing kinds — `team_message`, `team_member_joined`, `team_member_left`, `pr_state_changed`, `ci_conclusion_changed`, `merge_state_changed`, plus the new `events.jsonl` kinds — render through the same grid).
- Any change to the `TeamInboxMessage` schema or to which messages get written.

## Visual model

Every row that has a timestamp follows a single 2-column grid:

| Column          | Width  | Content                                                        |
| --------------- | ------ | -------------------------------------------------------------- |
| Timestamp       | 60 pt  | `HH:mm`, tabular nums, dim, right-aligned. Hidden on continuation rows except on hover. |
| Content         | 1 fr   | Optional header line (worktree name, plus optional `→ recipient` and `URGENT`), then body. |

Two row variants break the grid:

- **Centered marker** — used for `team_member_joined` / `team_member_left`. Horizontal rule on each side of a single line of dim text (`worktree joined the team`, `worktree left the team`). No timestamp gutter, no body row.
- **Day divider** — same horizontal-rule shape as the centered marker, but with an uppercase day label (`TODAY`, `YESTERDAY`, `MAR 5`).

### Header line

Every row that uses the grid renders a header line above the body:

- **Worktree name** — bold, foreground color. Acts as the row's actor. For chat (`team_message`) this is `from.member`; for routed system events it's the worktree the event is scoped to (read from `to.member` for the dispatched routing target).
- **`→ recipient`** — appended for direct chat messages where `from` ≠ `to` and the message isn't a broadcast. Dim text, smaller font.
- **`URGENT`** — appended (right-aligned via `margin-left: auto`) when `priority == .urgent`. Bold, system red.

The header line is **suppressed** on continuation rows (consecutive messages from the same worktree within a 5-minute window).

### Body

- **Chat (`team_message`)** — plain foreground text, white-space: pre-wrap.
- **System (PR / CI / merge / future kinds)** — dim text (secondary color), one-size-smaller. Leading 14pt icon glyph (`●` for PR, `✓` for CI, `⤲` for merge, `info.circle` style for unknown future kinds). Inline state values rendered as monospace pills with a 1-pixel border, e.g. `pending → success`. The body styling alone — no badge, no per-event-kind row chrome — distinguishes automated events from human messages.

### Centered markers

```
─── tailscale-alternative joined the team ───
```

The worktree name is foreground-secondary; the surrounding text is foreground-tertiary. No icon. Hairline rule fills the remaining width on each side.

## Data → row mapping

The mapping is computed in `TeamActivityLogRow.style` (or its replacement). For each `TeamInboxMessage`:

| Condition                                             | Variant                                                      |
| ----------------------------------------------------- | ------------------------------------------------------------ |
| `kind == "team_member_joined"`                        | Centered marker, text `<to.member> joined the team`          |
| `kind == "team_member_left"`                          | Centered marker, text `<to.member> left the team`            |
| `kind == "team_message"` and `from.member != "system"` | Chat row (header: `from.member` [→ `to.member` if direct], body: `body`) |
| `kind == "pr_state_changed"`                          | System row (worktree: `to.member`, icon: `●`, body composed from event attrs) |
| `kind == "ci_conclusion_changed"`                     | System row (worktree: `to.member`, icon: `✓`)                |
| `kind == "merge_state_changed"`                       | System row (worktree: `to.member`, icon: `⤲`)                |
| Any other kind (forward-compat)                       | System row (worktree: `to.member`, icon: `info.circle`, body: `kind` + raw `body`) |

Continuation collapsing applies to consecutive rows of the **same variant** with the **same worktree** within 5 minutes. Centered markers and day dividers reset the continuation chain.

System events with no clear scoped worktree (`to.member == "system"` for example, or future broadcast events) fall back to a fixed sentinel — likely a centered marker styled like the join/leave markers — rather than rendering with an empty header.

## Component structure

The redesign collapses the current two private subviews (`ChatBubbleView`, `SystemEntryView`) into a smaller set keyed off the new variant model:

- `TeamActivityLogRow` — public wrapper. Continues to take `message: TeamInboxMessage` plus, optionally, the previous-row context needed for continuation collapsing (a small `RowContinuationContext` value type passed in by the list view).
- `TranscriptRow` — renders the 2-column grid for chat and system variants. Accepts `header: HeaderModel?`, `body: BodyModel`, `timestamp: Date`, `isContinuation: Bool`.
- `CenteredMarkerRow` — renders the centered-rule marker. Accepts `text: String`.
- `DayDividerRow` — same shape as `CenteredMarkerRow` but with uppercase styling and different text source (`Today` / `Yesterday` / formatted date).

The list view (`TeamActivityLogWindow` / `TeamActivityLogViewModel`) computes:

1. The continuation context for each row by comparing against the previous message's variant, worktree, and timestamp.
2. The day-divider insertions between rows whose `createdAt` cross midnight in the user's local time zone.

Each component has a single responsibility and renders from already-resolved props — no model lookups inside the row views.

## Visual tokens

Colors and styles use SwiftUI semantic colors so dark / light mode switch automatically. The browser mockup at `worktree-as-actor.html` uses these CSS variable equivalents; SwiftUI tokens map as follows:

| Mockup variable     | SwiftUI source                 |
| ------------------- | ------------------------------ |
| `--fg`              | `Color.primary`                |
| `--fg-secondary`    | `Color.secondary`              |
| `--fg-tertiary`     | `Color.gray.opacity(0.6)` or `Color(NSColor.tertiaryLabelColor)` |
| `--bg-elev`         | `Color(NSColor.windowBackgroundColor).opacity(0.6)` (for pill background) |
| `--rule`            | `Color(NSColor.separatorColor)` |
| `--hover`           | `Color.primary.opacity(0.04)` (row hover) |
| `--urgent`          | `Color.red`                    |

Pills use `.font(.system(.footnote, design: .monospaced))`, a 1-pixel `Color(NSColor.separatorColor)` border, `RoundedRectangle(cornerRadius: 3)` background.

## Tests

New / updated test cases under `Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift` (the existing file gets reshaped to cover the new variant model rather than the old `Style` enum):

1. **Variant resolution** — a parameterized test that asserts `(kind, from, to)` triples produce the expected variant: chat, system, joined-marker, left-marker, fallback-system.
2. **Continuation collapsing** — given two messages from the same worktree 30 seconds apart of the same variant, the second is marked as a continuation; given the same pair 6 minutes apart, the second is not.
3. **Reset on marker** — a `team_member_joined` between two messages from the same worktree breaks the continuation chain.
4. **Day-divider insertion** — given two messages straddling local midnight, the view model inserts a `Yesterday` divider.
5. **Direct-message recipient suffix** — chat row from `a` to `b` shows `→ b`; chat row from `a` to `a` (or whatever the "self" sentinel is) does not.
6. **Urgent flag** — the `URGENT` marker appears on the header iff `priority == .urgent`.

The `RoutableEvent` → `TeamInboxMessage` body composition stays where it is today (in `EventBodyRenderer` / similar); the activity log just consumes the resulting body string.

## Architectural decisions

- **Worktree-as-actor for system events.** Rather than introducing a `[system]` badge or a separate column, system events reuse the chat row layout with the worktree filling the sender slot. This uses one mental model — "every row is attributable to a worktree" — and minimizes per-event-kind chrome.
- **Drop role visualization.** The `lead` / `coworker` distinction is still useful for routing and for the team-list CLI, but it doesn't add value in the activity feed (the feed is a chronological transcript, not a roster). Surfacing it as a per-row badge added visual weight without changing how a reader consumes the row.
- **No avatars.** Two-letter initials in deterministic-color circles add a band of color to every row but don't disambiguate any worktree better than the bold name does. The user dropped them deliberately.
- **Continuation collapsing on the view-model side.** The row view stays pure; the model annotates each row with a `previousIsSameActor: Bool`-style flag computed from `(variant, worktree, createdAt)` against the previous row. Keeps row rendering testable in isolation.
- **Day dividers in local time.** Crossing local midnight inserts a divider; explicit human-readable label (`Today` / `Yesterday` / `MMM d`) saves the reader from parsing dates on every row.

## Open questions / future work

- **System event icon set.** The mockup uses character glyphs (`●`, `✓`, `⤲`); the implementation should swap to SF Symbols (`circle.fill`, `checkmark.seal`, `arrow.triangle.merge`) for sharper rendering. Confirm the symbol names render at the row's font size.
- **Fallback worktree for events with `to.member == "system"`.** If any future event kind resolves to "everyone" / no specific worktree, it should render as a centered marker with the event headline rather than a system row with an empty actor.
- **Hover-only timestamp on continuation rows.** Mockup uses `:hover` to reveal; SwiftUI doesn't have a direct `:hover` for grid cells. The implementation will either show the timestamp dimmed permanently on continuation rows, or use SwiftUI's `.onHover` to drive a state-flag that toggles visibility.
- **Future avatar reintroduction.** If a presence/identity story emerges (status, badges, etc.) we may revisit avatars then; for now the UI stays text-first.

## Files to modify

- `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift` — replace the body with the new variant model and the three new subviews.
- `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogViewModel.swift` — add continuation-context computation and day-divider insertion.
- `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogWindow.swift` — minor: pass through whatever new props the row needs (continuation context, day-divider markers).
- New: `Sources/Graftty/Views/TeamActivityLog/TranscriptRow.swift`, `CenteredMarkerRow.swift`, `DayDividerRow.swift` — the three new subviews.
- `Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift` — reshape to cover the new variant model.
- New: `Tests/GrafttyTests/Views/TeamActivityLogViewModelTests.swift` if the view-model continuation logic warrants a dedicated suite.

## Out-of-scope follow-ups

- Surfacing the new `events.jsonl` observability events (registered, watcher lifecycle, nudge skip reasons) in the activity log. Once those events are routed through `TeamInboxMessage`, the existing fallback-system variant renders them; richer per-kind formatting can come later.
- Search / filter UI on the activity log window.
- A "compact density" toggle. Today's rendering matches Slack compact mode by default.
