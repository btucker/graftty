# Sidebar reorganization: pinned tiles and one place for waiting work

Date: 2026-11-09
Worktree: `mac-sidebar-reorg`
Mockup: `docs/design/sidebar-reorganization.html` (open it next to this document)

## Why

Two problems with the current per-project worktree list, on Mac and on mobile:

1. **Waiting work is in two places.** Needs you holds only rows whose agent asks a
   question or carries a notification. A finished agent turn the user has not
   opened stays in Recent (IOS-13.4). So the user scans the top pane *and* Recent
   to catch everything waiting for them.
2. **Pinned agents get pushed around.** Pinned agents are long-lived places the user
   returns to: loops that check things periodically, and specialists such as
   `crash-report` that hold context, so new work of that kind is dropped there. The
   user finds them by position. Today Needs you sits above Pinned in the same
   resizable top pane, so a growing Needs you moves Pinned down. A pinned agent that
   asks something is pulled *out* of Pinned into Needs you (IOS-13.2), so its
   familiar spot is empty.

Also, the Add worktree button floats between the resizable top pane and the
list (`SidebarWorktreeViewport` `controls:` slot), so its position changes with
the split and it does not clearly belong to anything.

**Success:** the user looks in one place (Needs you plus the tile borders right
above it) to see everything waiting, and every pinned agent is always in the same
spot.

## Goals

- Every worktree waiting for the user is visible without scanning Recent.
- Pinned agents have fixed positions that change only when the user reorders them.
- Add worktree has a fixed, obvious home.
- Mac and mobile per-project lists share the same organization.

## Non-goals

- The phone **Projects** screen (cross-project). design-mobile owns it (PR #851:
  ask deck + notices list). This design only has to keep feeding it correctly (see
  "Coordination with design-mobile").
- Fixing Codex agents that do not show as Working. That is a separate bug: pane
  busy state comes only from `claude agents --json` (`AgentLivenessParsing`), and the
  provider-progress fallback in `SidebarWorktreeContext` (`resumed`) only applies
  after an earlier stop, so a Codex first turn never counts as working. It gets its
  own test-first fix and PR. It is not part of this work.
- New git information. Rows keep today's divergence and PR data; only placement
  changes.

## Anti-goals (failure even if it technically works)

- A pinned agent that changes position on its own (because of attention, activity,
  a sleeping host, or a growing list).
- A worktree waiting for the user that appears only in Recent.
- The same worktree listed twice in one list.
- Tiles carrying many small indicators. The user rejected dots, names under tiles,
  initials, and git status on tiles as "too many things".

## The design

### Layout (per project, top to bottom)

1. Search field (unchanged).
2. **Pinned tile grid.** All pinned agents of the selected project.
3. Divider, then a **"+ New worktree"** line.
4. **Needs you**: temporary worktrees only.
5. **Working**: temporary worktrees only (as today, IOS-13.3).
6. **Recent**: temporary worktrees only.

The resizable split between the top pane and the list goes away
(replaces LAYOUT-2.212). The tile grid and the New worktree line stay fixed above
the scrolling list, as Pinned and Add worktree do today (LAYOUT-2.89), in both Mac
sidebar modes (with and without the project rail).

While the search query is non-empty, the sidebar shows today's search results
instead of tiles and sections (as today, where the pinned pane is hidden during
search).

### Pinned tiles

- **Order:** shared pinned rank (LAYOUT-2.219/2.220), default-branch checkout first
  (LAYOUT-2.103). Order changes only when the user drags a tile. Pinned rows never
  move to Needs you, Working, or Recent in the per-project list (replaces IOS-13.2).
- **Look:** a rounded square showing the worktree's drawn icon (LAYOUT-2.200/2.202),
  else its emoji, else the project icon for the default checkout (LAYOUT-2.82). A
  short **word** sits on a dark gradient band across the bottom of the tile.
- **Host:** when the worktree is on a host other than this device, a small host
  badge in the top-left corner shows the host name, truncated to fit. Local tiles
  have no badge.
- **No git status on tiles.**
- **States** (exactly these; no dots):

  | State | Tile | Source (`SidebarRowStatus`) |
  |---|---|---|
  | Waiting for you (question, notification, or unseen finished turn) | Orange border (attention color) | `.question`, `.notification`, `.whereWeAre(isUnread: true)` |
  | Working | Moving blue ring around the border | `.working` |
  | Host asleep | Whole tile faded, moon glyph top-right, no border state | row is cached (`availability == .wakeable`) |
  | Idle, seen | Icon faded (as LAYOUT-2.211) | `.whereWeAre(isUnread: false)`, `.none` |
  | Selected | Lighter tile background | current selection |

- **Hover (Mac):** a card under the tile shows the full worktree name, host name, and
  the status line the row would show (LAYOUT-2.222), including a question on its
  tint. This is how the user reads a pinned agent's question without opening it.
- **Click/tap:** opens the worktree, as clicking a row does today. Opening clears an
  unseen finished turn (existing behavior).
- **Context menu (right-click / long-press):** the same menu a pinned row has today
  (including Dismiss Request, LAYOUT-2.216, and unpin).
- **Drag:** reorders pins using the existing rank writes (LAYOUT-2.206). Dropping a
  temporary row onto the grid pins it (as LAYOUT-2.113 does for the Pinned header);
  remote-move rules stay as LAYOUT-2.111.

- **No folders.** Pinned virtual folders (LAYOUT-2.32–2.37, the `.folder` case of
  `MergedWorktreeNode` in pinned lists, REMOTE-14.3/14.6) are removed; the grid
  is flat. Delete those specs and the folder-aware reorder rules (e.g. LAYOUT-2.34);
  pinned order is the flat shared rank.
- **Overflow:** the grid wraps without limit and every tile is always visible.
  The list below gets the remaining height and scrolls. No internal grid scrolling,
  so a waiting pinned agent can never be hidden.

### "+ New worktree"

A plain line directly under the tile grid, the first line above Needs you
(like Arc's "New Tab" under its pinned tiles). It does what the Add worktree
button does today, with the same host choice and enablement rules
(`selectedProjectAddWorktreeHeader`, `canAddWorktree`). On mobile it replaces the
navigation bar `+` on the project list. Double-clicking empty list space keeps
adding a worktree on Mac.

### Needs you membership

A temporary worktree is in Needs you when its resolved status is a question, a
notification, **or an unseen finished turn** (`.whereWeAre(isUnread: true)`,
i.e. `unseenAgentStop` present and not running). This replaces IOS-13.4.

- Ordered newest first by when it asked or stopped (as today's `asked` ordering).
- Opening the worktree clears the unseen stop, and the row returns to Working or
  Recent, subject to the existing `Hold` (rows do not move while the pointer or
  finger is on the list, IOS-13.7).
- A finished turn whose recap has a `need` resolves as `.question` first (existing
  order in `SidebarRowStatus.resolve`), so it is listed once, as a question.
- Sleeping-host rows stay in Recent (IOS-13.6).
- **Dismiss clears unseen finishes too.** Dismiss Request (LAYOUT-2.216) on a row or
  tile also marks an unseen finished turn as seen, retired on the owning host so
  every client agrees (as LAYOUT-2.218 does for requests). This needs a host-side
  clear-unseen path for remote rows.

### Project attention counts

The project count (Mac rail badge, mobile per-project counts;
`SidebarActivityCounts.attentionByProject`, LAYOUT-2.210) means **everything
waiting**: the project's Needs you rows plus its waiting pinned tiles (questions,
notifications, and unseen finished turns). Today it counts only pending requests.
This type is shared with mobile and design-mobile's Projects screen, so they see
the same number (design-mobile informed).

### Rows (temporary worktrees, Mac; see "My calls" for mobile)

```
[icon] name  host                    #PR
       status line…              ↑3+ ↓1
```

- Line 1: icon, name, host name when the worktree is on a host other than this
  device (always, not only on a name clash; replaces part of LAYOUT-2.221 and
  follows LAYOUT-2.224), and the PR/MR badge right-aligned (colored by CI, PR-3.5).
- Line 2: status line (LAYOUT-2.222), with the divergence summary
  (`SidebarDivergenceGutter`) right-aligned beneath the PR badge. The status line
  truncates before the divergence. The question tint stays left-aligned.
- Replaces the trailing-on-the-name-line placement in DIVERGE-1.1.

### Mobile and iPad

- The per-project list on iPhone uses the same structure: tile grid (same visuals,
  long-press for the menu, drag to reorder), "+ New worktree" row, then Needs you,
  Working, Recent (replaces IOS-13.1 grouping).
- iPad sidebar mode follows the same structure.

## Coordination with design-mobile (PR #851)

Agreed with design-mobile's agent on 2026-11-09:

- The phone Projects screen's ask deck and notices list read
  `activitySections(...).needsYou` across projects. **Pinned rows must stay in that
  cross-project list.** So "pinned rows are not in Needs you" is a per-screen choice
  (the per-project list, which has tiles), not a change to
  `WorktreeActivitySections.make` for everyone. Suggested shape: `make` keeps pulling
  waiting pinned rows into `needsYou`, and the per-project views filter them out
  (or `make` takes a flag). Builder's call.
- Unseen finished turns without a question will appear in design-mobile's notices
  list. design-mobile wants that.
- design-mobile changes the IOS-13.9 test title in `WorktreeActivitySectionsTests.swift`
  and IOS-13.15 in `MobileAttentionPaneTests`. Expect a trivial conflict if this work
  edits those titles.

## Specs affected

To be rewritten (not deleted) per CLAUDE.md, with tests: IOS-13.1, IOS-13.2,
IOS-13.4, LAYOUT-2.212, LAYOUT-2.89, LAYOUT-2.103, LAYOUT-2.112, LAYOUT-2.115,
LAYOUT-2.221, DIVERGE-1.1, LAYOUT-2.81 (badge position), LAYOUT-2.210 (counts),
LAYOUT-2.216/2.218 (dismiss). Deleted: LAYOUT-2.32–2.37 and other pinned-folder
specs, LAYOUT-2.106 (collapse). New specs for tiles,
tile states, host badge, hover card, and the New worktree line go under LAYOUT-2.x.
The builder should grep `@spec` for "Pinned" and "Add Worktree" for any others.

## Decided by the user

- Unseen finished turns go to Needs you, on Mac and mobile.
- Pinned agents become Arc-style tiles that light up in place, not mirrored into Needs you.
- Tile label: a word on a dark caption band (not names below, not initials, not pills).
- Tile state: orange border only for "waiting", no dots.
- Host badge top-left on remote tiles.
- No git status on tiles.
- "+ New worktree" line directly under the tiles.
- Remote rows always name their host.
- Rows: PR right-aligned on the name line; divergence right-aligned beneath it.
- Phone Projects screen follows design-mobile.
- Codex Working detection is a separate fix.
- Pinned folders are dropped; the grid is flat.
- The grid grows without limit; the list below scrolls.
- Project counts mean everything waiting.
- Dismiss Request also clears an unseen finished turn, on every device.

## My calls (check these)

- **Tile word:** the first segment of the worktree name split on `-`, `_`, `/`, or
  space (`crash-report` → `crash`, `ci-watch` → `ci`). The default checkout uses its
  branch name (`main`). No per-pin custom word in this work.
- **Grid columns:** as many as fit with a minimum tile width of about 56 pt (four at
  the default Mac sidebar width, four on iPhone).
- **Moving ring:** respects Reduce Motion by showing a static blue border instead.
- **Collapsing:** the Pinned collapse control (LAYOUT-2.106) goes away; tiles are
  always shown.
- **Mac without the project rail:** every project is on screen in its own
  disclosure group, so each group contains its own tile grid, "+ New worktree"
  line, and Needs you / Working / Recent. These scroll with the list; only the
  rail mode keeps the grid fixed above the list. (A fixed stack of every
  project's grid could fill the window.)
- **Mobile rows:** keep IOS-13.11 (no divergence on mobile rows). Rows show no
  time, matching the Mac sidebar (IOS-13.12); only ask cards show one (IOS-13.8).
  The PR number stays after the name as IOS-13.12 says. Mobile rows otherwise
  change only in naming a remote host always. The "PR right / divergence beneath"
  row layout is Mac only.
  (The phone mockup's ↑/↓ is wrong on this point.)

## Left to the builder

- Exact sizes, spacing, gradient, and animation timing (match the mockup's feel).
- Whether the "pinned out of per-project Needs you" rule lives in `make` (flag) or
  in the views.
- How the hover card is implemented (popover vs. custom overlay), within the
  LAYOUT-2.130 popover crash history.
- Accessibility labels for tiles (must include name, host, and state).
