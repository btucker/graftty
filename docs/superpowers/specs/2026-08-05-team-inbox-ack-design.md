# Team Inbox Consuming Reads

## Problem

`graftty team inbox` historically behaved like a diagnostic query. An agent
could display a durable message but had no supported way to record that the
message was handled, so some agents edited cursor files directly. That exposes
an internal storage model, is race-prone, and can make delivery skip or replay
rows.

The natural user model is simpler: reading your own inbox normally marks the
rows you actually received as read. Peeking and history inspection should be
explicit exceptions.

## Goals

- Make an unscoped `graftty team inbox` a consuming read for the calling
  worktree.
- Display unread rows oldest-first and advance only through the last displayed
  row.
- Advance only after stdout accepts the complete output.
- Provide `--keep-unread` for peeking, with legacy `--unread` as an alias.
- Keep `--history` and diagnostic selectors nonmutating.
- Keep multi-page `--all` reads bounded to a stable snapshot so later arrivals
  remain unread.
- Preserve the shared worktree watermark as the cross-session authority and
  make existing hook sessions honor a later watermark.
- Tell agents in the built-in session prompt never to edit Graftty state files.

## Non-goals

- Per-message read flags or arbitrary holes in the ordered inbox prefix.
- Deleting, compacting, or rewriting `messages.jsonl`.
- Allowing one worktree to consume another worktree's inbox.
- Exposing a public acknowledgement or cursor-mutation command.
- Hiding delivery, output, or advancement failures.

## CLI behavior

```sh
graftty team inbox                 # consume the oldest unread page
graftty team inbox --all           # consume the current unread snapshot
graftty team inbox --keep-unread   # peek at unread rows
graftty team inbox --unread        # compatibility alias for --keep-unread
graftty team inbox --history       # inspect prior rows
```

The default command resolves the current worktree, fetches unread rows after
its shared watermark, writes them to stdout, and then advances through the last
displayed row. A default page is bounded, so unread rows beyond that page remain
for the next invocation.

`--all` follows forward pagination through a fixed upper snapshot. The server
sets that upper bound on the first page. Follow-up requests carry both the last
displayed row and the snapshot bound. Rows appended after the first response
are excluded and remain unread.

`--keep-unread` and `--unread` show the same unread view without advancement.
`--history` preserves the prior newest-first diagnostic history surface.
Supplying `--worktree`, `--repo`, or `--member` also implies a peek: diagnostic
scope must never consume a target inbox. Peek and diagnostic reads explain on
stderr that a consuming read must be run from the target worktree. Stdout stays
clean for text and JSON consumers.

There is no public `team ack` command. Read state is an outcome of successful
delivery, not a separate repair action.

## Output and failure boundary

The CLI assembles the complete text or JSON document before writing it. It does
not request advancement until the output write succeeds.

- If fetching or output fails, the watermark is unchanged.
- If output succeeds but advancement fails, the CLI exits nonzero and explains
  that the displayed rows remain unread and that the caller should rerun
  `graftty team inbox`.
- Recovery text explicitly says not to edit Graftty state files.
- An empty result does not send an advancement request.

This boundary can duplicate a displayed row if the process dies between output
and advancement. That is preferable to silently losing a row that never
reached stdout.

## Store and wire behavior

The inbox response carries independent pagination fields:

- `next_before_id` for nonmutating history pagination;
- `next_after_id` for oldest-first unread pagination; and
- `snapshot_through_id` as the fixed unread upper bound.

Unread requests also carry `forward_pagination: true`. The app rejects an
unread request without that capability marker so an older CLI cannot ignore
the new forward cursor and silently truncate an `--all` read. The initial
unread log snapshot and its shared watermark are selected under the same
worktree-watermark lock, preventing a concurrently committed watermark from
pointing beyond the snapshot being paged. In the opposite version skew, the
CLI rejects a nonempty unread response without `snapshot_through_id` before
output or advancement, so an older app cannot supply backward-paged rows to a
new consuming client.

After successful output, the CLI sends an internal request containing the
calling worktree and the exact last displayed message ID. The app resolves the
caller to a team member, then advances under the existing inter-process
worktree-watermark lock. The store validates that the target exists and is
addressed to that worktree. Advancing to an ID at or behind the current
watermark is an idempotent success. Other worktrees and all session cursors are
unchanged.

The internal operation deliberately has no “all” form and no optional target.
The display path chooses the exact eligible boundary; the mutation path can
only commit that boundary.

## Existing sessions and automatic delivery

The shared worktree watermark remains the cross-session source of truth.
Session-start hook delivery derives its effective read position from the later
known append-order anchor of the session cursor and worktree watermark. This
prevents an existing session from replaying rows consumed elsewhere. If a
persisted anchor is absent from the retained log, the reader preserves the
conservative replay fallback rather than guessing its former order.

Every automatic surface should advance at its successful-delivery boundary.
Codex app-server and hook delivery already do so. Claude post-tool rendering
must render before committing advancement. The watcher keeps its locked claim
as the cross-process duplicate-prevention boundary for a successful wake.

## Agent instructions

The built-in session prompt explains that:

- `graftty team inbox` reads the oldest unread page and marks displayed rows
  read after successful output;
- `--keep-unread`/`--unread`, `--history`, and diagnostic selectors do not mark
  rows read; and
- agents must never edit Graftty state files to change delivery positions.

## Requirements

- **TEAM-4.8:** When `graftty team inbox` displays unread messages for the
  calling worktree, the application shall advance that worktree's shared
  delivery watermark through the last displayed row only after stdout accepts
  the complete output.
- **TEAM-4.9:** When a team inbox read uses `--keep-unread`, its `--unread`
  alias, or a diagnostic selector, the application shall leave delivery state
  unchanged and explain on stderr how the target worktree can perform a
  consuming read.
- **TEAM-4.10:** When an unread team inbox read spans pages, the application
  shall return the oldest rows first from a fixed upper snapshot so only
  displayed rows are eligible for advancement and later arrivals remain
  unread.
- **TEAM-4.11:** When a nonempty unread team inbox response lacks the
  fixed-snapshot capability, the CLI shall reject it before output or
  advancement rather than risk misordered or silently truncated delivery.
- **TEAM-11.9:** When an existing session cursor trails its worktree's shared
  delivery watermark, hook delivery shall use the later watermark as its
  effective read position so rows successfully read by another delivery
  surface are not redelivered.

## TDD and verification

1. Promote the requirements into failing Swift Testing titles.
2. Cover CLI mode parsing, output-before-advance ordering, failure behavior,
   diagnostic guidance, exact store advancement, and fixed-snapshot paging.
3. Implement the wire, store, handler, CLI, prompt, and documentation changes.
4. Run `scripts/swiftpm test` and regenerate `SPECS.md` with
   `scripts/generate-specs.py`.
5. Run `/code-review xhigh --fix` before handing the branch back.

## Design concerns

- The protocol still permits a caller that can write directly to the local
  socket to send the internal advance request. It is scoped and validated by
  caller worktree, but it is not a security boundary.
- A crash after stdout and before advancement causes replay by design.
- The watcher advances at claim time to coordinate concurrent watcher
  processes. If waking the runtime fails after that claim, its semantics differ
  from the stricter CLI output boundary and deserve a future reservation/commit
  design if observed message loss becomes a practical problem.
