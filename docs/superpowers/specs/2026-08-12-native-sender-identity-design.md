# Native Claude delivery: sender identity and plain bodies

**Date:** 2026-08-12
**Branch:** native-codex-claude-messaging
**Status:** Approved

## Problem

Messages delivered through Claude's native peer socket all arrive labeled
"Graftty team" (`ClaudePeerDeliveryService` hardcodes `senderName`), so the
recipient cannot tell which agent — or which system source — sent them without
reading the body. Separately, each row is wrapped in a
`<graftty-peer-message agent="…">` envelope whose only jobs are sender
identification and reply addressing; on the native path both jobs are now
better served by the socket-level sender name, making the envelope noise.

## Design

### 1. Native sender name

`ClaudePeerDeliveryService` derives `senderName` from the first pending
message instead of the constant. Rows with `from.member == "system"` use
rules 3–4; all other rows use rules 1–2:

1. **Agent-authored rows** (`from.agentID` present):
   `"<teamName>/<from.member>#<from.agentID>"`, e.g.
   `graftty/main#codex-96cd535bedd7`. Both parts are already persisted on
   every row: `teamName` is the repo display name and `from.member` is the
   sanitized worktree display name. No repos snapshot is needed in the
   delivery actor. The `<from.member>#<from.agentID>` suffix is already a
   routable `graftty team send` address (`splitLiteralAgentAddress` accepts
   display-name`#`agent-id).
2. **Agent-authored rows without an agent ID**: `"<teamName>/<from.member>"`.
3. **System rows with a persisted SCM source** (see §3): the provider's
   display name — `github` → `GitHub`, `gitlab` → `GitLab`, any other raw
   value capitalized as-is (first letter uppercased).
4. **Other system rows** (`from.member == "system"`, no source — roster
   changes, member joined/left): `"Graftty team"`, unchanged.

The name derivation is a pure static function so it is directly testable.

### 2. Drop the envelope on the Claude native path only

`ClaudePeerDeliveryService` sends plain message bodies
(`TeamHookRenderer.content(message:)`) joined by one blank line, with no
`<graftty-peer-message>` wrapper and no attribute/body escaping.

The wrapper (`TeamPeerMessageFormatter.context`) remains for its other two
consumers, which have no native sender concept:

- Hook-based delivery (`TeamHookRenderer` session-start / post-tool-use)
- Codex app-server delivery (`CodexAppServerDeliveryService`)

### 3. Same-sender batch runs

A native send's `senderName` is per-frame, but today's deliverable prefix can
mix senders. `deliverOnce` trims the pending prefix to its **leading run of
rows sharing the same derived sender name** (two system rows share a `from`
endpoint but may have different sources, so the grouping key is the name
itself); the existing
`onMessageArrival` repeat-loop redelivers, so later runs go out in follow-up
frames each under their own correct name. Watermark advancement and the
too-large frame halving loop are unchanged (halving applies within the run).

### 4. Persist the SCM source on inbox rows

`TeamInboxMessage` gains an optional `source: String?` field (Codable;
old rows decode with `nil`, old readers ignore the new key — no migration).
`TeamEventDispatcher.dispatchRoutableEvent` sets it from `attrs["provider"]`,
which the PR poller already stamps (`"github"` / `"gitlab"`) on every
pr/ci/merge transition event. Roster and membership notices carry no provider
and leave it nil. The `member == "system"` convention on the from-endpoint is
untouched — renderers that key on it keep working.

### 5. Reply-guidance documentation

Native messages no longer show a wrapper with an `agent="…"` reply address,
so the guidance in:

- `Sources/GrafttyKit/AgentPlugins/claude/plugins/graftty-team/skills/graftty-team/SKILL.md`
- `Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift`

is updated to cover both delivery forms: wrapper-form messages keep the
"reply to the `agent` attribute" rule; natively-delivered messages identify
the sender as `<project>/<worktree>#<agent-id>` and the reply address is that
name **without the `<project>/` prefix** (or the exact canonical address from
`graftty team list --json`). The Codex plugin SKILL.md is untouched — Codex
delivery keeps the wrapper.

## Spec changes (EARS / @spec)

- **Amend AGENT-6.17**: scope the `<graftty-peer-message>` rendering clause
  to wrapper-path (hook and Codex app-server) delivery.
- **New AGENT-6.18** (sender identity): When the application delivers inbox
  rows through Claude's native peer socket, it shall identify the sender as
  `<team>/<worktree-member>#<agent-id>` for agent-authored rows (omitting the
  `#` suffix when no agent ID was persisted), as the originating SCM's display
  name for system rows with a persisted source, and as "Graftty team" for
  other system rows.
- **New AGENT-6.19** (plain same-sender frames): When pending deliverable
  rows are sent through Claude's native peer socket, the application shall
  send only the leading run of rows sharing one derived sender name per frame,
  with bodies joined by a blank line and no per-message envelope, leaving
  later runs for subsequent frames.
- **New AGENT-6.20** (source persistence): When the dispatcher writes a
  routable-event system row that carries a provider attribute, the
  application shall persist that provider on the inbox row. (Dual
  enforcement: structural `@spec` doc comment on `TeamInboxMessage.source`.)

## Testing

- `ClaudePeerDeliveryServiceTests`: sender-name derivation cases (agent row,
  no-agent-ID row, GitHub system row, roster system row), plain-body frame
  content, same-sender run trimming with follow-up frame delivery, watermark
  behavior unchanged.
- `TeamEventDispatcherTests`: routable event persists `source`; membership
  events leave it nil.
- `TeamInstructionsRendererTests`: updated guidance text.
- Existing wrapper tests (hook renderer, Codex delivery, envelope escaping)
  continue to pass unchanged.

## Out of scope

- Codex app-server delivery naming (no native sender concept).
- Making `<project>/<worktree>#<agent-id>` itself a routable address.
- Persisting full event attrs on inbox rows.
