# Channel Routing Matrix — Design Specification

A user-configurable routing matrix in the Agent Teams Settings pane that decides which agents receive which automated channel events (PR state changes, CI conclusions, mergability transitions). Replaces the current single *Notify team about GitHub/GitLab PR activity* checkbox with explicit per-event-type, per-recipient-class control. Also retires the `team_pr_merged` event in favor of routing the existing `pr_state_changed` (with `to=merged`) through the matrix.

## Goal

After this ships, this user story works:

> I'm working on three feature branches with team mode enabled. By default, when a coworker's CI fails, only that coworker hears about it (no spam to the lead or me). When a PR merges, only my lead hears about it (the worktree's about to be cleaned up; my coworker on a different branch doesn't need the noise). I want my lead to also hear about CI failures so it can step in if a coworker is stuck — so I open Settings → Agent Teams, find the Channel Routing section, and tick the *Root agent* checkbox in the *CI conclusion changed* row. Done.

## Scope

**In scope (v1):**

- A new **Channel Routing** Section in the Agent Teams Settings pane: a 4-row × 3-column matrix of toggles, replacing the existing *Notify team about GitHub/GitLab PR activity* checkbox.
- Persistence: a single `ChannelRoutingPreferences` `Codable` struct stored as JSON in one `@AppStorage` key (`channelRoutingPreferences`), via a small `RawRepresentable` adapter so `@AppStorage` accepts it.
- Default cell values match the user-described "obvious" routing (worktree-only for state/CI/mergability, root-only for merges).
- The routing layer: a single helper that, given an event type and the subject worktree path, returns the recipient set; the existing `onTransition` closure in `AppServices.init` consults it and dispatches one channel event per recipient.
- **Retire** the `team_pr_merged` event entirely: drop the `TeamChannelEvents.prMerged` builder, drop the `TeamMembershipEvents.firePRMerged` helper, drop `TEAM-5.4` from SPECS.md, drop the dispatch test, drop the mention from the lead-variant MCP-instructions renderer. After this change, the lead receives merge notifications via `pr_state_changed` (with `to=merged`) routed by the matrix.
- SPECS.md updates (see "Identifier reservations" below).

**Out of scope (v2+):**

- Per-recipient prompt templating (e.g., "include the PR title in the body when sending to root, but only the SHA when sending to coworkers"). v1 sends the same event payload to every recipient.
- Routing for team-internal events (`team_message`, `team_member_joined`, `team_member_left`). These remain hard-coded as today (point-to-point and lead-only respectively); they're plumbing, not user-configurable status.
- Per-repo overrides. The matrix is a global setting; every team-enabled repo uses the same routing.
- Custom event types. The four rows are fixed; users can't add new ones.
- Migration of the deprecated `teamPRNotificationsEnabled` flag — the branch hasn't shipped, so we just delete the key.

## Architecture

The change is concentrated in three places:

1. **Data model** — a new `ChannelRoutingPreferences` struct + `RawRepresentable` adapter for `@AppStorage`.
2. **Settings UI** — a new `ChannelRoutingMatrixView` rendered inside `AgentTeamsSettingsPane`.
3. **Routing layer** — a small `ChannelEventRouter` helper that the existing `onTransition` closure consults to fan out events per the matrix.

```
       ┌─── Settings → Agent Teams ────────────┐
       │  [ matrix view: 4×3 toggles ]         │
       │  ↳ binds to ChannelRoutingPreferences │
       │    (single AppStorage key, JSON)      │
       └────────────────────┬──────────────────┘
                            │ AppStorage write
                            ▼
              UserDefaults["channelRoutingPreferences"]
                            ▲
                            │ AppStorage read
       ┌────────────────────┴──────────────────┐
       │ AppServices.init                      │
       │   prStatusStore.onTransition = { ... }│
       │   ─ for each transition:              │
       │     1. classify event type            │
       │     2. ChannelEventRouter.recipients( │
       │          event, subject:, repos:)     │
       │     3. dispatch once per recipient    │
       └───────────────────────────────────────┘
```

Existing `pr_state_changed`, `ci_conclusion_changed`, `merge_state_changed` events are unchanged at the wire level — the matrix only changes their routing fan-out.

## Data model

### `ChannelRoutingPreferences`

```swift
public struct ChannelRoutingPreferences: Codable, Equatable, Sendable {
    /// PR/MR transitioned to a non-merged state (open, closed, reopened).
    public var prStateChanged: RecipientSet
    /// PR/MR transitioned to merged.
    public var prMerged: RecipientSet
    /// CI conclusion (success/failure/cancelled) changed.
    public var ciConclusionChanged: RecipientSet
    /// PR mergability (clean/dirty/blocked) changed.
    public var mergabilityChanged: RecipientSet

    public init(
        prStateChanged: RecipientSet = .worktree,
        prMerged: RecipientSet = .root,
        ciConclusionChanged: RecipientSet = .worktree,
        mergabilityChanged: RecipientSet = .worktree
    ) {
        self.prStateChanged = prStateChanged
        self.prMerged = prMerged
        self.ciConclusionChanged = ciConclusionChanged
        self.mergabilityChanged = mergabilityChanged
    }
}

public struct RecipientSet: Codable, Equatable, Sendable, OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The repo's root worktree (the team's lead).
    public static let root              = RecipientSet(rawValue: 1 << 0)
    /// The worktree the event is *about* (e.g., the worktree whose PR transitioned).
    public static let worktree          = RecipientSet(rawValue: 1 << 1)
    /// All other coworkers in the same repo.
    public static let otherWorktrees    = RecipientSet(rawValue: 1 << 2)
}
```

`OptionSet` lets each row's value be 0–7 (any combination of root / worktree / others). The defaults set just one bit per row.

### `RawRepresentable` adapter for `@AppStorage`

`@AppStorage` accepts `RawRepresentable` types where the raw type is `String`, `Int`, etc. Add a small extension that adapts `Codable` to `RawRepresentable<String>` via JSON:

```swift
extension ChannelRoutingPreferences: RawRepresentable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ChannelRoutingPreferences.self, from: data)
        else { return nil }
        self = decoded
    }
    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
```

`@AppStorage` then accepts it directly: `@AppStorage("channelRoutingPreferences") private var routing = ChannelRoutingPreferences()`.

## Settings UI

A new `Section("Channel routing")` inside `AgentTeamsSettingsPane`, rendered when `agentTeamsEnabled` is true, between the existing main-toggle Section and the lead/coworker prompt Sections.

### Layout

```
┌─ Channel routing ───────────────────────────────────────────┐
│                                                             │
│                       Root agent  Worktree agent  Other ws  │
│                                                             │
│  PR/MR state changed     ☐            ☑              ☐      │
│  PR/MR merged            ☑            ☐              ☐      │
│  CI conclusion changed   ☐            ☑              ☐      │
│  Mergability changed     ☐            ☑              ☐      │
│                                                             │
│ Choose which agents receive each automated channel          │
│ message. "Worktree agent" means the agent in the worktree   │
│ the event is about (e.g., the branch whose CI just failed). │
└─────────────────────────────────────────────────────────────┘
```

Implementation: a SwiftUI `Grid` with the header row (`GridRow { Text(""); Text("Root agent"); ... }`) and one `GridRow` per event type. Each cell is a `Toggle("", isOn: <Binding>)` with `.toggleStyle(.checkbox)` and an empty label. Bind each cell to a derived `Binding<Bool>` that flips a single bit of the corresponding `RecipientSet` field on the parent `ChannelRoutingPreferences`. A small extension simplifies the binding plumbing:

```swift
extension Binding where Value == ChannelRoutingPreferences {
    func cell(_ keyPath: WritableKeyPath<ChannelRoutingPreferences, RecipientSet>,
              _ recipient: RecipientSet) -> Binding<Bool> {
        Binding<Bool>(
            get: { self.wrappedValue[keyPath: keyPath].contains(recipient) },
            set: { newValue in
                if newValue { self.wrappedValue[keyPath: keyPath].insert(recipient) }
                else        { self.wrappedValue[keyPath: keyPath].remove(recipient) }
            }
        )
    }
}
```

### Footer text

> Choose which agents receive each automated channel message. "Worktree agent" means the agent in the worktree the event is about (e.g., the branch whose CI just failed); "Other worktree agents" means every other coworker in the same repo. Use the lead/coworker prompts below to define what each agent should do when it receives an event.

## Routing layer

### `ChannelEventRouter`

```swift
public enum RoutableEvent: Sendable, Equatable {
    case prStateChanged
    case prMerged
    case ciConclusionChanged
    case mergabilityChanged
}

public enum ChannelEventRouter {
    /// Resolves the set of recipient worktree paths for `event` originating
    /// from `subjectWorktreePath`, given the user's configured matrix and
    /// the current repo state.
    public static func recipients(
        event: RoutableEvent,
        subjectWorktreePath: String,
        repos: [RepoEntry],
        preferences: ChannelRoutingPreferences
    ) -> [String]
}
```

Algorithm:

1. Find the repo containing `subjectWorktreePath` (existing `AppState.repo(forWorktreePath:)` helper). If absent, return `[]`.
2. If the repo has fewer than 2 worktrees, return `[subjectWorktreePath]` only when the event's matrix value contains `.worktree` — otherwise `[]`. (Single-worktree repos have no team and no concept of "root" or "other coworkers"; the matrix treats them as a degenerate case.)
3. Compute the matrix value for the event (one of the four `RecipientSet` fields).
4. Build the union:
   - If `.root` is set: include `repo.path` (the lead).
   - If `.worktree` is set: include `subjectWorktreePath`.
   - If `.otherWorktrees` is set: include every `worktree.path` in the repo where `worktree.path != subjectWorktreePath` and `worktree.path != repo.path`.
5. De-duplicate (in case `subjectWorktreePath == repo.path`, root + worktree are the same path).
6. Return the deduped list.

### Integration in `AppServices.init`

The existing `onTransition` closure today does:

```swift
self.prStatusStore.onTransition = { [weak router] worktreePath, message in
    router?.dispatch(worktreePath: worktreePath, message: message)
}
```

Replace with a routing-aware version:

```swift
self.prStatusStore.onTransition = { [weak router, weak self] worktreePath, message in
    guard let router, let self else { return }
    guard UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled) else { return }
    guard case let .event(type, _, _) = message,
          let event = RoutableEvent(channelEventType: type) else { return }
    let prefs = ChannelRoutingPreferences.fromUserDefaults()
    let appState = self.appStateProvider?() ?? AppState()
    let recipients = ChannelEventRouter.recipients(
        event: event,
        subjectWorktreePath: worktreePath,
        repos: appState.repos,
        preferences: prefs
    )
    for recipient in recipients {
        router.dispatch(worktreePath: recipient, message: message)
    }
}
```

A small `RoutableEvent.init(channelEventType:)` failable initializer maps the wire type strings (`"pr_state_changed"`, `"ci_conclusion_changed"`, `"merge_state_changed"`) to the right enum case. For `pr_state_changed`, it inspects the message attrs to choose `.prMerged` (when `attrs["to"] == "merged"`) vs `.prStateChanged` (otherwise).

The existing `dispatch(worktreePath:message:)` is unchanged; we just call it once per recipient.

## What's retired

These get deleted in this change:

- `TeamChannelEvents.prMerged(...)` builder (`Sources/GrafttyKit/Teams/TeamChannelEvents.swift`)
- `TeamChannelEvents.EventType.prMerged` constant
- `TeamMembershipEvents.firePRMerged(...)` helper (`Sources/GrafttyKit/Teams/TeamMembershipEvents.swift`)
- The PR-merged dispatch site in `AppServices.init.onTransition` — replaced by the matrix-based dispatch above
- `Tests/GrafttyKitTests/PRStatus/TeamPRMergedDispatchTests.swift` — entire file
- The mention of `team_pr_merged` in `TeamInstructionsRenderer.renderLead` — replaced by `pr_state_changed` (the lead now receives merge notifications via the routed `pr_state_changed`)
- `SettingsKeys.teamPRNotificationsEnabled` — deleted (no migration; the branch hasn't shipped)
- `TEAM-5.4` requirement in SPECS.md — removed

After this change, the only `team_*` events are `team_message`, `team_member_joined`, `team_member_left`.

## Channel events (after the matrix lands)

The four routable events the matrix governs:

| Event              | Wire type              | Subject worktree           |
| ------------------ | ---------------------- | -------------------------- |
| PR state changed   | `pr_state_changed`     | The PR's worktree (existing PRStatusStore key) |
| PR merged          | `pr_state_changed` *with attrs.to=merged* | Same |
| CI changed         | `ci_conclusion_changed`| Same |
| Mergability changed| `merge_state_changed`  | Same |

Note: the wire type for the PR-merge case is the same as the non-merged case (`pr_state_changed` with different attrs). The matrix routes them differently because they're different *RoutableEvent* cases, even though they share an event type string.

This is intentional: agents that don't care about the merged-vs-not distinction can pattern-match on `pr_state_changed` and treat all transitions uniformly. Agents that *do* care can inspect `attrs.to` per the existing event schema.

## Data flows

### A coworker's CI fails

1. `PRStatusStore` polling observes the CI conclusion transition.
2. Its `onTransition` callback fires with `(worktreePath: <coworker's wt>, message: ci_conclusion_changed)`.
3. The closure classifies `message` → `RoutableEvent.ciConclusionChanged`.
4. `ChannelEventRouter.recipients` reads the matrix → finds `ciConclusionChanged = .worktree` (default).
5. Returns `[<coworker's wt>]`.
6. `router.dispatch` fires the event into the coworker's pane only.

If the user has *also* ticked the *Root agent* cell in that row, step 4 returns `.worktree | .root`, and step 5 returns `[<coworker's wt>, <repo's root path>]`. Step 6 dispatches twice — once into each pane.

### A coworker's PR merges

1. `PRStatusStore` polling observes `state` transition to `.merged` for the coworker's worktree.
2. `onTransition` callback fires.
3. The closure inspects `message.attrs["to"]`. It equals `"merged"`. → `RoutableEvent.prMerged`.
4. `ChannelEventRouter.recipients` reads matrix → finds `prMerged = .root` (default).
5. Returns `[<repo's root path>]`.
6. `router.dispatch` fires `pr_state_changed` (the wire type) with `to=merged` into the lead's pane only.

The lead's MCP instructions (post-renderer-update) explain that `pr_state_changed` events arrive when PR state changes, including merges.

### Single-worktree repo

1. A repo has only its root worktree (no team).
2. `PRStatusStore` fires for the root's PR.
3. `ChannelEventRouter.recipients` checks `repo.worktrees.count >= 2` — fails.
4. The degenerate-case rule applies: if the matrix's relevant row has `.worktree` set, the event still dispatches to the root (it *is* the worktree-of-the-event, and the user wants their solo agent to know). Otherwise no dispatch.

This preserves the channels feature for single-worktree-repo users (who are still helped by being told their PR merged), while letting team users override globally.

## Edge cases

- **`subjectWorktreePath == repo.path`** (the event is *about* the lead's own worktree). The matrix's `.root` and `.worktree` cells point at the same path. The dedupe in step 5 ensures only one dispatch.
- **Repo not found.** `appState.repo(forWorktreePath:)` returns nil. Recipients = []. The event silently doesn't fire. This matches today's behavior (the existing `pr_state_changed` dispatch already routes per worktree path; an unknown path was already a silent no-op).
- **Matrix row is fully off (000).** Recipients = []. The event silently doesn't fire. The user has explicitly opted out of that event class.
- **Matrix not yet persisted** (first launch on a fresh install). `@AppStorage` returns the default `ChannelRoutingPreferences()`. All four rows have their documented defaults. No "first run" UX is needed.
- **Migration from a build with `teamPRNotificationsEnabled`.** None: the branch hasn't shipped; we delete the key.

## Components

### New files

| File                                                                  | Purpose                                                                |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `Sources/GrafttyKit/Channels/ChannelRoutingPreferences.swift`         | The Codable struct + `RecipientSet` `OptionSet` + `RawRepresentable` adapter. |
| `Sources/GrafttyKit/Channels/RoutableEvent.swift`                     | Enum + failable initializer that classifies `ChannelServerMessage.event(...)` payloads into matrix rows. |
| `Sources/GrafttyKit/Channels/ChannelEventRouter.swift`                | The `recipients(event:subjectWorktreePath:repos:preferences:)` helper. |
| `Sources/Graftty/Views/Settings/ChannelRoutingMatrixView.swift`       | The matrix `Grid` view, used inside `AgentTeamsSettingsPane`.          |
| `Tests/GrafttyKitTests/Channels/ChannelRoutingPreferencesTests.swift` | Codable round-trip + default values + JSON-via-`RawRepresentable`.     |
| `Tests/GrafttyKitTests/Channels/ChannelEventRouterTests.swift`        | Unit tests for the recipient-set computation across various matrix configs. |
| `Tests/GrafttyKitTests/Channels/RoutableEventTests.swift`             | Tests for the wire-type → enum classifier.                             |

### Modified files

| File                                                                  | Change                                                                 |
| --------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift`         | Replace the *Notify team about GitHub/GitLab PR activity* checkbox with `ChannelRoutingMatrixView` rendered inside its own Section. |
| `Sources/Graftty/Channels/SettingsKeys.swift`                         | Drop `teamPRNotificationsEnabled`. Add `channelRoutingPreferences`.    |
| `Sources/Graftty/GrafttyApp.swift`                                    | Replace the existing `prStatusStore.onTransition` closure with the matrix-aware version (above). |
| `Sources/GrafttyKit/Teams/TeamChannelEvents.swift`                    | Drop `prMerged(...)` builder and `EventType.prMerged`.                 |
| `Sources/GrafttyKit/Teams/TeamMembershipEvents.swift`                 | Drop `firePRMerged(...)` helper.                                       |
| `Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift`             | Drop `team_pr_merged` from the lead-variant event list; add `pr_state_changed` and the others to both variants (mechanism-only documentation). |
| `Tests/GrafttyKitTests/PRStatus/TeamPRMergedDispatchTests.swift`      | Delete (entire file).                                                  |
| `Tests/GrafttyKitTests/Teams/TeamChannelEventsTests.swift`            | Drop the `prMergedFullPayload` and `prMergedOmitsEmptyMergeSha` tests. |
| `Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift`     | Update the `leadVariantDocumentsTeamEvents` test to assert the new event list (no `team_pr_merged`; includes `pr_state_changed`, `ci_conclusion_changed`, `merge_state_changed`). |
| `SPECS.md`                                                            | Remove `TEAM-5.4`. Replace `TEAM-1.5` and `TEAM-1.6` with the new matrix description (see SPECS reservations). |

## SPECS.md identifier reservations

Existing TEAM-1.6 (lead/coworker prompts) and TEAM-1.7 (launch-flag panel) are unchanged. The matrix gets new identifiers:

- **TEAM-1.5** *(rewritten — was the `teamPRNotificationsEnabled` gate)*: `agentTeamsEnabled` plus the new `channelRoutingPreferences` JSON struct (see TEAM-1.8) supersede the previous coupled `teamPRNotificationsEnabled` flag. Channel events fire only when `agentTeamsEnabled` is true; per-event recipient sets are taken from the matrix in `channelRoutingPreferences`.
- **TEAM-1.8** *(new)*: The Agent Teams Settings pane shall render a 4×3 matrix of toggles (rows: PR state changed / PR merged / CI conclusion changed / Mergability changed; columns: Root agent / Worktree agent / Other worktree agents). Each cell binds to one bit of a `RecipientSet` field on the persisted `ChannelRoutingPreferences` `Codable` struct. Defaults: state-changed/CI/mergability → worktree only; merged → root only. The matrix is rendered as its own Section between the main toggle and the lead/coworker prompts.
- **TEAM-1.9** *(new)*: When `PRStatusStore` fires a transition that produces a routable channel event (`pr_state_changed`, `ci_conclusion_changed`, `merge_state_changed`), the application shall consult `channelRoutingPreferences` for the corresponding row and dispatch the event once per recipient resolved by `ChannelEventRouter.recipients`. The router classifies `pr_state_changed` events with `attrs.to == "merged"` as the *PR merged* row; all other `pr_state_changed` events are the *PR state changed* row. Single-worktree repos (no team) receive the event only when the relevant row's `Worktree agent` cell is set; root and other-worktree cells are no-ops there.
- **TEAM-5.4** *(removed)*: The dedicated `team_pr_merged` event is retired. PR-merge notifications now flow as `pr_state_changed` with `attrs.to = "merged"`, routed by the matrix per TEAM-1.9.

## Open questions

None.
