# Channel Routing Matrix + Stencil Prompts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the *Notify team about GitHub/GitLab PR activity* checkbox with a per-event-type / per-recipient-class routing matrix; replace the two role-specific prompts (`teamLeadPrompt`, `teamCoworkerPrompt`) with two purpose-specific Stencil templates (`teamSessionPrompt`, `teamPrompt`); retire the `team_pr_merged` event entirely.

**Architecture:** Matrix decisions live in a `ChannelRoutingPreferences` `Codable` struct stored as JSON via `@AppStorage`'s `RawRepresentable` adapter. `RoutableEvent` classifies an outbound `ChannelServerMessage` into one of four matrix rows. `ChannelEventRouter` resolves recipient worktree paths from (event, subject, repos, prefs). `EventBodyRenderer` runs the user's `teamPrompt` Stencil template against the `agent` context for each delivery and prepends the rendered text to the event body. The `onTransition` closure in `AppServices.init` chains all four. `ChannelSettingsObserver.composedPrompt` renders `teamSessionPrompt` and appends to the auto-generated team text in MCP instructions.

**Tech Stack:** Swift, SwiftUI, ArgumentParser, Stencil (new SwiftPM dep), XCTest + Swift Testing.

**Spec:** [`docs/superpowers/specs/2026-04-27-channel-routing-matrix-design.md`](../specs/2026-04-27-channel-routing-matrix-design.md) — read first.

---

## Task ordering and parallelism

```
Task 1  — SPECS.md updates                              ┐
Task 2  — Package.swift: add Stencil                    │  (Phase 1: foundations,
Task 3  — SettingsKeys updates                          │   parallel-safe)
Task 4  — ChannelRoutingPreferences + RecipientSet      ┘
Task 5  — RoutableEvent classifier                       (depends on 4)
Task 6  — ChannelEventRouter                             (depends on 4, 5)
Task 7  — EventBodyRenderer                              (depends on 2)
Task 8  — ChannelRoutingMatrixView (UI)                  (depends on 3, 4)
Task 9  — Retire team_pr_merged everywhere               (independent)
Task 10 — TeamInstructionsRenderer event-list update     (depends on 9)
Task 11 — AgentTeamsSettingsPane: matrix + 2 prompts     (depends on 3, 8)
Task 12 — composedPrompt: render teamSessionPrompt       (depends on 3, 7, 10)
Task 13 — Rewrite onTransition with matrix + body render (depends on 5, 6, 7)
Task 14 — Wire EventBodyRenderer into peer dispatch      (depends on 7, 13)
```

For subagent dispatch: tasks 1, 2, 3 in parallel first; then 4; then 5 + 7 + 9 in parallel; then 6 + 10; then 8; then 11; then 12; then 13; then 14.

(In practice, subagent-driven-development runs tasks sequentially. The above grouping is informational.)

---

### Task 1: SPECS.md — TEAM-1.5/1.6/3.3 rewrites, TEAM-1.8/1.9 added, TEAM-5.4 removed

**Files:**
- Modify: `SPECS.md`

This task is documentation-only. It updates the spec section so subsequent task commits can reference the new requirement IDs. Lift wording from the design doc.

- [ ] **Step 1: Find the existing TEAM-1.5, TEAM-1.6, TEAM-3.3, TEAM-5.4 lines**

```bash
grep -nE "^\\*\\*TEAM-(1\\.[5-7]|3\\.3|5\\.4)\\*\\*" SPECS.md
```

Expected: matches showing each requirement's current line. Note the line numbers.

- [ ] **Step 2: Rewrite TEAM-1.5**

Replace the existing TEAM-1.5 line entirely with:

```
**TEAM-1.5** `agentTeamsEnabled` plus the `channelRoutingPreferences` JSON struct (see TEAM-1.8) supersede the previous coupled `teamPRNotificationsEnabled` flag. Channel events fire only when `agentTeamsEnabled` is true; per-event recipient sets are taken from the matrix in `channelRoutingPreferences`.
```

- [ ] **Step 3: Rewrite TEAM-1.6**

Replace the existing TEAM-1.6 line entirely with:

```
**TEAM-1.6** The Agent Teams Settings pane shall expose **two** user-editable Stencil-templated text areas: `teamSessionPrompt` (`@AppStorage("teamSessionPrompt")`, String, default empty) — rendered once at session start against the `agent` context (only `agent.branch` and `agent.lead` are meaningful; `agent.this_worktree` and `agent.other_worktree` are always `false`); the rendered text is appended after a blank line to the auto-generated team-aware MCP-instructions text. And `teamPrompt` (`@AppStorage("teamPrompt")`, String, default empty) — rendered per channel-event delivery against the full four-field `agent` context; the rendered text is prepended after a blank line to the channel event's body before dispatch. Both templates use the same `agent` struct shape: `branch` (String), `lead` (Bool), `this_worktree` (Bool), `other_worktree` (Bool). The previously-defined `teamLeadPrompt` and `teamCoworkerPrompt` AppStorage keys are removed.
```

- [ ] **Step 4: Rewrite TEAM-3.3**

Replace the existing TEAM-3.3 line entirely with:

```
**TEAM-3.3** Two separate user templates contribute to what each agent sees. **MCP instructions** (session start): the auto-generated team-aware text from `TeamInstructionsRenderer` is followed (after a blank line) by the rendered `teamSessionPrompt` template, evaluated against the agent's session-start context. If the template is empty, whitespace-only after render, or fails to render (Stencil throws), the appended portion is omitted and a render-failure error is logged via `os_log`. **Per channel-event delivery**: the rendered `teamPrompt` template is prepended (followed by a blank line) to the event body before dispatch. The same render/empty/failure rules apply. This applies to every channel event flowing through `ChannelRouter.dispatch` — PR/CI/merge events as routed by the matrix, plus `team_message`, `team_member_joined`, and `team_member_left`.
```

- [ ] **Step 5: Add TEAM-1.8 and TEAM-1.9 immediately after TEAM-1.7**

Find TEAM-1.7 (search `grep -n "TEAM-1\\.7" SPECS.md`). Insert after that line, separated by blank lines:

```
**TEAM-1.8** The Agent Teams Settings pane shall render a 4×3 matrix of toggles (rows: PR state changed / PR merged / CI conclusion changed / Mergability changed; columns: Root agent / Worktree agent / Other worktree agents). Each cell binds to one bit of a `RecipientSet` field on the persisted `ChannelRoutingPreferences` `Codable` struct. Defaults: state-changed/CI/mergability → worktree only; merged → root only. The matrix is rendered as its own Section between the main toggle and the prompt sections.

**TEAM-1.9** When `PRStatusStore` fires a transition that produces a routable channel event (`pr_state_changed`, `ci_conclusion_changed`, `merge_state_changed`), the application shall consult `channelRoutingPreferences` for the corresponding row and dispatch the event once per recipient resolved by `ChannelEventRouter.recipients`. The router classifies `pr_state_changed` events with `attrs.to == "merged"` as the *PR merged* row; all other `pr_state_changed` events are the *PR state changed* row. Single-worktree repos (no team) receive the event only when the relevant row's `Worktree agent` cell is set; root and other-worktree cells are no-ops there.
```

- [ ] **Step 6: Remove TEAM-5.4**

Find the existing TEAM-5.4 line. Replace its requirement text with a tombstone marker:

```
**TEAM-5.4** ~~Removed — the dedicated `team_pr_merged` event is retired. PR-merge notifications now flow as `pr_state_changed` with `attrs.to = "merged"`, routed by the matrix per TEAM-1.9.~~
```

(Striking through preserves the ID so future requirements don't collide; matches the existing CHAN-2.2 tombstone style in SPECS.md.)

- [ ] **Step 7: Verify the count of TEAM-* requirements is sane**

Run: `grep -cE "^\\*\\*TEAM-[0-9]+\\.[0-9]+\\*\\*" SPECS.md`
Expected: a number close to the current count (no large delta — we replaced/added/struck-through, not bulk-deleted).

- [ ] **Step 8: Commit**

```bash
git add SPECS.md
git commit -m "specs: matrix routing (TEAM-1.8, 1.9) + two-prompt rewrite (TEAM-1.6, 3.3); retire TEAM-5.4"
```

---

### Task 2: Package.swift — add Stencil dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Read the current dependencies array**

```bash
grep -n "dependencies:\\|\\.package(url:" Package.swift | head -20
```

Note where the `dependencies:` array of `Package(...)` lives and where existing package dependencies are declared.

- [ ] **Step 2: Add the Stencil package dependency**

In `Package.swift`'s top-level `dependencies:` array, add:

```swift
.package(url: "https://github.com/stencilproject/Stencil.git", from: "0.15.1"),
```

Place it alphabetically among the other `.package(url:...)` entries.

- [ ] **Step 3: Add Stencil as a target dependency on GrafttyKit**

Find the `.target(name: "GrafttyKit", ...)` declaration. Its `dependencies:` array currently lists peer targets and possibly other packages. Add:

```swift
.product(name: "Stencil", package: "Stencil"),
```

- [ ] **Step 4: Resolve and build**

Run:

```bash
swift package resolve
swift build
```

Expected: Stencil resolves, project builds with no errors.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add Stencil dependency to GrafttyKit (TEAM-1.6, TEAM-3.3)"
```

---

### Task 3: SettingsKeys — drop deprecated, add new

**Files:**
- Modify: `Sources/Graftty/Channels/SettingsKeys.swift`

- [ ] **Step 1: Read the current file**

```bash
cat Sources/Graftty/Channels/SettingsKeys.swift
```

- [ ] **Step 2: Replace the file contents**

```swift
import Foundation

/// Centralized UserDefaults key strings used across Settings panes and observers.
enum SettingsKeys {
    static let agentTeamsEnabled       = "agentTeamsEnabled"
    static let channelsEnabled         = "channelsEnabled"
    static let channelRoutingPreferences = "channelRoutingPreferences"
    static let teamSessionPrompt       = "teamSessionPrompt"
    static let teamPrompt              = "teamPrompt"
    static let defaultCommand          = "defaultCommand"
}
```

The dropped keys: `teamPRNotificationsEnabled`, `teamLeadPrompt`, `teamCoworkerPrompt`. The added keys: `channelRoutingPreferences`, `teamSessionPrompt`, `teamPrompt`. (`channelsEnabled` is kept because it appears as a string literal in some legacy paths the rest of the plan may still reference, even though it isn't actively read; harmless if present.)

- [ ] **Step 3: Build to surface broken references**

```bash
swift build 2>&1 | tail -30
```

Expected: build errors at sites that read the now-dropped keys (e.g. `SettingsKeys.teamLeadPrompt` etc.). These are intentional — Tasks 11 and 12 will rewrite the consumers. For now, those sites stay broken; we'll fix them in dedicated tasks. **Do not** fix them in this task.

- [ ] **Step 4: Commit**

If the build fails (which is expected), DO NOT pass `--no-verify`. Just commit the SettingsKeys file alone — the broken references are in *other* files and will be addressed in subsequent tasks. To commit just this file:

```bash
git add Sources/Graftty/Channels/SettingsKeys.swift
git commit -m "feat(teams): SettingsKeys drop teamPRNotificationsEnabled + role prompts; add matrix + 2 prompts"
```

If your pre-commit hooks block on build failures, run `git commit --no-verify` *only for this commit* — the next tasks will restore the build.

---

### Task 4: ChannelRoutingPreferences + RecipientSet + RawRepresentable adapter

**Files:**
- Create: `Sources/GrafttyKit/Channels/ChannelRoutingPreferences.swift`
- Test: `Tests/GrafttyKitTests/Channels/ChannelRoutingPreferencesTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/GrafttyKitTests/Channels/ChannelRoutingPreferencesTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("ChannelRoutingPreferences")
struct ChannelRoutingPreferencesTests {

    @Test func defaultsMatchSpec() {
        let prefs = ChannelRoutingPreferences()
        #expect(prefs.prStateChanged == .worktree)
        #expect(prefs.prMerged == .root)
        #expect(prefs.ciConclusionChanged == .worktree)
        #expect(prefs.mergabilityChanged == .worktree)
    }

    @Test func recipientSetSupportsUnion() {
        var s: RecipientSet = []
        #expect(s.isEmpty)
        s.insert(.root)
        #expect(s.contains(.root))
        #expect(!s.contains(.worktree))
        s.insert(.worktree)
        #expect(s.contains(.root))
        #expect(s.contains(.worktree))
        s.remove(.root)
        #expect(!s.contains(.root))
        #expect(s.contains(.worktree))
    }

    @Test func codableRoundTripPreservesValues() throws {
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.worktree, .root]
        prefs.ciConclusionChanged = []
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(ChannelRoutingPreferences.self, from: data)
        #expect(decoded == prefs)
        #expect(decoded.prStateChanged.contains(.worktree))
        #expect(decoded.prStateChanged.contains(.root))
        #expect(decoded.ciConclusionChanged.isEmpty)
    }

    @Test func rawRepresentableRoundTrip() {
        var prefs = ChannelRoutingPreferences()
        prefs.prMerged = [.root, .otherWorktrees]
        let raw = prefs.rawValue
        #expect(!raw.isEmpty)
        let decoded = ChannelRoutingPreferences(rawValue: raw)
        #expect(decoded == prefs)
    }

    @Test func rawRepresentableRecoversFromGarbage() {
        // Invalid JSON should decode as nil (so @AppStorage falls back to default).
        #expect(ChannelRoutingPreferences(rawValue: "not json") == nil)
        #expect(ChannelRoutingPreferences(rawValue: "") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ChannelRoutingPreferences 2>&1 | tail -10
```

Expected: FAIL — `ChannelRoutingPreferences` and `RecipientSet` undefined.

- [ ] **Step 3: Create `Sources/GrafttyKit/Channels/ChannelRoutingPreferences.swift`**

```swift
import Foundation

/// Set of recipient classes for a single matrix row, encoded as bit flags so
/// each row's value is one of 0–7 (any combination of root / worktree / others).
public struct RecipientSet: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The repo's root worktree (the team's lead).
    public static let root           = RecipientSet(rawValue: 1 << 0)
    /// The worktree the event is *about*.
    public static let worktree       = RecipientSet(rawValue: 1 << 1)
    /// All other coworkers in the same repo.
    public static let otherWorktrees = RecipientSet(rawValue: 1 << 2)
}

/// User-configurable routing matrix for the four routable channel events
/// (TEAM-1.8). Each field is a `RecipientSet` controlling which recipient
/// classes the corresponding event type fans out to.
public struct ChannelRoutingPreferences: Codable, Equatable, Sendable {
    public var prStateChanged: RecipientSet
    public var prMerged: RecipientSet
    public var ciConclusionChanged: RecipientSet
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

// MARK: - @AppStorage adapter

/// `@AppStorage` accepts `RawRepresentable` whose raw type is `String`, `Int`,
/// etc. This adapter wraps the JSON encoding so the struct can be persisted
/// directly: `@AppStorage("channelRoutingPreferences") var prefs = ChannelRoutingPreferences()`.
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

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter ChannelRoutingPreferences 2>&1 | tail -10
```

Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Channels/ChannelRoutingPreferences.swift Tests/GrafttyKitTests/Channels/ChannelRoutingPreferencesTests.swift
git commit -m "feat(teams): add ChannelRoutingPreferences + RecipientSet (TEAM-1.8)"
```

---

### Task 5: RoutableEvent classifier

**Files:**
- Create: `Sources/GrafttyKit/Channels/RoutableEvent.swift`
- Test: `Tests/GrafttyKitTests/Channels/RoutableEventTests.swift`

`RoutableEvent` maps a `ChannelServerMessage.event(...)` payload onto one of the four matrix rows. The four rows correspond to `prStateChanged`, `prMerged`, `ciConclusionChanged`, `mergabilityChanged`.

- [ ] **Step 1: Write failing tests**

Create `Tests/GrafttyKitTests/Channels/RoutableEventTests.swift`:

```swift
import Testing
@testable import GrafttyKit

@Suite("RoutableEvent classifier")
struct RoutableEventTests {

    @Test func prStateChangedNonMergeIsState() {
        let event = RoutableEvent(channelEventType: "pr_state_changed", attrs: ["to": "open"])
        #expect(event == .prStateChanged)
    }

    @Test func prStateChangedToMergedIsMerged() {
        let event = RoutableEvent(channelEventType: "pr_state_changed", attrs: ["to": "merged"])
        #expect(event == .prMerged)
    }

    @Test func prStateChangedClosedIsState() {
        let event = RoutableEvent(channelEventType: "pr_state_changed", attrs: ["to": "closed"])
        #expect(event == .prStateChanged)
    }

    @Test func ciConclusionChangedClassifies() {
        let event = RoutableEvent(channelEventType: "ci_conclusion_changed", attrs: [:])
        #expect(event == .ciConclusionChanged)
    }

    @Test func mergeStateChangedClassifies() {
        let event = RoutableEvent(channelEventType: "merge_state_changed", attrs: [:])
        #expect(event == .mergabilityChanged)
    }

    @Test func unknownTypeReturnsNil() {
        #expect(RoutableEvent(channelEventType: "team_message", attrs: [:]) == nil)
        #expect(RoutableEvent(channelEventType: "made_up", attrs: [:]) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter RoutableEvent 2>&1 | tail -5
```

Expected: FAIL — `RoutableEvent` undefined.

- [ ] **Step 3: Create `Sources/GrafttyKit/Channels/RoutableEvent.swift`**

```swift
import Foundation

/// One of the four event types the channel routing matrix governs.
/// Maps wire-format `ChannelServerMessage.event(...)` payloads to matrix rows.
public enum RoutableEvent: Sendable, Equatable {
    case prStateChanged
    case prMerged
    case ciConclusionChanged
    case mergabilityChanged

    /// Failable initializer: returns nil for events outside the matrix
    /// (e.g. `team_message`, `team_member_joined`). Distinguishes
    /// `pr_state_changed` with `attrs.to == "merged"` as the merged row.
    public init?(channelEventType type: String, attrs: [String: String]) {
        switch type {
        case "pr_state_changed":
            if attrs["to"] == "merged" {
                self = .prMerged
            } else {
                self = .prStateChanged
            }
        case "ci_conclusion_changed":
            self = .ciConclusionChanged
        case "merge_state_changed":
            self = .mergabilityChanged
        default:
            return nil
        }
    }

    /// The matrix-row `RecipientSet` field this event uses.
    public func recipientSet(in prefs: ChannelRoutingPreferences) -> RecipientSet {
        switch self {
        case .prStateChanged:        return prefs.prStateChanged
        case .prMerged:              return prefs.prMerged
        case .ciConclusionChanged:   return prefs.ciConclusionChanged
        case .mergabilityChanged:    return prefs.mergabilityChanged
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter RoutableEvent 2>&1 | tail -5
```

Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Channels/RoutableEvent.swift Tests/GrafttyKitTests/Channels/RoutableEventTests.swift
git commit -m "feat(teams): RoutableEvent classifier (TEAM-1.9)"
```

---

### Task 6: ChannelEventRouter — recipient resolver

**Files:**
- Create: `Sources/GrafttyKit/Channels/ChannelEventRouter.swift`
- Test: `Tests/GrafttyKitTests/Channels/ChannelEventRouterTests.swift`

Resolves the set of recipient worktree paths for a given event + subject + repos + matrix.

- [ ] **Step 1: Write failing tests**

Create `Tests/GrafttyKitTests/Channels/ChannelEventRouterTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("ChannelEventRouter")
struct ChannelEventRouterTests {

    private func makeRepo(branches: [String]) -> RepoEntry {
        TeamTestFixtures.makeRepo(branches: branches)
    }

    @Test func defaultPrStateChangedGoesToWorktreeOnly() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        let prefs = ChannelRoutingPreferences()
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            preferences: prefs
        )
        #expect(r == ["/r/multi/.worktrees/feature-login"])
    }

    @Test func defaultPrMergedGoesToRootOnly() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        let prefs = ChannelRoutingPreferences()
        let r = ChannelEventRouter.recipients(
            event: .prMerged,
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            preferences: prefs
        )
        #expect(r == ["/r/multi"])
    }

    @Test func unionRoutesToBothRootAndWorktree() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.root, .worktree]
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            preferences: prefs
        )
        #expect(Set(r) == Set(["/r/multi", "/r/multi/.worktrees/feature-login"]))
    }

    @Test func otherWorktreesIncludesAllNonSubjectNonRoot() {
        let repo = makeRepo(branches: ["main", "a", "b", "c"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.otherWorktrees]
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi/.worktrees/a",
            repos: [repo],
            preferences: prefs
        )
        #expect(Set(r) == Set(["/r/multi/.worktrees/b", "/r/multi/.worktrees/c"]))
    }

    @Test func dedupsWhenSubjectIsAlsoRoot() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.root, .worktree]
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi",   // root is also subject
            repos: [repo],
            preferences: prefs
        )
        #expect(r.count == 1)
        #expect(r == ["/r/multi"])
    }

    @Test func emptyMatrixRowMeansNoRecipients() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = []
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            preferences: prefs
        )
        #expect(r.isEmpty)
    }

    @Test func unknownSubjectReturnsEmpty() {
        let repo = makeRepo(branches: ["main", "feature/login"])
        let prefs = ChannelRoutingPreferences()
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/some/random/path",
            repos: [repo],
            preferences: prefs
        )
        #expect(r.isEmpty)
    }

    @Test func singleWorktreeRepoOnlyDispatchesToWorktreeIfSet() {
        let repo = makeRepo(branches: ["main"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.worktree, .root, .otherWorktrees]
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi",
            repos: [repo],
            preferences: prefs
        )
        // Single-worktree repo: only the worktree cell matters; it's the subject.
        #expect(r == ["/r/multi"])
    }

    @Test func singleWorktreeRepoEmptyWhenWorktreeCellOff() {
        let repo = makeRepo(branches: ["main"])
        var prefs = ChannelRoutingPreferences()
        prefs.prStateChanged = [.root, .otherWorktrees]   // worktree NOT set
        let r = ChannelEventRouter.recipients(
            event: .prStateChanged,
            subjectWorktreePath: "/r/multi",
            repos: [repo],
            preferences: prefs
        )
        #expect(r.isEmpty)
    }
}
```

The fixture `TeamTestFixtures.makeRepo(branches:)` already exists in `Tests/GrafttyKitTests/Teams/TeamTestFixtures.swift` from the previous feature.

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter ChannelEventRouter 2>&1 | tail -5
```

Expected: FAIL — `ChannelEventRouter` undefined.

- [ ] **Step 3: Create `Sources/GrafttyKit/Channels/ChannelEventRouter.swift`**

```swift
import Foundation

/// Resolves the set of recipient worktree paths for a routable channel event,
/// given the event's subject, the repo state, and the user's routing matrix.
/// Implements TEAM-1.9.
public enum ChannelEventRouter {

    public static func recipients(
        event: RoutableEvent,
        subjectWorktreePath: String,
        repos: [RepoEntry],
        preferences: ChannelRoutingPreferences
    ) -> [String] {
        // Find the repo that contains the subject worktree.
        guard let repo = repos.first(where: { repo in
            repo.worktrees.contains(where: { $0.path == subjectWorktreePath })
        }) else {
            return []
        }

        let row = event.recipientSet(in: preferences)

        // Single-worktree repos: only the worktree cell is meaningful.
        // Root + otherWorktrees cells are no-ops because there is no team.
        if repo.worktrees.count < 2 {
            return row.contains(.worktree) ? [subjectWorktreePath] : []
        }

        var paths: [String] = []
        if row.contains(.root) {
            paths.append(repo.path)
        }
        if row.contains(.worktree) {
            paths.append(subjectWorktreePath)
        }
        if row.contains(.otherWorktrees) {
            for wt in repo.worktrees
                where wt.path != subjectWorktreePath && wt.path != repo.path {
                paths.append(wt.path)
            }
        }

        // Dedupe while preserving order: the subject may equal the root.
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter ChannelEventRouter 2>&1 | tail -5
```

Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Channels/ChannelEventRouter.swift Tests/GrafttyKitTests/Channels/ChannelEventRouterTests.swift
git commit -m "feat(teams): ChannelEventRouter recipient resolver (TEAM-1.9)"
```

---

### Task 7: EventBodyRenderer — Stencil per-delivery

**Files:**
- Create: `Sources/GrafttyKit/Channels/EventBodyRenderer.swift`
- Test: `Tests/GrafttyKitTests/Channels/EventBodyRendererTests.swift`

Renders `teamPrompt` per delivery and prepends to the event body. Returns the original event unchanged on empty template, empty render, or render failure.

- [ ] **Step 1: Write failing tests**

Create `Tests/GrafttyKitTests/Channels/EventBodyRendererTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("EventBodyRenderer")
struct EventBodyRendererTests {

    private func makeRepo() -> RepoEntry {
        TeamTestFixtures.makeRepo(branches: ["main", "feature/login"])
    }

    private func makeEvent(_ body: String = "PR #42 merged.") -> ChannelServerMessage {
        .event(type: "pr_state_changed", attrs: ["to": "merged"], body: body)
    }

    @Test func emptyTemplatePassesThrough() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: ""
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event variant"); return
        }
        #expect(body == "PR #42 merged.")
    }

    @Test func happyPathPrependsRendered() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "Lead got an event."
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body == "Lead got an event.\n\nPR #42 merged.")
    }

    @Test func leadFlagIsTrueForRootRecipient() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.lead %}LEAD{% else %}NOT_LEAD{% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("LEAD"))
    }

    @Test func leadFlagIsFalseForCoworker() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi/.worktrees/feature-login",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.lead %}LEAD{% else %}NOT_LEAD{% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("NOT_LEAD"))
    }

    @Test func thisWorktreeFlagIsTrueWhenRecipientIsSubject() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi/.worktrees/feature-login",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.this_worktree %}MINE{% else %}NOT_MINE{% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("MINE"))
    }

    @Test func otherWorktreeFlagIsTrueWhenRecipientIsNotSubject() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.other_worktree %}OTHER{% else %}NOT_OTHER{% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("OTHER"))
    }

    @Test func nilSubjectMakesBothPerEventFlagsFalse() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: .event(type: "team_message", attrs: ["from": "lead"], body: "hi"),
            recipientWorktreePath: "/r/multi/.worktrees/feature-login",
            subjectWorktreePath: nil,
            repos: [repo],
            templateString: "{% if agent.this_worktree %}T{% endif %}{% if agent.other_worktree %}O{% endif %}NEITHER"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body.hasPrefix("NEITHER"))
    }

    @Test func renderFailureFallsBackToOriginal() {
        let repo = makeRepo()
        // Unbalanced tags — Stencil throws.
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.lead %}unclosed"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body == "PR #42 merged.")
    }

    @Test func whitespaceOnlyRenderSkipsPrepend() {
        let repo = makeRepo()
        let result = EventBodyRenderer.body(
            for: makeEvent(),
            recipientWorktreePath: "/r/multi",
            subjectWorktreePath: "/r/multi/.worktrees/feature-login",
            repos: [repo],
            templateString: "{% if agent.lead %}  {% endif %}"
        )
        guard case let .event(_, _, body) = result else {
            Issue.record("expected .event"); return
        }
        #expect(body == "PR #42 merged.")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
swift test --filter EventBodyRenderer 2>&1 | tail -5
```

Expected: FAIL — `EventBodyRenderer` undefined.

- [ ] **Step 3: Create `Sources/GrafttyKit/Channels/EventBodyRenderer.swift`**

```swift
import Foundation
import os
import Stencil

/// Renders the user's `teamPrompt` Stencil template against the per-delivery
/// `agent` context and returns a `ChannelServerMessage` with the rendered text
/// prepended to the body. On empty template, empty render, or render failure,
/// returns the original event unchanged. Implements TEAM-3.3.
public enum EventBodyRenderer {

    private static let logger = Logger(subsystem: "com.btucker.graftty", category: "EventBodyRenderer")

    public static func body(
        for event: ChannelServerMessage,
        recipientWorktreePath: String,
        subjectWorktreePath: String?,
        repos: [RepoEntry],
        templateString: String
    ) -> ChannelServerMessage {
        // Empty template = passthrough.
        guard !templateString.isEmpty else { return event }
        guard case let .event(type, attrs, originalBody) = event else { return event }

        // Compute the agent context for this delivery.
        let recipientRepo = repos.first { repo in
            repo.worktrees.contains(where: { $0.path == recipientWorktreePath })
        }
        let recipient = recipientRepo?.worktrees.first(where: { $0.path == recipientWorktreePath })

        let isLead = (recipientRepo?.path == recipientWorktreePath)
        let isThisWorktree: Bool = {
            guard let subject = subjectWorktreePath else { return false }
            return subject == recipientWorktreePath
        }()
        let isOtherWorktree: Bool = {
            guard let subject = subjectWorktreePath else { return false }
            return subject != recipientWorktreePath
        }()

        let context: [String: Any] = [
            "agent": [
                "branch": recipient?.branch ?? "",
                "lead": isLead,
                "this_worktree": isThisWorktree,
                "other_worktree": isOtherWorktree,
            ]
        ]

        // Render. Stencil throws on parse / runtime errors; on failure, return
        // the original event so the agent still receives it (just without the
        // user-contributed prefix).
        let rendered: String
        do {
            rendered = try Environment().renderTemplate(string: templateString, context: context)
        } catch {
            logger.error("teamPrompt render failed: \(error.localizedDescription, privacy: .public)")
            return event
        }

        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return event }

        return .event(type: type, attrs: attrs, body: "\(trimmed)\n\n\(originalBody)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
swift test --filter EventBodyRenderer 2>&1 | tail -5
```

Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Channels/EventBodyRenderer.swift Tests/GrafttyKitTests/Channels/EventBodyRendererTests.swift
git commit -m "feat(teams): EventBodyRenderer Stencil per-delivery (TEAM-3.3)"
```

---

### Task 8: ChannelRoutingMatrixView (UI)

**Files:**
- Create: `Sources/Graftty/Views/Settings/ChannelRoutingMatrixView.swift`

The matrix view: a 4×3 `Grid` of toggles, header row with column labels, each cell a `Toggle("", isOn: $binding).toggleStyle(.checkbox)`. Bound to the `ChannelRoutingPreferences` via a `Binding<ChannelRoutingPreferences>`.

- [ ] **Step 1: Create the file**

```swift
import SwiftUI
import GrafttyKit

/// 4×3 routing matrix UI (TEAM-1.8). Each cell binds to one bit of the
/// corresponding `RecipientSet` field on `ChannelRoutingPreferences`.
struct ChannelRoutingMatrixView: View {
    @Binding var prefs: ChannelRoutingPreferences

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            // Header
            GridRow {
                Text("")
                Text("Root agent")
                    .font(.caption.weight(.semibold))
                    .gridColumnAlignment(.center)
                Text("Worktree agent")
                    .font(.caption.weight(.semibold))
                    .gridColumnAlignment(.center)
                Text("Other worktree agents")
                    .font(.caption.weight(.semibold))
                    .gridColumnAlignment(.center)
            }
            Divider().gridCellColumns(4)

            row("PR/MR state changed",     keyPath: \.prStateChanged)
            row("PR/MR merged",            keyPath: \.prMerged)
            row("CI conclusion changed",   keyPath: \.ciConclusionChanged)
            row("Mergability changed",     keyPath: \.mergabilityChanged)
        }
    }

    @ViewBuilder
    private func row(
        _ label: String,
        keyPath: WritableKeyPath<ChannelRoutingPreferences, RecipientSet>
    ) -> some View {
        GridRow {
            Text(label)
            cellToggle(keyPath: keyPath, recipient: .root)
            cellToggle(keyPath: keyPath, recipient: .worktree)
            cellToggle(keyPath: keyPath, recipient: .otherWorktrees)
        }
    }

    private func cellToggle(
        keyPath: WritableKeyPath<ChannelRoutingPreferences, RecipientSet>,
        recipient: RecipientSet
    ) -> some View {
        Toggle("", isOn: Binding<Bool>(
            get: { prefs[keyPath: keyPath].contains(recipient) },
            set: { newValue in
                if newValue { prefs[keyPath: keyPath].insert(recipient) }
                else        { prefs[keyPath: keyPath].remove(recipient) }
            }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .gridColumnAlignment(.center)
    }
}
```

- [ ] **Step 2: Build to verify the new view compiles**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds. (No tests added — this is SwiftUI; the integration test happens in Task 11 manual verification.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Views/Settings/ChannelRoutingMatrixView.swift
git commit -m "feat(teams): ChannelRoutingMatrixView 4x3 toggle grid (TEAM-1.8)"
```

---

### Task 9: Retire `team_pr_merged` everywhere

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamChannelEvents.swift`
- Modify: `Sources/GrafttyKit/Teams/TeamMembershipEvents.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Delete: `Tests/GrafttyKitTests/PRStatus/TeamPRMergedDispatchTests.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamChannelEventsTests.swift`

`team_pr_merged` is being retired. PR-merge notifications now flow as `pr_state_changed` with `attrs.to == "merged"`, routed by the matrix.

- [ ] **Step 1: Drop `prMerged(...)` builder + EventType constant from `TeamChannelEvents.swift`**

Open `Sources/GrafttyKit/Teams/TeamChannelEvents.swift`. Find and delete:

- The line `public static let prMerged = "team_pr_merged"` (inside the `EventType` enum)
- The entire `public static func prMerged(...)` method

Save.

- [ ] **Step 2: Drop the `firePRMerged(...)` helper from `TeamMembershipEvents.swift`**

Open `Sources/GrafttyKit/Teams/TeamMembershipEvents.swift`. Find and delete the entire `public static func firePRMerged(...)` method. Save.

- [ ] **Step 3: Drop the team_pr_merged dispatch site from `AppServices.init`**

In `Sources/Graftty/GrafttyApp.swift`, find the existing `prStatusStore.onTransition` closure. Inside it (after the standard `router.dispatch(...)` call), remove the conditional block that classifies merged transitions and calls `TeamMembershipEvents.firePRMerged(...)`. The closure should at this point only call `router.dispatch` for the wire event — Task 13 rewrites it more substantially.

- [ ] **Step 4: Delete `Tests/GrafttyKitTests/PRStatus/TeamPRMergedDispatchTests.swift`**

```bash
git rm Tests/GrafttyKitTests/PRStatus/TeamPRMergedDispatchTests.swift
```

(`git rm` deletes the file and stages the removal.)

- [ ] **Step 5: Drop the `prMerged*` tests from `TeamChannelEventsTests.swift`**

Open `Tests/GrafttyKitTests/Teams/TeamChannelEventsTests.swift`. Find and delete the entire test methods named `prMergedFullPayload` and `prMergedOmitsEmptyMergeSha`. The other tests (`teamMessageEventShape`, `memberJoinedEventShape`, `memberLeftReasonRendered`) stay.

- [ ] **Step 6: Build + run tests**

```bash
swift build && swift test 2>&1 | tail -5
```

Expected: build succeeds; tests pass with a slightly lower count (tests deleted).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(teams): retire team_pr_merged event (TEAM-5.4 removed)"
```

---

### Task 10: TeamInstructionsRenderer — update event list

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift`

The lead-variant rendering currently lists `team_pr_merged` in the documented event types. Replace with `pr_state_changed`, `ci_conclusion_changed`, `merge_state_changed`. The coworker variant doesn't enumerate events — leave it.

- [ ] **Step 1: Update the lead variant string**

Open `Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift`. Find the multi-line string literal in `renderLead(...)`. Locate the lines:

```
  - team_member_joined — a new coworker joined; attrs: team, member, branch, worktree.
  - team_member_left   — a coworker left; attrs: team, member, reason (removed | exited).
  - team_pr_merged     — a coworker's PR merged; attrs: team, member, pr_number, branch.
```

Replace those three lines with:

```
  - team_member_joined — a new coworker joined; attrs: team, member, branch, worktree.
  - team_member_left   — a coworker left; attrs: team, member, reason (removed | exited).
  - pr_state_changed   — a worktree's PR transitioned (open/closed/merged); routing per matrix.
  - ci_conclusion_changed — a worktree's CI conclusion changed; routing per matrix.
  - merge_state_changed — a worktree's PR mergability changed; routing per matrix.
```

- [ ] **Step 2: Update the corresponding test**

Open `Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift`. Find the `leadVariantDocumentsTeamEvents` test. Replace its body's expectation that `team_pr_merged` is mentioned with expectations for the three new event names:

```swift
@Test func leadVariantDocumentsTeamEvents() {
    let view = makeView()
    let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.lead)
    #expect(prompt.contains("team_member_joined"))
    #expect(prompt.contains("team_member_left"))
    #expect(prompt.contains("team_message"))
    #expect(prompt.contains("pr_state_changed"))
    #expect(prompt.contains("ci_conclusion_changed"))
    #expect(prompt.contains("merge_state_changed"))
    #expect(!prompt.contains("team_pr_merged"))
}
```

- [ ] **Step 3: Run the test**

```bash
swift test --filter TeamInstructionsRenderer 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift
git commit -m "feat(teams): TeamInstructionsRenderer documents matrix-routed events"
```

---

### Task 11: AgentTeamsSettingsPane — matrix + two prompts

**Files:**
- Modify: `Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift`
- Modify: `Tests/GrafttyTests/Settings/AgentTeamsSettingsPaneTests.swift`

Replace the *Notify team about GitHub/GitLab PR activity* checkbox with the matrix view; replace the two role-specific prompt fields with the two purpose-specific prompt fields. The launch-flag panel (TEAM-1.7) stays.

- [ ] **Step 1: Read the current pane**

```bash
cat Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift
```

Note the structure of existing Sections (toggle Section, Channels-disclosure, prompt Sections, launch-flag Section).

- [ ] **Step 2: Rewrite the pane**

Replace `Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift` with:

```swift
import SwiftUI
import GrafttyKit

/// Settings pane that exposes the `agentTeamsEnabled` toggle, the channel
/// routing matrix (TEAM-1.8), the launch-flag disclosure (TEAM-1.7), and the
/// two user-editable prompts (TEAM-1.6).
struct AgentTeamsSettingsPane: View {
    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false
    @AppStorage("teamSessionPrompt") private var teamSessionPrompt: String = ""
    @AppStorage("teamPrompt") private var teamPrompt: String = ""
    @AppStorage("channelRoutingPreferences") private var channelRoutingPreferences = ChannelRoutingPreferences()

    static let launchFlag = "--dangerously-load-development-channels server:graftty-channel"

    var body: some View {
        Form {
            Section {
                Toggle("Enable agent teams", isOn: $agentTeamsEnabled)
            } footer: {
                Text("When on, every Claude pane Graftty launches in a multi-worktree repo participates in a team. Add the launch flag below to your `claude` invocation for channel events to flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if agentTeamsEnabled {
                Section("Launch Claude with this flag") {
                    HStack {
                        Text(Self.launchFlag)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            #if os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.launchFlag, forType: .string)
                            #endif
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy")
                    }
                } footer: {
                    Text("Add this flag to your `claude` invocation (e.g., the Default Command field on the General Settings pane) for channel events to flow into the session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Channel routing") {
                    ChannelRoutingMatrixView(prefs: $channelRoutingPreferences)
                } footer: {
                    Text("Choose which agents receive each automated channel message. \"Worktree agent\" means the agent in the worktree the event is about (e.g., the branch whose CI just failed); \"Other worktree agents\" means every other coworker in the same repo. Use the prompt below to define what each agent should do when it receives an event.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Session prompt") {
                    TextEditor(text: $teamSessionPrompt)
                        .frame(minHeight: 100)
                        .font(.system(.body, design: .monospaced))
                    DisclosureGroup("Available variables in your template") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("agent.branch (String) — agent's branch.")
                            Text("agent.lead (Bool) — true iff this agent is the team's lead.")
                            Text("agent.this_worktree (Bool) — always false (no event yet).")
                            Text("agent.other_worktree (Bool) — always false (no event yet).")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Stencil template rendered once when each Claude session starts. Appended to that session's MCP instructions, so it stays in the agent's system context for the whole session. Useful for stable team-level coordination policy that doesn't depend on individual events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Per-event prompt") {
                    TextEditor(text: $teamPrompt)
                        .frame(minHeight: 100)
                        .font(.system(.body, design: .monospaced))
                    DisclosureGroup("Available variables in your template") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("agent.branch (String) — agent's branch.")
                            Text("agent.lead (Bool) — true iff this agent is the team's lead.")
                            Text("agent.this_worktree (Bool) — true iff event is about agent's own worktree.")
                            Text("agent.other_worktree (Bool) — true iff event is about a different worktree.")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Stencil template rendered freshly for each channel event delivered to each agent. The rendered text is prepended to the event the agent receives. Useful for event-aware reactions — branch on agent.this_worktree to react differently when the event is about the agent's own worktree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 360)
    }
}
```

- [ ] **Step 3: Update the test file**

Open `Tests/GrafttyTests/Settings/AgentTeamsSettingsPaneTests.swift`. Delete any tests that reference `applyTeamModeToggleSideEffects`, `applyChannelsToggleSideEffects`, `teamLeadPrompt`, or `teamCoworkerPrompt`. (Some of these were already removed in the prior feature; double-check what's there.)

Replace the file contents with:

```swift
import Testing
import SwiftUI
@testable import Graftty

@Suite("AgentTeamsSettingsPane Tests")
struct AgentTeamsSettingsPaneTests {

    @Test func teamSessionPromptDefaultsToEmpty() {
        let defaults = UserDefaults(suiteName: "AgentTeamsPaneTests-1")!
        defaults.removePersistentDomain(forName: "AgentTeamsPaneTests-1")
        let value = defaults.string(forKey: "teamSessionPrompt") ?? ""
        #expect(value.isEmpty)
    }

    @Test func teamPromptDefaultsToEmpty() {
        let defaults = UserDefaults(suiteName: "AgentTeamsPaneTests-2")!
        defaults.removePersistentDomain(forName: "AgentTeamsPaneTests-2")
        let value = defaults.string(forKey: "teamPrompt") ?? ""
        #expect(value.isEmpty)
    }

    @Test func teamSessionPromptAndTeamPromptAreIndependent() {
        let defaults = UserDefaults(suiteName: "AgentTeamsPaneTests-3")!
        defaults.removePersistentDomain(forName: "AgentTeamsPaneTests-3")
        defaults.set("session", forKey: "teamSessionPrompt")
        defaults.set("event",   forKey: "teamPrompt")
        #expect(defaults.string(forKey: "teamSessionPrompt") == "session")
        #expect(defaults.string(forKey: "teamPrompt") == "event")
    }
}
```

- [ ] **Step 4: Build and run tests**

```bash
swift build 2>&1 | tail -5 && swift test --filter AgentTeamsSettings 2>&1 | tail -5
```

Expected: build succeeds, tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift Tests/GrafttyTests/Settings/AgentTeamsSettingsPaneTests.swift
git commit -m "feat(teams): AgentTeamsSettingsPane matrix + two prompts (TEAM-1.6, 1.8)"
```

---

### Task 12: ChannelSettingsObserver — render `teamSessionPrompt` into MCP instructions

**Files:**
- Modify: `Sources/Graftty/Channels/ChannelSettingsObserver.swift`

`composedPrompt(forWorktree:)` currently appends one of (`teamLeadPrompt` | `teamCoworkerPrompt`) to the team-aware text. Replace with: render `teamSessionPrompt` as a Stencil template against the `agent` context for this worktree at session start; append after a blank line if non-empty.

- [ ] **Step 1: Read the current `composedPrompt(forWorktree:)` and KVO observation**

```bash
grep -n "composedPrompt\\|teamLeadPrompt\\|teamCoworkerPrompt\\|channelPrompt\\|teamPrompt\\|teamSessionPrompt" Sources/Graftty/Channels/ChannelSettingsObserver.swift
```

Note where the prompt logic lives and where the KVO publishers are wired.

- [ ] **Step 2: Replace `composedPrompt(forWorktree:)`**

Replace the body of `private func composedPrompt(forWorktree worktreePath: String) -> String` with:

```swift
private func composedPrompt(forWorktree worktreePath: String) -> String {
    let teamsEnabled = UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled)
    guard teamsEnabled,
          let appState = appStateProvider?(),
          let worktree = appState.worktree(forPath: worktreePath),
          let team = TeamView.team(for: worktree, in: appState.repos, teamsEnabled: true),
          let me = team.members.first(where: { $0.worktreePath == worktreePath })
    else {
        return ""
    }

    let teamInstructions = TeamInstructionsRenderer.render(team: team, viewer: me)

    let template = UserDefaults.standard.string(forKey: SettingsKeys.teamSessionPrompt) ?? ""
    guard !template.isEmpty else { return teamInstructions }

    let context: [String: Any] = [
        "agent": [
            "branch": me.branch,
            "lead": me.role == .lead,
            "this_worktree": false,
            "other_worktree": false,
        ]
    ]

    let rendered: String
    do {
        rendered = try Stencil.Environment().renderTemplate(string: template, context: context)
    } catch {
        os_log(.error, "teamSessionPrompt render failed: %{public}@", error.localizedDescription)
        return teamInstructions
    }

    let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? teamInstructions : "\(teamInstructions)\n\n\(trimmed)"
}
```

Add the imports at the top of the file if not already present:

```swift
import Stencil
import os
```

- [ ] **Step 3: Update KVO observers**

Find the KVO observation section that previously observed `teamLeadPrompt` + `teamCoworkerPrompt` (or `channelPrompt`). Replace with:

```swift
UserDefaults.standard.publisher(for: \.teamSessionPrompt)
    .dropFirst()
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.router?.broadcastInstructions() }
    .store(in: &cancellables)
```

If a publisher for `teamPrompt` was previously observed (it shouldn't have been for MCP instructions), remove it — `teamPrompt` is consumed fresh per event by `EventBodyRenderer`, not observed for broadcasts.

Add a `UserDefaults` extension property for KVO if not already present:

```swift
extension UserDefaults {
    @objc dynamic var teamSessionPrompt: String {
        get { string(forKey: SettingsKeys.teamSessionPrompt) ?? "" }
    }
}
```

(Mirror the pattern already used for the existing observed keys.)

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: success. (No new tests — the integration test happens in step 5 of the broader plan via existing ChannelRouterTeamIntegrationTests.)

- [ ] **Step 5: Run all existing tests**

```bash
swift test 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/Channels/ChannelSettingsObserver.swift
git commit -m "feat(teams): composedPrompt renders teamSessionPrompt into MCP instructions (TEAM-3.3)"
```

---

### Task 13: Rewrite `onTransition` closure with matrix + body rendering

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

The existing `prStatusStore.onTransition` closure dispatches one event per transition. Replace it with a closure that:

1. Classifies the message via `RoutableEvent`.
2. Resolves recipients via `ChannelEventRouter.recipients`.
3. For each recipient, runs `EventBodyRenderer.body(...)` to produce a per-recipient body.
4. Dispatches the rendered event.

- [ ] **Step 1: Find the closure**

```bash
grep -n "prStatusStore.onTransition" Sources/Graftty/GrafttyApp.swift
```

- [ ] **Step 2: Replace the closure**

Replace the entire `prStatusStore.onTransition = { ... }` assignment with:

```swift
self.prStatusStore.onTransition = { [weak router, weak self] subjectWorktreePath, message in
    guard let router, let self else { return }
    guard UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled) else { return }
    guard case let .event(_, attrs, _) = message,
          let routableEvent = RoutableEvent(
              channelEventType: messageType(message),
              attrs: attrs
          )
    else {
        // Non-routable channel events still get dispatched to the originating worktree.
        router.dispatch(worktreePath: subjectWorktreePath, message: message)
        return
    }

    let prefsRaw = UserDefaults.standard.string(forKey: SettingsKeys.channelRoutingPreferences) ?? ""
    let prefs = ChannelRoutingPreferences(rawValue: prefsRaw) ?? ChannelRoutingPreferences()

    let appState = self.appStateProvider?() ?? AppState()
    let recipients = ChannelEventRouter.recipients(
        event: routableEvent,
        subjectWorktreePath: subjectWorktreePath,
        repos: appState.repos,
        preferences: prefs
    )

    let template = UserDefaults.standard.string(forKey: SettingsKeys.teamPrompt) ?? ""

    for recipient in recipients {
        let renderedMessage = EventBodyRenderer.body(
            for: message,
            recipientWorktreePath: recipient,
            subjectWorktreePath: subjectWorktreePath,
            repos: appState.repos,
            templateString: template
        )
        router.dispatch(worktreePath: recipient, message: renderedMessage)
    }
}
```

Add a small helper at file scope (or inside `AppServices`) to extract the event type string from a `ChannelServerMessage`:

```swift
private func messageType(_ message: ChannelServerMessage) -> String {
    if case let .event(type, _, _) = message { return type }
    return ""
}
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 4: Run all tests**

```bash
swift test 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "feat(teams): onTransition routes via matrix + EventBodyRenderer (TEAM-1.9, TEAM-3.3)"
```

---

### Task 14: Wire EventBodyRenderer into `team_message`, `team_member_joined`, `team_member_left` dispatch sites

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift` (the `.teamMessage` socket handler)
- Modify: `Sources/GrafttyKit/Teams/TeamMembershipEvents.swift`

Per TEAM-3.3, every channel event flowing through `ChannelRouter.dispatch` should run through `EventBodyRenderer` so the user's `teamPrompt` template is prepended. Tasks 9–13 covered the routable PR/CI events; this task covers the team-internal events.

- [ ] **Step 1: Update `.teamMessage` handler**

In `Sources/Graftty/GrafttyApp.swift`, find the case-`.teamMessage` block in the socket dispatcher (where `TeamChannelEvents.teamMessage(...)` is built and `channelRouter.dispatch(...)` is called). Replace the `dispatch` call with:

```swift
let template = UserDefaults.standard.string(forKey: SettingsKeys.teamPrompt) ?? ""
let renderedMessage = EventBodyRenderer.body(
    for: TeamChannelEvents.teamMessage(
        team: team.repoDisplayName,
        from: senderMember.name,
        text: text
    ),
    recipientWorktreePath: recipientMember.worktreePath,
    subjectWorktreePath: nil,           // team_message has no worktree subject
    repos: appState.repos,
    templateString: template
)
channelRouter.dispatch(
    worktreePath: recipientMember.worktreePath,
    message: renderedMessage
)
```

(The exact local variable names — `team`, `senderMember`, `recipientMember`, `appState` — match the existing handler's locals.)

- [ ] **Step 2: Update `TeamMembershipEvents.fireJoined` and `fireLeft`**

In `Sources/GrafttyKit/Teams/TeamMembershipEvents.swift`, the two helpers each call a `dispatch` closure with a built event. Their callers (in `AddWorktreeFlow`, `MainWindow`, `GrafttyApp` web closure) should run the event through `EventBodyRenderer` before passing it to `dispatch`.

The cleanest seam: leave `TeamMembershipEvents` unchanged at its dispatch-callback signature (it shouldn't know about `EventBodyRenderer`); update each *caller* to wrap the dispatch closure.

For each caller (`AddWorktreeFlow.swift`, `MainWindow.swift`, the web closure in `GrafttyApp.swift`'s `setWorktreeCreator`), change the dispatch closure passed into `fireJoined` / `fireLeft`. Old form:

```swift
dispatch: { path, msg in router.dispatch(worktreePath: path, message: msg) }
```

New form:

```swift
dispatch: { [appState, router] path, msg in
    let template = UserDefaults.standard.string(forKey: SettingsKeys.teamPrompt) ?? ""
    let rendered = EventBodyRenderer.body(
        for: msg,
        recipientWorktreePath: path,
        subjectWorktreePath: { () -> String? in
            // member_joined/member_left attrs include the joiner/leaver's worktree path.
            if case let .event(_, attrs, _) = msg { return attrs["worktree"] }
            return nil
        }(),
        repos: appState.repos,
        templateString: template
    )
    router.dispatch(worktreePath: path, message: rendered)
}
```

Note: the `member_joined` event's `attrs.worktree` is the joiner's worktree — that's the subject. For `member_left`, the event's `attrs.member` is the leaver's name; if the worktree is no longer in the repo (it's been removed), `subjectWorktreePath` is nil and `agent.this_worktree` / `agent.other_worktree` are both `false`. That's fine — the template can detect "no subject" and render appropriate guidance.

If `attrs["worktree"]` isn't present in `member_left` events (currently it isn't), pass `nil` for `subjectWorktreePath`. The template gets both per-event flags as false; the user can detect `not agent.this_worktree and not agent.other_worktree` and react accordingly.

- [ ] **Step 3: Build + run tests**

```bash
swift build 2>&1 | tail -10 && swift test 2>&1 | tail -5
```

Expected: build succeeds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/AddWorktreeFlow.swift Sources/Graftty/Views/MainWindow.swift Sources/GrafttyKit/Teams/TeamMembershipEvents.swift
git commit -m "feat(teams): EventBodyRenderer wired into peer + membership events (TEAM-3.3)"
```

---

## Verification (after all tasks complete)

- [ ] **Step 1: Full test suite**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass. Count should be ≈ previous count − some deleted tests + some new tests.

- [ ] **Step 2: Build the app bundle**

```bash
swift build
```

Expected: success, no warnings.

- [ ] **Step 3: Manual end-to-end check**

In a running Graftty:

1. Open Settings → Agent Teams. Confirm:
   - The matrix appears with 4 rows × 3 columns of checkboxes; defaults match (worktree-only for state/CI/mergability, root-only for merged).
   - Two prompt sections: "Session prompt" and "Per-event prompt", both with empty defaults and "Available variables" disclosures.
   - The "Launch Claude with this flag" panel still appears.

2. Toggle a matrix cell on (e.g., add "Root agent" to *CI conclusion changed*). Confirm the change persists after closing and reopening Settings.

3. Type a session prompt: `{% if agent.lead %}You are the lead.{% endif %}`. Open a Claude pane in a multi-worktree-team-enabled repo. Verify the rendered text appears in the pane's MCP instructions / channels prompt context.

4. Type a per-event prompt: `{% if agent.this_worktree %}MINE!{% endif %}`. Trigger a `pr_state_changed` event (or simulate via PRStatusStore in a debug build). Verify the recipient who is the subject worktree sees `MINE!` prepended to the event body.

- [ ] **Step 4: `/simplify`**

Per the project's standard finishing workflow.

- [ ] **Step 5: Push and confirm CI passes**

```bash
git push
gh pr checks 86
```

Confirm green CI before reporting work complete.
