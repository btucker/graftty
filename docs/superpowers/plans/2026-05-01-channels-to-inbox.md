# Replace Claude Channels with the Team Inbox - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Claude-only push channel surface (MCP server + socket router + launch flag) with a single producer-side `TeamEventDispatcher` that writes into the existing `TeamInbox`, so PR/CI/membership events flow through the same path as `team_message`. Add a SwiftUI **Team Activity Log** window to view inbox state. Delete every channel-only file.

**Architecture:** Producers (`PRStatusStore`, `TeamMembershipEvents`, the `team msg` / `team broadcast` CLI handlers) call `TeamEventDispatcher.dispatch(event:repos:)`. The dispatcher consults `TeamEventRoutingPreferences` (renamed from `ChannelRoutingPreferences`), renders a per-recipient body via `EventBodyRenderer.body(...)`, and writes one `TeamInbox.appendMessage(...)` row per recipient. Codex/Claude sessions consume rows at hook boundaries; the user views rows in the activity window via `TeamInboxObserver` (FSEvents tail).

**Tech Stack:** Swift 6 / Swift Testing + XCTest / SwiftUI / SwiftPM. Persistence is JSONL appended to `<App Support>/Graftty/team-inbox/<team-id>/messages.jsonl`. UserDefaults for prefs. `DispatchSource.makeFileSystemObjectSource` for file watching. The `claude` CLI subprocess for legacy MCP unregistration.

**Spec:** `docs/superpowers/specs/2026-05-01-channels-to-inbox-design.md`.

**Working directory:** `/Users/btucker/projects/graftty/.worktrees/codex-hooks` (the codex-hooks branch). Already merged with `origin/main`.

---

## Conventions

- **TDD:** every behavioral task starts with a failing Swift Testing `@Test`, then implementation, then green run.
- **Spec annotations (CLAUDE.md):** every new behavior adds `@spec <ID>: <EARS-text>` to the test title. Reworded specs update existing test titles. Deleted specs remove the test (or the `*Todo.swift` entry).
- **`SPECS.md`:** regenerate via `scripts/generate-specs.py` and commit alongside the code in every task that adds, removes, or rewords a `@spec` annotation. CI's `verify-specs` job runs `scripts/generate-specs.py --check`.
- **Build/test commands:**
  - `swift build` - whole package
  - `swift test --filter <SuiteOrTest>` - single suite or `@Test` name
  - `swift test` - everything (run at end of each phase)
- **Commits:** one per task. Do not amend; add new commits. No `--no-verify`.
- **No live channel breakage during phases 1-3:** the `ChannelRouter` stays alive and wired; producers route to both the dispatcher and the router until phase 2 task 2.5. Phase 4 is the actual delete.

---

## File Structure (target end state)

### New files

| Path | Responsibility |
|---|---|
| `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift` | Producer-side fan-out: matrix lookup, per-recipient render, inbox write |
| `Sources/GrafttyKit/Teams/TeamInboxObserver.swift` | Watches `<team>/messages.jsonl`, publishes `[TeamInboxMessage]` updates |
| `Sources/GrafttyKit/Teams/LegacyChannelCleanup.swift` | One-shot startup: unregister MCP, delete `~/.claude/.mcp.json`, delete plugin dir, scrub `defaultCommand` |
| `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogWindow.swift` | SwiftUI window scoped to one team |
| `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift` | Row renderer (chat bubble vs system entry) |
| `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift` | Dispatcher coverage |
| `Tests/GrafttyKitTests/Teams/TeamInboxObserverTests.swift` | FSEvents tail coverage |
| `Tests/GrafttyKitTests/Teams/LegacyChannelCleanupTests.swift` | Cleanup coverage |
| `Tests/GrafttyKitTests/PRStatus/PRStatusStoreInboxBridgeTests.swift` | PR transitions land in inbox |
| `Tests/GrafttyKitTests/Teams/TeamMembershipEventsInboxTests.swift` | Joined/left land in inbox |
| `Tests/GrafttyTests/Views/TeamActivityLogWindowTests.swift` | Window-level coverage |
| `Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift` | Row renderer coverage |

### Renamed/relocated files

| From | To |
|---|---|
| `Sources/GrafttyKit/Channels/EventBodyRenderer.swift` | `Sources/GrafttyKit/Teams/EventBodyRenderer.swift` |
| `Sources/GrafttyKit/Channels/RoutableEvent.swift` | `Sources/GrafttyKit/Teams/RoutableEvent.swift` |
| `Sources/GrafttyKit/Channels/ChannelRoutingPreferences.swift` | `Sources/GrafttyKit/Teams/TeamEventRoutingPreferences.swift` (renamed) |
| `Sources/GrafttyKit/Channels/ChannelEvent.swift` (event-type constants only) | merged into `Sources/GrafttyKit/Teams/TeamChannelEvents.swift` (renamed `TeamEvents.swift`) |
| `Sources/Graftty/Channels/SettingsKeys.swift` | `Sources/Graftty/Settings/SettingsKeys.swift` |
| `Sources/Graftty/Channels/DefaultPrompts.swift` | `Sources/Graftty/Settings/DefaultPrompts.swift` |

### Deleted files

| File | Reason |
|---|---|
| `Sources/GrafttyKit/Channels/ChannelRouter.swift` | No more push channel |
| `Sources/GrafttyKit/Channels/ChannelSocketServer.swift` | No socket server |
| `Sources/GrafttyKit/Channels/MCPStdioServer.swift` | No MCP server |
| `Sources/GrafttyKit/Channels/ChannelMCPInstaller.swift` | Cleanup logic moves to `LegacyChannelCleanup` |
| `Sources/GrafttyKit/Channels/ChannelEventRouter.swift` | Folded into `TeamEventDispatcher` |
| `Sources/Graftty/Channels/ChannelSettingsObserver.swift` | Nothing to observe |
| `Sources/GrafttyCLI/MCPChannel.swift` | `graftty mcp channel` removed |
| `Sources/GrafttyCLI/ChannelSocketClient.swift` | No socket to dial |
| Plus: every test file under `Tests/GrafttyKitTests/Channels/`, `Tests/GrafttyTests/Channels/`, `Tests/GrafttyCLITests/MCPChannel*`, etc. |

---

## Phase 1: TeamEventDispatcher (no producer wired yet)

Goal: a working `TeamEventDispatcher` that, given a routable event and a `repos` snapshot, writes the right inbox rows. Channel router still receives events from existing producers - phase 1 is purely additive.

### Task 1.1: Add `TeamInboxEndpoint.system(repoPath:)` factory

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInbox.swift` (around line 14, struct `TeamInboxEndpoint`)
- Test: `Tests/GrafttyKitTests/Teams/TeamInboxEndpointTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyKitTests/Teams/TeamInboxEndpointTests.swift`:

```swift
import Testing
@testable import GrafttyKit

@Suite("TeamInboxEndpoint")
struct TeamInboxEndpointTests {
    @Test("@spec TEAM-5.4: When constructing a system endpoint, the application shall produce an endpoint with member='system', worktree=<repoPath>, and runtime=nil.")
    func systemEndpointShape() {
        let endpoint = TeamInboxEndpoint.system(repoPath: "/repo")
        #expect(endpoint.member == "system")
        #expect(endpoint.worktree == "/repo")
        #expect(endpoint.runtime == nil)
    }

    @Test("system endpoint round-trips through Codable")
    func systemEndpointCodable() throws {
        let endpoint = TeamInboxEndpoint.system(repoPath: "/repo")
        let data = try JSONEncoder().encode(endpoint)
        let decoded = try JSONDecoder().decode(TeamInboxEndpoint.self, from: data)
        #expect(decoded == endpoint)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter TeamInboxEndpointTests
```

Expected: FAIL - `system(repoPath:)` not defined.

- [ ] **Step 3: Add factory**

In `Sources/GrafttyKit/Teams/TeamInbox.swift`, append after the `TeamInboxEndpoint` struct's existing `init`:

```swift
extension TeamInboxEndpoint {
    /// Synthetic sender used by automated team events (PR/CI/membership)
    /// where there is no human author. The activity window and hook
    /// renderers detect `member == "system"` and present these rows
    /// differently from chat messages.
    public static func system(repoPath: String) -> TeamInboxEndpoint {
        TeamInboxEndpoint(member: "system", worktree: repoPath, runtime: nil)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter TeamInboxEndpointTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Regenerate specs and commit**

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/Teams/TeamInbox.swift \
        Tests/GrafttyKitTests/Teams/TeamInboxEndpointTests.swift \
        SPECS.md
git commit -m "feat(teams): add TeamInboxEndpoint.system factory (TEAM-5.4)"
```

---

### Task 1.2: `TeamEventDispatcher` skeleton + `team_message` unicast

**Files:**
- Create: `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`
- Create: `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamEventDispatcher")
struct TeamEventDispatcherTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("teamEventDispatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("@spec TEAM-5.1: When team_message is dispatched, the application shall append exactly one inbox row addressed to the named recipient.")
    func teamMessageWritesOneRowToRecipient() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root)
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )

        try dispatcher.dispatchTeamMessage(
            from: "alice",
            to: "main",
            text: "ping",
            priority: .normal,
            repos: [repo],
            teamsEnabled: true
        )

        let teamID = TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true).map { TeamID(team: $0) }!
        let messages = try inbox.messages(teamID: teamID.value)
        #expect(messages.count == 1)
        #expect(messages.first?.from.member == "alice")
        #expect(messages.first?.to.member == "main")
        #expect(messages.first?.body == "ping")
        #expect(messages.first?.kind == "team_message")
    }
}
```

(`TeamTestFixtures.makeRepo` already exists in the kit tests under `Tests/GrafttyKitTests/Teams/TeamTestFixtures.swift`. `TeamID` is a small wrapper computed by `TeamInboxRequestHandler`; we're going to reuse the same logic.)

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter TeamEventDispatcherTests
```

Expected: FAIL - `TeamEventDispatcher` not defined.

- [ ] **Step 3: Implement skeleton**

Create `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`:

```swift
import Foundation
import os

/// Single producer-side fan-out for every team event. Replaces the
/// channel-router dispatch path; consumers (hook handler, activity
/// window) read directly from the inbox.
///
/// Owns three concerns:
/// 1. Matrix lookup - which worktrees should receive a given event
/// 2. Per-recipient body rendering via `EventBodyRenderer`
/// 3. One `TeamInbox.appendMessage` per resolved recipient
public final class TeamEventDispatcher {
    private static let logger = Logger(subsystem: "com.btucker.graftty", category: "TeamEventDispatcher")

    private let inbox: TeamInbox
    private let preferencesProvider: () -> TeamEventRoutingPreferences
    private let templateProvider: () -> String

    public init(
        inbox: TeamInbox,
        preferencesProvider: @escaping () -> TeamEventRoutingPreferences,
        templateProvider: @escaping () -> String
    ) {
        self.inbox = inbox
        self.preferencesProvider = preferencesProvider
        self.templateProvider = templateProvider
    }

    /// Dispatch a unicast `team_message` (TEAM-5.1).
    public func dispatchTeamMessage(
        from sender: String,
        to recipientName: String,
        text: String,
        priority: TeamInboxPriority,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws {
        guard teamsEnabled else { return }
        guard let senderMember = TeamLookup.member(named: sender, in: repos),
              let team = TeamLookup.team(for: senderMember.worktreePath, in: repos),
              let recipientMember = team.memberNamed(recipientName)
        else { return }

        try inbox.appendMessage(
            teamID: TeamLookup.id(of: team),
            teamName: team.repoDisplayName,
            repoPath: team.repoPath,
            from: TeamInboxEndpoint(member: senderMember.name, worktree: senderMember.worktreePath, runtime: nil),
            to: TeamInboxEndpoint(member: recipientMember.name, worktree: recipientMember.worktreePath, runtime: nil),
            priority: priority,
            body: text
        )
    }
}
```

The `TeamLookup` helper centralizes the existing `TeamView.team(for:in:teamsEnabled:)` logic (already in the kit). If it doesn't exist as a public type, add a `TeamLookup` enum next to `TeamView` exposing `team(for:in:)`, `member(named:in:)`, and `id(of:)` - the team-id derivation that `TeamInboxRequestHandler` does inline today.

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter TeamEventDispatcherTests
```

Expected: PASS.

- [ ] **Step 5: Regenerate specs and commit**

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/Teams/TeamEventDispatcher.swift \
        Sources/GrafttyKit/Teams/TeamLookup.swift \
        Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift \
        SPECS.md
git commit -m "feat(teams): TeamEventDispatcher skeleton + team_message unicast (TEAM-5.1)"
```

---

### Task 1.3: Dispatcher fans out PR/CI matrix events

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `TeamEventDispatcherTests.swift`:

```swift
@Test("@spec TEAM-5.5: When PRStatusStore fires pr_state_changed (non-merged), the dispatcher shall write one inbox row per recipient resolved via the prStateChanged matrix row.")
func prStateChangedFansOutPerMatrix() throws {
    let root = try Self.temporaryDirectory()
    let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice", "bob"])
    let inbox = TeamInbox(rootDirectory: root)
    let prefs = TeamEventRoutingPreferences(
        prStateChanged: [.worktree, .otherWorktrees],
        prMerged: [.root],
        ciConclusionChanged: [.worktree],
        mergabilityChanged: [.worktree]
    )
    let dispatcher = TeamEventDispatcher(
        inbox: inbox,
        preferencesProvider: { prefs },
        templateProvider: { "" }
    )

    let event = ChannelServerMessage.event(
        type: ChannelEventType.prStateChanged,
        attrs: ["worktree": "/repo/.worktrees/alice", "to": "open", "from": "draft", "pr_number": "42", "pr_url": "https://x", "provider": "github", "repo": "x/y"],
        body: "PR #42 state changed: draft → open"
    )

    try dispatcher.dispatchRoutableEvent(
        event,
        subjectWorktreePath: "/repo/.worktrees/alice",
        repos: [repo]
    )

    let team = TeamView.team(for: repo.worktrees[1], in: [repo], teamsEnabled: true)!
    let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
    #expect(messages.count == 2)
    let recipientPaths = Set(messages.map { $0.to.worktree })
    #expect(recipientPaths == ["/repo/.worktrees/alice", "/repo/.worktrees/bob"])
    #expect(messages.allSatisfy { $0.kind == "pr_state_changed" })
    #expect(messages.allSatisfy { $0.from.member == "system" })
}

@Test("@spec TEAM-5.6: When pr_state_changed has attrs.to == 'merged', the dispatcher shall use the prMerged matrix row.")
func prMergedUsesMergedRow() throws {
    let root = try Self.temporaryDirectory()
    let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
    let inbox = TeamInbox(rootDirectory: root)
    let prefs = TeamEventRoutingPreferences(
        prStateChanged: [],
        prMerged: [.root],
        ciConclusionChanged: [],
        mergabilityChanged: []
    )
    let dispatcher = TeamEventDispatcher(
        inbox: inbox,
        preferencesProvider: { prefs },
        templateProvider: { "" }
    )

    let event = ChannelServerMessage.event(
        type: ChannelEventType.prStateChanged,
        attrs: ["worktree": "/repo/.worktrees/alice", "to": "merged", "from": "open", "pr_number": "42", "pr_url": "https://x", "provider": "github", "repo": "x/y"],
        body: "PR #42 state changed: open → merged"
    )

    try dispatcher.dispatchRoutableEvent(
        event,
        subjectWorktreePath: "/repo/.worktrees/alice",
        repos: [repo]
    )

    let team = TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true)!
    let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
    #expect(messages.count == 1)
    #expect(messages.first?.to.worktree == "/repo")  // root only
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter TeamEventDispatcherTests
```

Expected: FAIL - `dispatchRoutableEvent` not defined.

- [ ] **Step 3: Add the method**

Append to `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`:

```swift
extension TeamEventDispatcher {
    /// Dispatch a routable matrix-governed event (PR/CI/merge). Computes
    /// recipients via `TeamEventRoutingPreferences`, renders the body
    /// through `EventBodyRenderer.body`, writes one inbox row per recipient.
    public func dispatchRoutableEvent(
        _ event: ChannelServerMessage,
        subjectWorktreePath: String,
        repos: [RepoEntry]
    ) throws {
        guard case let .event(eventType, attrs, _) = event else { return }
        guard let routable = RoutableEvent(channelEventType: eventType, attrs: attrs) else { return }
        guard let team = TeamLookup.team(for: subjectWorktreePath, in: repos) else { return }

        let prefs = preferencesProvider()
        let template = templateProvider()
        let recipients = TeamEventRouter.recipients(
            event: routable,
            subjectWorktreePath: subjectWorktreePath,
            repos: repos,
            preferences: prefs
        )

        for recipientPath in recipients {
            guard let recipientMember = team.members.first(where: { $0.worktreePath == recipientPath }) else { continue }
            let renderedMessage = EventBodyRenderer.body(
                for: event,
                recipientWorktreePath: recipientPath,
                subjectWorktreePath: subjectWorktreePath,
                repos: repos,
                templateString: template
            )
            guard case let .event(_, _, renderedBody) = renderedMessage else { continue }

            try inbox.appendMessage(
                teamID: TeamLookup.id(of: team),
                teamName: team.repoDisplayName,
                repoPath: team.repoPath,
                from: .system(repoPath: team.repoPath),
                to: TeamInboxEndpoint(member: recipientMember.name, worktree: recipientMember.worktreePath, runtime: nil),
                priority: .normal,
                kind: eventType,
                body: renderedBody
            )
        }
    }
}
```

You'll need to extend `TeamInbox.appendMessage` to accept an optional `kind:` parameter (defaulting to `"team_message"`) - check `Sources/GrafttyKit/Teams/TeamInbox.swift` line 128 and add the parameter, then update the existing one call site in `TeamInboxRequestHandler.send` and the new call sites here. Also add `TeamEventRouter.recipients(...)`, which is a verbatim port of `ChannelEventRouter.recipients(...)` but takes `TeamEventRoutingPreferences` instead of `ChannelRoutingPreferences`. (Currently those are the same type pre-rename - so until phase 5 this is just a forwarding alias. After phase 5 both halves are renamed atomically.)

For now (phase 1), put `TeamEventRouter` in `Sources/GrafttyKit/Teams/TeamEventRouter.swift` as:

```swift
import Foundation

/// Resolves the set of recipient worktree paths for a routable team event.
/// Phase-1 shim: forwards to the existing `ChannelEventRouter` until phase 5.
public enum TeamEventRouter {
    public static func recipients(
        event: RoutableEvent,
        subjectWorktreePath: String,
        repos: [RepoEntry],
        preferences: TeamEventRoutingPreferences
    ) -> [String] {
        ChannelEventRouter.recipients(
            event: event,
            subjectWorktreePath: subjectWorktreePath,
            repos: repos,
            preferences: preferences
        )
    }
}

public typealias TeamEventRoutingPreferences = ChannelRoutingPreferences
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter TeamEventDispatcherTests
```

Expected: PASS (3 tests).

- [ ] **Step 5: Regenerate specs and commit**

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/Teams/TeamEventDispatcher.swift \
        Sources/GrafttyKit/Teams/TeamEventRouter.swift \
        Sources/GrafttyKit/Teams/TeamInbox.swift \
        Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift \
        Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift \
        SPECS.md
git commit -m "feat(teams): dispatch routable PR/CI events via inbox (TEAM-5.5, TEAM-5.6)"
```

---

### Task 1.4: Dispatcher fans out membership events to lead

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `TeamEventDispatcherTests.swift`:

```swift
@Test("@spec TEAM-5.7: When a worktree joins a team-enabled repo, the dispatcher shall append one team_member_joined inbox row addressed to the lead.")
func memberJoinedAddressesLead() throws {
    let root = try Self.temporaryDirectory()
    let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
    let inbox = TeamInbox(rootDirectory: root)
    let dispatcher = TeamEventDispatcher(
        inbox: inbox,
        preferencesProvider: { TeamEventRoutingPreferences() },
        templateProvider: { "" }
    )

    try dispatcher.dispatchMemberJoined(
        joinerWorktreePath: "/repo/.worktrees/alice",
        repos: [repo]
    )

    let team = TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true)!
    let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
    #expect(messages.count == 1)
    #expect(messages.first?.to.worktree == "/repo")
    #expect(messages.first?.kind == "team_member_joined")
    #expect(messages.first?.from.member == "system")
}

@Test("@spec TEAM-5.8: When a worktree is removed from a team-enabled repo, the dispatcher shall append one team_member_left inbox row addressed to the lead.")
func memberLeftAddressesLead() throws {
    let root = try Self.temporaryDirectory()
    let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main"])  // alice is gone
    let inbox = TeamInbox(rootDirectory: root)
    let dispatcher = TeamEventDispatcher(
        inbox: inbox,
        preferencesProvider: { TeamEventRoutingPreferences() },
        templateProvider: { "" }
    )

    try dispatcher.dispatchMemberLeft(
        leaverBranch: "alice",
        leaverWorktreePath: "/repo/.worktrees/alice",
        reason: .removed,
        repos: [repo]
    )

    let team = TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true)
    // team is nil for a single-worktree repo, so we skip via teamID lookup another way:
    // actually, the dispatcher should still produce the row even if the team has shrunk to 1 worktree.
    // The team-id derivation needs the repo path, which is stable.
    let teamID = TeamLookup.id(forRepoPath: "/repo")
    let messages = try inbox.messages(teamID: teamID)
    #expect(messages.count == 1)
    #expect(messages.first?.to.worktree == "/repo")
    #expect(messages.first?.kind == "team_member_left")
}
```

- [ ] **Step 2: Run tests to verify they fail**

```
swift test --filter TeamEventDispatcherTests
```

Expected: FAIL - `dispatchMemberJoined` / `dispatchMemberLeft` not defined.

- [ ] **Step 3: Implement**

Append to `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`:

```swift
extension TeamEventDispatcher {
    /// Dispatch `team_member_joined` to the team lead.
    public func dispatchMemberJoined(
        joinerWorktreePath: String,
        repos: [RepoEntry]
    ) throws {
        guard let repo = repos.first(where: { repo in
            repo.worktrees.contains(where: { $0.path == joinerWorktreePath })
        }) else { return }
        guard repo.worktrees.count >= 2 else { return }
        guard let joiner = repo.worktrees.first(where: { $0.path == joinerWorktreePath }) else { return }
        guard repo.path != joinerWorktreePath else { return }  // joiner is the lead

        let event = TeamChannelEvents.memberJoined(
            team: repo.displayName,
            member: WorktreeNameSanitizer.sanitize(joiner.branch),
            branch: joiner.branch,
            worktree: joiner.path
        )
        try writeSystemRow(
            event: event,
            kind: TeamChannelEvents.EventType.memberJoined,
            recipientPath: repo.path,  // lead only
            repos: repos
        )
    }

    /// Dispatch `team_member_left` to the team lead.
    public func dispatchMemberLeft(
        leaverBranch: String,
        leaverWorktreePath: String,
        reason: TeamChannelEvents.LeaveReason,
        repos: [RepoEntry]
    ) throws {
        guard let repo = repos.first(where: { repo in
            repo.worktrees.contains(where: { $0.path == repo.path })
                && repo.path == repoPathFor(leaverWorktreePath: leaverWorktreePath, repos: repos)
        }) ?? repos.first(where: { $0.path == repoPathFor(leaverWorktreePath: leaverWorktreePath, repos: repos) })
        else { return }
        // Notify the lead only if the lead is still present.
        guard repo.worktrees.contains(where: { $0.path == repo.path }) else { return }
        guard leaverWorktreePath != repo.path else { return }  // leaver was the lead

        let event = TeamChannelEvents.memberLeft(
            team: repo.displayName,
            member: WorktreeNameSanitizer.sanitize(leaverBranch),
            reason: reason
        )
        try writeSystemRow(
            event: event,
            kind: TeamChannelEvents.EventType.memberLeft,
            recipientPath: repo.path,
            repos: repos
        )
    }

    private func repoPathFor(leaverWorktreePath: String, repos: [RepoEntry]) -> String {
        // The leaver's worktreePath of form "<repo.path>/.worktrees/<branch>" lets us
        // recover the repo path by trimming the suffix. This is the same pattern
        // TeamMembershipEvents.fireLeft uses today.
        if let cut = leaverWorktreePath.range(of: "/.worktrees/") {
            return String(leaverWorktreePath[..<cut.lowerBound])
        }
        return leaverWorktreePath
    }

    private func writeSystemRow(
        event: ChannelServerMessage,
        kind: String,
        recipientPath: String,
        repos: [RepoEntry]
    ) throws {
        guard let team = TeamLookup.team(for: recipientPath, in: repos) ?? TeamLookup.teamForRepoPath(recipientPath, in: repos),
              let recipientMember = team.members.first(where: { $0.worktreePath == recipientPath })
                ?? TeamLookup.fallbackLeadMember(forRepoPath: recipientPath)
        else {
            // Even with a one-worktree repo, we still want to write the row so the
            // lead sees it on next session start. Use a synthetic recipient endpoint.
            try inbox.appendMessage(
                teamID: TeamLookup.id(forRepoPath: recipientPath),
                teamName: lookupRepoDisplayName(recipientPath, in: repos),
                repoPath: recipientPath,
                from: .system(repoPath: recipientPath),
                to: TeamInboxEndpoint(member: "lead", worktree: recipientPath, runtime: nil),
                priority: .normal,
                kind: kind,
                body: extractBody(event)
            )
            return
        }

        try inbox.appendMessage(
            teamID: TeamLookup.id(of: team),
            teamName: team.repoDisplayName,
            repoPath: team.repoPath,
            from: .system(repoPath: team.repoPath),
            to: TeamInboxEndpoint(member: recipientMember.name, worktree: recipientMember.worktreePath, runtime: nil),
            priority: .normal,
            kind: kind,
            body: extractBody(event)
        )
    }

    private func extractBody(_ event: ChannelServerMessage) -> String {
        if case let .event(_, _, body) = event { return body }
        return ""
    }

    private func lookupRepoDisplayName(_ repoPath: String, in repos: [RepoEntry]) -> String {
        repos.first(where: { $0.path == repoPath })?.displayName ?? repoPath
    }
}
```

(`TeamLookup.teamForRepoPath` and `TeamLookup.fallbackLeadMember` are extensions you'll add to `TeamLookup` to handle the one-worktree-repo case for `team_member_left`.)

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter TeamEventDispatcherTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Regenerate specs and commit**

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/Teams/TeamEventDispatcher.swift \
        Sources/GrafttyKit/Teams/TeamLookup.swift \
        Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift \
        SPECS.md
git commit -m "feat(teams): dispatch member_joined/left to lead via inbox (TEAM-5.7, TEAM-5.8)"
```

---

## Phase 2: Wire producers through the dispatcher

Goal: `PRStatusStore`, `TeamMembershipEvents`, and the `team msg`/`team broadcast` CLI handlers stop calling `ChannelRouter.dispatch` and start calling `TeamEventDispatcher` instead. Channel router stays alive but receives no events.

### Task 2.1: `PRStatusStore.onTransition` switches signature to `(RoutableEvent, String) -> Void`

**Files:**
- Modify: `Sources/GrafttyKit/PRStatus/PRStatusStore.swift` (line 54 - `onTransition` declaration; 314+ - emission sites)
- Modify: existing `PRStatusStore` tests
- Test: existing tests verify shape

- [ ] **Step 1: Write the failing test**

Modify the existing `PRStatusStoreTests` (or add to it) with a test asserting the new closure shape. Since the closure type is changing, the test enforces the new contract:

```swift
@Test("@spec TEAM-5.5 (revised): PRStatusStore.onTransition delivers the routable event plus the subject worktree path; raw ChannelServerMessage construction lives at the dispatcher boundary now.")
func onTransitionDeliversRoutableEvent() throws {
    let store = PRStatusStore(remoteBranchStore: nil)
    var captured: [(RoutableEvent, String, [String: String])] = []
    store.onTransition = { event, worktreePath, attrs in
        captured.append((event, worktreePath, attrs))
    }

    store.detectAndFireTransitionsForTesting(
        worktreePath: "/repo/.worktrees/alice",
        previous: PRInfo(number: 42, state: .open, checks: .pending, title: "x", url: URL(string: "https://x")!),
        current: PRInfo(number: 42, state: .merged, checks: .pending, title: "x", url: URL(string: "https://x")!),
        origin: HostingOrigin(provider: .github, slug: "x/y")
    )

    #expect(captured.count == 1)
    #expect(captured.first?.0 == .prMerged)
    #expect(captured.first?.1 == "/repo/.worktrees/alice")
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter PRStatusStoreTests/onTransitionDeliversRoutableEvent
```

Expected: FAIL - the closure type and the emission shape don't match.

- [ ] **Step 3: Change the closure signature and emission sites**

In `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`:

Replace line 54:

```swift
@ObservationIgnored public var onTransition: (@MainActor (_ event: RoutableEvent, _ worktreePath: String, _ attrs: [String: String]) -> Void)?
```

In `detectAndFireTransitions`, replace `onTransition(worktreePath, .event(...))` calls with:

```swift
if previous.state != current.state {
    var attrs = common
    attrs["from"] = previous.state.rawValue
    attrs["to"] = current.state.rawValue
    attrs["pr_title"] = current.title
    let routable: RoutableEvent = (current.state == .merged) ? .prMerged : .prStateChanged
    onTransition(routable, worktreePath, attrs)
}

if previous.checks != current.checks {
    var attrs = common
    attrs["from"] = previous.checks.rawValue
    attrs["to"] = current.checks.rawValue
    onTransition(.ciConclusionChanged, worktreePath, attrs)
}
```

Update the doc comment on `onTransition` to describe the new shape (delivering a routable-event-shaped tuple, not a `ChannelServerMessage`).

- [ ] **Step 4: Update the only caller in `GrafttyApp.swift`**

In `Sources/Graftty/GrafttyApp.swift` around line 123, replace the entire `prStatusStore.onTransition = …` block with:

```swift
self.prStatusStore.onTransition = { [weak self] routable, subjectWorktreePath, attrs in
    guard let self else { return }
    guard UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled) else { return }
    let appState = self.appStateProvider?() ?? AppState()
    let event = ChannelServerMessage.event(
        type: routable.wireType,
        attrs: attrs,
        body: routable.defaultBody(attrs: attrs)
    )
    do {
        try self.teamEventDispatcher.dispatchRoutableEvent(
            event,
            subjectWorktreePath: subjectWorktreePath,
            repos: appState.repos
        )
    } catch {
        NSLog("[Graftty] dispatchRoutableEvent failed: %@", String(describing: error))
    }
}
```

`teamEventDispatcher` is a new field on `AppServices`; you'll add the property and constructor wiring as part of this task. Add to `AppServices`:

```swift
let teamEventDispatcher: TeamEventDispatcher
```

In `AppServices.init`, after constructing `TeamInbox`:

```swift
let inbox = TeamInbox(
    rootDirectory: AppState.defaultDirectory
        .appendingPathComponent("team-inbox", isDirectory: true)
)
self.teamEventDispatcher = TeamEventDispatcher(
    inbox: inbox,
    preferencesProvider: {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.channelRoutingPreferences) ?? ""
        return TeamEventRoutingPreferences(rawValue: raw) ?? TeamEventRoutingPreferences()
    },
    templateProvider: {
        UserDefaults.standard.string(forKey: SettingsKeys.teamPrompt) ?? ""
    }
)
```

(The `TeamInbox` instance is currently constructed inside `teamInboxRequestHandler()` static helper; lift it to a stored property so the dispatcher and the handler share it.)

`RoutableEvent.wireType` and `defaultBody(attrs:)` are tiny helpers - add to `Sources/GrafttyKit/Channels/RoutableEvent.swift`:

```swift
extension RoutableEvent {
    /// The wire-format `type` string used in `ChannelServerMessage.event(type:…)`.
    public var wireType: String {
        switch self {
        case .prStateChanged, .prMerged:
            return ChannelEventType.prStateChanged
        case .ciConclusionChanged:
            return ChannelEventType.ciConclusionChanged
        case .mergabilityChanged:
            return ChannelEventType.mergeStateChanged
        }
    }

    /// Default body string built from the event's attrs. Used by the
    /// dispatcher when reconstructing a ChannelServerMessage from the
    /// (event, attrs, worktreePath) tuple emitted by PRStatusStore.
    public func defaultBody(attrs: [String: String]) -> String {
        let prNum = attrs["pr_number"] ?? "?"
        switch self {
        case .prStateChanged, .prMerged:
            let from = attrs["from"] ?? "?"
            let to = attrs["to"] ?? "?"
            return "PR #\(prNum) state changed: \(from) → \(to)"
        case .ciConclusionChanged:
            let from = attrs["from"] ?? "?"
            let to = attrs["to"] ?? "?"
            return "CI on PR #\(prNum): \(from) → \(to)"
        case .mergabilityChanged:
            let from = attrs["from"] ?? "?"
            let to = attrs["to"] ?? "?"
            return "PR #\(prNum) mergability: \(from) → \(to)"
        }
    }
}
```

- [ ] **Step 5: Run tests**

```
swift build
swift test --filter PRStatusStoreTests
swift test --filter TeamEventDispatcherTests
```

Expected: all green.

- [ ] **Step 6: Regenerate specs and commit**

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/PRStatus/PRStatusStore.swift \
        Sources/GrafttyKit/Channels/RoutableEvent.swift \
        Sources/Graftty/GrafttyApp.swift \
        Tests/GrafttyKitTests/PRStatus/PRStatusStoreTests.swift \
        SPECS.md
git commit -m "refactor(pr-status): emit RoutableEvent from onTransition; dispatch via inbox"
```

---

### Task 2.2: `TeamMembershipEvents.fire*` switch dispatch type to dispatcher calls

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamMembershipEvents.swift`
- Modify: `Sources/Graftty/AddWorktreeFlow.swift` (line 177 area)
- Modify: `Sources/Graftty/Views/MainWindow.swift` (line 620 area)
- Modify: existing `TeamMembershipEventsTests`

- [ ] **Step 1: Write the failing test**

In `Tests/GrafttyKitTests/Teams/TeamMembershipEventsInboxTests.swift` (new file):

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamMembershipEvents writes to TeamInbox")
struct TeamMembershipEventsInboxTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("teamMembershipInboxTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("@spec TEAM-5.7 (revised): TeamMembershipEvents.fireJoined writes a team_member_joined inbox row addressed to the lead.")
    func fireJoinedWritesInboxRow() throws {
        let root = try Self.temporaryDirectory()
        let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
        let inbox = TeamInbox(rootDirectory: root)
        let dispatcher = TeamEventDispatcher(
            inbox: inbox,
            preferencesProvider: { TeamEventRoutingPreferences() },
            templateProvider: { "" }
        )

        TeamMembershipEvents.fireJoined(
            repo: repo,
            joinerWorktreePath: "/repo/.worktrees/alice",
            teamsEnabled: true,
            dispatcher: dispatcher
        )

        let team = TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true)!
        let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
        #expect(messages.count == 1)
        #expect(messages.first?.kind == "team_member_joined")
        #expect(messages.first?.to.worktree == "/repo")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter TeamMembershipEventsInboxTests
```

Expected: FAIL - `dispatcher:` parameter not yet accepted.

- [ ] **Step 3: Change the API**

In `Sources/GrafttyKit/Teams/TeamMembershipEvents.swift`, replace the `dispatch:` closure parameter with a `dispatcher: TeamEventDispatcher`:

```swift
public static func fireJoined(
    repo: RepoEntry,
    joinerWorktreePath: String,
    teamsEnabled: Bool,
    dispatcher: TeamEventDispatcher
) {
    guard teamsEnabled, repo.worktrees.count >= 2 else { return }
    guard repo.worktrees.contains(where: { $0.path == joinerWorktreePath }) else { return }
    guard repo.path != joinerWorktreePath else { return }

    do {
        try dispatcher.dispatchMemberJoined(
            joinerWorktreePath: joinerWorktreePath,
            repos: [repo]
        )
    } catch {
        NSLog("[Graftty] fireJoined dispatch failed: %@", String(describing: error))
    }
}

public static func fireLeft(
    repo: RepoEntry,
    leaverBranch: String,
    leaverPath: String,
    reason: TeamChannelEvents.LeaveReason,
    teamsEnabled: Bool,
    dispatcher: TeamEventDispatcher
) {
    guard teamsEnabled else { return }
    guard repo.worktrees.contains(where: { $0.path == repo.path }) else { return }
    guard leaverPath != repo.path else { return }

    do {
        try dispatcher.dispatchMemberLeft(
            leaverBranch: leaverBranch,
            leaverWorktreePath: leaverPath,
            reason: reason,
            repos: [repo]
        )
    } catch {
        NSLog("[Graftty] fireLeft dispatch failed: %@", String(describing: error))
    }
}
```

Update both call sites:

- `Sources/Graftty/AddWorktreeFlow.swift` line 177 - replace the `dispatch: EventBodyRenderer.dispatchClosure(...)` with `dispatcher: services.teamEventDispatcher`. The `services` reference needs to be threaded through the call chain (probably by adding a `teamEventDispatcher` parameter to `AddWorktreeFlow.add(...)`).
- `Sources/Graftty/Views/MainWindow.swift` line 620 - same swap. Thread `services.teamEventDispatcher` from `MainWindow`'s init.

- [ ] **Step 4: Run all team tests**

```
swift build
swift test --filter "TeamMembershipEventsInboxTests|TeamMembershipEvents"
```

Expected: all green.

- [ ] **Step 5: Regenerate and commit**

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/Teams/TeamMembershipEvents.swift \
        Sources/Graftty/AddWorktreeFlow.swift \
        Sources/Graftty/Views/MainWindow.swift \
        Sources/Graftty/GrafttyApp.swift \
        Tests/GrafttyKitTests/Teams/TeamMembershipEventsInboxTests.swift \
        SPECS.md
git commit -m "refactor(teams): TeamMembershipEvents writes through TeamEventDispatcher"
```

---

### Task 2.3: `team msg` / `team broadcast` use the dispatcher

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift` (`send`, `broadcast` methods)
- Modify: `Sources/Graftty/GrafttyApp.swift` (`handleTeamMessage`, `handleTeamBroadcast`, `dispatchTeamChannel`)

The current `TeamInboxRequestHandler.send` already writes to `TeamInbox`, then `dispatchTeamChannel` writes to the channel router. We collapse the second write so only the dispatcher handles it.

- [ ] **Step 1: Add a failing test** (skip if 1.2's `teamMessageWritesOneRowToRecipient` already covers; otherwise expand)

Verify in the existing `TeamInboxRequestHandlerTests.sendAppendsAddressedMessage` that the row is now written through the dispatcher path with the expected shape. (It should already be — `TeamInbox.appendMessage` is the same; the dispatcher just adds matrix/render logic.) Add a regression test asserting the rendered body for non-empty `teamPrompt`:

```swift
@Test("@spec TEAM-5.1 (revised): When team_message is dispatched and teamPrompt is non-empty, the rendered prompt is prepended to the body before the inbox write.")
func teamMessageRespectsTeamPromptTemplate() throws {
    let root = try Self.temporaryDirectory()
    let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
    let inbox = TeamInbox(rootDirectory: root)
    let dispatcher = TeamEventDispatcher(
        inbox: inbox,
        preferencesProvider: { TeamEventRoutingPreferences() },
        templateProvider: { "From {{ agent.branch }}: " }
    )

    try dispatcher.dispatchTeamMessage(
        from: "alice",
        to: "main",
        text: "ping",
        priority: .normal,
        repos: [repo],
        teamsEnabled: true
    )

    let team = TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true)!
    let messages = try inbox.messages(teamID: TeamLookup.id(of: team))
    #expect(messages.first?.body.hasPrefix("From main:") == true)
    #expect(messages.first?.body.contains("ping") == true)
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter TeamEventDispatcherTests/teamMessageRespectsTeamPromptTemplate
```

Expected: FAIL - `dispatchTeamMessage` does not currently invoke `EventBodyRenderer.body`.

- [ ] **Step 3: Render in `dispatchTeamMessage`**

Change `dispatchTeamMessage`'s body to:

```swift
let template = templateProvider()
let event = TeamChannelEvents.teamMessage(
    team: team.repoDisplayName,
    from: senderMember.name,
    text: text
)
let renderedMessage = EventBodyRenderer.body(
    for: event,
    recipientWorktreePath: recipientMember.worktreePath,
    subjectWorktreePath: nil,
    repos: repos,
    templateString: template
)
let renderedBody: String = {
    if case let .event(_, _, body) = renderedMessage { return body }
    return text
}()

try inbox.appendMessage(
    teamID: TeamLookup.id(of: team),
    teamName: team.repoDisplayName,
    repoPath: team.repoPath,
    from: TeamInboxEndpoint(member: senderMember.name, worktree: senderMember.worktreePath, runtime: nil),
    to: TeamInboxEndpoint(member: recipientMember.name, worktree: recipientMember.worktreePath, runtime: nil),
    priority: priority,
    body: renderedBody
)
```

- [ ] **Step 4: Run tests**

```
swift test --filter TeamEventDispatcherTests
swift test --filter TeamInboxRequestHandlerTests
```

Expected: all green.

- [ ] **Step 5: Have `TeamInboxRequestHandler.send` and `.broadcast` delegate to the dispatcher**

The existing `TeamInboxRequestHandler.send` writes directly to inbox. Convert it to call `dispatcher.dispatchTeamMessage(...)` instead. (Pass `dispatcher` into `TeamInboxRequestHandler.init`. The two callers in `GrafttyApp.swift` already have `services.teamEventDispatcher` available.)

Also remove `dispatchTeamChannel(...)` from `GrafttyApp.swift` (lines ~1582-1603) since it pushes to `channelRouter`. The dispatcher fully replaces it now.

- [ ] **Step 6: Build, run, commit**

```
swift build
swift test
```

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/Teams/TeamEventDispatcher.swift \
        Sources/GrafttyKit/Teams/TeamInboxRequestHandler.swift \
        Sources/Graftty/GrafttyApp.swift \
        Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift \
        SPECS.md
git commit -m "refactor(teams): team_message goes through the dispatcher; drop dispatchTeamChannel"
```

---

### Task 2.4: Disconnect channel router from producers

After 2.1-2.3, `ChannelRouter` is still constructed in `AppServices` but no producer calls `router.dispatch`. Verify by grep:

- [ ] **Step 1: Grep for residual call sites**

```bash
grep -rn "channelRouter\.dispatch\|ChannelRouter\.dispatch\|broadcastInstructions" Sources/Graftty Sources/GrafttyKit
```

Expected: only the `WebController.setWorktreeCreator` block (line ~795) remains. Update that block:

```swift
let teamDispatcher = services.teamEventDispatcher
webController.setWorktreeCreator { req in
    let result = await AddWorktreeFlow.add(
        // … existing args …
        teamEventDispatcher: teamDispatcher
    )
    switch result {
    case .success(let outcome):
        return .success(WebServer.CreateWorktreeResponse(
            sessionName: outcome.sessionName,
            worktreePath: outcome.worktreePath
        ))
    case .failure(let err):
        // … unchanged …
    }
}
```

The `await channelRouterForWeb.broadcastInstructions()` call goes away (live broadcast is dropped per spec out-of-scope).

- [ ] **Step 2: Build & test**

```
swift build
swift test
```

Expected: green.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "refactor: drop channel router calls from web worktree creator"
```

---

## Phase 3: Team Activity Log window

Goal: a SwiftUI window that shows live inbox state for one team. Channel router is still alive (deletes happen in phase 4).

### Task 3.1: `TeamInboxObserver`

**Files:**
- Create: `Sources/GrafttyKit/Teams/TeamInboxObserver.swift`
- Create: `Tests/GrafttyKitTests/Teams/TeamInboxObserverTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("TeamInboxObserver")
struct TeamInboxObserverTests {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inboxObserverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("@spec TEAM-7.4: When a row is appended, the observer emits the new array within a second.")
    func emitsOnAppend() async throws {
        let root = try Self.temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root)
        let teamID = "team-1"
        let observer = TeamInboxObserver(rootDirectory: root, teamID: teamID)
        var emitted: [[TeamInboxMessage]] = []
        let cancellable = observer.start { messages in emitted.append(messages) }
        defer { cancellable.cancel() }

        try inbox.appendMessage(
            teamID: teamID, teamName: "t", repoPath: "/r",
            from: TeamInboxEndpoint(member: "a", worktree: "/r", runtime: nil),
            to: TeamInboxEndpoint(member: "b", worktree: "/r/x", runtime: nil),
            priority: .normal, body: "hi"
        )

        // Wait up to 1 second for the observer to fire.
        let deadline = Date().addingTimeInterval(1.0)
        while emitted.count < 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }
        #expect(emitted.count >= 1)
        #expect(emitted.last?.count == 1)
    }

    @Test("@spec TEAM-7.4 (file-late case): When the messages file is created after the observer starts, the observer still emits on subsequent appends.")
    func emitsAfterFileCreatedLate() async throws {
        let root = try Self.temporaryDirectory()
        let teamID = "team-2"
        let observer = TeamInboxObserver(rootDirectory: root, teamID: teamID)
        var emitted: [[TeamInboxMessage]] = []
        let cancellable = observer.start { messages in emitted.append(messages) }
        defer { cancellable.cancel() }

        // File doesn't exist yet; make some noise then create it.
        try await Task.sleep(nanoseconds: 100_000_000)

        let inbox = TeamInbox(rootDirectory: root)
        try inbox.appendMessage(
            teamID: teamID, teamName: "t", repoPath: "/r",
            from: TeamInboxEndpoint(member: "a", worktree: "/r", runtime: nil),
            to: TeamInboxEndpoint(member: "b", worktree: "/r/x", runtime: nil),
            priority: .normal, body: "late"
        )

        let deadline = Date().addingTimeInterval(1.0)
        while emitted.last?.count != 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(emitted.last?.count == 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```
swift test --filter TeamInboxObserverTests
```

Expected: FAIL - type does not exist.

- [ ] **Step 3: Implement**

Create `Sources/GrafttyKit/Teams/TeamInboxObserver.swift`:

```swift
import Foundation
import os

/// Watches a team's `messages.jsonl` file via `DispatchSource.makeFileSystemObjectSource`
/// and emits the parsed message list on every append. Survives the
/// "file-not-yet-created" case by additionally watching the parent
/// directory for `.write` and reattaching when the file appears.
///
/// One observer per (rootDirectory, teamID). View-only; does not mutate
/// cursors or watermarks.
public final class TeamInboxObserver {
    private static let logger = Logger(subsystem: "com.btucker.graftty", category: "TeamInboxObserver")

    public final class Cancellable {
        private let onCancel: () -> Void
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        public func cancel() { onCancel() }
    }

    private let inbox: TeamInbox
    private let teamID: String
    private let queue: DispatchQueue
    private var fileSource: DispatchSourceFileSystemObject?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileFD: Int32 = -1
    private var dirFD: Int32 = -1

    public init(rootDirectory: URL, teamID: String) {
        self.inbox = TeamInbox(rootDirectory: rootDirectory)
        self.teamID = teamID
        self.queue = DispatchQueue(label: "com.btucker.graftty.TeamInboxObserver", qos: .utility)
    }

    public func start(_ callback: @escaping ([TeamInboxMessage]) -> Void) -> Cancellable {
        queue.async {
            self.attach(callback: callback)
            // Initial emit reflects the current on-disk state.
            self.emit(callback: callback)
        }
        return Cancellable { [weak self] in self?.tearDown() }
    }

    private func attach(callback: @escaping ([TeamInboxMessage]) -> Void) {
        let messagesURL = TeamInbox.messagesURLFor(rootDirectory: inbox.rootDirectory, teamID: teamID)
        let parentURL = messagesURL.deletingLastPathComponent()

        // Always watch the parent directory; reattach the file source on .write.
        try? FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        dirFD = open(parentURL.path, O_EVTONLY)
        if dirFD >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFD,
                eventMask: [.write],
                queue: queue
            )
            src.setEventHandler { [weak self] in
                guard let self else { return }
                self.attachFileSource(callback: callback)
                self.emit(callback: callback)
            }
            src.setCancelHandler { [weak self] in
                guard let self else { return }
                close(self.dirFD)
                self.dirFD = -1
            }
            src.resume()
            dirSource = src
        }

        attachFileSource(callback: callback)
    }

    private func attachFileSource(callback: @escaping ([TeamInboxMessage]) -> Void) {
        let messagesURL = TeamInbox.messagesURLFor(rootDirectory: inbox.rootDirectory, teamID: teamID)

        // Tear down any existing file source (e.g. previous file inode replaced).
        fileSource?.cancel()
        fileSource = nil
        if fileFD >= 0 { close(fileFD); fileFD = -1 }

        guard FileManager.default.fileExists(atPath: messagesURL.path) else { return }
        fileFD = open(messagesURL.path, O_EVTONLY)
        guard fileFD >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileFD,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // On delete/rename, reattach via the directory source.
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.attachFileSource(callback: callback)
                return
            }
            self.emit(callback: callback)
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileFD >= 0 { close(self.fileFD); self.fileFD = -1 }
        }
        src.resume()
        fileSource = src
    }

    private func emit(callback: @escaping ([TeamInboxMessage]) -> Void) {
        do {
            let messages = try inbox.messages(teamID: teamID)
            callback(messages)
        } catch {
            Self.logger.error("inbox read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func tearDown() {
        queue.async {
            self.fileSource?.cancel()
            self.fileSource = nil
            self.dirSource?.cancel()
            self.dirSource = nil
        }
    }
}
```

This requires exposing `TeamInbox.messagesURLFor(rootDirectory:teamID:)` as a static helper and `TeamInbox.rootDirectory` as a public property; both are tiny additions to `TeamInbox.swift`.

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter TeamInboxObserverTests
```

Expected: 2 tests pass (may take ~1 second per test due to FSEvents wait).

- [ ] **Step 5: Regenerate and commit**

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/Teams/TeamInboxObserver.swift \
        Sources/GrafttyKit/Teams/TeamInbox.swift \
        Tests/GrafttyKitTests/Teams/TeamInboxObserverTests.swift \
        SPECS.md
git commit -m "feat(teams): TeamInboxObserver tails messages.jsonl (TEAM-7.4)"
```

---

### Task 3.2: `TeamActivityLogRow` view + tests

**Files:**
- Create: `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift`
- Create: `Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftUI
@testable import Graftty
@testable import GrafttyKit

final class TeamActivityLogRowTests: XCTestCase {
    /// @spec TEAM-7.5: Renders chat-bubble for team_message rows.
    func testRendersChatBubbleForTeamMessage() {
        let msg = TeamInboxMessage(
            id: "1", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: TeamInboxEndpoint(member: "alice", worktree: "/r/a", runtime: nil),
            to: TeamInboxEndpoint(member: "bob", worktree: "/r/b", runtime: nil),
            priority: .normal, kind: "team_message", body: "ping"
        )
        let row = TeamActivityLogRow(message: msg)
        let style = row.style
        XCTAssertEqual(style, .chatBubble(senderName: "alice", recipientName: "bob", priority: .normal))
    }

    /// @spec TEAM-7.5: Renders system entry with kind icon for pr_state_changed.
    func testRendersSystemEntryForPRStateChanged() {
        let msg = TeamInboxMessage(
            id: "2", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: .system(repoPath: "/r"),
            to: TeamInboxEndpoint(member: "alice", worktree: "/r/a", runtime: nil),
            priority: .normal, kind: "pr_state_changed",
            body: "PR #42 state changed: open → merged"
        )
        let row = TeamActivityLogRow(message: msg)
        XCTAssertEqual(row.style, .systemEntry(symbolName: "circle.fill", headline: "PR state changed"))
    }

    /// @spec TEAM-7.7: Renders unknown kind as generic system entry.
    func testRendersGenericSystemEntryForUnknownKind() {
        let msg = TeamInboxMessage(
            id: "3", batchID: nil, createdAt: Date(), team: "t", repoPath: "/r",
            from: .system(repoPath: "/r"),
            to: TeamInboxEndpoint(member: "alice", worktree: "/r/a", runtime: nil),
            priority: .normal, kind: "future_kind", body: "hello"
        )
        let row = TeamActivityLogRow(message: msg)
        XCTAssertEqual(row.style, .systemEntry(symbolName: "info.circle", headline: "future_kind"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter TeamActivityLogRowTests
```

Expected: FAIL - type doesn't exist.

- [ ] **Step 3: Implement**

Create `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift`:

```swift
import SwiftUI
import GrafttyKit

struct TeamActivityLogRow: View {
    let message: TeamInboxMessage

    enum Style: Equatable {
        case chatBubble(senderName: String, recipientName: String, priority: TeamInboxPriority)
        case systemEntry(symbolName: String, headline: String)
    }

    var style: Style {
        if message.from.member == "system" || message.kind != "team_message" {
            return Self.systemStyle(forKind: message.kind)
        }
        return .chatBubble(
            senderName: message.from.member,
            recipientName: message.to.member,
            priority: message.priority
        )
    }

    private static func systemStyle(forKind kind: String) -> Style {
        switch kind {
        case "pr_state_changed":
            return .systemEntry(symbolName: "circle.fill", headline: "PR state changed")
        case "ci_conclusion_changed":
            return .systemEntry(symbolName: "checkmark.seal", headline: "CI conclusion changed")
        case "merge_state_changed":
            return .systemEntry(symbolName: "arrow.triangle.merge", headline: "Mergability changed")
        case "team_member_joined":
            return .systemEntry(symbolName: "person.fill.badge.plus", headline: "Team member joined")
        case "team_member_left":
            return .systemEntry(symbolName: "person.fill.badge.minus", headline: "Team member left")
        default:
            return .systemEntry(symbolName: "info.circle", headline: kind)
        }
    }

    var body: some View {
        switch style {
        case let .chatBubble(senderName, recipientName, priority):
            ChatBubbleView(
                senderName: senderName,
                recipientName: recipientName,
                body: message.body,
                createdAt: message.createdAt,
                priority: priority
            )
        case let .systemEntry(symbolName, headline):
            SystemEntryView(
                symbolName: symbolName,
                headline: headline,
                body: message.body,
                createdAt: message.createdAt
            )
        }
    }
}

private struct ChatBubbleView: View {
    let senderName: String
    let recipientName: String
    let body: String
    let createdAt: Date
    let priority: TeamInboxPriority

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(senderName) → \(recipientName)").font(.caption).foregroundStyle(.secondary)
                if priority == .urgent {
                    Text("URGENT").font(.caption).bold().foregroundColor(.red)
                }
                Spacer()
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Text(body)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SystemEntryView: View {
    let symbolName: String
    let headline: String
    let body: String
    let createdAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.caption).bold()
                Text(body).font(.caption).foregroundStyle(.secondary)
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```
swift test --filter TeamActivityLogRowTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Regenerate and commit**

```bash
python scripts/generate-specs.py
git add Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift \
        Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift \
        SPECS.md
git commit -m "feat(activity-log): TeamActivityLogRow renders chat vs system styles (TEAM-7.5, TEAM-7.7)"
```

---

### Task 3.3: `TeamActivityLogWindow` view + viewmodel + tests

**Files:**
- Create: `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogWindow.swift`
- Create: `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogViewModel.swift`
- Create: `Tests/GrafttyTests/Views/TeamActivityLogWindowTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Graftty
@testable import GrafttyKit

final class TeamActivityLogViewModelTests: XCTestCase {
    /// @spec TEAM-7.3: Window displays every TeamInboxMessage for the team chronologically.
    func testInitialEmptyThenObserverEmitsLoadsMessages() throws {
        let root = try temporaryDirectory()
        let inbox = TeamInbox(rootDirectory: root)
        let viewModel = TeamActivityLogViewModel(rootDirectory: root, teamID: "t1", teamName: "team")

        XCTAssertTrue(viewModel.messages.isEmpty)

        try inbox.appendMessage(
            teamID: "t1", teamName: "team", repoPath: "/r",
            from: TeamInboxEndpoint(member: "a", worktree: "/r", runtime: nil),
            to: TeamInboxEndpoint(member: "b", worktree: "/r/b", runtime: nil),
            priority: .normal, body: "hi"
        )

        viewModel.start()
        defer { viewModel.stop() }

        // Wait up to 1s.
        let exp = expectation(description: "observer fired")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(viewModel.messages.count, 1)
        XCTAssertEqual(viewModel.messages.first?.body, "hi")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("activityLogVM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
```

- [ ] **Step 2: Run to verify fail**

```
swift test --filter TeamActivityLogViewModelTests
```

Expected: FAIL.

- [ ] **Step 3: Implement viewmodel + window**

`Sources/Graftty/Views/TeamActivityLog/TeamActivityLogViewModel.swift`:

```swift
import Foundation
import GrafttyKit
import Observation

@Observable
final class TeamActivityLogViewModel {
    var messages: [TeamInboxMessage] = []
    let teamName: String

    private let observer: TeamInboxObserver
    private var cancellable: TeamInboxObserver.Cancellable?

    init(rootDirectory: URL, teamID: String, teamName: String) {
        self.teamName = teamName
        self.observer = TeamInboxObserver(rootDirectory: rootDirectory, teamID: teamID)
    }

    func start() {
        cancellable = observer.start { [weak self] messages in
            DispatchQueue.main.async {
                self?.messages = messages
            }
        }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
    }
}
```

`Sources/Graftty/Views/TeamActivityLog/TeamActivityLogWindow.swift`:

```swift
import SwiftUI
import GrafttyKit
import AppKit

struct TeamActivityLogWindow: View {
    @State private var viewModel: TeamActivityLogViewModel
    let messagesFileURL: URL

    init(rootDirectory: URL, teamID: String, teamName: String) {
        _viewModel = State(initialValue: TeamActivityLogViewModel(
            rootDirectory: rootDirectory,
            teamID: teamID,
            teamName: teamName
        ))
        self.messagesFileURL = rootDirectory
            .appendingPathComponent(teamID, isDirectory: true)
            .appendingPathComponent("messages.jsonl")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Team Activity - \(viewModel.teamName)").font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([messagesFileURL])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal messages.jsonl in Finder")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            Divider()

            if viewModel.messages.isEmpty {
                Spacer()
                Text("No team activity yet.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.messages, id: \.id) { msg in
                                TeamActivityLogRow(message: msg).id(msg.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: viewModel.messages.last?.id) { _, newID in
                        if let newID { proxy.scrollTo(newID, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }
}
```

- [ ] **Step 4: Run tests**

```
swift build
swift test --filter TeamActivityLogViewModelTests
swift test --filter TeamActivityLogRowTests
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
python scripts/generate-specs.py
git add Sources/Graftty/Views/TeamActivityLog \
        Tests/GrafttyTests/Views/TeamActivityLogWindowTests.swift \
        SPECS.md
git commit -m "feat(activity-log): TeamActivityLogWindow + viewmodel (TEAM-7.3, TEAM-7.6)"
```

---

### Task 3.4: Wire window into Window menu + sidebar context menu

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift` (Window scene group)
- Modify: `Sources/Graftty/Views/SidebarView.swift` (worktree row context menu)

- [ ] **Step 1: Add window scene**

Inside `var body: some Scene`, after the `WindowGroup` for `MainWindow`, add:

```swift
WindowGroup("Team Activity Log", id: "team-activity-log", for: TeamActivityLogWindowID.self) { $id in
    if let id {
        TeamActivityLogWindow(
            rootDirectory: AppState.defaultDirectory.appendingPathComponent("team-inbox"),
            teamID: id.teamID,
            teamName: id.teamName
        )
    } else {
        Text("No team selected.").padding()
    }
}
.commands {
    CommandGroup(after: .windowList) {
        Button("Team Activity Log") {
            // Find focused worktree's team and present the window.
            guard let focusedWorktreePath = self.appState.focusedWorktreePath,
                  let team = TeamView.team(for: focusedWorktreePath, in: self.appState.repos, teamsEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.agentTeamsEnabled))
            else { return }
            openWindow(id: "team-activity-log", value: TeamActivityLogWindowID(
                teamID: TeamLookup.id(of: team),
                teamName: team.repoDisplayName
            ))
        }
        .keyboardShortcut("T", modifiers: [.command, .shift])
        .disabled(!isTeamFocused)
    }
}
```

`TeamActivityLogWindowID` is a simple `Hashable & Codable` struct in the same file:

```swift
struct TeamActivityLogWindowID: Hashable, Codable {
    let teamID: String
    let teamName: String
}
```

`isTeamFocused` is a computed property reading `appState` to test whether the focused worktree is in a team-enabled repo with ≥2 worktrees.

- [ ] **Step 2: Sidebar context menu**

In `Sources/Graftty/Views/SidebarView.swift`, find the existing context menu on team-enabled worktree rows (around the *Show Team Members…* item — it's already there per TEAM-6.2) and add:

```swift
Button("Show Team Activity…") {
    guard let team = TeamView.team(for: worktree.path, in: repos, teamsEnabled: true) else { return }
    openWindow(id: "team-activity-log", value: TeamActivityLogWindowID(
        teamID: TeamLookup.id(of: team),
        teamName: team.repoDisplayName
    ))
}
```

- [ ] **Step 3: Build + smoke**

```
swift build
swift run Graftty
```

(Manual smoke: enable Agent Teams, open a team-enabled worktree, run `graftty team msg <peer> "test"`, see the row appear in the activity window.)

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/Views/SidebarView.swift
git commit -m "feat(activity-log): wire window into Window menu + sidebar (TEAM-7.1, TEAM-7.2)"
```

---

## Phase 4: Delete the channel surface

Goal: every channel-only file is gone. The `Channels/` directories under both `Sources/GrafttyKit/` and `Sources/Graftty/` empty out. Build is green.

### Task 4.1: Delete kit-side channel files

**Files (delete):**
- `Sources/GrafttyKit/Channels/ChannelRouter.swift`
- `Sources/GrafttyKit/Channels/ChannelSocketServer.swift`
- `Sources/GrafttyKit/Channels/MCPStdioServer.swift`
- `Sources/GrafttyKit/Channels/ChannelMCPInstaller.swift` (logic preserved in `LegacyChannelCleanup`, see phase 6 — already exists in tree-shaped form, can be deleted now)
- `Sources/GrafttyKit/Channels/ChannelEventRouter.swift`
- All `Tests/GrafttyKitTests/Channels/*.swift` (delete the entire directory)

- [ ] **Step 1: Delete files**

```bash
rm Sources/GrafttyKit/Channels/ChannelRouter.swift \
   Sources/GrafttyKit/Channels/ChannelSocketServer.swift \
   Sources/GrafttyKit/Channels/MCPStdioServer.swift \
   Sources/GrafttyKit/Channels/ChannelEventRouter.swift
rm -rf Tests/GrafttyKitTests/Channels
```

(Keep `ChannelMCPInstaller.swift` for now; phase 6 will absorb it into `LegacyChannelCleanup`.)

- [ ] **Step 2: Remove references from `AppServices`**

In `Sources/Graftty/GrafttyApp.swift`:
- Delete the `let channelRouter: ChannelRouter` field (line ~67) and its construction.
- Delete the `let channelSettingsObserver: ChannelSettingsObserver` field and construction.
- Delete the `let channelSocketPath = SocketPathResolver.resolveChannels()` line.
- Delete the `Box<ChannelSettingsObserver>` workaround.

- [ ] **Step 3: Build**

```
swift build
```

Expected: many errors. Each error is a call site that referenced `channelRouter` / `channelSettingsObserver`. Walk through them and delete or rewrite as `services.teamEventDispatcher` calls. Keep going until build is green. (`Sources/Graftty/GrafttyApp.swift` startup logic, `MainWindow` props, the web controller block, `installChannelMCPServer` static, etc.)

- [ ] **Step 4: Run tests**

```
swift test
```

Expected: green (some tests reference deleted types — delete those test files in the next step).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(channels): delete channel router, socket server, MCP server, event router"
```

---

### Task 4.2: Delete `ChannelSettingsObserver`

**Files (delete):**
- `Sources/Graftty/Channels/ChannelSettingsObserver.swift`
- Test files referencing `ChannelSettingsObserver`

- [ ] **Step 1: Delete the file**

```bash
rm Sources/Graftty/Channels/ChannelSettingsObserver.swift
```

- [ ] **Step 2: Remove references**

Search and remove:

```bash
grep -rn "ChannelSettingsObserver" Sources Tests
```

Each hit should be removed or rewritten. The file `GrafttyApp.swift` still references it from `appStateProvider` wiring (line ~612) — drop that block; the dispatcher reads `repos` directly from `appState` per dispatch.

- [ ] **Step 3: Build & test**

```
swift build && swift test
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(channels): delete ChannelSettingsObserver and live broadcast wiring"
```

---

### Task 4.3: Delete CLI MCPChannel + ChannelSocketClient

**Files (delete):**
- `Sources/GrafttyCLI/MCPChannel.swift`
- `Sources/GrafttyCLI/ChannelSocketClient.swift`
- `Tests/GrafttyCLITests/MCPChannel*.swift` (if exists)

- [ ] **Step 1: Delete**

```bash
rm Sources/GrafttyCLI/MCPChannel.swift Sources/GrafttyCLI/ChannelSocketClient.swift
```

- [ ] **Step 2: Remove the `mcp channel` subcommand from the CLI's command tree**

Edit `Sources/GrafttyCLI/CLI.swift` and the `MCP` subcommand declaration to drop the `Channel` subcommand. Update help text.

- [ ] **Step 3: Build & test**

```
swift build && swift test
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(cli): drop graftty mcp channel subcommand"
```

---

### Task 4.4: Build verification - everything green without channel files

- [ ] **Step 1: Full build + test**

```
swift build
swift test
```

Expected: green.

- [ ] **Step 2: grep for stragglers**

```bash
grep -rn "ChannelRouter\|MCPStdioServer\|ChannelSocketServer\|ChannelSettingsObserver\|ChannelMCPInstaller\|ChannelEventRouter\|MCPChannel\|ChannelSocketClient" Sources Tests
```

Expected: a few references in `EventBodyRenderer` (file moves in phase 5), `RoutableEvent` (file moves in phase 5), `ChannelRoutingPreferences` (file moves in phase 5), and `ChannelMCPInstaller` (absorbed into `LegacyChannelCleanup` in phase 6). Anything else: track down and remove.

- [ ] **Step 3: Note progress in commit**

```bash
git commit --allow-empty -m "chore: phase 4 complete - all channel-only files deleted"
```

---

## Phase 5: Relocate kept files + rename

Goal: `Sources/GrafttyKit/Channels/` and `Sources/Graftty/Channels/` directories no longer exist. Files moved to their new homes. UserDefaults key migration in place.

### Task 5.1: Move `EventBodyRenderer` to `Teams/`

**Files:**
- Move: `Sources/GrafttyKit/Channels/EventBodyRenderer.swift` → `Sources/GrafttyKit/Teams/EventBodyRenderer.swift`
- Update: any imports that referenced the file by directory (none in Swift; this is a no-op for compilation, but let's be tidy)

- [ ] **Step 1: Move**

```bash
git mv Sources/GrafttyKit/Channels/EventBodyRenderer.swift Sources/GrafttyKit/Teams/EventBodyRenderer.swift
```

- [ ] **Step 2: Drop the now-unused `dispatchClosure` function**

The function (~lines 100-125) returns a `(path, msg) -> Void` closure that wrapped `ChannelRouter.dispatch`. With the channel router gone, no caller remains. Delete the entire `dispatchClosure` static func. Tests that referenced it should already have been removed in phase 4 cleanup.

- [ ] **Step 3: Build + test**

```
swift build && swift test
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(teams): relocate EventBodyRenderer; drop dispatchClosure"
```

---

### Task 5.2: Move `RoutableEvent` and event-type constants to `Teams/`

**Files:**
- Move: `Sources/GrafttyKit/Channels/RoutableEvent.swift` → `Sources/GrafttyKit/Teams/RoutableEvent.swift`
- Move: event-type constants (`prStateChanged`, `ciConclusionChanged`, `mergeStateChanged`, `instructions`, `channelError`) from `Sources/GrafttyKit/Channels/ChannelEvent.swift` into `Sources/GrafttyKit/Teams/TeamChannelEvents.swift` (rename the file `TeamEvents.swift` while you're there)
- Delete: `Sources/GrafttyKit/Channels/ChannelEvent.swift` (after extracting the type constants)
- Delete: `ChannelClientMessage` enum (no consumers after phase 4) and `ChannelServerMessage` enum (still used as a wire-shape; keep but move into `Teams/TeamEvents.swift`)

- [ ] **Step 1: Move + extract**

```bash
git mv Sources/GrafttyKit/Channels/RoutableEvent.swift Sources/GrafttyKit/Teams/RoutableEvent.swift
git mv Sources/GrafttyKit/Teams/TeamChannelEvents.swift Sources/GrafttyKit/Teams/TeamEvents.swift
```

In `TeamEvents.swift`, append a `TeamEvents.WireType` enum (formerly `ChannelEventType`):

```swift
extension TeamChannelEvents {
    /// Wire-format event type strings used in inbox `kind` fields and
    /// in the legacy `ChannelServerMessage.event(type:…)` wire-shape
    /// retained for `EventBodyRenderer` parameter compatibility.
    public enum WireType {
        public static let prStateChanged       = "pr_state_changed"
        public static let ciConclusionChanged  = "ci_conclusion_changed"
        public static let mergeStateChanged    = "merge_state_changed"
    }
}
```

Move `ChannelServerMessage` (the `.event(type:attrs:body:)` wire-shape) into the same file - `EventBodyRenderer.body(...)` still takes one. Rename to `TeamEventEnvelope` for clarity, with a `case event(type:attrs:body:)` shape. Update every call site (search-replace `ChannelServerMessage` → `TeamEventEnvelope`).

Delete `ChannelClientMessage` entirely.

- [ ] **Step 2: Update RoutableEvent to use new constant names**

In `Sources/GrafttyKit/Teams/RoutableEvent.swift`:

```swift
case ChannelEventType.prStateChanged → case TeamChannelEvents.WireType.prStateChanged
```

(Don't rename `RoutableEvent` itself — leave the type name as-is; just update its references.)

- [ ] **Step 3: Delete `Sources/GrafttyKit/Channels/ChannelEvent.swift`**

```bash
rm Sources/GrafttyKit/Channels/ChannelEvent.swift
```

- [ ] **Step 4: Build & test**

```
swift build && swift test
```

Expected: green after fixing the search-replace fallout.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(teams): consolidate RoutableEvent + event constants under Teams/"
```

---

### Task 5.3: Rename `ChannelRoutingPreferences` → `TeamEventRoutingPreferences`

**Files:**
- Rename: `Sources/GrafttyKit/Channels/ChannelRoutingPreferences.swift` → `Sources/GrafttyKit/Teams/TeamEventRoutingPreferences.swift`
- Type rename: `ChannelRoutingPreferences` → `TeamEventRoutingPreferences`
- Drop the typealias added in phase 1 (Task 1.3) since the type is now properly named

- [ ] **Step 1: Move + rename type**

```bash
git mv Sources/GrafttyKit/Channels/ChannelRoutingPreferences.swift \
       Sources/GrafttyKit/Teams/TeamEventRoutingPreferences.swift
```

In the new file, replace `ChannelRoutingPreferences` with `TeamEventRoutingPreferences` everywhere.

- [ ] **Step 2: Drop the typealias and update consumers**

Remove `public typealias TeamEventRoutingPreferences = ChannelRoutingPreferences` from `TeamEventRouter.swift`. Search-replace `ChannelRoutingPreferences` → `TeamEventRoutingPreferences` across the project.

- [ ] **Step 3: Build & test**

```
swift build && swift test
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(teams): rename ChannelRoutingPreferences → TeamEventRoutingPreferences"
```

---

### Task 5.4: UserDefaults key migration

**Files:**
- Modify: `Sources/Graftty/Settings/SettingsKeys.swift` (will be created/relocated in 5.5; for now still in `Channels/`)
- Modify: `Sources/Graftty/GrafttyApp.swift` (run migration once at startup)
- Modify: any `@AppStorage` annotations using the old key

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyTests/Settings/SettingsKeyMigrationTests.swift`:

```swift
import XCTest
@testable import Graftty

final class SettingsKeyMigrationTests: XCTestCase {
    /// @spec TEAM-1.10: Migrates `channelRoutingPreferences` to `teamEventRoutingPreferences` once.
    func testMigratesOldKeyToNew() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        defaults.set("{\"prMerged\":1}", forKey: "channelRoutingPreferences")

        SettingsKeyMigration.run(in: defaults)

        XCTAssertNil(defaults.string(forKey: "channelRoutingPreferences"))
        XCTAssertEqual(defaults.string(forKey: "teamEventRoutingPreferences"), "{\"prMerged\":1}")
    }

    func testDoesNotOverwriteExistingNewKey() {
        let defaults = UserDefaults(suiteName: "test-\(UUID())")!
        defaults.set("{\"prMerged\":1}", forKey: "channelRoutingPreferences")
        defaults.set("{\"prMerged\":2}", forKey: "teamEventRoutingPreferences")

        SettingsKeyMigration.run(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "teamEventRoutingPreferences"), "{\"prMerged\":2}")
    }
}
```

- [ ] **Step 2: Run to fail**

```
swift test --filter SettingsKeyMigrationTests
```

Expected: FAIL.

- [ ] **Step 3: Implement**

Create `Sources/Graftty/Settings/SettingsKeyMigration.swift`:

```swift
import Foundation

enum SettingsKeyMigration {
    static let oldKey = "channelRoutingPreferences"
    static let newKey = "teamEventRoutingPreferences"

    static func run(in defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: newKey) == nil,
              let old = defaults.string(forKey: oldKey)
        else {
            // Either already migrated or no old data.
            defaults.removeObject(forKey: oldKey)
            return
        }
        defaults.set(old, forKey: newKey)
        defaults.removeObject(forKey: oldKey)
    }
}
```

Wire it into `GrafttyApp.startup` (very early, before any `@AppStorage` reads):

```swift
SettingsKeyMigration.run()
```

Update `SettingsKeys.swift`:

```swift
static let teamEventRoutingPreferences = "teamEventRoutingPreferences"
```

(remove `channelRoutingPreferences`).

Update `AgentTeamsSettingsPane.swift`'s `@AppStorage` annotation to the new key. Update `AppServices.init`'s `preferencesProvider`.

- [ ] **Step 4: Run tests**

```
swift test --filter SettingsKeyMigrationTests
swift test
```

Expected: green.

- [ ] **Step 5: Commit**

```bash
python scripts/generate-specs.py
git add Sources/Graftty/Settings/SettingsKeyMigration.swift \
        Sources/Graftty/Settings/SettingsKeys.swift \
        Sources/Graftty/GrafttyApp.swift \
        Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift \
        Tests/GrafttyTests/Settings/SettingsKeyMigrationTests.swift \
        SPECS.md
git commit -m "feat(settings): migrate channelRoutingPreferences → teamEventRoutingPreferences (TEAM-1.10)"
```

---

### Task 5.5: Move `SettingsKeys` and `DefaultPrompts` to `Settings/`

**Files:**
- Move: `Sources/Graftty/Channels/SettingsKeys.swift` → `Sources/Graftty/Settings/SettingsKeys.swift`
- Move: `Sources/Graftty/Channels/DefaultPrompts.swift` → `Sources/Graftty/Settings/DefaultPrompts.swift`

- [ ] **Step 1: Move + remove the empty `Channels/` directory**

```bash
git mv Sources/Graftty/Channels/SettingsKeys.swift Sources/Graftty/Settings/SettingsKeys.swift
git mv Sources/Graftty/Channels/DefaultPrompts.swift Sources/Graftty/Settings/DefaultPrompts.swift
rmdir Sources/Graftty/Channels
```

(Also `rmdir Sources/GrafttyKit/Channels` if empty.)

- [ ] **Step 2: Build & test**

```
swift build && swift test
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor(settings): relocate SettingsKeys/DefaultPrompts under Settings/"
```

---

### Task 5.6: Settings UI text updates

**Files:**
- Modify: `Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift`

- [ ] **Step 1: Update the matrix section header and footer**

Replace `Text("Automated event routing")` (or similar - the WIP version of the file already has it as "Automated event routing" or "Channel routing" — check) with `Text("Team event routing")`. Update footer to:

```swift
Text("Choose which agents receive each automated team event. Events flow into the team inbox and are delivered to agents through hook context. \"Worktree agent\" means the agent in the worktree the event is about; \"Other worktree agents\" means every other coworker in the same repo.")
```

Add a footer note under the *Session prompt* and *Per-event prompt* sections explaining no live fan-out:

```swift
Text("Changes apply when each agent session next starts. Live in-session refresh has been removed.")
```

- [ ] **Step 2: Build & smoke**

```
swift build
swift run Graftty
```

(Visually verify Settings pane.)

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift
git commit -m "ui(settings): rename to 'Team event routing' + apply-at-session-start note"
```

---

## Phase 6: LegacyChannelCleanup + spec finalization

Goal: a one-shot startup task removes leftover MCP / plugin-dir / launch-flag config from prior versions. Spec annotations are fully updated.

### Task 6.1: `LegacyChannelCleanup` skeleton + first test (MCP unregister)

**Files:**
- Create: `Sources/GrafttyKit/Teams/LegacyChannelCleanup.swift`
- Create: `Tests/GrafttyKitTests/Teams/LegacyChannelCleanupTests.swift`

- [ ] **Step 1: Failing test**

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("LegacyChannelCleanup")
struct LegacyChannelCleanupTests {
    final class FakeExecutor: CLIExecutor, @unchecked Sendable {
        var capturedCommands: [(String, [String])] = []
        var stubResult: CLIResult = CLIResult(exitCode: 0, stdout: "", stderr: "")
        func capture(command: String, args: [String], at directory: String) async throws -> CLIResult {
            capturedCommands.append((command, args))
            return stubResult
        }
    }

    @Test("@spec TEAM-8.1: When the application starts, the application shall best-effort run `claude mcp remove graftty-channel`.")
    func unregistersMCPServer() async {
        let exec = FakeExecutor()
        await LegacyChannelCleanup.unregisterMCPServer(executor: exec)
        #expect(exec.capturedCommands.count == 1)
        #expect(exec.capturedCommands.first?.0 == "claude")
        #expect(exec.capturedCommands.first?.1 == ["mcp", "remove", "graftty-channel"])
    }
}
```

- [ ] **Step 2: Run to fail**

```
swift test --filter LegacyChannelCleanupTests
```

- [ ] **Step 3: Implement**

```swift
import Foundation
import os

public enum LegacyChannelCleanup {
    private static let logger = Logger(subsystem: "com.btucker.graftty", category: "LegacyChannelCleanup")
    private static let serverName = "graftty-channel"

    public static func run(executor: CLIExecutor = CLIRunner()) async {
        await unregisterMCPServer(executor: executor)
        removeLegacyMCPConfigFile(at: defaultLegacyMCPConfigPath())
        removeLegacyPluginDirectory(pluginsRoot: defaultLegacyPluginsRoot())
        scrubDefaultCommandLaunchFlag()
    }

    static func unregisterMCPServer(executor: CLIExecutor) async {
        do {
            _ = try await executor.capture(
                command: "claude",
                args: ["mcp", "remove", serverName],
                at: "/"
            )
        } catch {
            logger.info("legacy MCP unregister skipped: \(String(describing: error), privacy: .public)")
        }
    }

    // (other steps follow in subsequent tasks)
}
```

- [ ] **Step 4: Run + commit**

```
swift test --filter LegacyChannelCleanupTests
```

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/Teams/LegacyChannelCleanup.swift \
        Tests/GrafttyKitTests/Teams/LegacyChannelCleanupTests.swift \
        SPECS.md
git commit -m "feat(cleanup): unregister legacy graftty-channel MCP server (TEAM-8.1)"
```

---

### Task 6.2: Cleanup steps 2 + 3 (`.mcp.json` + plugin dir)

Mirror logic from the existing `ChannelMCPInstaller.removeLegacyMCPConfigFile` and `removeLegacyPluginDirectory`. Pull the function bodies in verbatim, plus tests covering:
- file present + correct shape → deleted
- file present + extra MCP servers → preserved
- file absent → no-op
- plugin dir present → deleted
- plugin dir absent → no-op

Same TDD cadence: failing test, implement, pass, commit.

```bash
git commit -m "feat(cleanup): remove legacy .mcp.json + plugin dir (TEAM-8.2, TEAM-8.3)"
```

---

### Task 6.3: defaultCommand launch-flag scrub

**Files:**
- Modify: `Sources/GrafttyKit/Teams/LegacyChannelCleanup.swift`
- Modify: `Tests/GrafttyKitTests/Teams/LegacyChannelCleanupTests.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift` to present the alert from main actor when scrub runs

- [ ] **Step 1: Failing test**

```swift
@Test("@spec TEAM-8.4: defaultCommand strip removes the channels launch flag substring and adjacent whitespace.")
func defaultCommandStripCleansFlag() {
    let defaults = UserDefaults(suiteName: "test-\(UUID())")!
    defaults.set("claude --dangerously-load-development-channels server:graftty-channel", forKey: "defaultCommand")

    let didStrip = LegacyChannelCleanup.scrubDefaultCommandLaunchFlag(in: defaults)

    #expect(didStrip == true)
    #expect(defaults.string(forKey: "defaultCommand") == "claude")
}

@Test("@spec TEAM-8.4: defaultCommand strip is a no-op when flag is absent.")
func defaultCommandStripNoOp() {
    let defaults = UserDefaults(suiteName: "test-\(UUID())")!
    defaults.set("claude", forKey: "defaultCommand")

    let didStrip = LegacyChannelCleanup.scrubDefaultCommandLaunchFlag(in: defaults)

    #expect(didStrip == false)
    #expect(defaults.string(forKey: "defaultCommand") == "claude")
}
```

- [ ] **Step 2: Run to fail; implement**

```swift
@discardableResult
public static func scrubDefaultCommandLaunchFlag(in defaults: UserDefaults = .standard) -> Bool {
    let key = "defaultCommand"
    let flag = "--dangerously-load-development-channels server:graftty-channel"
    guard let current = defaults.string(forKey: key), current.contains(flag) else { return false }
    var cleaned = current.replacingOccurrences(of: flag, with: "")
    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
    while cleaned.contains("  ") { cleaned = cleaned.replacingOccurrences(of: "  ", with: " ") }
    defaults.set(cleaned, forKey: key)
    return true
}
```

In `GrafttyApp.swift`, call `LegacyChannelCleanup.run()` from `startup()`. If `scrubDefaultCommandLaunchFlag` returned `true`, present an `NSAlert` on the main actor:

```swift
Task { @MainActor in
    let scrubbed = LegacyChannelCleanup.scrubDefaultCommandLaunchFlag()
    if scrubbed {
        let alert = NSAlert()
        alert.messageText = "Legacy launch flag removed"
        alert.informativeText = "Removed --dangerously-load-development-channels server:graftty-channel from your default command. Agent teams now run via the unified hook adapter."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
```

- [ ] **Step 3: Pass + commit**

```
swift test --filter LegacyChannelCleanupTests
swift build
```

```bash
python scripts/generate-specs.py
git add Sources/GrafttyKit/Teams/LegacyChannelCleanup.swift \
        Sources/Graftty/GrafttyApp.swift \
        Tests/GrafttyKitTests/Teams/LegacyChannelCleanupTests.swift \
        SPECS.md
git commit -m "feat(cleanup): scrub --dangerously-load-development-channels from defaultCommand (TEAM-8.4)"
```

---

### Task 6.4: Wire `LegacyChannelCleanup.run()` into startup + delete `ChannelMCPInstaller`

- [ ] **Step 1: In `GrafttyApp.startup()`**

Replace the existing `installChannelMCPServer` call with a single:

```swift
Task { await LegacyChannelCleanup.run() }
```

Delete the `installChannelMCPServer` static func and the `agentHookCLIPath` helper if no other caller uses it.

- [ ] **Step 2: Delete `ChannelMCPInstaller.swift` and its tests**

```bash
rm Sources/GrafttyKit/Channels/ChannelMCPInstaller.swift
rm Tests/GrafttyKitTests/Channels/ChannelMCPInstallerTests.swift  # if not already deleted
rmdir Sources/GrafttyKit/Channels  # should succeed if empty
```

- [ ] **Step 3: Build & test**

```
swift build && swift test
```

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(cleanup): wire LegacyChannelCleanup into startup; delete ChannelMCPInstaller"
```

---

### Task 6.5: Spec annotations - delete obsolete, reword, finalize

**Files:**
- Modify: every test file containing a `@spec TEAM-1.7`, `@spec TEAM-3.1`, or `@spec TEAM-3.4` annotation - delete those tests (or remove the annotation if the test still has reason to live)
- Modify: every test file containing a `@spec TEAM-1.2`, `1.5`, `1.8`, `1.9`, `3.3`, `5.1`, `5.2`, `5.3` - reword the EARS text per the spec doc's "Reword" section
- Modify: `Tests/GrafttyTests/Specs/TeamTodo.swift` - move any newly-implemented requirements out of the inventory; promote `TEAM-7.x` and `TEAM-8.x` `@Test(.disabled)` entries to real tests where the implementation is in place

- [ ] **Step 1: Locate all affected `@spec` annotations**

```bash
grep -rn "@spec TEAM-" Sources Tests | grep -E "TEAM-(1\.7|1\.2|1\.5|1\.8|1\.9|3\.1|3\.3|3\.4|5\.1|5\.2|5\.3)"
```

For each match, edit the EARS text per the spec doc.

For TEAM-1.7, TEAM-3.1, TEAM-3.4: delete the test or remove the annotation. (Both delete and remove are valid; the latter keeps the test running if it still tests other behavior.)

- [ ] **Step 2: Inventory entries**

In `Tests/GrafttyTests/Specs/TeamTodo.swift`, add `@Test(.disabled("not yet implemented"))` entries for any TEAM-7.x or TEAM-8.x requirement not yet covered by a real test. Conversely, promote (delete from `*Todo.swift`) the requirements that have real tests now.

- [ ] **Step 3: Regenerate SPECS.md**

```bash
python scripts/generate-specs.py
git diff SPECS.md  # sanity check
```

- [ ] **Step 4: Commit**

```bash
git add Tests/GrafttyTests/Specs Tests/GrafttyKitTests Sources SPECS.md
git commit -m "docs(specs): finalize @spec annotations for channels-to-inbox migration"
```

---

## Final phase: simplify + PR

### Task 7.1: Run `/simplify`

CLAUDE.md mandates `/simplify` before opening a PR.

- [ ] **Step 1: Invoke `/simplify`**

The orchestrator (or human reviewer) runs the slash command. The simplify pass reviews changed code for reuse, quality, and efficiency, applies fixes inline.

- [ ] **Step 2: Build + full test**

```
swift build && swift test
```

- [ ] **Step 3: Commit any simplify-pass changes**

```bash
git add -A
git commit -m "chore: simplify pass before PR"  # adapt message based on actual changes
```

---

### Task 7.2: Open PR

- [ ] **Step 1: Push and open PR**

```bash
git push -u origin codex-hooks
gh pr create --title "Replace Claude channels with team inbox + activity log window" \
  --body "$(cat <<'EOF'
## Summary
- Producer-side `TeamEventDispatcher` replaces the channel-router dispatch path. PR/CI/membership events and `team_message` all flow through `TeamInbox.appendMessage`.
- Channel surface deleted: router, socket server, MCP stdio server, settings observer, MCP installer, channel event router, `graftty mcp channel` CLI subcommand.
- New `TeamInboxObserver` + `TeamActivityLogWindow` give the user a read-only chronological view of every inbox row for a team.
- One-shot `LegacyChannelCleanup.run()` at startup unregisters the legacy MCP server, deletes `~/.claude/.mcp.json` if it has no other servers, removes the plugin dir, and scrubs `--dangerously-load-development-channels server:graftty-channel` from `defaultCommand`.
- Spec annotations updated: TEAM-1.7 / 3.1 / 3.4 deleted; TEAM-1.2 / 1.5 / 1.8 / 1.9 / 3.3 / 5.1-5.3 reworded; TEAM-7 (activity log) and TEAM-8 (legacy cleanup) added.

Spec: `docs/superpowers/specs/2026-05-01-channels-to-inbox-design.md`.
Plan: `docs/superpowers/plans/2026-05-01-channels-to-inbox.md`.

## Test plan
- [x] `swift test` (full suite green)
- [x] Smoke: enable Agent Teams, open a multi-worktree repo, run `graftty team msg <peer> "test"`, see the row in the activity window within 1s
- [x] Smoke: `Window → Team Activity Log` opens the window for the focused worktree's team
- [x] Smoke: PR state transition fires - the row appears in the activity window for the matrix-resolved recipients
- [x] Smoke: a user with the legacy launch flag in `defaultCommand` sees the one-shot scrub alert on next launch

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review

Looking at this plan against the spec:

**Spec coverage check:**
- Spec §"In scope" / producer-side fan-out → Phase 1 + Phase 2 (tasks 1.2-1.4, 2.1-2.4) ✓
- Spec §"Deletion" of channel files → Phase 4 ✓
- Spec §"Relocation" → Phase 5 ✓
- Spec §"Settings UI cleanup" → Task 5.6 ✓
- Spec §"One-time legacy cleanup" → Phase 6 ✓
- Spec §"Team Activity Log window" → Phase 3 + Task 3.4 wiring ✓
- Spec §"Spec annotation updates" → Task 6.5 ✓
- Spec §"Tests" (delete/add/modify) → coverage spread across phases; the Add table maps 1:1 to tasks 1.x-3.x and 6.1-6.3 ✓
- Spec §"TDD build sequence" 6 phases → matches exactly ✓
- Spec §"Risks" - the "FSEvents reattach on file recreation" risk is addressed by `attachFileSource` + `dirSource` reattach pattern in Task 3.1 ✓
- Spec §"Risks" - "Auto-scroll heuristic" - simplified to "scroll-to-bottom on append unconditionally" in Task 3.3 (TODO: revisit if it feels wrong; flag during review)

**Placeholder scan:** none of "TBD", "implement later", "fill in details", "add appropriate error handling" appear in the plan.

**Type consistency check:**
- `TeamEventDispatcher` constructor signature: `init(inbox:, preferencesProvider:, templateProvider:)` — used consistently in 1.2, 1.3, 1.4, 2.1, 2.2, 2.3
- `TeamLookup.id(of:)` and `TeamLookup.id(forRepoPath:)` — both used; both need to be added in Task 1.2's `TeamLookup` introduction
- `dispatcher.dispatchTeamMessage` / `dispatchRoutableEvent` / `dispatchMemberJoined` / `dispatchMemberLeft` — names consistent across phases
- `TeamInboxEndpoint.system(repoPath:)` — added in 1.1, used in 1.3, 1.4, 6.x
- `RoutableEvent.wireType` and `defaultBody(attrs:)` — added in 2.1, used in 2.1's onTransition handler

One inconsistency caught: in Task 2.2 the test uses `TeamView.team(for: repo.worktrees[0], …)` but `TeamView.team` may take a `WorktreeEntry` not a path. Pre-implementation, the reference code at the top showed both signatures; the dispatcher uses worktreePath. The plan's tests are written assuming the existing `TeamView.team(for:in:teamsEnabled:)` signature - cross-check during implementation.
