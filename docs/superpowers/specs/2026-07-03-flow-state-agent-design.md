# Flow State Agent Design

## Context

Graftty already treats multi-worktree repositories as agent teams. Claude and
Codex agents can register presence, receive inbox messages, react to PR/CI
events, and coordinate through `graftty team` and `graftty pane` commands.
Recent work also added attention-oriented navigation and richer worktree/pane
overviews.

The missing layer is cross-project focus. When a user has many worktrees across
many projects, the hard problem is not seeing that something needs attention.
The hard problem is deciding whether switching to it is worth the mental reload
cost. Flow State is an app-level coordinator whose job is to keep the human in a
productive flow state by preserving context, clustering nearby work, and
surfacing only the interruptions that justify a switch.

The user-facing name is **Flow State**. Internal and CLI identifiers may use
`flow` where brevity matters.

## Goals

- Add a persistent top-level **Flow State** item at the top of the sidebar.
- Run a persistent Claude or Codex **Flow State agent** with a dedicated,
  editable system prompt.
- Let the Flow State agent use the `graftty` CLI directly to inspect state,
  ask per-worktree agents for status, maintain focus notes, and coordinate soft
  follow-up.
- Optimize recommendations around human context-switching cost, not raw event
  urgency.
- Use worktrees as the primary unit of work; panes and agent sessions are
  signals that feed worktree state.
- Keep the UI sparse and opinionated: one primary recommendation, nearby
  same-context opportunities, held interruptions, and concise resume cards.
- Require confirmation or explicit opt-in for disruptive actions.

## Non-Goals

- Flow State is not a generic project-management dashboard.
- Flow State is not another repo-scoped team member.
- Flow State should not require the user to monitor another transcript during
  normal use.
- Flow State should not directly type into arbitrary panes, run project
  commands, close panes, or delete worktrees without explicit authorization.
- Flow State should not try to infer durable cross-worktree "tasks" as a first
  version. Topic labels and clusters are enough.

## Product Shape

The sidebar gets a top-level **Flow State** row above repositories and
worktrees. It is visually distinct from worktree rows, but it participates in
the same navigation model: selecting it opens the Flow State view in the main
area.

The row should remain calm. It may show a compact status such as `Stay here`,
`2 held`, `Needs setup`, or `Unavailable`, but it should not badge every event.
The row earns attention only when Flow State believes the user should consider
changing course.

The Flow State view is an opinionated focus queue:

- **Primary recommendation**: the one best current focus move, including whether
  to stay in the current context or switch worktrees.
- **Why this preserves flow**: a short explanation that names context cost.
- **Same-context opportunities**: nearby worktrees worth handling while the
  current repo, domain, or problem shape is warm.
- **Held interruptions**: attention items Flow State is intentionally deferring
  because the switch is not worth it yet.
- **Resume cards**: compact state packets for worktrees that may need re-entry.
- **Recent Flow State activity**: status requests, skipped refreshes, errors,
  and published recommendations.
- **Confirmable proposed actions**: side effects that need human approval.

The view should avoid stress-dashboard framing. It should not lead with "7
things need attention." A good recommendation looks like: "Stay in graftty for
now; two nearby worktrees need short decisions. Defer billing-api because it
has high reload cost and no urgent blocker."

## Runtime Architecture

Flow State is backed by one persistent, app-managed agent pane/session. The
agent runtime is selected in Settings: Claude or Codex.

The Flow State agent is special:

- It is global, not repo-scoped.
- It is launched with a dedicated Flow State system prompt.
- It can use the `graftty` CLI directly.
- It receives or fetches compact cross-worktree context.
- It can autonomously ask per-worktree agents for concise status when useful.
- It publishes structured recommendations that graftty can render in the Flow
  State view.

The pane exists for real agent execution, but it is not the primary product
surface. The normal surface is the sidebar row and Flow State view. The user
should still have an explicit way to open the underlying Flow State pane for
debugging or direct conversation.

Lifecycle:

1. When Flow State is enabled, graftty ensures one persistent Flow State
   agent pane/session exists.
2. The pane runs outside any repo worktree or in a reserved app-managed
   workspace.
3. graftty launches the selected runtime with the editable Flow State system
   prompt.
4. The agent uses `graftty flow`, `graftty team`, and read-oriented
   `graftty pane` commands to observe and coordinate.
5. The agent periodically or eventfully publishes structured recommendations.
6. graftty stores the latest valid recommendation and renders it.
7. If the agent exits, graftty marks Flow State unavailable and offers restart.
8. If the runtime or prompt changes, graftty restarts the Flow State agent after
   confirmation.

## Settings

Settings should add a **Flow State Agent** section:

- Enable Flow State.
- Runtime: Claude or Codex.
- Editable system prompt.
- Reset prompt to default.
- Start, stop, and restart Flow State agent.
- Rate-limit controls or defaults for autonomous status requests.
- Permission mode, initially conservative.

The default prompt should be owned by graftty and should tell the agent to:

- Preserve the human's flow state across active worktrees.
- Prefer staying near the current repo, domain, or problem shape unless a
  higher-value interruption justifies switching.
- Use `graftty` CLI commands for observation and soft coordination.
- Ask worktree agents for summaries only when stale, attention-active, or likely
  relevant soon.
- Keep recommendations concise and structured.
- Label uncertainty instead of inventing crisp next actions.
- Avoid direct pane mutation unless explicitly authorized.
- Respect rate limits and quiet periods.

## CLI Contract

The `graftty` CLI is the Flow State agent's main action surface. Existing
commands remain important:

```sh
graftty team list
graftty team send <member> --stdin
graftty team inbox --json
graftty pane list <worktree>
graftty pane show <worktree>:<pane>
```

A new `flow` namespace should provide cross-repo state and Flow State-specific
memory rather than duplicate all team and pane commands.

Initial command shape:

```sh
graftty flow status
graftty flow context
graftty flow recommend
graftty flow snooze <worktree>
graftty flow note <worktree> --stdin
graftty flow summary <worktree> --stdin
graftty flow publish --stdin
```

Responsibilities:

- `flow status`: summarize whether Flow State is enabled, running, stale, or
  unavailable.
- `flow context`: return a compact cross-worktree context packet.
- `flow recommend`: return the latest structured recommendation, if any.
- `flow snooze`: defer a worktree or interruption from future recommendations.
- `flow note`: store Flow State memory or an agent-authored note for a
  worktree.
- `flow summary`: store a per-worktree status summary with explicit next-action
  and needs-human fields. This is the preferred write path for worktree agents;
  `flow note` remains free-form memory for the Flow State agent.
- `flow publish`: accept structured recommendation output from the Flow State
  agent.

`flow context` is critical. If the Flow State agent has to scrape every pane
transcript to understand the world, the feature will become slow, noisy, and
expensive. The context packet should include compact signals, summaries,
timestamps, and reload-cost hints.

`flow publish` should accept a strict, versioned JSON envelope from day one:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-03T19:00:00Z",
  "primary": {
    "worktreeRef": "repo-name:worktree-name",
    "intent": "stay",
    "title": "Stay in graftty",
    "reason": "Current repo has nearby decisions; switching now has high reload cost.",
    "confidence": "medium"
  },
  "sameContext": [],
  "heldInterruptions": [],
  "resumeCards": [],
  "proposedActions": []
}
```

Version 1 requirements:

- `schemaVersion` is required and must be `1`.
- `generatedAt` is required and must parse as an absolute timestamp.
- `primary` is required. `worktreeRef` may be omitted only when the primary
  recommendation is setup/error-oriented rather than worktree-oriented.
- `primary.title`, `primary.reason`, and `primary.confidence` are required.
- `primary.intent` is one of `stay`, `switch`, `setup`, `wait`, or `none`.
- `primary.confidence` is one of `low`, `medium`, or `high`.
- Lists default to empty arrays when omitted by the agent, but graftty stores
  them normalized as arrays.
- Unknown enum values make the publish invalid; graftty keeps the last valid
  recommendation and records a concise Flow State activity error.
- Unknown object fields are preserved in storage for forward compatibility but
  ignored by v1 UI rendering.

`proposedActions` should also use a small versioned shape:

```json
{
  "id": "ask-drag-files-status",
  "kind": "team_status_request",
  "target": "drag-files",
  "body": "Please reply with status, blocker, next action, and whether you need the human.",
  "requiresConfirmation": false
}
```

For v1, `kind` is one of `team_status_request`, `team_message`,
`focus_worktree`, `restart_agent`, or `pane_command`. graftty may execute only
actions that are both supported by policy and either do not require
confirmation or have been confirmed by the user.

`proposedActions` requirements:

- `id`, `kind`, and `requiresConfirmation` are required.
- `requiresConfirmation` is advisory output from the agent. graftty must derive
  the effective confirmation requirement from its own permission policy and may
  only make the action stricter, never looser.
- `team_status_request` requires `target` and `body`; it is executable without
  confirmation only when the body matches the fixed status-gathering template
  constraints in the permissions section.
- `team_message` requires `target` and `body`; it always requires confirmation
  unless it also satisfies the `team_status_request` constraints.
- `focus_worktree` requires `target` and always requires confirmation.
- `restart_agent` requires `target` and always requires confirmation.
- `pane_command` requires `target` and `body`; it is explicit opt-in only and
  never executable solely from `flow publish`.
- Unknown action kinds invalidate the publish.

The three recommendation lists should use minimal v1 item schemas so storage
and rendering stay deterministic.

`sameContext` item:

```json
{
  "worktreeRef": "graftty:review-fixes",
  "title": "Handle adjacent review fixes",
  "reason": "Same repo and test context as current work.",
  "estimatedEffort": "short",
  "confidence": "medium"
}
```

`heldInterruptions` item:

```json
{
  "worktreeRef": "billing-api:ci-fix",
  "title": "CI failed",
  "reason": "Important, but switching repos now has high reload cost.",
  "holdUntil": "next_focus_break",
  "urgency": "medium"
}
```

`resumeCards` item:

```json
{
  "worktreeRef": "mobile:pairing-polish",
  "title": "Pairing polish",
  "summary": "Agent is waiting on visual QA for the pairing screen.",
  "nextAction": "Open the worktree and review the latest screenshot.",
  "stale": false
}
```

List item requirements:

- `worktreeRef`, `title`, and `reason` are required for `sameContext` and
  `heldInterruptions`.
- `worktreeRef`, `title`, `summary`, and `nextAction` are required for
  `resumeCards`.
- `estimatedEffort` is one of `quick`, `short`, `medium`, `deep`, or `unknown`.
- `urgency` is one of `low`, `medium`, `high`, or `critical`.
- `holdUntil` is one of `next_focus_break`, `manual_refresh`, an absolute
  timestamp, or omitted.
- `stale` defaults to `false` when omitted.
- Unknown enum values invalidate the publish; unknown object fields are
  preserved for forward compatibility but ignored by v1 UI rendering.

## Worktree Snapshot

Worktrees are the primary recommendation unit. Pane and agent details feed into
the worktree snapshot.

Each `FlowWorktreeSnapshot` should include:

- repo path/name
- worktree name/path/branch
- selected and focused status
- recent user activity timestamp
- recent agent activity timestamp
- attention state and source
- agent runtime, presence, busy, and waiting state
- PR, CI, and merge status when available
- dirty and divergence stats
- latest agent-authored summary
- latest known next action
- explicit "needs human" flag when available
- last Flow State message time
- snooze/defer metadata
- inferred topic labels from repo, branch, PR, and summary

Unknown state must remain explicit. If a worktree has no recent summary and
observable signals are ambiguous, Flow State should label it as unclear with
high reload cost instead of fabricating a next action.

## Scoring Model

Flow State optimizes for useful flow-preserving focus moves. The model can be
heuristic at first, but the ingredients should be visible enough to debug.

Useful scoring hints:

- `flowAffinity`: closeness to the current human context.
- `resumptionCost`: estimated cost to reload the worktree.
- `unlockValue`: how much a small human action would unblock progress.
- `riskUrgency`: CI failure, merge conflict, review feedback, stale PR, or
  externally visible risk.
- `completionMomentum`: likelihood that the worktree is close to done.
- `interruptPenalty`: cost of breaking the current focus block.

The system should bias toward `flowAffinity` and low `resumptionCost`. Urgency
can override that bias when the payoff is clear, but urgency should not be the
default sort key.

The structured recommendation follows the `flow publish` schema. A minimal
recommendation may look like:

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-07-03T19:00:00Z",
  "primary": {
    "worktreeRef": "graftty:multi-project-assistant",
    "intent": "stay",
    "title": "Stay in graftty",
    "confidence": "medium",
    "reason": "Current repo has two nearby decisions; switching now has high reload cost."
  },
  "sameContext": [],
  "heldInterruptions": [],
  "resumeCards": [],
  "proposedActions": []
}
```

## Permissions And Guardrails

The Flow State agent can invoke `graftty` CLI commands directly, so guardrails
should exist in both the prompt and the CLI capability design.

Autonomous:

- Read global state.
- Inspect team lists and inboxes.
- Ask per-worktree agents for concise status using a fixed status-request
  template.
- Request next-action summaries using a fixed summary-request template.
- Maintain Flow State notes and snoozes.
- Publish recommendations.

Autonomous but rate-limited:

- Nudge stale agents for updates.
- Ask attention-active agents whether they are blocked.
- Ask "what do you need from the human?" when a worktree is likely to be
  re-entered soon.

Autonomous messages are limited to status-gathering templates. A message is
autonomous only when all of these are true:

- It is addressed to a single worktree agent, not a broadcast.
- It asks for status, blocker, next action, tests/PR state, or whether the
  human is needed.
- It does not instruct the recipient to change files, run commands, merge,
  rebase, restart, close panes, contact external systems, or alter priorities.
- It includes a Flow State marker so recipients and logs can identify it as a
  status request.
- It respects the per-worktree rate limit.

Any free-form message that falls outside those constraints is a proposed action
and requires confirmation before the Flow State agent sends it.

Confirmation required:

- Broad broadcasts.
- Switching the human's active worktree.
- Sending potentially disruptive instructions.
- Restarting agent panes.

Out of scope or explicit opt-in:

- Direct `graftty pane send` into arbitrary panes.
- Running project commands.
- Closing panes.
- Deleting or mutating worktrees.

Direct pane mutation commands should either be unavailable to Flow State by
default or require a graftty-mediated confirmation token.

## Error Handling

- Agent not running: show setup or restart state.
- Runtime missing: show an actionable install/configuration message.
- Invalid structured output: keep the last valid recommendation and show that
  the agent output needs attention.
- Stale summaries: label them stale and avoid over-ranking them.
- CLI errors: surface concise errors in Flow State activity.
- Excessive autonomous messaging: enforce rate limits and record skipped
  refreshes.
- User ignores or rejects recommendations: treat that as feedback and reduce
  similar future nudges.

The first refresh policy should be simple and conservative:

- Publish a recommendation when the Flow State view opens.
- Publish when the selected worktree changes and remains selected for at least
  30 seconds.
- Publish when a worktree receives attention and the current focus block has
  been stable for at least 5 minutes.
- Publish on a background interval no more often than every 10 minutes while
  Flow State is enabled.
- Do not ask the same worktree agent for status more than once every 20 minutes
  unless the user explicitly requests a refresh.

## Testing Strategy

- Unit tests for `FlowWorktreeSnapshot` construction.
- Unit tests for scoring hints: flow affinity, resumption cost, unlock/risk
  signals, and interrupt penalty.
- CLI tests for `graftty flow context`, `status`, `note`, `snooze`, and
  `summary`, and `publish`.
- Prompt/settings tests for default prompt registration, prompt editing, and
  reset behavior.
- Lifecycle tests for start, stop, restart, missing runtime, and runtime
  switching.
- Permission tests proving Flow State cannot directly mutate panes without
  explicit opt-in or confirmation.
- UI tests for sidebar placement, calm status rendering, stale/error states,
  and action confirmation.

## Open Implementation Questions

- Whether the app-managed Flow State workspace should be visible in any normal
  worktree list or completely hidden outside the Flow State view.
- How much of the scoring model belongs in Swift versus in the Flow State
  prompt. The likely starting point is Swift-provided hints plus agent
  reasoning.
