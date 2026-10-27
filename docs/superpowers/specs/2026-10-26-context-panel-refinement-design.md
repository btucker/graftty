# Context panel refinement

## Problem

The worktree Context panel (Mac side panel, mobile drawer) is hard to scan:

- Runs of peer messages render as identical cards ("refactoring-simplification"
  five times) whose content is hidden behind a chevron, and every row carries a
  full "Oct 24, 2026 at 1:35 AM CDT" stamp.
- The current brief sits at the top and the latest history at the bottom of a
  single scroll, so a returning reader must scroll the whole history to connect
  "where we are" with "what just happened".

## Decisions (approved 2026-10-26)

Layout A (pinned brief, chat-style timeline), with the conciseness layer, and
layout B's collapsing header on mobile only. Summaries apply to agent-to-agent
messages only; human input always renders verbatim.

## Design

### Conciseness layer (shared Mac + mobile)

Projection lives in `WorktreeTimeline.rows(showAll:)` (GrafttyProtocol, so it is
covered on Linux too). `Row` gains a `kind`:

- `.event`: one event.
- `.folded`: the existing CONTEXT-14 fold of older legacy checkpoints
  (`isGroup` keeps meaning this).
- `.peerMessages`: consecutive `agentMessage` events from the same sender
  (`sourceWorktreePath`, else `title`). Exact consecutive duplicates collapse
  into one entry with a repeat count.
- `.inputs`: consecutive human `user` events no more than 10 minutes apart.

Folding and merging both preserve chronological order; flattening rows yields
`events` unchanged.

The view replaces per-row full timestamps with day separators ("Today",
"Yesterday", or a medium date) and a short local time per row. A peer card
shows the sender once with a message count. When collapsed, it shows the last
two messages and an "N earlier" control. Each message is one line, and tapping
the line shows the full original text.

### Peer message gists

`PeerMessageGist` (GrafttyCommandUI) produces the one-line text for a peer
message:

- If the text already fits one line (no newline, at most 80 characters), it is
  shown verbatim and no model runs.
- Otherwise, when Apple Intelligence is available (`FoundationModels`,
  `SystemLanguageModel.default.availability == .available`, macOS 26 / iOS 26),
  the gist is generated on the displaying device and marked with a sparkle so
  that it reads as machine-written.
- In every other case (older OS, Apple Intelligence off, generation failure),
  the gist is the first sentence or line of the original text, truncated, with
  no sparkle.

Gists are cached in memory by message text and are generated at most once per
text per process. Human input never goes through this path.

### Layout (WorktreeContextPanel)

- The brief (title, purpose, where we are, decisions, waiting-for-you, up next)
  is pinned above the timeline. Its height is capped at roughly half the
  panel, and it scrolls internally when its content exceeds that.
- Only the timeline scrolls. It is oldest-first and opens anchored to the
  latest event. A new event scrolls the timeline only while the reader is
  already at the bottom. Otherwise a "Jump to latest" pill appears. This rule
  lives in a pure `TimelineFollow` state value so it can be tested.
- Mobile (compact) only: while the reader is scrolled away from the latest
  event, the pinned brief collapses to a one-line bar with the title and either
  the next step or the pending question. Tapping the bar expands it again.
  Returning to the bottom restores the full brief.
- The sidebar report (`SidebarWorktreeReport`, compact brief) is unchanged.

### Jump to terminal and scrollback map (PR 2, stacked)

Clicking a timeline message (human input or peer message) scrolls that
worktree's agent terminal to where the message appears in scrollback. A
top-right terminal overlay (mockup option C) shows a strip covering the
whole scrollback. Orange marks show human inputs, blue marks show peer
messages, and a box shows the viewport. Scrubbing the strip scrolls the
terminal and shows the nearest message in a live label. The label is the
peer gist or the verbatim human text.

Mechanism: a locator scans scrollback rows (`ghostty_surface_read_text`
with SCREEN points) for each message's normalized text. Resize redraws
duplicate rows, so the locator chooses among duplicate matches, then
calls `scroll_to_row:N`. `UserInput` does not record its pane. Until it
does, use the worktree's last agent stop pane (`attentionPaneRoute`).

Fullscreen agent TUIs are unsupported: their transcript lives in the
alternate screen and never reaches scrollback. Graftty's wrappers turn
fullscreen off for both providers: `CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1`
for Claude and `--no-alt-screen` for Codex.

## Delivery

1. PR 1, this branch: the conciseness layer, gists, pinned layout, and the
   mobile collapsing header.
2. PR 2, stacked on PR 1: the wrapper alternate-screen opt-out, the
   locator, the overlay, and timeline click-to-scroll.
