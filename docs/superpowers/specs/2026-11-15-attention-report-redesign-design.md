# Context updates and attention requests

The user approved this design on 2026-11-15. The implementation is in this
worktree. Verification and known baseline failures are recorded below.

## Why reports need separate lifetimes

The report contract makes an agent reconstruct information the host already
has. A title, purpose, emoji, and accumulated decisions rarely change, but
the reporting instructions request them every turn. This adds writing work
and creates opportunities for unchanged information to drift.

The two consumers need different things. Context explains the work when
someone returns. Needs attention identifies a request or result that deserves
their attention. Routine progress can improve Context without creating an
attention item.

## Agreed direction

- Agents submit changed information. The host retains context and assembles
  complete snapshots for Mac and GrafttyMobile.
- Purpose and identity persist until changed.
- A new current-state group replaces the previous group. Its next step is
  optional, so a finished task does not need a fictitious next step.
- The decisions list changes explicitly. Replace the list only when it
  changes. Defer individual decision IDs and edit operations.
- History entries record meaningful changes independently of current state.
- Questions belong to a specific turn and never carry forward implicitly.
- Routine completions remain activity. Requests and notable results can
  appear in Needs attention.
- A turn can acknowledge that nothing changed without inventing progress.

Separate lifetimes do not require separate commands. One submission can
update context and request attention together.

## Update contract

Use `graftty context update --stdin` to submit optional groups through the
private file handoff. `graftty context show --json` reads the retained brief
and verifies that the owning live host supports this contract.

```json
{
	"purpose": {
		"title": "Crash investigation",
		"context": "A startup crash prevents some users from opening their workspace."
	},
	"now": {
		"summary": "The regression test passes with the fix.",
		"next": "Run the full suite."
	},
	"decisions": ["Keep the saved workspace format compatible."],
	"historyEntry": {
		"headline": "The crash comes from a missing pane",
		"detail": "A restored layout can reference a pane that no longer exists."
	}
}
```

Each group has explicit update rules:

| Group | When supplied | When omitted |
| --- | --- | --- |
| `purpose` | Replace title and motivation together | Retain both |
| Presentation fields | Assign initial emoji or supply a drawing for a purpose change or requested redraw | Retain identity |
| `now` | Replace summary and optional next step together | Retain current state |
| `decisions` | Replace the list; `[]` clears it | Retain the list |
| `historyEntry` | Append one meaningful event | Append nothing |
| `attention` | Create an explicit request or notice for this turn | Create nothing |

Presentation fields are `emoji`, `emojiAlternatives`, `icon`, and
`iconDescription`. They are optional top-level fields. Use complete
replacement within each supplied context group. Avoid recursive merge
rules that make agents guess which old fields remain. Omission is sufficient
for unchanged groups. Do not introduce a separate patch language.

A first update supplies purpose and current state. Identity can follow once
the agent understands the task. Later updates can contain only `now` or
another changed group. A changed purpose does not silently delete decisions
or history. The agent replaces decisions if the old list no longer applies.

Allow `now.next` to be absent. For a cleared group, use an explicit operation
only where there is a real use case. Do not accept blank strings as deletion.

## Attention kinds

An ask needs an answer:

```json
{
	"attention": {
		"kind": "ask",
		"question": "Ship now or wait for CI?",
		"background": "The regression test passed. The full suite is still running.",
		"options": [
			{"label": "Wait", "cost": "About 15 minutes", "suggested": true},
			{"label": "Ship now", "cost": "Full-suite result unknown"}
		]
	}
}
```

A notice has no answer to send:

```json
{
	"attention": {
		"kind": "notice",
		"message": "The crash fix is ready to review."
	}
}
```

Reserve notices for an outcome worth reviewing, an important failure, or a
handoff. Examples include a reviewable fix and a deployment failure that
requires the user's awareness. Routine test results and incremental progress
update `now` instead. The agent explicitly chooses a notice. The host does
not infer importance from wording or from a process becoming idle.

The Context panel and attention views render asks with their answer controls.
They render notices with acknowledgement and navigation controls. A notice
has no reply field or options. Both can use the retained worktree context.
An ask also carries enough immediate background to make its choices clear.

## Lifecycle and recovery rules

An authored ask becomes actionable when its owning turn stops. The host
assigns a request identity tied to the session and turn. An answer targets
that exact request. Changed or retired requests reject stale answers.

On successful answer delivery, the view marks the ask as sent and disables
duplicate sends. Provider progress retires the ask. Dismissal or explicit
withdrawal also retires it. Resuming the owning turn without an answer retires
the ask too, matching the existing turn-scoped model. The agent must ask
again if the question still matters. Questions that survive across turns are
outside this first design.

Notices remain unread until acknowledged. Provider progress does not erase
a notice, because an agent can keep working after producing a reviewable
result. Updating context alone does not acknowledge or reactivate anything.
An omitted `attention` never copies an older request into the new turn.

Provider permission prompts continue to use provider-owned attention.
They retain their existing terminal-only answer path.

The CLI and host own session identity, timestamps, and retry receipts. Reusing
a receipt cannot append history twice or create a second attention item.
Freshness is tracked per replaceable group. A later progress update must not
cause a delayed purpose update to be dropped merely because the worktree's
global update time advanced.

The primary agent owns the worktree's durable context. Additional agents'
completion records must not overwrite its purpose and current state.

The read command returns an atomic snapshot stamped with the owning host
process ID and start time. An exited or replaced host cannot advertise
support through a stale file. Neither reads nor updates need the control socket. An explicit no-change acknowledgement
satisfies the turn's reporting check without changing the content timestamp.
The stop hook still knows whether this turn submitted anything, but it does
not demand fresh prose.

## Implementation implications

`WorktreeBrief.update` already retains omitted context and decisions.
`AttentionRecap` still requires title, completed, and next. The CLI also
requires emoji. Reporting instructions repeat more fields than storage needs.

The Context panel reads the accumulated brief, while
`SidebarAttentionCardContent` reads a stopped turn's raw recap. All consumers
need host-composed snapshots before sparse authoring becomes the default.
Client snapshots remain complete even when an agent sends a small update.

The existing unseen-stop signal contributes to `hasAttention`. Separate that
activity signal from explicit attention throughout sidebar badges, navigation,
desktop notifications, and mobile views. Updating only the panel would leave
routine stops requesting attention elsewhere.

Keep decoding old persisted reports and serving complete snapshots to older
clients. Translate legacy recaps at ingestion. Treat an old report's `need`
as an ask, and retain ordinary completion as activity. Never turn a routine
legacy stop into a new notice merely to preserve the old attention behavior.
Require the live host snapshot before sending the new shape. Older hosts
continue to accept the legacy report command.

## Suggested implementation order

1. Define the update groups and their tests. Cover omission, replacement,
   absent next steps, explicit clearing, retries, and per-group freshness.
2. Assemble complete snapshots for all consumers. Preserve legacy decoding.
3. Separate routine activity, asks, and notices in shared models. Cover both
   platforms, resume, acknowledgement, stale replies, and restart recovery.
4. Add update and read commands, then shorten skills and hook instructions.
   Show retained purpose at session start and accept no-change turns.

Follow the repository's behavioral `@spec` and RED/GREEN process when
implementing. This document records design discussion. It does not replace
the generated requirement inventory in `SPECS.md`.

## Verification

- The affected suites and all protocol tests passed with 863 Swift Testing
  tests across five targets. The final context layout also received a focused
  check after placing notices before questions.
- GrafttyMobile built for the iOS simulator.
- Spec generation, stale-spec checking, Linux test membership, and whitespace
  checks passed.
- The complete SwiftPM suite encountered timing failures in unrelated port,
  remote-feed, and UI tests and stopped making progress. That run was stopped.
- The existing `contextUsesOpaqueThemeSurface` test failed with the same
  14 color assertions against both the changed panel and the original panel
  from `HEAD`. The affected-suite run excludes this confirmed baseline failure.

The new commands require a running host built from this change. Existing
installed apps continue to use the legacy report contract until updated.
