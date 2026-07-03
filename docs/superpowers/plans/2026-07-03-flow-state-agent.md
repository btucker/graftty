# Flow State Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Graftty's Flow State feature: a top-level sidebar focus surface backed by a persistent Claude/Codex agent that coordinates through `graftty flow`.

**Architecture:** Add Flow State as a first-class GrafttyKit domain with strict Codable envelopes, disk-backed memory, and pure context-building. Expose that domain through the existing Unix-socket CLI protocol, then wire the macOS app to render the latest recommendation and manage the persistent Flow State agent pane/session. Keep side-effect guardrails in Swift; the agent's prompt is guidance, not the permission source.

**Tech Stack:** Swift 5.10, Swift Testing, SwiftUI/AppKit, swift-argument-parser, existing `NotificationMessage` socket protocol, zmx/libghostty pane infrastructure.

---

## Scope And Sequencing

This is one feature, but it crosses several seams. Implement sequentially with one subagent per task. Do not dispatch multiple implementation subagents in parallel: the tasks share protocol and app-state files.

Implementation order:

1. Flow State models and store in `GrafttyKit`.
2. Worktree snapshot/context builder in `GrafttyKit`.
3. Socket protocol and `graftty flow` CLI.
4. App request handling and Flow State activity execution policy.
5. Activity log, refresh coordination, and policy-gated action execution.
6. Settings defaults and Flow State prompt/runtime controls.
7. Sidebar row and Flow State view.
8. Persistent Flow State agent lifecycle.
9. Final integration, specs regeneration, and full verification.

Every task should commit when green. If a task adds or changes `@spec` annotations, run `scripts/generate-specs.py` and include `SPECS.md` in that task's commit.

## File Structure

Create:

- `Sources/GrafttyKit/FlowState/FlowStateModels.swift`  
  Codable enums and envelopes for `flow publish`, `flow context`, summaries, snoozes, and status.
- `Sources/GrafttyKit/FlowState/FlowStateStore.swift`  
  Disk-backed storage under `AppState.defaultDirectory/flow-state/`.
- `Sources/GrafttyKit/FlowState/FlowStateContextBuilder.swift`  
  Pure builder that derives `FlowWorktreeSnapshot` arrays from `AppState` plus optional summaries/recommendation memory.
- `Sources/GrafttyKit/FlowState/FlowStateActionPolicy.swift`  
  Permission and confirmation policy for `proposedActions`.
- `Sources/GrafttyKit/FlowState/FlowStateActivityStore.swift`  
  Append-only Flow State activity/error log plus status-request cooldown bookkeeping.
- `Sources/GrafttyKit/FlowState/FlowStateRefreshCoordinator.swift`  
  Pure refresh trigger/cooldown decisions for view-open, focus-stability, attention, and background interval.
- `Sources/GrafttyKit/FlowState/FlowStateActionExecutor.swift`  
  Executes autonomous Flow State actions only when policy allows; produces confirmed-action requests for UI.
- `Sources/GrafttyCLI/Flow.swift`  
  `graftty flow ...` command group.
- `Sources/Graftty/Views/FlowState/FlowStateView.swift`  
  Main Flow State UI.
- `Sources/Graftty/Views/FlowState/FlowStateSidebarRow.swift`  
  Top sidebar row rendering.
- `Sources/Graftty/Settings/FlowStateDefaults.swift`  
  Default prompt and Flow State UserDefaults registration.
- `Sources/Graftty/Views/Settings/FlowStateSettingsPane.swift`  
  Settings section for runtime/prompt/lifecycle.
- `Sources/Graftty/FlowState/FlowStateAgentController.swift`  
  App-managed lifecycle for the persistent Flow State agent pane/session.
- `Sources/Graftty/FlowState/FlowStateSignalBuilder.swift`  
  App-target mapping from long-lived Graftty services into `FlowExternalSignals`.
- Tests under:
  - `Tests/GrafttyKitTests/FlowState/`
  - `Tests/GrafttyKitTests/FlowState/FlowStateTestSupport.swift`
  - `Tests/GrafttyKitTests/Notification/FlowStateProtocolTests.swift`
  - `Tests/GrafttyTests/CLI/FlowCommandTests.swift`
  - `Tests/GrafttyTests/FlowState/`
  - `Tests/GrafttyTests/Settings/FlowStateSettingsPaneTests.swift`
  - `Tests/GrafttyTests/Views/FlowStateViewTests.swift`

Modify:

- `Sources/GrafttyKit/Notification/NotificationMessage.swift`  
  Add flow request/response cases.
- `Sources/GrafttyCLI/CLI.swift`  
  Register `Flow.self`; update response exhaustiveness.
- `Sources/Graftty/GrafttyApp.swift`  
  Register defaults, initialize Flow State store/controller, handle flow socket requests, add Settings tab.
- `Sources/Graftty/Views/MainWindow.swift`  
  Add Flow State selection mode and detail rendering.
- `Sources/Graftty/Views/SidebarView.swift`  
  Add top-level Flow State row.
- `Sources/Graftty/Settings/SettingsKeys.swift`  
  Add Flow State keys.
- `Sources/Graftty/Settings/DefaultPrompts.swift`  
  Keep Agent Teams defaults unchanged; Flow State gets its own defaults file.
- `Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift`  
  Add round-trip coverage or create focused `FlowStateProtocolTests.swift`.
- `SPECS.md`  
  Regenerated from new `@spec` annotations.

---

### Task 1: Flow State Models And Store

**Files:**
- Create: `Sources/GrafttyKit/FlowState/FlowStateModels.swift`
- Create: `Sources/GrafttyKit/FlowState/FlowStateStore.swift`
- Create: `Tests/GrafttyKitTests/FlowState/FlowStateTestSupport.swift`
- Test: `Tests/GrafttyKitTests/FlowState/FlowStateModelsTests.swift`
- Test: `Tests/GrafttyKitTests/FlowState/FlowStateStoreTests.swift`

- [ ] **Step 1: Add shared Flow State test support**

Create `Tests/GrafttyKitTests/FlowState/FlowStateTestSupport.swift`:

```swift
import Foundation

func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("graftty-flow-state-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
```

All `GrafttyKitTests/FlowState` suites in this plan use this helper instead of
assuming an existing global `temporaryDirectory()` in the repo.

- [ ] **Step 2: Write failing model tests**

Create `Tests/GrafttyKitTests/FlowState/FlowStateModelsTests.swift` with Swift Testing coverage for the strict v1 schema:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateModels")
struct FlowStateModelsTests {
    @Test("@spec FLOW-1.1: When `graftty flow publish` receives a version-1 recommendation envelope with valid primary/list/action fields, the application shall decode and preserve it as Flow State's latest recommendation.")
    func validRecommendationEnvelopeDecodes() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {
            "worktreeRef": "graftty:multi-project-assistant",
            "intent": "stay",
            "title": "Stay in graftty",
            "reason": "Same repo decisions are cheaper than switching.",
            "confidence": "medium"
          },
          "sameContext": [{
            "worktreeRef": "graftty:review-fixes",
            "title": "Review fixes",
            "reason": "Same test context.",
            "estimatedEffort": "short",
            "confidence": "high"
          }],
          "heldInterruptions": [{
            "worktreeRef": "billing-api:ci-fix",
            "title": "CI failed",
            "reason": "Important but high reload cost.",
            "holdUntil": "next_focus_break",
            "urgency": "medium"
          }],
          "resumeCards": [{
            "worktreeRef": "mobile:pairing-polish",
            "title": "Pairing polish",
            "summary": "Waiting on visual QA.",
            "nextAction": "Review screenshot.",
            "stale": false
          }],
          "proposedActions": [{
            "id": "ask-status",
            "kind": "team_status_request",
            "target": "review-fixes",
            "body": "[Flow State] Please reply with status, blocker, next action, and whether you need the human.",
            "requiresConfirmation": false
          }]
        }
        """
        let envelope = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.primary.intent == .stay)
        #expect(envelope.sameContext.first?.estimatedEffort == .short)
        #expect(envelope.heldInterruptions.first?.holdUntil == .nextFocusBreak)
        #expect(envelope.resumeCards.first?.stale == false)
        #expect(envelope.proposedActions.first?.kind == .teamStatusRequest)
    }

    @Test("@spec FLOW-1.2: If a Flow State recommendation envelope contains an unknown enum value in any rendered or executable field, the application shall reject the publish rather than silently render incompatible state.")
    func unknownEnumValueFailsDecode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {
            "intent": "teleport",
            "title": "Bad",
            "reason": "Bad",
            "confidence": "medium"
          }
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        }
    }

    @Test("@spec FLOW-1.4: When a Flow State recommendation object contains unknown object fields, the application shall preserve those fields when storing and re-emitting the recommendation while ignoring them for v1 rendering.")
    func unknownObjectFieldsArePreserved() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {
            "intent": "none",
            "title": "No recommendation",
            "reason": "Idle",
            "confidence": "low",
            "futurePrimaryField": {"nested": true}
          },
          "futureTopLevelField": "keep me",
          "sameContext": [{
            "worktreeRef": "repo:feature",
            "title": "Feature",
            "reason": "Nearby",
            "futureListField": 42
          }]
        }
        """
        let decoded = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        let reencoded = try JSONEncoder.flowState.encode(decoded)
        let text = String(data: reencoded, encoding: .utf8) ?? ""
        #expect(text.contains("futureTopLevelField"))
        #expect(text.contains("futurePrimaryField"))
        #expect(text.contains("futureListField"))
    }

    @Test("@spec FLOW-1.5: Flow State shall reject recommendation envelopes with unsupported schema versions, missing required envelope fields, missing required primary fields, invalid action kinds, invalid action payloads, or unknown rendered list enum values.")
    func invalidRecommendationShapesFailDecode() throws {
        let invalidJSON: [String] = [
            #"{"schemaVersion":2,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"}}"#,
            #"{"schemaVersion":1,"primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"}}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z"}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","reason":"Idle","confidence":"low"}}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"},"proposedActions":[{"id":"x","kind":"teleport","target":"repo:feature"}]}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"},"proposedActions":[{"id":"x","kind":"team_status_request"}]}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"},"sameContext":[{"title":"Nearby","reason":"r","estimatedEffort":"forever","confidence":"low"}]}"#
        ]
        for json in invalidJSON {
            #expect(throws: Error.self) {
                _ = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
            }
        }
    }

    @Test("@spec FLOW-1.6: Flow State shall normalize omitted recommendation lists to empty arrays and default omitted resume-card stale state to false.")
    func omittedListsAndResumeStaleDefaults() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {"intent": "none", "title": "None", "reason": "Idle", "confidence": "low"},
          "resumeCards": [{"title": "Resume", "summary": "s", "nextAction": "n"}]
        }
        """
        let decoded = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        #expect(decoded.sameContext.isEmpty)
        #expect(decoded.heldInterruptions.isEmpty)
        #expect(decoded.proposedActions.isEmpty)
        #expect(decoded.resumeCards.first?.stale == false)
    }
}
```

- [ ] **Step 3: Write failing store tests**

Create `Tests/GrafttyKitTests/FlowState/FlowStateStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateStore")
struct FlowStateStoreTests {
    @Test("@spec FLOW-1.3: When Flow State stores a recommendation, summary, note, or snooze, the application shall persist it under the Flow State root and load it after store reinitialization.")
    func persistsRecommendationSummaryNoteAndSnooze() throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let generatedAt = Date(timeIntervalSince1970: 1_783_108_800)
        let recommendation = FlowRecommendationEnvelope(
            schemaVersion: 1,
            generatedAt: generatedAt,
            primary: FlowPrimaryRecommendation(
                worktreeRef: "repo:feature",
                intent: .stay,
                title: "Stay",
                reason: "Nearby work",
                confidence: .medium
            )
        )
        try store.writeRecommendation(recommendation)
        try store.writeSummary(FlowWorktreeSummary(
            worktreeRef: "repo:feature",
            updatedAt: generatedAt,
            summary: "Tests are running",
            nextAction: "Wait for tests",
            needsHuman: false
        ))
        try store.writeNote(FlowWorktreeNote(
            worktreeRef: "repo:feature",
            updatedAt: generatedAt,
            body: "User prefers to finish this repo first."
        ))
        try store.writeSnooze(FlowSnooze(
            worktreeRef: "repo:other",
            updatedAt: generatedAt,
            until: .nextFocusBreak,
            reason: "High reload cost"
        ))

        let reloaded = FlowStateStore(rootDirectory: root)
        #expect(try reloaded.recommendation()?.primary.title == "Stay")
        #expect(try reloaded.summaries()["repo:feature"]?.nextAction == "Wait for tests")
        #expect(try reloaded.notes()["repo:feature"]?.body.contains("finish this repo") == true)
        #expect(try reloaded.snoozes()["repo:other"]?.until == .nextFocusBreak)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run:

```bash
swift test --filter FlowStateModelsTests
swift test --filter FlowStateStoreTests
```

Expected: fail to compile because `FlowRecommendationEnvelope`, `FlowStateStore`, and related types do not exist.

- [ ] **Step 5: Implement models**

Create `Sources/GrafttyKit/FlowState/FlowStateModels.swift`. Include:

- `JSONDecoder.flowState` and `JSONEncoder.flowState` with ISO-8601 date handling.
- `FlowRecommendationEnvelope`.
- `FlowPrimaryRecommendation`.
- `FlowRecommendationIntent`.
- `FlowConfidence`.
- `FlowSameContextItem`.
- `FlowHeldInterruptionItem`.
- `FlowResumeCard`.
- `FlowProposedAction`.
- `FlowProposedActionKind`.
- `FlowEstimatedEffort`.
- `FlowUrgency`.
- `FlowHoldUntil` with string cases plus absolute timestamp support.
- `FlowWorktreeSummary`.
- `FlowWorktreeNote`.
- `FlowSnooze`.
- `FlowStatus`.
- `FlowPromptMode`: `.systemPrompt`, `.appendSystemPrompt`, `.bootstrapPrompt`,
  `.unavailable`; included in `FlowStatus` so Codex fallback mode is visible.
  `FlowStatus`'s public initializer defaults `promptMode` to `.unavailable`
  so existing status-only tests and call sites can stay concise.
- `FlowJSONValue`: a recursive JSON value enum for unknown-field preservation.

Custom decoding/encoding requirements:

- `FlowRecommendationEnvelope`, `FlowPrimaryRecommendation`, `FlowSameContextItem`,
  `FlowHeldInterruptionItem`, `FlowResumeCard`, and `FlowProposedAction` must
  capture unknown keyed fields into `extraFields: [String: FlowJSONValue]`.
- Re-encoding those objects must emit the known fields plus `extraFields`.
- Unknown enum values still fail decode; unknown object fields do not.
- `schemaVersion` must equal `1`; any other value fails decode.
- `generatedAt` and `primary` are required.
- Primary `intent`, `title`, `reason`, and `confidence` are required.
- Recommendation list fields default to `[]` when absent.
- `FlowResumeCard.stale` defaults to `false` when absent.
- `FlowProposedAction` validates required fields by kind:
  - `team_status_request` and `team_message`: require `target` and non-empty `body`.
  - `focus_worktree` and `restart_agent`: require `target`.
  - `pane_command`: require `target` and non-empty `body`.
- V1 UI/model code ignores `extraFields`; storage and CLI JSON output preserve them.

Keep all types `public`, `Codable`, `Sendable`, `Equatable` where possible. Add memberwise public initializers for tests and CLI construction.

- [ ] **Step 6: Implement store**

Create `Sources/GrafttyKit/FlowState/FlowStateStore.swift`:

```swift
public final class FlowStateStore: Sendable {
    public init(rootDirectory: URL)
    public static func defaultRoot() -> URL
    public static func defaultStore() -> FlowStateStore
    public func recommendation() throws -> FlowRecommendationEnvelope?
    public func writeRecommendation(_ envelope: FlowRecommendationEnvelope) throws
    public func summaries() throws -> [String: FlowWorktreeSummary]
    public func writeSummary(_ summary: FlowWorktreeSummary) throws
    public func notes() throws -> [String: FlowWorktreeNote]
    public func writeNote(_ note: FlowWorktreeNote) throws
    public func snoozes() throws -> [String: FlowSnooze]
    public func writeSnooze(_ snooze: FlowSnooze) throws
}
```

Use atomic writes via `Data.write(options: .atomic)`. Store:

- `latest-recommendation.json`
- `summaries/<safe-worktree-ref>.json`
- `notes/<safe-worktree-ref>.json`
- `snoozes/<safe-worktree-ref>.json`

Use a small private sanitizer that replaces `/`, `:`, and path separators with `_`; keep the original `worktreeRef` inside the JSON.

- [ ] **Step 7: Run focused tests**

Run:

```bash
swift test --filter FlowStateModelsTests
swift test --filter FlowStateStoreTests
```

Expected: pass.

- [ ] **Step 8: Regenerate specs and commit**

Run:

```bash
scripts/generate-specs.py
git status --short
git add Sources/GrafttyKit/FlowState Tests/GrafttyKitTests/FlowState SPECS.md
git commit -m "feat(flow): add Flow State models and store"
```

---

### Task 2: Worktree Snapshot And Context Builder

**Files:**
- Create: `Sources/GrafttyKit/FlowState/FlowStateContextBuilder.swift`
- Modify: `Sources/GrafttyKit/FlowState/FlowStateModels.swift`
- Test: `Tests/GrafttyKitTests/FlowState/FlowStateContextBuilderTests.swift`

- [ ] **Step 1: Write failing context tests**

Create `Tests/GrafttyKitTests/FlowState/FlowStateContextBuilderTests.swift`:

```swift
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("FlowStateContextBuilder")
struct FlowStateContextBuilderTests {
    @Test("@spec FLOW-2.1: `graftty flow context` shall expose each tracked worktree as a FlowWorktreeSnapshot with repo identity, worktree identity, selected/focused state, attention state, stored summary fields, scoring hints, and external git/agent signals when available.")
    func snapshotsIncludeWorktreeSignalsAndSummaries() throws {
        var wt = WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
        wt.setAttention(Attention(text: "Codex needs input", timestamp: Date(timeIntervalSince1970: 10), source: .agentStop), pane: nil)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [wt])
        let appState = AppState(repos: [repo], selectedWorktreePath: wt.path)
        let worktreeRef = FlowWorktreeIdentity.ref(repoDisplayName: "repo", repoPath: "/repo", worktreePath: wt.path, branch: wt.branch)
        let summary = FlowWorktreeSummary(
            worktreeRef: worktreeRef,
            updatedAt: Date(timeIntervalSince1970: 20),
            summary: "Agent is blocked on API choice.",
            nextAction: "Answer the API question.",
            needsHuman: true
        )

        let context = FlowStateContextBuilder.build(
            appState: appState,
            summaries: [worktreeRef: summary],
            notes: [:],
            snoozes: [:],
            signals: FlowExternalSignals(
                agentPresenceByWorktreeRef: [
                    worktreeRef: FlowAgentPresenceSnapshot(runtime: "codex", present: true, busy: false, waiting: true)
                ],
                gitByWorktreeRef: [
                    worktreeRef: FlowGitSnapshot(dirtyCount: 2, ahead: 1, behind: 0)
                ],
                prByWorktreeRef: [
                    worktreeRef: FlowPRSnapshot(number: 42, state: "open", ciConclusion: "failure", mergeState: "dirty")
                ],
                activityByWorktreeRef: [
                    worktreeRef: FlowActivitySnapshot(lastUserActivityAt: Date(timeIntervalSince1970: 12), lastAgentActivityAt: Date(timeIntervalSince1970: 18), lastFlowMessageAt: Date(timeIntervalSince1970: 19))
                ]
            ),
            now: Date(timeIntervalSince1970: 30)
        )

        let snapshot = try #require(context.worktrees.first)
        #expect(snapshot.repoName == "repo")
        #expect(snapshot.displayRef == "repo:feature")
        #expect(snapshot.worktreeRef.contains("repo#"))
        #expect(snapshot.selected == true)
        #expect(snapshot.attention?.text == "Codex needs input")
        #expect(snapshot.summary?.needsHuman == true)
        #expect(snapshot.agentPresence?.waiting == true)
        #expect(snapshot.git?.dirtyCount == 2)
        #expect(snapshot.pr?.ciConclusion == "failure")
        #expect(snapshot.lastFlowMessageAt == Date(timeIntervalSince1970: 19))
        #expect(snapshot.scoring.unlockValue == .high)
        #expect(snapshot.resumptionCostHint == .low)
    }

    @Test("@spec FLOW-2.2: When a worktree has no summary and ambiguous observable state, Flow State context shall mark the snapshot as unclear instead of inventing a next action.")
    func unclearWhenNoSummaryOrAttention() throws {
        let wt = WorktreeEntry(path: "/repo/.worktrees/old", branch: "old", state: .running)
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [wt])
        let context = FlowStateContextBuilder.build(
            appState: AppState(repos: [repo]),
            summaries: [:],
            notes: [:],
            snoozes: [:],
            signals: .empty,
            now: Date(timeIntervalSince1970: 30)
        )
        #expect(context.worktrees.first?.clarity == .unclear)
        #expect(context.worktrees.first?.nextAction == nil)
    }

    @Test("@spec FLOW-2.3: Flow State shall use collision-resistant worktree identities so two repositories with the same display name and branch cannot share summaries, snoozes, notes, or status-request cooldowns.")
    func worktreeIdentityDoesNotCollideAcrossSameNamedRepos() throws {
        let first = WorktreeEntry(path: "/one/app/.worktrees/feature", branch: "feature", state: .running)
        let second = WorktreeEntry(path: "/two/app/.worktrees/feature", branch: "feature", state: .running)
        let appState = AppState(repos: [
            RepoEntry(path: "/one/app", displayName: "app", worktrees: [first]),
            RepoEntry(path: "/two/app", displayName: "app", worktrees: [second])
        ])

        let context = FlowStateContextBuilder.build(appState: appState, summaries: [:], notes: [:], snoozes: [:], signals: .empty, now: Date(timeIntervalSince1970: 30))

        #expect(Set(context.worktrees.map(\.worktreeKey)).count == 2)
        #expect(Set(context.worktrees.map(\.worktreeRef)).count == 2)
        #expect(context.worktrees.allSatisfy { $0.displayRef == "app:feature" })
    }

    @Test("@spec FLOW-2.4: Flow State scoring shall preserve the current human context by ranking selected or same-repo low-reload work above unrelated failing CI unless the unrelated work is critical or explicitly higher payoff.")
    func scoringDoesNotDefaultToUrgencyFirst() throws {
        let current = WorktreeEntry(path: "/repo/.worktrees/current", branch: "current", state: .running)
        let remote = WorktreeEntry(path: "/other/.worktrees/ci", branch: "ci", state: .running)
        let appState = AppState(
            repos: [
                RepoEntry(path: "/repo", displayName: "repo", worktrees: [current]),
                RepoEntry(path: "/other", displayName: "other", worktrees: [remote])
            ],
            selectedWorktreePath: current.path
        )
        let currentRef = FlowWorktreeIdentity.ref(repoDisplayName: "repo", repoPath: "/repo", worktreePath: current.path, branch: current.branch)
        let remoteRef = FlowWorktreeIdentity.ref(repoDisplayName: "other", repoPath: "/other", worktreePath: remote.path, branch: remote.branch)
        let context = FlowStateContextBuilder.build(
            appState: appState,
            summaries: [
                currentRef: FlowWorktreeSummary(worktreeRef: currentRef, updatedAt: Date(timeIntervalSince1970: 20), summary: "Active work", nextAction: "Finish test", needsHuman: false)
            ],
            notes: [:],
            snoozes: [:],
            signals: FlowExternalSignals(
                prByWorktreeRef: [
                    remoteRef: FlowPRSnapshot(number: 9, state: "open", ciConclusion: "failure", mergeState: nil)
                ]
            ),
            now: Date(timeIntervalSince1970: 30)
        )

        let selected = try #require(context.worktrees.first { $0.worktreePath == current.path })
        let unrelated = try #require(context.worktrees.first { $0.worktreePath == remote.path })
        #expect(selected.scoring.flowAffinity.rawRank > unrelated.scoring.flowAffinity.rawRank)
        #expect(selected.resumptionCostHint == .low)
        #expect(unrelated.resumptionCostHint == .high)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter FlowStateContextBuilderTests
```

Expected: fail to compile because context types do not exist.

- [ ] **Step 3: Add context model types**

In `FlowStateModels.swift`, add:

- `FlowContextEnvelope`.
- `FlowWorktreeSnapshot`.
- `FlowWorktreeIdentity`.
- `FlowSnapshotAttention`.
- `FlowSnapshotClarity`.
- `FlowResumptionCostHint`.
- `FlowTopicLabel`.
- `FlowExternalSignals`.
- `FlowAgentPresenceSnapshot`.
- `FlowGitSnapshot`.
- `FlowPRSnapshot`.
- `FlowActivitySnapshot`.
- `FlowScoringHints`.
- Scoring hint enums for `flowAffinity`, `unlockValue`, `riskUrgency`,
  `completionMomentum`, and `interruptPenalty`.
- Scoring hint enums expose a small `rawRank` integer used only for tests and
  ordering helpers.

The snapshot must include every field from the design's `FlowWorktreeSnapshot`
section, even when the first implementation fills some values with `nil`:

- repo path/name
- worktree name/path/branch/ref
- `worktreeKey`: stable collision-resistant internal key derived from repo path
  and worktree path.
- `worktreeRef`: stable CLI-facing ref derived from `worktreeKey` plus a short
  human hint, not just display name and branch.
- `displayRef`: human-only `repoDisplayName:branch` label that may collide and
  must never be used for store or signal joins.
- selected state
- focused pane/session state when available
- recent user activity timestamp
- recent agent activity timestamp
- attention state/source
- agent runtime/presence/busy/waiting state
- PR/CI/merge status
- dirty/divergence stats
- latest summary/next action/needs-human flag
- last Flow State message time
- snooze/defer metadata
- topic labels
- scoring hints

Do not add terminal tail scraping here.

- [ ] **Step 4: Implement builder**

Create `FlowStateContextBuilder.swift`:

```swift
public enum FlowStateContextBuilder {
    public static func build(
        appState: AppState,
        summaries: [String: FlowWorktreeSummary],
        notes: [String: FlowWorktreeNote],
        snoozes: [String: FlowSnooze],
        signals: FlowExternalSignals = .empty,
        now: Date
    ) -> FlowContextEnvelope
}
```

Rules:

- `FlowWorktreeIdentity.key(repoPath:worktreePath:)` returns a deterministic
  short SHA-256/hex key over the absolute repo path and worktree path.
- `FlowWorktreeIdentity.ref(repoDisplayName:repoPath:worktreePath:branch:)`
  returns the stable CLI-facing ref used by context, summaries, notes, snoozes,
  signals, and cooldowns.
- `worktreeRef` is `"\(repo.displayName)#\(keyPrefix):\(WorktreeNameSanitizer.sanitize(worktree.branch))"`.
- `displayRef` is `"\(repo.displayName):\(WorktreeNameSanitizer.sanitize(worktree.branch))"` and is used only for labels.
- `selected` compares `appState.selectedWorktreePath`.
- `attention` prefers worktree-level attention; if absent, represent the first pane attention by timestamp order or dictionary order.
- `summary` comes from the summaries map by `worktreeRef`.
- Agent, git, PR, summary, note, snooze, and activity fields are joined by
  `worktreeKey`/stable `worktreeRef`, never by `displayRef`.
- `clarity == .clear` when summary exists or attention exists; otherwise `.unclear`.
- `nextAction` comes only from summary, never inferred from empty state.
- `resumptionCostHint == .low` for selected worktree, `.medium` for same repo as selected, `.high` for other repo/no selection.
- `scoring.flowAffinity` follows the same selected/same-repo/other-repo ladder.
- `scoring.unlockValue == .high` when `summary.needsHuman == true`, agent is waiting, or attention source is `.agentStop`; otherwise `.medium` for PR/CI risk and `.low` by default.
- `scoring.riskUrgency == .high` for failing CI, dirty merge state, or critical urgency held interruption; otherwise `.low`/`.medium` based on available PR/git signals.
- `topicLabels` start with repo display name and sanitized branch components split on `/`, `-`, `_`.

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter FlowStateContextBuilderTests
```

Expected: pass.

- [ ] **Step 6: Regenerate specs and commit**

Run:

```bash
scripts/generate-specs.py
git add Sources/GrafttyKit/FlowState Tests/GrafttyKitTests/FlowState SPECS.md
git commit -m "feat(flow): build Flow State context snapshots"
```

---

### Task 3: Socket Protocol And `graftty flow` CLI

**Files:**
- Modify: `Sources/GrafttyKit/Notification/NotificationMessage.swift`
- Create: `Sources/GrafttyCLI/Flow.swift`
- Modify: `Sources/GrafttyCLI/CLI.swift`
- Test: `Tests/GrafttyKitTests/Notification/FlowStateProtocolTests.swift`
- Test: `Tests/GrafttyKitTests/FlowState/FlowStateCLIRenderingTests.swift`
- Test: `Tests/GrafttyTests/CLI/FlowCommandTests.swift`

- [ ] **Step 1: Write failing protocol tests**

Create `Tests/GrafttyKitTests/Notification/FlowStateProtocolTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("Flow State socket protocol")
struct FlowStateProtocolTests {
    @Test("@spec FLOW-3.1: Flow State socket requests shall round-trip through NotificationMessage using stable wire type names.")
    func flowRequestsRoundTrip() throws {
        let messages: [NotificationMessage] = [
            .flowStatus,
            .flowContext,
            .flowRecommend,
            .flowSnooze(worktreeRef: "repo:feature", reason: "Later"),
            .flowNote(worktreeRef: "repo:feature", body: "note"),
            .flowSummary(FlowWorktreeSummary(worktreeRef: "repo:feature", updatedAt: Date(timeIntervalSince1970: 1), summary: "s", nextAction: "n", needsHuman: true)),
            .flowPublish(rawJSON: "{\"schemaVersion\":1}"),
            .flowRequestStatus(worktreeRef: "repo:feature", explicit: false),
        ]
        for message in messages {
            let data = try JSONEncoder().encode(message)
            let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
            #expect(decoded == message)
        }
    }

    @Test("@spec FLOW-3.2: Flow State socket responses shall round-trip through ResponseMessage with typed status, context, and recommendation payloads.")
    func flowResponsesRoundTrip() throws {
        let context = FlowContextEnvelope(generatedAt: Date(timeIntervalSince1970: 1), worktrees: [])
        let recommendation = FlowRecommendationEnvelope(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 1), primary: FlowPrimaryRecommendation(worktreeRef: nil, intent: .none, title: "No recommendation", reason: "No worktrees", confidence: .low))
        let responses: [ResponseMessage] = [
            .flowStatus(FlowStatus(enabled: true, running: false, message: "Needs start")),
            .flowContext(context),
            .flowRecommendation(recommendation),
        ]
        for response in responses {
            let data = try JSONEncoder().encode(response)
            let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
            #expect(decoded == response)
        }
    }

    @Test("@spec FLOW-3.4: `graftty flow publish` shall send raw JSON to the app so invalid agent output can be recorded as Flow State activity while preserving the last valid recommendation.")
    func flowPublishCarriesRawJSON() throws {
        let raw = "{\"schemaVersion\":1,\"primary\":{\"intent\":\"bad\"}}"
        let data = try JSONEncoder().encode(NotificationMessage.flowPublish(rawJSON: raw))
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == .flowPublish(rawJSON: raw))
    }
}
```

- [ ] **Step 2: Write failing CLI rendering tests**

Create `Tests/GrafttyKitTests/FlowState/FlowStateCLIRenderingTests.swift` for pure helpers that `Flow.swift` will use:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("Flow State CLI rendering")
struct FlowStateCLIRenderingTests {
    @Test("@spec FLOW-3.3: `graftty flow recommend` shall render the latest recommendation as JSON by default so agents can consume it without scraping prose.")
    func recommendationJSONRenders() throws {
        let envelope = FlowRecommendationEnvelope(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1),
            primary: FlowPrimaryRecommendation(worktreeRef: "repo:feature", intent: .stay, title: "Stay", reason: "Because", confidence: .medium)
        )
        let text = try FlowCLIOutput.recommendationJSON(envelope)
        #expect(text.contains("\"schemaVersion\""))
        #expect(text.contains("\"Stay\""))
    }
}
```

- [ ] **Step 3: Write failing CLI command tests**

Create `Tests/GrafttyTests/CLI/FlowCommandTests.swift` around a dispatcher seam
instead of testing process-global stdin/stdout directly. Import both
`GrafttyKit` and `@testable import GrafttyCLI`.

Required coverage:

- `flow status` sends `.flowStatus` and renders `FlowCLIOutput.statusLine`.
- `flow context` sends `.flowContext` and prints JSON.
- `flow recommend` sends `.flowRecommend` and prints JSON.
- `flow snooze <worktreeRef> --reason <reason>` sends `.flowSnooze`.
- `flow note <worktreeRef> --stdin` reads stdin and sends `.flowNote`.
- `flow summary <worktreeRef> --stdin` decodes summary JSON, rejects
  mismatched `summary.worktreeRef`, and sends `.flowSummary` on match.
- `flow publish --stdin` sends `.flowPublish(rawJSON:)` with the exact stdin
  bytes/text, including invalid JSON and invalid enum values, so the app can
  record the publish error while preserving the last valid recommendation.
- `flow request-status <worktreeRef>` sends
  `.flowRequestStatus(worktreeRef:explicit:)` with `explicit == false`.
- `flow request-status <worktreeRef> --explicit` sends the same request with
  `explicit == true`.

Define a test fake transport that records the outgoing `NotificationMessage`
and returns a configured `ResponseMessage`. Do not require a live Graftty socket
for unit tests.

- [ ] **Step 4: Run tests to verify they fail**

Run:

```bash
swift test --filter FlowStateProtocolTests
swift test --filter FlowStateCLIRenderingTests
swift test --filter FlowCommandTests
```

Expected: fail to compile.

- [ ] **Step 5: Extend socket protocol**

In `NotificationMessage.swift`:

- Add cases:
  - `flowStatus`
  - `flowContext`
  - `flowRecommend`
  - `flowSnooze(worktreeRef: String, reason: String?)`
  - `flowNote(worktreeRef: String, body: String)`
  - `flowSummary(FlowWorktreeSummary)`
  - `flowPublish(rawJSON: String)`
  - `flowRequestStatus(worktreeRef: String, explicit: Bool)`
- Add wire types:
  - `flow_status`
  - `flow_context`
  - `flow_recommend`
  - `flow_snooze`
  - `flow_note`
  - `flow_summary`
  - `flow_publish`
  - `flow_request_status`
- Add response cases:
  - `flowStatus(FlowStatus)`
  - `flowContext(FlowContextEnvelope)`
  - `flowRecommendation(FlowRecommendationEnvelope)`
- Update all exhaustive switches in `CLIEnv.expectOk`, `PaneList`, `PaneShow`, `PaneSend`, and team CLI handling to reject unexpected flow responses cleanly.

- [ ] **Step 6: Add CLI output helpers**

In `FlowStateModels.swift` or a new `Sources/GrafttyKit/FlowState/FlowCLIOutput.swift`, add:

```swift
public enum FlowCLIOutput {
    public static func recommendationJSON(_ envelope: FlowRecommendationEnvelope) throws -> String
    public static func contextJSON(_ envelope: FlowContextEnvelope) throws -> String
    public static func statusLine(_ status: FlowStatus) -> String
}
```

Prefer JSON for `context` and `recommend`; human-readable one-line output is acceptable for `status`.

- [ ] **Step 7: Implement command dispatcher and `graftty flow` command group**

Add a testable dispatcher seam in `Sources/GrafttyCLI/Flow.swift`:

```swift
protocol FlowCommandTransport {
    func request(_ message: NotificationMessage) throws -> ResponseMessage
}

struct FlowCommandDispatcher {
    var transport: any FlowCommandTransport
    var stdin: () throws -> String
    var stdout: (String) -> Void
    var stderr: (String) -> Void
}
```

The real CLI adapter delegates to the existing socket environment. Tests inject
the fake transport/stdin/stdout/stderr. Keep this local to `Flow.swift` unless
the existing CLI helpers already provide an equivalent seam.

Create `Sources/GrafttyCLI/Flow.swift` with:

- `Flow: ParsableCommand`
- `FlowStatusCommand`
- `FlowContextCommand`
- `FlowRecommendCommand`
- `FlowSnoozeCommand`
- `FlowNoteCommand`
- `FlowSummaryCommand`
- `FlowPublishCommand`
- `FlowRequestStatusCommand`

Wire `GrafttyCLI.configuration.subcommands` to `[Notify.self, Pane.self, Team.self, Flow.self, InternalGroup.self]`.

Command behavior:

- `status`: sends `.flowStatus`; prints status line.
- `context`: sends `.flowContext`; prints JSON.
- `recommend`: sends `.flowRecommend`; prints JSON.
- `snooze <worktreeRef> [--reason <reason>]`: sends `.flowSnooze`.
- `note <worktreeRef> --stdin`: reads body from stdin; sends `.flowNote`.
- `summary <worktreeRef> --stdin`: reads JSON summary body, decodes `FlowWorktreeSummary`, verifies path arg matches `summary.worktreeRef`, sends `.flowSummary`.
- `publish --stdin`: reads raw stdin text and sends `.flowPublish(rawJSON:)`
  without local decoding. The app validates and records invalid publish errors
  so it can keep the last valid recommendation.
- `request-status <worktreeRef> [--explicit]`: sends
  `.flowRequestStatus(worktreeRef:explicit:)`. The app constructs the fixed
  status-gathering message, applies permission mode and cooldowns, and records
  activity. This command is the only autonomous status-gathering path available
  to the Flow State agent.

Use the existing `TeamMessageInput` pattern, but do not make it private-reused across files unless access control stays clean. A small duplicate `FlowStdinInput` is acceptable.

- [ ] **Step 8: Run focused tests**

Run:

```bash
swift test --filter FlowStateProtocolTests
swift test --filter FlowStateCLIRenderingTests
swift test --filter FlowCommandTests
```

Expected: pass.

- [ ] **Step 9: Regenerate specs and commit**

Run:

```bash
scripts/generate-specs.py
git add Sources/GrafttyKit/Notification/NotificationMessage.swift Sources/GrafttyKit/FlowState Sources/GrafttyCLI/CLI.swift Sources/GrafttyCLI/Flow.swift Tests/GrafttyKitTests/Notification/FlowStateProtocolTests.swift Tests/GrafttyKitTests/FlowState Tests/GrafttyTests/CLI/FlowCommandTests.swift SPECS.md
git commit -m "feat(flow): add Flow State CLI protocol"
```

---

### Task 4: App Flow Request Handler And Action Policy

**Files:**
- Create: `Sources/GrafttyKit/FlowState/FlowStateActionPolicy.swift`
- Create: `Sources/GrafttyKit/FlowState/FlowStateActivityStore.swift`
- Create: `Sources/GrafttyKit/FlowState/FlowStateRequestHandler.swift`
- Create: `Sources/Graftty/FlowState/FlowStateSignalBuilder.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyKitTests/FlowState/FlowStateActionPolicyTests.swift`
- Test: `Tests/GrafttyKitTests/FlowState/FlowStateActivityStoreTests.swift`
- Test: `Tests/GrafttyKitTests/FlowState/FlowStateRequestHandlerTests.swift`
- Test: `Tests/GrafttyTests/FlowState/FlowStateAppRequestDispatchTests.swift`

- [ ] **Step 1: Write failing action-policy tests**

Create `FlowStateActionPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateActionPolicy")
struct FlowStateActionPolicyTests {
    @Test("@spec FLOW-4.1: Flow State shall treat an agent-provided `requiresConfirmation` value as advisory and derive the effective confirmation requirement from Graftty policy.")
    func confirmationIsDerivedByPolicy() {
        let action = FlowProposedAction(
            id: "focus",
            kind: .focusWorktree,
            target: "repo:feature",
            body: nil,
            requiresConfirmation: false
        )
        #expect(FlowStateActionPolicy.effectiveRequirement(for: action) == .confirmationRequired)
    }

    @Test("@spec FLOW-4.2: Flow State may execute autonomous team status requests only when they are single-target status-gathering template messages.")
    func autonomousStatusRequestRequiresTemplateShape() {
        let ok = FlowProposedAction(
            id: "ask",
            kind: .teamStatusRequest,
            target: "feature",
            body: "[Flow State] Please reply with status, blocker, next action, tests/PR state, and whether you need the human.",
            requiresConfirmation: false
        )
        let bad = FlowProposedAction(
            id: "mutate",
            kind: .teamStatusRequest,
            target: "feature",
            body: "[Flow State] Please run tests and push fixes.",
            requiresConfirmation: false
        )
        #expect(FlowStateActionPolicy.effectiveRequirement(for: ok) == .autonomousAllowed)
        #expect(FlowStateActionPolicy.effectiveRequirement(for: bad) == .confirmationRequired)
    }
}
```

- [ ] **Step 2: Write failing activity-store tests**

Create `FlowStateActivityStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateActivityStore")
struct FlowStateActivityStoreTests {
    @Test("@spec FLOW-4.3: When Flow State records activity, the application shall append durable activity rows and preserve per-worktree status-request cooldown timestamps.")
    func recordsActivityAndCooldowns() throws {
        let store = FlowStateActivityStore(rootDirectory: try temporaryDirectory())
        let now = Date(timeIntervalSince1970: 100)
        try store.append(.init(createdAt: now, kind: .publishError, message: "invalid enum", worktreeRef: nil))
        try store.recordStatusRequest(worktreeRef: "repo:feature", at: now)
        #expect(try store.recent(limit: 10).first?.message == "invalid enum")
        #expect(try store.lastStatusRequestAt(worktreeRef: "repo:feature") == now)
    }
}
```

- [ ] **Step 3: Write failing request-handler tests**

Create `FlowStateRequestHandlerTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateRequestHandler")
struct FlowStateRequestHandlerTests {
    @Test("@spec FLOW-4.4: Flow State request handling shall persist notes, summaries, snoozes, and recommendations and return typed status/context/recommendation responses.")
    func handlerPersistsAndReturnsFlowState() throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let activity = FlowStateActivityStore(rootDirectory: root)
        let handler = FlowStateRequestHandler(
            store: store,
            activityStore: activity,
            appState: AppState(repos: [
                RepoEntry(path: "/repo", displayName: "repo", worktrees: [
                    WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature", state: .running)
                ])
            ]),
            now: { Date(timeIntervalSince1970: 100) }
        )

        let worktreeRef = FlowWorktreeIdentity.ref(repoDisplayName: "repo", repoPath: "/repo", worktreePath: "/repo/.worktrees/feature", branch: "feature")
        let summary = FlowWorktreeSummary(worktreeRef: worktreeRef, updatedAt: Date(timeIntervalSince1970: 100), summary: "Blocked", nextAction: "Answer", needsHuman: true)
        #expect(try handler.handle(.flowSummary(summary)) == .ok)
        let context = try #require(handler.handle(.flowContext))
        if case .flowContext(let envelope) = context {
            #expect(envelope.worktrees.first?.summary?.summary == "Blocked")
        } else {
            Issue.record("Expected flowContext response")
        }
    }

    @Test("@spec FLOW-4.5: If `flow publish` receives invalid structured output, the application shall keep the last valid recommendation and record a Flow State activity error.")
    func invalidPublishKeepsLastValidRecommendationAndRecordsActivity() throws {
        let root = try temporaryDirectory()
        let store = FlowStateStore(rootDirectory: root)
        let activity = FlowStateActivityStore(rootDirectory: root)
        let handler = FlowStateRequestHandler(store: store, activityStore: activity, appState: AppState(), now: { Date(timeIntervalSince1970: 100) })
        let valid = """
        {"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"}}
        """
        #expect(try handler.handle(.flowPublish(rawJSON: valid)) == .ok)
        let invalid = """
        {"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"teleport","title":"Bad","reason":"Bad","confidence":"low"}}
        """
        if case .error = try handler.handle(.flowPublish(rawJSON: invalid)) {
            #expect(try store.recommendation()?.primary.title == "None")
            #expect(try activity.recent(limit: 1).first?.kind == .publishError)
        } else {
            Issue.record("Expected invalid publish error")
        }
    }
}
```

- [ ] **Step 4: Write failing app request-dispatch tests**

Create `Tests/GrafttyTests/FlowState/FlowStateAppRequestDispatchTests.swift`
for a small app-target helper introduced in Step 9. Avoid testing the full
SwiftUI app. Required coverage:

- `.flowContext` routed through the app helper includes signals supplied from
  `WorktreeStatsStore`, `PRStatusStore`, `ClaudeSessionRegistry`, pane/input
  activity registries, and `FlowStateActivityStore` when those services have
  matching worktree state.
- `.flowPublish(rawJSON:)` returns `.error` for invalid output and preserves the
  previous valid recommendation in `FlowStateStore`.
- `.flowStatus` uses an injected Flow State status provider, so Task 8 can
  return the controller status without rewriting request dispatch.
- `.flowRequestStatus(worktreeRef:explicit:)` remains a placeholder until Task
  5, where `FlowStateActionExecutor.requestStatus` is introduced. Task 4 should
  not create the executor early.

- [ ] **Step 5: Run tests to verify they fail**

Run:

```bash
swift test --filter FlowStateActionPolicyTests
swift test --filter FlowStateActivityStoreTests
swift test --filter FlowStateRequestHandlerTests
swift test --filter FlowStateAppRequestDispatchTests
```

Expected: fail to compile.

- [ ] **Step 6: Implement action policy**

Create `FlowStateActionPolicy.swift`:

```swift
public enum FlowActionRequirement: String, Codable, Sendable, Equatable {
    case autonomousAllowed
    case confirmationRequired
    case explicitOptInOnly
    case unsupported
}

public enum FlowStateActionPolicy {
    public static func effectiveRequirement(for action: FlowProposedAction) -> FlowActionRequirement
}
```

Rules from the spec:

- `teamStatusRequest`: autonomous only when body has `[Flow State]`, asks for status/blocker/next action/human need, and does not include mutation verbs such as `run`, `push`, `merge`, `rebase`, `restart`, `close`, `delete`.
- `teamMessage`, `focusWorktree`, `restartAgent`: confirmation required.
- `paneCommand`: explicit opt-in only.
- Unknown action kinds are impossible after decode; keep an `.unsupported` branch for future callers.

- [ ] **Step 7: Implement activity store**

Create `FlowStateActivityStore.swift`:

```swift
public struct FlowStateActivity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case publishError, publishAccepted, statusRequestSent, statusRequestSkipped, actionRequiresConfirmation, actionExecuted }
    public let createdAt: Date
    public let kind: Kind
    public let message: String
    public let worktreeRef: String?
}

public final class FlowStateActivityStore: Sendable {
    public init(rootDirectory: URL)
    public static func defaultRoot() -> URL
    public static func defaultStore() -> FlowStateActivityStore
    public func append(_ activity: FlowStateActivity) throws
    public func recent(limit: Int) throws -> [FlowStateActivity]
    public func recordStatusRequest(worktreeRef: String, at: Date) throws
    public func lastStatusRequestAt(worktreeRef: String) throws -> Date?
}
```

Store activity as JSONL at `activity.jsonl`; store cooldowns as JSON at
`status-request-cooldowns.json`.

- [ ] **Step 8: Implement request handler**

Create `FlowStateRequestHandler.swift`:

```swift
public struct FlowStateRequestHandler {
    public init(store: FlowStateStore, activityStore: FlowStateActivityStore, appState: AppState, signals: FlowExternalSignals = .empty, status: FlowStatus = .init(enabled: false, running: false, message: nil), now: @escaping () -> Date = Date.init)
    public func handle(_ message: NotificationMessage) throws -> ResponseMessage?
}
```

Behavior:

- `.flowStatus`: return initializer-supplied status.
- `.flowContext`: load summaries/notes/snoozes from store and return `.flowContext(FlowStateContextBuilder.build(..., signals: signals))`.
- `.flowRecommend`: return stored recommendation if present; otherwise a `.none` recommendation with low confidence.
- `.flowSnooze`: write `FlowSnooze` using the request's `worktreeRef`,
  `until`, and `reason`.
- `.flowNote`: write `FlowWorktreeNote`.
- `.flowSummary`: write summary.
- `.flowPublish(rawJSON)`: decode inside the app handler. On success, compute derived action requirements, write recommendation, append `.publishAccepted`, and return `.ok`. On decode/validation failure, do not overwrite `latest-recommendation.json`; append `.publishError`; return `.error`.
- `.flowRequestStatus`: return nil here. The app layer handles this request in
  Task 5 because it needs the action executor, team messaging, settings, and
  cooldown services.
- Non-flow messages return nil.

Do not execute proposed actions from inside this pure request handler. Action
execution is wired in the app layer in Task 5 after the app has real team,
focus, and lifecycle services.

- [ ] **Step 9: Wire `GrafttyApp.handlePaneRequest`**

Modify `GrafttyApp.handlePaneRequest`:

- Add flow cases to the request-style switch.
- Extend `AppServices` with:
  - `flowStateStore: FlowStateStore`
  - `flowStateActivityStore: FlowStateActivityStore`
  - `flowStateStatusProvider: (() -> FlowStatus)?`, initially nil and wired
    from the controller in Task 8.
- Extend the `socketServer.onRequest` closure in `GrafttyApp.startup()` to pass
  `services.statsStore`, `services.prStatusStore`,
  `services.claudeSessionRegistry`, `terminalManager`,
  `services.agentStateRegistry`, `services.inputActivityRegistry`,
  `services.flowStateStore`, `services.flowStateActivityStore`, and
  `services.flowStateStatusProvider` into request handling.
- Update the `handlePaneRequest` signature, or introduce a dedicated
  `handleFlowRequest` helper called by `handlePaneRequest`, so flow handling
  receives those app services explicitly. Do not read global singleton stores
  from inside the helper in tests.
- Add app-target `FlowStateSignalBuilder` to keep `GrafttyApp.swift` from
  absorbing the mapping logic.
- Construct `FlowExternalSignals` from those services:
  - agent presence/busy/waiting from team presence plus Claude liveness and pane attention
  - dirty/divergence from `WorktreeStatsStore`
  - PR/CI/merge from `PRStatusStore`
  - last Flow State message/cooldown from `FlowStateActivityStore`
  - recent user activity from pane input/activity registries when available; otherwise nil
- Construct `FlowStateRequestHandler(store: flowStateStore, activityStore: flowStateActivityStore, appState: appState.wrappedValue, signals: signals, status: flowStateStatusProvider?() ?? ...)`.
- Return errors as `.error("failed to handle flow request: ...")`.
- Add flow cases to the fire-and-forget no-op switch in `onMessage`.

- [ ] **Step 10: Run focused tests**

Run:

```bash
swift test --filter FlowStateActionPolicyTests
swift test --filter FlowStateActivityStoreTests
swift test --filter FlowStateRequestHandlerTests
swift test --filter FlowStateAppRequestDispatchTests
```

Expected: pass.

- [ ] **Step 11: Regenerate specs and commit**

Run:

```bash
scripts/generate-specs.py
git add Sources/GrafttyKit/FlowState Sources/Graftty/FlowState/FlowStateSignalBuilder.swift Sources/Graftty/GrafttyApp.swift Tests/GrafttyKitTests/FlowState Tests/GrafttyTests/FlowState/FlowStateAppRequestDispatchTests.swift SPECS.md
git commit -m "feat(flow): handle Flow State requests"
```

---

### Task 5: Activity, Refresh Coordination, And Action Execution

**Files:**
- Create: `Sources/GrafttyKit/FlowState/FlowStateRefreshCoordinator.swift`
- Create: `Sources/GrafttyKit/FlowState/FlowStateActionExecutor.swift`
- Modify: `Sources/GrafttyKit/FlowState/FlowStateActivityStore.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyKitTests/FlowState/FlowStateRefreshCoordinatorTests.swift`
- Test: `Tests/GrafttyKitTests/FlowState/FlowStateActionExecutorTests.swift`

- [ ] **Step 1: Write failing refresh-coordinator tests**

Create `FlowStateRefreshCoordinatorTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateRefreshCoordinator")
struct FlowStateRefreshCoordinatorTests {
    @Test("@spec FLOW-5.1: Flow State shall request a recommendation refresh on view open, selected-worktree stability, attention events after a stable focus block, and a conservative background interval.")
    func refreshTriggersFollowPolicy() {
        let now = Date(timeIntervalSince1970: 1_000)
        var coordinator = FlowStateRefreshCoordinator(
            refreshInterval: 600,
            focusStabilityDelay: 30,
            attentionStableFocusDelay: 300,
            statusRequestCooldown: 1_200,
            now: { now }
        )
        #expect(coordinator.shouldRefresh(for: .viewOpened) == true)
        coordinator.recordSelectionChanged(to: "repo:feature", at: now)
        #expect(coordinator.shouldRefresh(for: .selectionStable(worktreeRef: "repo:feature", selectedAt: now.addingTimeInterval(-31))) == true)
        #expect(coordinator.shouldRefresh(for: .attention(worktreeRef: "repo:other", currentFocusStableSince: now.addingTimeInterval(-301))) == true)
        coordinator.recordBackgroundRefresh(at: now)
        #expect(coordinator.shouldRefresh(for: .backgroundTick) == false)
        #expect(coordinator.shouldRefresh(for: .backgroundTick, at: now.addingTimeInterval(601)) == true)
    }

    @Test("@spec FLOW-5.2: Flow State shall not ask the same worktree agent for status more than once during the configured cooldown unless the user explicitly requests refresh.")
    func statusRequestCooldownIsEnforced() {
        let now = Date(timeIntervalSince1970: 1_000)
        var coordinator = FlowStateRefreshCoordinator(statusRequestCooldown: 1_200, now: { now })
        coordinator.recordStatusRequest(worktreeRef: "repo:feature", at: now)
        #expect(coordinator.canRequestStatus(worktreeRef: "repo:feature", explicit: false, at: now.addingTimeInterval(100)) == false)
        #expect(coordinator.canRequestStatus(worktreeRef: "repo:feature", explicit: true, at: now.addingTimeInterval(100)) == true)
        #expect(coordinator.canRequestStatus(worktreeRef: "repo:feature", explicit: false, at: now.addingTimeInterval(1_201)) == true)
    }
}
```

- [ ] **Step 2: Write failing action-executor tests**

Create `FlowStateActionExecutorTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateActionExecutor")
struct FlowStateActionExecutorTests {
    @Test("@spec FLOW-5.3: Flow State shall autonomously execute only policy-allowed team status requests and shall record skipped or confirmation-required actions as activity.")
    func executesOnlyAutonomousStatusRequest() throws {
        let activity = FlowStateActivityStore(rootDirectory: try temporaryDirectory())
        let sender = RecordingFlowTeamMessenger()
        let executor = FlowStateActionExecutor(activityStore: activity, teamMessenger: sender, now: { Date(timeIntervalSince1970: 100) })
        let allowed = FlowProposedAction(
            id: "ask",
            kind: .teamStatusRequest,
            target: "feature",
            body: "[Flow State] Please reply with status, blocker, next action, tests/PR state, and whether you need the human.",
            requiresConfirmation: false
        )
        let focus = FlowProposedAction(id: "focus", kind: .focusWorktree, target: "repo:feature", body: nil, requiresConfirmation: false)
        try executor.executeAutonomousActions([allowed, focus])
        #expect(sender.sent.count == 1)
        #expect(sender.sent.first?.target == "feature")
        #expect(try activity.recent(limit: 10).contains { $0.kind == .actionRequiresConfirmation })
    }

    @Test("@spec FLOW-5.4: When Flow State permission mode is Manual Only, the application shall not execute autonomous status requests and shall record them as requiring confirmation.")
    func manualOnlyPermissionModeDisablesAutonomousStatusRequests() throws {
        let activity = FlowStateActivityStore(rootDirectory: try temporaryDirectory())
        let sender = RecordingFlowTeamMessenger()
        let executor = FlowStateActionExecutor(activityStore: activity, teamMessenger: sender, permissionMode: .manualOnly, now: { Date(timeIntervalSince1970: 100) })
        let allowed = FlowProposedAction(
            id: "ask",
            kind: .teamStatusRequest,
            target: "feature",
            body: "[Flow State] Please reply with status, blocker, next action, tests/PR state, and whether you need the human.",
            requiresConfirmation: false
        )
        try executor.executeAutonomousActions([allowed])
        #expect(sender.sent.isEmpty)
        #expect(try activity.recent(limit: 10).contains { $0.kind == .actionRequiresConfirmation })
    }
}
```

Use a tiny test messenger type in the test file conforming to the executor's messenger protocol.

- [ ] **Step 3: Run tests to verify they fail**

Run:

```bash
swift test --filter FlowStateRefreshCoordinatorTests
swift test --filter FlowStateActionExecutorTests
```

Expected: fail to compile.

- [ ] **Step 4: Implement refresh coordinator**

Create `FlowStateRefreshCoordinator.swift`:

- `FlowRefreshTrigger`: `.viewOpened`, `.selectionStable(worktreeRef:selectedAt:)`, `.attention(worktreeRef:currentFocusStableSince:)`, `.backgroundTick`, `.explicitUserRefresh`.
- `FlowStateRefreshCoordinator`: pure struct with configurable intervals.
- Methods:
  - `shouldRefresh(for:at:)`
  - `recordSelectionChanged(to:at:)`
  - `recordBackgroundRefresh(at:)`
  - `recordStatusRequest(worktreeRef:at:)`
  - `canRequestStatus(worktreeRef:explicit:at:)`

This task only makes the decision logic testable. App timers are wired in Task 8.

- [ ] **Step 5: Implement action executor**

Create `FlowStateActionExecutor.swift`:

```swift
public protocol FlowTeamMessaging {
    func sendStatusRequest(target: String, body: String) throws
    func sendMessage(target: String, body: String) throws
}

public protocol FlowConfirmedAppActions {
    func focusWorktree(ref: String) throws
    func restartAgent(ref: String) throws
}

public enum FlowStatePermissionMode: String, Codable, Sendable, Equatable {
    case conservative
    case manualOnly
}

public struct FlowStateActionExecutor {
    public init(activityStore: FlowStateActivityStore, teamMessenger: any FlowTeamMessaging, appActions: (any FlowConfirmedAppActions)? = nil, permissionMode: FlowStatePermissionMode = .conservative, now: @escaping () -> Date = Date.init)
    public func executeAutonomousActions(_ actions: [FlowProposedAction]) throws
    public func requestStatus(worktreeRef: String, explicit: Bool) throws
    public func executeConfirmedAction(_ action: FlowProposedAction) throws
}
```

Rules:

- For each action, derive `FlowStateActionPolicy.effectiveRequirement`.
- `.autonomousAllowed`: in `.conservative` mode, call
  `teamMessenger.sendStatusRequest`, append `.actionExecuted`, and record
  status-request cooldown. In `.manualOnly` mode, append
  `.actionRequiresConfirmation` and do not execute.
- `.confirmationRequired`: append `.actionRequiresConfirmation`; do not execute.
- `.explicitOptInOnly` / `.unsupported`: append skipped activity; do not execute.
- `requestStatus(worktreeRef:explicit:)` constructs the fixed Flow State status
  template internally. It must not accept free-form body text. It enforces
  `FlowStateActivityStore.lastStatusRequestAt` cooldowns unless `explicit` is
  true, respects `FlowStatePermissionMode`, sends through
  `FlowTeamMessaging.sendStatusRequest`, and records `.statusRequestSent` or
  `.statusRequestSkipped`.
- `executeConfirmedAction` may execute only `team_message`, `team_status_request`,
  `focus_worktree`, and `restart_agent` after the UI confirms them. Team
  messages go through `FlowTeamMessaging`. Focus/restart actions require an
  injected `FlowConfirmedAppActions`; if absent, append a skipped/error
  activity instead of silently succeeding. It must still refuse `pane_command`
  unless a future explicit opt-in setting exists.

- [ ] **Step 6: Wire autonomous execution after valid publish**

In `GrafttyApp.handlePaneRequest` or its Flow request helper:

- After `.flowPublish(rawJSON:)` decodes and stores a valid recommendation,
  reload the accepted recommendation from `FlowStateStore` and call
  `FlowStateActionExecutor.executeAutonomousActions(envelope.proposedActions)`.
- Handle `.flowRequestStatus(worktreeRef:explicit:)` in the app request path by
  constructing the same `FlowStateActionExecutor` and calling
  `requestStatus(worktreeRef:explicit:)`; return `.ok` for sent requests and
  `.error` only for unexpected execution failures. Cooldown/manual-mode skips
  should be recorded activity and returned as `.ok` with no team message sent.
- Construct the executor with `permissionMode` read from
  `SettingsKeys.flowStatePermissionMode`; invalid/missing values fall back to
  `.conservative`.
- Implement production `FlowTeamMessaging` by sending through `TeamInboxRequestHandler.send` with a Flow State pseudo-caller only for status requests. If the existing team handler requires a real caller worktree, resolve the target worktree's team and use the team lead/root worktree as caller; record an activity error if no team can be resolved.
- Implement production `FlowConfirmedAppActions` in the app target, not in
  `GrafttyKit`, because focus and agent restart require `AppState`,
  `TerminalManager`, and Flow State controller access.
- Never execute `focus_worktree`, `team_message`, `restart_agent`, or `pane_command` here.

- [ ] **Step 7: Run focused tests**

Run:

```bash
swift test --filter FlowStateRefreshCoordinatorTests
swift test --filter FlowStateActionExecutorTests
```

Expected: pass.

- [ ] **Step 8: Regenerate specs and commit**

Run:

```bash
scripts/generate-specs.py
git add Sources/GrafttyKit/FlowState Sources/Graftty/GrafttyApp.swift Tests/GrafttyKitTests/FlowState SPECS.md
git commit -m "feat(flow): execute Flow State coordination actions"
```

---

### Task 6: Settings Defaults And Prompt Editing

**Files:**
- Modify: `Sources/Graftty/Settings/SettingsKeys.swift`
- Create: `Sources/Graftty/Settings/FlowStateDefaults.swift`
- Create: `Sources/Graftty/Views/Settings/FlowStateSettingsPane.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyTests/Settings/FlowStateSettingsPaneTests.swift`

- [ ] **Step 1: Write failing settings tests**

Create `FlowStateSettingsPaneTests.swift`:

```swift
import Testing
@testable import Graftty

@Suite("FlowStateSettingsPane")
struct FlowStateSettingsPaneTests {
    @Test("@spec FLOW-6.1: The application shall register non-empty Flow State defaults for enablement, runtime, and editable system prompt.")
    func defaultsAreRegisteredAndPromptIsNonEmpty() {
        #expect(!FlowStateDefaults.systemPrompt.isEmpty)
        #expect(FlowStateDefaults.systemPrompt.contains("Flow State"))
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStateRuntime] as? String == "codex")
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStateEnabled] as? Bool == false)
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStatePermissionMode] as? String == "conservative")
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStateRefreshIntervalMinutes] as? Int == 10)
        #expect(FlowStateDefaults.registrations[SettingsKeys.flowStateStatusRequestCooldownMinutes] as? Int == 20)
    }

    @Test("@spec FLOW-6.2: The Flow State system prompt shall instruct the agent to preserve human flow and use `graftty flow` rather than acting as a repo-scoped team member.")
    func promptContainsCorePolicy() {
        let prompt = FlowStateDefaults.systemPrompt
        #expect(prompt.contains("preserve the human"))
        #expect(prompt.contains("graftty flow"))
        #expect(prompt.contains("not a repo-scoped team member"))
        #expect(prompt.contains("flow request-status"))
        #expect(prompt.contains("Do not use graftty team"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter FlowStateSettingsPaneTests
```

Expected: fail to compile.

- [ ] **Step 3: Add settings keys and defaults**

Add to `SettingsKeys.swift`:

```swift
static let flowStateEnabled = "flowStateEnabled"
static let flowStateRuntime = "flowStateRuntime"
static let flowStatePermissionMode = "flowStatePermissionMode"
static let flowStateSystemPrompt = "flowStateSystemPrompt"
static let flowStateRefreshIntervalMinutes = "flowStateRefreshIntervalMinutes"
static let flowStateStatusRequestCooldownMinutes = "flowStateStatusRequestCooldownMinutes"
```

Create `FlowStateDefaults.swift` with:

- `systemPrompt`.
- `registrations`.
- runtime default `"codex"`.
- enabled default `false`.
- permission mode default `"conservative"`; this mode allows only
  policy-approved status gathering without confirmation.
- refresh interval `10`.
- status request cooldown `20`.
- The default prompt must explicitly instruct the Flow State agent:
  - Preserve the human's current flow and optimize for context-switching cost.
  - Use `graftty flow context`, `graftty flow request-status`, and
    `graftty flow publish --stdin`.
  - Do not use `graftty team send`, `graftty team broadcast`, or other team
    messaging commands directly; autonomous status gathering must go through
    `graftty flow request-status <worktreeRef>` so Swift can enforce cooldowns,
    permission mode, and audit logging.

In `GrafttyApp.init()`, register both `DefaultPrompts.registrations` and `FlowStateDefaults.registrations`.

- [ ] **Step 4: Add settings pane**

Create `FlowStateSettingsPane.swift` with:

- Toggle: "Enable Flow State".
- Picker: Codex / Claude, bound to `flowStateRuntime`.
- Picker: permission mode, initially just "Conservative" and "Manual Only".
  Manual Only disables autonomous status requests even if the action policy
  would otherwise allow them.
- Stepper or numeric field: refresh interval minutes.
- Stepper or numeric field: status request cooldown minutes.
- TextEditor for system prompt.
- Button "Reset Prompt" that restores `FlowStateDefaults.systemPrompt`.
- Lifecycle buttons "Start", "Stop", "Restart" wired to injected closures with default no-ops for previews/tests. Production closures are supplied in Task 8.

Keep this pane functional but do not implement lifecycle side effects in this task.

Add it to `GrafttyApp.Settings` `TabView`:

```swift
FlowStateSettingsPane()
    .tabItem { Label("Flow State", systemImage: "arrow.triangle.branch") }
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
swift test --filter FlowStateSettingsPaneTests
```

Expected: pass.

- [ ] **Step 6: Regenerate specs and commit**

Run:

```bash
scripts/generate-specs.py
git add Sources/Graftty/Settings Sources/Graftty/Views/Settings Sources/Graftty/GrafttyApp.swift Tests/GrafttyTests/Settings/FlowStateSettingsPaneTests.swift SPECS.md
git commit -m "feat(flow): add Flow State settings"
```

---

### Task 7: Sidebar Row And Flow State View

**Files:**
- Create: `Sources/Graftty/Views/FlowState/FlowStateSidebarRow.swift`
- Create: `Sources/Graftty/Views/FlowState/FlowStateView.swift`
- Modify: `Sources/Graftty/Views/SidebarView.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Test: `Tests/GrafttyTests/Views/FlowStateViewTests.swift`
- Test: `Tests/GrafttyTests/Views/SidebarFlowStateTests.swift`

- [ ] **Step 1: Write failing view-model tests**

Prefer testing pure view model helpers over brittle SwiftUI inspection. Create `FlowStateViewTests.swift`:

```swift
import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("FlowStateViewModel")
struct FlowStateViewTests {
    @Test("@spec FLOW-7.1: The Flow State sidebar row shall render a calm status label from the latest recommendation instead of counting every attention event.")
    func sidebarStatusUsesPrimaryIntent() {
        let rec = FlowRecommendationEnvelope(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1),
            primary: FlowPrimaryRecommendation(worktreeRef: "repo:feature", intent: .stay, title: "Stay here", reason: "Because", confidence: .medium)
        )
        #expect(FlowStateSidebarStatus.label(recommendation: rec, status: FlowStatus(enabled: true, running: true, message: nil)) == "Stay here")
    }

    @Test("@spec FLOW-7.2: When Flow State has no valid recommendation, the view model shall render setup or unavailable state instead of a fake next action.")
    func unavailableDoesNotInventAction() {
        let model = FlowStateViewModel.make(recommendation: nil, status: FlowStatus(enabled: false, running: false, message: "Needs setup"))
        #expect(model.primaryTitle == "Needs setup")
        #expect(model.primaryReason.contains("Enable Flow State"))
    }

    @Test("@spec FLOW-7.3: Flow State shall render recent activity such as publish errors and skipped status requests separately from the primary recommendation.")
    func activityDoesNotBecomePrimaryRecommendation() {
        let activity = [
            FlowStateActivity(createdAt: Date(timeIntervalSince1970: 1), kind: .publishError, message: "invalid enum", worktreeRef: nil),
            FlowStateActivity(createdAt: Date(timeIntervalSince1970: 2), kind: .statusRequestSkipped, message: "cooldown", worktreeRef: "repo:feature")
        ]
        let model = FlowStateViewModel.make(recommendation: nil, status: FlowStatus(enabled: true, running: true, message: nil), activity: activity)
        #expect(model.primaryTitle != "invalid enum")
        #expect(model.recentActivity.map(\.message).contains("invalid enum"))
        #expect(model.recentActivity.map(\.message).contains("cooldown"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter FlowStateViewTests
```

Expected: fail to compile.

- [ ] **Step 3: Add view models**

In `FlowStateView.swift` or a small companion file, add:

- `FlowStateViewModel`.
- `FlowStateSidebarStatus`.

These should be pure and testable:

```swift
struct FlowStateViewModel: Equatable {
    let primaryTitle: String
    let primaryReason: String
    let sameContext: [FlowSameContextItem]
    let heldInterruptions: [FlowHeldInterruptionItem]
    let resumeCards: [FlowResumeCard]
    let recentActivity: [FlowStateActivity]
}
```

- [ ] **Step 4: Add Flow State selection mode**

`AppState.selectedWorktreePath` can remain worktree-only. Add view-local selection in `MainWindow`:

```swift
private enum MainSelection: Equatable {
    case flowState
    case worktree(String?)
}
@State private var mainSelection: MainSelection = .worktree(nil)
```

Rules:

- Selecting Flow State sets `mainSelection = .flowState` and does not mutate `appState.selectedWorktreePath`.
- Selecting a worktree sets `mainSelection = .worktree(path)` and calls existing `selectWorktree(path)`.
- Existing `.onChange(of: appState.selectedWorktreePath)` should set `mainSelection = .worktree(newPath)` only when the change comes from normal worktree navigation. If this creates a loop, keep the simpler rule: detail renders Flow State only from a separate `@State var showingFlowState = false`; worktree selection sets it false.

- [ ] **Step 5: Add sidebar row**

Create `FlowStateSidebarRow.swift` with a compact row:

- Label: "Flow State".
- SF Symbol: `arrow.triangle.branch` or `point.3.connected.trianglepath.dotted`.
- Trailing status text from `FlowStateSidebarStatus`.
- Selected styling should match existing sidebar theme.

Modify `SidebarView`:

- Add inputs:
  - `flowStateStatus: FlowStatus`
  - `flowStateRecommendation: FlowRecommendationEnvelope?`
  - `isFlowStateSelected: Bool`
  - `onSelectFlowState: () -> Void`
- Insert `FlowStateSidebarRow` before `ForEach(appState.repos)`.

- [ ] **Step 6: Add Flow State detail view**

Create `FlowStateView.swift`:

- Render primary title/reason.
- Sections for same-context, held interruptions, resume cards, proposed actions,
  and recent Flow State activity.
- Proposed-action buttons render with policy-derived state: autonomous actions show as already handled or pending; confirmation-required actions are enabled and call an injected `confirmAction` closure; explicit-opt-in-only actions are visible but disabled with explanatory copy.
- Include "Open Flow State Agent Pane" and "Restart Agent" buttons wired as closures.
- Include "Refresh" wired to an injected `requestRefresh` closure.

Modify `MainWindow` detail:

- If Flow State selected, render `FlowStateView`.
- Else render existing breadcrumb + terminal content.
- Confirmed proposed actions call the app-owned `FlowStateActionExecutor.executeConfirmedAction`.

For this task, load recommendation/status/activity directly from `FlowStateStore.defaultStore()` and `FlowStateActivityStore.defaultStore()` at view appearance using a lightweight `@State` refresh. Do not add Combine observation yet.

- [ ] **Step 7: Run focused tests**

Run:

```bash
swift test --filter FlowStateViewTests
```

Expected: pass.

- [ ] **Step 8: Regenerate specs and commit**

Run:

```bash
scripts/generate-specs.py
git add Sources/Graftty/Views/FlowState Sources/Graftty/Views/SidebarView.swift Sources/Graftty/Views/MainWindow.swift Tests/GrafttyTests/Views/FlowStateViewTests.swift SPECS.md
git commit -m "feat(flow): add Flow State sidebar view"
```

---

### Task 8: Persistent Flow State Agent Lifecycle

**Files:**
- Create: `Sources/Graftty/FlowState/FlowStateAgentController.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/Graftty/Views/Settings/FlowStateSettingsPane.swift`
- Modify: `Sources/Graftty/Views/FlowState/FlowStateView.swift`
- Test: `Tests/GrafttyTests/FlowState/FlowStateAgentControllerTests.swift`
- Test: `Tests/GrafttyTests/FlowState/FlowStateRuntimeLaunchCommandTests.swift`

- [ ] **Step 1: Write failing lifecycle tests**

Create `FlowStateAgentControllerTests.swift` using an injectable process runner. Do not spawn real Claude/Codex in tests.

```swift
import Foundation
import Testing
@testable import Graftty

@Suite("FlowStateAgentController")
struct FlowStateAgentControllerTests {
    @Test("@spec FLOW-8.1: When Flow State is enabled, the application shall ensure one persistent app-managed Flow State agent pane exists for the selected runtime and editable system prompt.")
    func ensureCreatesOneAgentPaneOnly() async throws {
        let launcher = RecordingFlowAgentPaneLauncher()
        let controller = FlowStateAgentController(
            launcher: launcher,
            workspaceDirectory: URL(fileURLWithPath: "/tmp/flow-state-test"),
            promptProvider: { "prompt" },
            runtimeProvider: { .codex },
            enabledProvider: { true }
        )
        await controller.ensureRunning()
        await controller.ensureRunning()
        #expect(await launcher.starts.count == 1)
        #expect(await launcher.starts.first?.runtime == .codex)
        #expect(await launcher.starts.first?.command.contains("codex") == true)
        #expect(await launcher.starts.first?.workspaceDirectory.path == "/tmp/flow-state-test")
    }

    @Test("@spec FLOW-8.2: If the Flow State runtime or system prompt changes, the application shall require confirmation before restarting the Flow State agent pane.")
    func runtimeOrPromptChangeRequiresConfirmedRestart() async throws {
        let launcher = RecordingFlowAgentPaneLauncher()
        nonisolated(unsafe) var prompt = "one"
        let controller = FlowStateAgentController(
            launcher: launcher,
            workspaceDirectory: URL(fileURLWithPath: "/tmp/flow-state-test"),
            promptProvider: { prompt },
            runtimeProvider: { .claude },
            enabledProvider: { true }
        )
        await controller.ensureRunning()
        prompt = "two"
        await controller.reconcileSettingsChanged()
        #expect(await launcher.stops == 0)
        #expect(await launcher.starts.count == 1)
        #expect(await controller.pendingRestartReason != nil)
        await controller.confirmPendingRestart()
        #expect(await launcher.stops == 1)
        #expect(await launcher.starts.count == 2)
    }

    @Test("@spec FLOW-8.3: If the user cancels a pending Flow State runtime or prompt restart, the existing Flow State agent pane shall keep running.")
    func cancelPendingRestartLeavesCurrentAgentRunning() async throws {
        let launcher = RecordingFlowAgentPaneLauncher()
        nonisolated(unsafe) var runtime: FlowStateRuntime = .codex
        let controller = FlowStateAgentController(
            launcher: launcher,
            workspaceDirectory: URL(fileURLWithPath: "/tmp/flow-state-test"),
            promptProvider: { "prompt" },
            runtimeProvider: { runtime },
            enabledProvider: { true }
        )
        await controller.ensureRunning()
        runtime = .claude
        await controller.reconcileSettingsChanged()
        await controller.cancelPendingRestart()
        #expect(await launcher.stops == 0)
        #expect(await launcher.starts.count == 1)
        #expect(await controller.pendingRestartReason == nil)
    }
}
```

Create `FlowStateRuntimeLaunchCommandTests.swift`:

```swift
import Foundation
import Testing
@testable import Graftty

@Suite("FlowStateRuntimeLaunchCommand")
struct FlowStateRuntimeLaunchCommandTests {
    @Test("@spec FLOW-8.4: Flow State runtime launch commands shall use the Flow State workspace, prompt file, shell-safe quoting, socket environment, and honest prompt mode for the selected runtime.")
    func launchCommandsIncludePromptWorkspaceAndSocketEnvironment() throws {
        let prompt = URL(fileURLWithPath: "/tmp/flow state/prompt's.md")
        let workspace = URL(fileURLWithPath: "/tmp/flow state/workspace")
        let claude = FlowStateRuntime.claude.launchCommand(
            promptFile: prompt,
            workspace: workspace,
            capabilities: .init(claudeSupportsSystemPromptFile: true, codexSupportsSystemInstructionConfig: false),
            socketPath: "/tmp/graftty.sock"
        )
        #expect(claude.command.contains("--system-prompt-file"))
        #expect(claude.command.contains("'\"'\"'"))
        #expect(claude.environment["GRAFTTY_SOCK"] == "/tmp/graftty.sock")
        #expect(claude.promptMode == .systemPrompt)

        let codex = FlowStateRuntime.codex.launchCommand(
            promptFile: prompt,
            workspace: workspace,
            capabilities: .init(claudeSupportsSystemPromptFile: true, codexSupportsSystemInstructionConfig: false),
            socketPath: "/tmp/graftty.sock"
        )
        #expect(codex.command.contains("codex --cd"))
        #expect(codex.promptMode == .bootstrapPrompt)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
swift test --filter FlowStateAgentControllerTests
swift test --filter FlowStateRuntimeLaunchCommandTests
```

Expected: fail to compile.

- [ ] **Step 3: Implement controller model**

Create `FlowStateAgentController.swift`:

- `FlowStateRuntime` enum: `.codex`, `.claude`, initialized from UserDefaults string.
- `FlowAgentPaneStartRequest`: runtime, prompt, workspaceDirectory, command, terminalID, paneSessionID.
- `FlowAgentPaneHandle` protocol with `close()` and `sendLine(_:)`.
- `FlowAgentPaneLaunching` protocol with `start(_:) async throws -> FlowAgentPaneHandle`.
- `FlowStateAgentController` as `@MainActor final class ObservableObject`.
- `pendingRestartReason: String?` published for the settings/view confirmation UI.

Controller behavior:

- `ensureRunning()` no-ops if disabled.
- Starts exactly one app-managed pane if enabled and no live handle.
- `stop()` closes the pane handle and clears state.
- `restart()` stops then starts only when called by explicit user action.
- `requestRefresh(reason:)` sends a single line to the Flow State agent pane:
  `Flow State refresh requested (<reason>). Run graftty flow context; request needed agent status only with graftty flow request-status <worktreeRef>; then publish with graftty flow publish --stdin.`
- `reconcileSettingsChanged()` compares runtime/prompt snapshot and sets
  `pendingRestartReason` when changed. It must not stop or restart the running
  pane until the user confirms.
- `confirmPendingRestart()` clears the pending reason and restarts once.
- `cancelPendingRestart()` clears the pending reason and leaves the current
  handle running.
- Published status maps to `FlowStatus`.
- Exposes `splitTree`, `paneSessions`, `workspaceDirectory`, and `focusedPaneSlotID` so `FlowStateView` can render the pane through `TerminalContentView`.

- [ ] **Step 4: Implement production pane launcher**

Production launcher uses the existing terminal surface infrastructure rather than a detached `Process`:

- Workspace: `AppState.defaultDirectory/flow-state/workspace`.
- Prompt file: `AppState.defaultDirectory/flow-state/system-prompt.md`.
- One reserved `PaneSlotID`, one reserved `PaneSessionID`, and `SplitTree(root: .leaf(slotID))`.
- Call `terminalManager.createSurface(terminalID:paneSessionID:worktreePath:extraInitialInput:)`.
- `worktreePath` is the Flow State workspace directory path, not any repo checkout.
- `extraInitialInput` is a single shell command that launches the selected runtime from the prompt file.

System-prompt and command construction:

- Claude: use `claude --system-prompt-file '<prompt-file>' --permission-mode manual --name 'Flow State'` when local help reports `--system-prompt-file`; fall back to `--append-system-prompt-file` only if needed.
- Codex: local help does not expose a system-prompt flag. Use an app-managed `CODEX_HOME` profile/config only if the installed Codex version supports a system/developer instruction config key; otherwise launch `codex --cd '<workspace>' '<bootstrap prompt text>'` and mark controller status as `runningWithBootstrapPrompt` so the UI is honest that this is a bootstrap prompt rather than a true system prompt.
- Both runtimes: pass the Flow State workspace as the working root, not a project worktree, and include `GRAFTTY_SOCK` in the environment so the agent can use `graftty flow`.

Quote paths with single-quote shell escaping. Put all runtime-specific command
construction behind
`FlowStateRuntime.launchCommand(promptFile:workspace:capabilities:socketPath:)`
and cover it with unit tests so later runtime flag changes do not leak through
the controller. The method returns command text, environment, and
`FlowPromptMode`. Keep capability detection injectable so tests do not shell out
to real Claude/Codex.

Record launch failure into controller status. Do not block the rest of Graftty.

Important hole to avoid: do not inject project worktree cwd. This agent is global and app-managed.

- [ ] **Step 5: Wire app lifecycle**

In `GrafttyApp`:

- Own a `@StateObject` or stored `FlowStateAgentController`.
- Register Flow State defaults before constructing settings.
- On app startup, call `ensureRunning()` when enabled.
- On settings changes, call `reconcileSettingsChanged()` and surface
  `pendingRestartReason` in Settings/Flow State view with Confirm Restart and
  Cancel actions.
- Inject lifecycle closures into `FlowStateSettingsPane` and `FlowStateView`.
- Make `flow status` response use controller status where possible.
- Own a `FlowStateRefreshCoordinator` instance.
- On Flow State view open, call `controller.requestRefresh(reason: "view opened")` when the coordinator allows it.
- On selected worktree changes, schedule a 30-second stability check; if the selection remains stable, request refresh.
- On worktree attention changes, request refresh only when the current focus block has been stable for at least 5 minutes.
- Run a background timer no more often than every 10 minutes while enabled.
- Use `FlowStateActivityStore` cooldowns so the controller/agent does not ask the same worktree for status more than once every 20 minutes unless the user clicks Refresh.

- [ ] **Step 6: Wire "Open Flow State Agent Pane"**

Because the Flow State agent is global, do not fake it as a normal repo worktree. Implement the visible pane inside the Flow State detail view:

- `FlowStateView` receives the controller and `TerminalManager`.
- If the controller has a live pane, render `TerminalContentView` with the controller's `splitTree`, `paneSessions`, and `focusedPaneSlotID`.
- If the pane is not running, render the recommendation/setup UI and a "Start Agent" action.
- The Flow State pane must not appear in `AppState.repos`, team lists, worktree navigation, or normal worktree deletion flows.
- Closing/stopping Flow State destroys only the controller-owned surface and zmx session.

- [ ] **Step 7: Run focused tests**

Run:

```bash
swift test --filter FlowStateAgentControllerTests
swift test --filter FlowStateRuntimeLaunchCommandTests
```

Expected: pass.

- [ ] **Step 8: Regenerate specs and commit**

Run:

```bash
scripts/generate-specs.py
git add Sources/Graftty/FlowState Sources/Graftty/GrafttyApp.swift Sources/Graftty/Views/Settings/FlowStateSettingsPane.swift Sources/Graftty/Views/FlowState/FlowStateView.swift Tests/GrafttyTests/FlowState/FlowStateAgentControllerTests.swift Tests/GrafttyTests/FlowState/FlowStateRuntimeLaunchCommandTests.swift SPECS.md
git commit -m "feat(flow): manage Flow State agent lifecycle"
```

---

### Task 9: Integration Verification And Cleanup

**Files:**
- Modify only files already touched by Tasks 1-8 unless a compile/test failure points to a specific exhaustive-switch or import fix.
- Update: `README.md` only if the implemented behavior is user-ready enough to document.

- [ ] **Step 1: Run targeted Flow State tests**

Run:

```bash
swift test --filter FlowState
swift test --filter Flow
```

Expected: pass.

- [ ] **Step 2: Run broader affected tests**

Run:

```bash
swift test --filter Notification
swift test --filter AgentTeamsSettingsPaneTests
swift test --filter AppStateTests
swift test --filter WorktreeNavigationTests
```

Expected: pass.

- [ ] **Step 3: Run specs generation check**

Run:

```bash
scripts/generate-specs.py --check
```

Expected: no diff / exit 0.

- [ ] **Step 4: Run full test suite**

Run:

```bash
swift test
```

Expected: pass. If the full suite hits a known unrelated flake, record the exact failure and rerun the failed test plus the narrower suites above.

- [ ] **Step 5: Manual CLI smoke test**

With Graftty running locally:

```bash
swift run graftty-cli flow status
swift run graftty-cli flow context
swift run graftty-cli flow request-status <worktreeRef> --explicit
cat /tmp/flow-recommendation.json | swift run graftty-cli flow publish --stdin
swift run graftty-cli flow recommend
```

Expected:

- `status` prints enabled/running availability.
- `context` prints JSON with worktrees.
- `request-status --explicit` sends one fixed-template status request or records
  a clear Flow State activity error if the worktree cannot be resolved.
- `publish` exits 0 for valid JSON.
- `recommend` prints the same recommendation JSON.

- [ ] **Step 6: Manual UI smoke test**

Launch the app from Xcode or:

```bash
swift run Graftty
```

Verify:

- Sidebar has top-level Flow State row above repos.
- Selecting Flow State does not clear the selected worktree.
- Flow State view renders latest recommendation or setup state.
- Settings has Flow State tab with enable/runtime/prompt controls.
- Invalid/empty recommendation does not crash the view.

- [ ] **Step 7: Final cleanup commit**

If cleanup changes were needed:

```bash
git add <changed-files>
git commit -m "test(flow): verify Flow State integration"
```

If no cleanup changes were needed, do not create an empty commit.
