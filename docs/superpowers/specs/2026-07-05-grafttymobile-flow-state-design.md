# GrafttyMobile Flow State Design

**Status:** Draft, awaiting user review.  
**Authors:** Ben Tucker, with Codex.  
**Date:** 2026-07-05.

## 1. Context

Flow State is currently a Mac-owned top-level coordinator. The Mac app runs the
persistent Claude/Codex Flow State pane, exposes `graftty flow` to that agent,
stores the latest valid recommendation, records Flow State activity, and renders
the recommendation in the Mac sidebar and detail view.

GrafttyMobile already treats the Mac as the authority for worktree and pane
state. It fetches `/worktrees/panes`, subscribes to remote pane state over the
paired host connection, and renders mobile-native worktree and terminal views.
Flow State on mobile should follow that same model: the mobile app is a remote
control surface for the Mac-owned Flow State service, not a second Flow State
agent.

## 2. Goal

After this ships, this user story works:

> I open GrafttyMobile, pick my Mac, and see a top-level Flow State item above
> the worktrees. I tap it and get the same current recommendation the Mac would
> show: whether to stay put, switch, defer an interruption, or resume something.
> I can request a refresh and confirm supported Flow State actions from mobile.
> If Flow State is off on the Mac, mobile tells me to enable it there instead of
> trying to run or configure an agent on iOS.

## 3. Scope

### In scope

- Add a top-level **Flow State** item to GrafttyMobile's host worktree screen.
- Add a mobile-native Flow State detail view for status, recommendation,
  proposed actions, and recent activity.
- Add Mac HTTP APIs for mobile to read Flow State state and request safe
  interactions.
- Reuse the existing shared Flow State models from `GrafttyKit` where possible.
- Let mobile request a recommendation refresh from the already-running Mac Flow
  State agent.
- Let mobile confirm supported proposed actions through the Mac, with the Mac
  retaining policy enforcement and side-effect ownership.
- Require Flow State to already be enabled on the Mac.
- Preserve mobile's local navigation state when Flow State focus actions target
  a worktree.

### Out of scope

- Running Claude, Codex, or any Flow State agent process on iOS.
- Enabling, starting, stopping, or restarting Flow State from mobile.
- Editing the Flow State system prompt or runtime from mobile.
- Reimplementing Flow State recommendation synthesis on mobile.
- Push notifications for Flow State changes.
- A full settings surface for Flow State on mobile.
- Long-lived streaming updates for Flow State. v1 can poll or refresh on view
  appearance, pull-to-refresh, and explicit action completion.

## 4. Architecture

```
GrafttyMobile                         Graftty.app on Mac
  │                                         │
  │── GET /flow/status ───────────────────►│ FlowStateAgentController.status
  │◄─ FlowStatus ──────────────────────────│
  │                                         │
  │── GET /flow/recommendation ───────────►│ FlowStateStore.recommendation()
  │◄─ FlowRecommendationEnvelope? ─────────│
  │                                         │
  │── GET /flow/activity?limit=10 ────────►│ FlowStateActivityStore.recent()
  │◄─ [FlowStateActivity] ─────────────────│
  │                                         │
  │── POST /flow/refresh ─────────────────►│ FlowStateAgentController.requestRefresh()
  │◄─ FlowStatus / error ──────────────────│
  │                                         │
  │── POST /flow/actions/confirm ─────────►│ FlowStateActionExecutor
  │◄─ FlowMobileActionResult ──────────────│
```

The Mac remains authoritative for every side effect. Mobile does not write Flow
State files directly and does not infer whether a proposed action is allowed.
It sends intent to the Mac; the Mac applies the same policy layer used by the
native Flow State view.

## 5. Mac API Contract

The web server adds Flow State endpoints behind the existing web access auth
gate. Endpoints return JSON and use the same error-envelope style as existing
mobile endpoints.

### `GET /flow/status`

Returns the current `FlowStatus`.

If the Mac is too old to know about Flow State mobile APIs, `/flow/*` routes do
not exist and mobile sees `404`. If the routes exist but the Mac has not wired
Flow State providers during startup, this endpoint returns `503` with a concise
error.

### `GET /flow/recommendation`

Returns the latest valid `FlowRecommendationEnvelope`.

If no recommendation exists yet, return `204 No Content` rather than a fake
recommendation. Mobile renders this together with status as "No recommendation
yet" or "Flow State must be enabled on the Mac."

### `GET /flow/activity?limit=10`

Returns recent `FlowStateActivity` rows. `limit` is optional and clamped to a
small maximum such as 50.

### `POST /flow/refresh`

Requests a refresh from the existing Mac Flow State agent.

Behavior:

- If Flow State is disabled, return `409` with an error explaining that it must
  be enabled on the Mac.
- If Flow State is enabled but not running, return `409` with the current status
  and do not start it.
- If Flow State is running, call `requestRefresh(reason: "mobile refresh")` and
  return the updated `FlowStatus`.

### `POST /flow/actions/confirm`

Body:

```json
{
  "actionId": "action-1"
}
```

The Mac looks up the action by id in the latest stored recommendation, verifies
that the action is still present and supported for mobile confirmation, then
executes it through `FlowStateActionExecutor`.

Supported v1 mobile confirmations:

- `focus_worktree`
- `team_status_request`
- `team_message`

Unsupported v1 mobile confirmations:

- `restart_agent`
- pane mutation commands
- any future action kind not explicitly supported by the current app version

Response:

```json
{
  "status": "ok",
  "message": "Focused worktree",
  "focusedWorktreePath": "/Users/btucker/projects/graftty/.worktrees/foo"
}
```

`focusedWorktreePath` is present only when the confirmed action resolved a
worktree focus target. Mobile uses it to update its own selected worktree when
the target exists in the current host's worktree list. The Mac may also update
its own selected worktree, but mobile must not depend on Mac window focus as the
source of truth for the mobile detail column.

## 6. Mobile UI

### Shared presentation

GrafttyMobile should introduce a reusable Flow State view model that adapts:

- `FlowStatus`
- optional `FlowRecommendationEnvelope`
- `[FlowStateActivity]`
- action-confirmation availability

The model should mirror the Mac view's product intent:

- one primary recommendation
- short explanation of why it preserves flow
- same-context items
- held interruptions
- resume cards
- confirmable proposed actions
- recent activity

The mobile view should be dense and calm. It is not an alert dashboard. It
should lead with the recommendation, not a count of everything that changed.

### iPad

The iPad sidebar inserts a special Flow State item above the repo/worktree
sections, below the host menu. It behaves like a top-level selection, not a
worktree:

- selecting Flow State clears no selected worktree path
- the previously focused pane can remain cached for when the user returns
- worktree rows should not remain visually active while Flow State is selected
- the detail column renders `MobileFlowStateView`

The Flow State item status label uses the latest recommendation title when
available, then `FlowStatus.message`, then a compact fallback such as `Off`,
`Running`, or `Idle`.

### iPhone

The compact host screen shows a Flow State row at the top of the host's
worktree list. Tapping it pushes `MobileFlowStateView` onto the `NavigationStack`.

The iPhone path should not require a separate host picker flow. It uses the
already-selected host from `WorktreePickerView`, just like worktree and pane
navigation.

### Disabled or unavailable state

When the Mac reports Flow State disabled, mobile renders:

- title: `Flow State is off on the Mac`
- body: `Enable Flow State in Graftty on your Mac to use it here.`
- actions: `Refresh`

Mobile does not show enable/start/restart buttons in v1.

## 7. Mobile Data Flow

Introduce a small `FlowStateClient` in `GrafttyMobileKit/Session`:

- `fetchStatus(baseURL:)`
- `fetchRecommendation(baseURL:)`
- `fetchActivity(baseURL:limit:)`
- `requestRefresh(baseURL:)`
- `confirmAction(baseURL:actionId:)`

Introduce a `MobileFlowStateStore` observable model that owns:

- current load state
- status
- recommendation
- activity
- in-flight refresh/confirm flags
- user-facing error message

The initial implementation can fetch the three read endpoints concurrently on
view appearance and pull-to-refresh. After `POST /flow/refresh` or
`POST /flow/actions/confirm`, mobile re-fetches the read endpoints.

For iPad, `IPadRootLayout` owns one `MobileFlowStateStore` for the selected
host so switching away from and back to Flow State does not blank the view. For
iPhone, the pushed `MobileFlowStateView` owns its own `MobileFlowStateStore`
because the pushed view is the interaction owner.

## 8. Selection And Focus Actions

Mobile and Mac selection are separate. A confirmed `focus_worktree` action can
ask the Mac to focus a worktree, but the mobile UI must update only from the
action response and its own worktree list.

Rules:

- If the confirmation response includes `focusedWorktreePath` and that path is
  present in the current mobile worktree list, iPad updates
  `IPadAppState.selectedWorktreePath` and `focusedPaneId` to the first pane in
  that worktree.
- If the path is absent because the mobile list is stale, mobile refreshes
  `/worktrees/panes` once, then applies the selection if present.
- If still absent, mobile leaves the Flow State view selected and shows a
  transient message that the worktree is not available on this host snapshot.
- iPhone can push the matching worktree detail/session route only when it can
  resolve the path from the current or freshly-refetched list; otherwise it
  remains on Flow State.

## 9. Error Handling

- HTTP `403`: show the existing not-authorized message style.
- HTTP `404` for Flow endpoints: show "This Mac needs a newer Graftty."
- HTTP `503` for Flow endpoints: show "Flow State is unavailable on this Mac."
- HTTP `409` disabled/not-running: show the server message and keep read-only
  recommendations if any are available.
- Malformed recommendation/activity/status JSON: show "The Mac sent Flow State
  data this version can't read" and keep any previously rendered data.
- Confirm action missing from latest recommendation: show "That recommendation
  changed. Refresh Flow State."
- Confirm action unsupported on mobile: show the action row as unavailable with
  a short explanation.

## 10. Testing

Use test-first implementation.

Mac-side tests:

- Web server route tests for `GET /flow/status`.
- `GET /flow/recommendation` returns `204` when no recommendation exists and
  JSON when one exists.
- `GET /flow/activity` clamps limit and returns recent activity.
- `POST /flow/refresh` returns `409` when disabled or not running, and calls
  the refresh hook only when running.
- `POST /flow/actions/confirm` rejects missing, stale, unsupported, and unknown
  actions.
- Confirming a supported focus action returns `focusedWorktreePath`.

Mobile-side tests:

- `FlowStateClient` decodes status, recommendation, activity, no-content
  recommendation, refresh response, and confirm response.
- Mobile view model renders disabled, no-recommendation, and valid
  recommendation states.
- iPad selection model treats Flow State as a top-level selection and suppresses
  worktree highlighting while selected.
- iPhone host screen exposes the Flow State row before grouped worktrees.
- Confirmed focus action updates mobile selection only when the target exists or
  becomes available after one refresh.

Regression tests should cover older Mac behavior where `/flow/*` returns 404 so
mobile degrades to the "newer Graftty required" state rather than breaking the
whole worktree picker.

## 11. Implementation Notes

- Keep shared wire DTOs in `GrafttyProtocol` only when they are needed by both
  the Mac web server and mobile client. Otherwise keep server-only helpers in
  `GrafttyKit`/`Graftty`.
- Do not move Mac-only `FlowStateAgentController` into shared code; it depends
  on local pane creation and the Mac app lifecycle.
- Prefer reusing `FlowRecommendationEnvelope`, `FlowStatus`, and
  `FlowStateActivity` instead of inventing mobile-specific duplicates.
- Keep mobile's Flow State row visually distinct from worktree rows. It is a
  mode switch, not a pseudo-worktree.
- Do not let the Flow State view trigger terminal connection churn. Entering and
  leaving Flow State should preserve the current terminal session objects.

## 12. Risks

- **Stale recommendations:** Mobile may show a recommendation produced before
  the user changed context on the Mac. Mitigation: show generated time and make
  refresh cheap.
- **Split authority:** Mac and mobile have separate visual selection. Mitigation:
  action responses carry `focusedWorktreePath`; mobile applies its own state
  deliberately.
- **Action drift:** The latest recommendation may change between render and
  confirmation. Mitigation: confirm by id against the latest stored
  recommendation and return a stale-action error when missing.
- **Endpoint sprawl:** Flow State could become a parallel CLI over HTTP.
  Mitigation: v1 exposes only read state, refresh, and action confirmation.
