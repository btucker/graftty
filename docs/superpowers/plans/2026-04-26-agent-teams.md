# Agent Teams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the agent-teams feature: when the user enables it, every claude pane Graftty auto-launches in a multi-worktree repo receives team-aware instructions (lead vs. coworker) through the existing `graftty-channel` MCP path, plus four `team_*` channel events and a `graftty team msg`/`team list` CLI for inter-pane messaging.

**Architecture:** No new persistence — team state is derived from the existing repo→worktree list plus one `@AppStorage("agentTeamsEnabled")` flag. The repo's root worktree (`worktree.path == repo.path`) is the lead. Team-aware system prompts ride the existing `ChannelRouter.onSubscribe` + `broadcastInstructions` pipeline by extending the prompt provider to be per-worktree and team-aware. The launch line is unchanged from channels mode (`claude --dangerously-load-development-channels server:graftty-channel`).

**Tech Stack:** Swift, SwiftUI, ArgumentParser, MCP stdio (existing in-tree), XCTest + Swift Testing.

**Spec:** [`docs/superpowers/specs/2026-04-26-agent-teams-design.md`](../specs/2026-04-26-agent-teams-design.md) — read this first.

---

## Task ordering and parallelism

```
Task 1 — SPECS.md updates                 ┐
Task 2 — agentTeamsEnabled flag + Pane    │  (Phase 1: foundations,
Task 3 — TeamView.swift + tests           │   can run in parallel
Task 4 — TeamChannelEvents.swift + tests  │   except Task 5 depends on Tasks 3+4)
Task 5 — TeamInstructionsRenderer + tests ┘
Task 6 — ChannelRouter integration          (depends on 3, 4, 5)
Task 7 — Socket protocol additions          (depends on 4)
Task 8 — graftty team CLI                   (depends on 7)
Task 9 — AppState worktree-event firing     (depends on 4, 6)
Task 10 — PR-merge integration              (depends on 4, 6)
Task 11 — Sidebar team styling              (depends on 3, 6)
Task 12 — Lock default-command field        (depends on 2)
```

For subagent-driven dispatch: Tasks 1, 2, 3, 4 in parallel first. Then Task 5. Then Task 6 + Task 7 in parallel. Then Tasks 8–12 in parallel.

---

### Task 1: SPECS.md — add TEAM-* requirements section

**Files:**
- Modify: `SPECS.md` (append a new top-level section after the last existing section)

This task is documentation-only. It adds the `TEAM-*` requirements that the rest of the implementation will reference. Place this section at the end of `SPECS.md`, before any "Non-goals" appendix if one exists. Use the EARS-style requirement form already established in SPECS.md.

- [ ] **Step 1: Add the TEAM section to SPECS.md**

Append the following section to `SPECS.md`. Bump the section number to whatever the next available number is (run `grep -nE "^## [0-9]+\." SPECS.md | tail -1` to find the last numbered section).

```markdown
## N. Agent Teams

### N.1 Settings & Enablement

**TEAM-1.1** The application shall provide a Settings tab named "Agent Teams" containing one boolean toggle, *Enable agent teams*, persisted via `@AppStorage("agentTeamsEnabled")` (Bool, default false).

**TEAM-1.2** When the user toggles `agentTeamsEnabled` from false to true, the application shall set `channelsEnabled` to true if it was false. When the user toggles `channelsEnabled` from true to false while `agentTeamsEnabled` is true, the application shall first set `agentTeamsEnabled` to false (the dependency is one-directional: teams require channels).

**TEAM-1.3** While `agentTeamsEnabled` is true, the Default Command field on the Settings General pane shall be rendered read-only with a footnote indicating that team mode manages it. The previously-stored value is preserved in `@AppStorage("defaultCommand")` and restored to the editable field when team mode is turned off.

**TEAM-1.4** While `agentTeamsEnabled` is true, the application shall override the user's stored `defaultCommand` value at pane-launch time with the canonical team-mode launch line `claude --dangerously-load-development-channels server:graftty-channel`. The override applies only inside the `defaultCommandDecision` call path used by Graftty to auto-type into newly opened panes; commands the user types into a shell prompt themselves are unaffected.

### N.2 Team Identity & Membership

**TEAM-2.1** A *team* is implicit in any `RepoEntry` with two or more `WorktreeEntry` children, while `agentTeamsEnabled` is true. A repo with one worktree (or with team mode off) has no team and no team-aware behavior.

**TEAM-2.2** A team's *member name* for a given worktree shall be `WorktreeNameSanitizer(worktree.branch)`, the same sanitization rule used for new worktree names per `GIT-5.1`.

**TEAM-2.3** A team's *lead* shall be the worktree where `worktree.path == repo.path` (the repository's main checkout per `LAYOUT-2.3`). All other worktrees of the team are *coworkers*.

**TEAM-2.4** Team identity, membership, and lead designation are derived live from `AppState`. The application shall not persist any team-specific data beyond `agentTeamsEnabled` itself.

### N.3 Team-Aware MCP Instructions

**TEAM-3.1** When a `graftty mcp-channel` subscriber connects on behalf of a worktree whose repo has team status (per TEAM-2.1), the application shall include the rendered team-aware instructions text in the initial `instructions` channel event sent to that subscriber. The instructions text describes only mechanism — peers, the `graftty team msg` command, the `team_*` channel event types — and contains no behavioral prescription.

**TEAM-3.2** The application shall render the *lead variant* of the team-aware instructions when the subscriber's worktree is the team's lead (per TEAM-2.3), and the *coworker variant* otherwise. Both variants name the team (by repo display name), the agent (by member name), and list the team's other members by name and worktree.

**TEAM-3.3** When the user's `channelPrompt` setting (per `CHAN-*`) is non-empty AND a team variant is rendered, the application shall concatenate the team variant followed by a newline followed by the user's `channelPrompt` and emit the combined string as the `instructions` event body. The team variant precedes the user's prompt so role context is established before any user policy guidance.

**TEAM-3.4** When the team membership of a worktree's repo changes (a worktree is added or removed, or `agentTeamsEnabled` toggles), the application shall re-render and re-broadcast the `instructions` event to every active subscriber whose worktree's team is affected. (This reuses the existing `broadcastInstructions` pipeline.)

### N.4 `graftty team` CLI

**TEAM-4.1** The application shall provide a CLI subcommand group `graftty team` with two subcommands: `msg <member-name> "<text>"` and `list`.

**TEAM-4.2** `graftty team msg <member-name> "<text>"` shall resolve the calling process's worktree via `WorktreeResolver.resolve()`, look up the team for that worktree, find a teammate matching `<member-name>`, and send a `team_message` channel event addressed to that teammate's worktree with `attrs.from = <calling-worktree's member name>` and body `<text>`. The CLI shall exit non-zero with a stderr message if (a) team mode is disabled, (b) the calling worktree has no team, or (c) `<member-name>` is not a teammate of the caller. In case (c) the error shall list the current teammates' member names.

**TEAM-4.3** `graftty team list` shall print one line per team member of the caller's team to stdout: `<member-name>  branch=<branch>  worktree=<path>  role=<lead|coworker>  running=<true|false>`. The first printed line shall be a header `team=<repo-display-name>  members=<count>`. The CLI shall exit non-zero with a stderr message if team mode is disabled or the calling worktree has no team.

### N.5 `team_*` Channel Events

**TEAM-5.1** The application shall emit a `team_message` channel event when `graftty team msg` is invoked successfully. Routing: addressed to the recipient's worktree only. Attributes: `team` (repo display name), `from` (sender's member name). Body: the message text.

**TEAM-5.2** The application shall emit a `team_member_joined` channel event when a worktree is added to a team (a new worktree appears in a team-enabled repo, or a single-worktree repo gains a second worktree). Routing: addressed to the team's lead's worktree only. Attributes: `team`, `member` (joiner's member name), `branch`, `worktree` (joiner's path).

**TEAM-5.3** The application shall emit a `team_member_left` channel event when a worktree is removed from a team (the worktree is deleted, or the team-enabled repo collapses to one worktree). Routing: addressed to the team's lead's worktree only. Attributes: `team`, `member` (departing member's name), `reason` (`removed` or `exited`).

**TEAM-5.4** The application shall emit a `team_pr_merged` channel event when `PRStatusStore` observes a transition to `.merged` for a worktree whose repo currently has team status. Routing: addressed to the team's lead's worktree only. Attributes: `team`, `member`, `pr_number`, `branch`, `merge_sha`.

### N.6 Sidebar Visualization

**TEAM-6.1** While `agentTeamsEnabled` is true and a `RepoEntry` has two or more worktrees, the sidebar shall render that repo with a small "team" icon (e.g., SF Symbol `person.2.fill`) adjacent to its disclosure header, and apply a subtle accent stripe along the leading edge of every worktree row that belongs to the repo (and that worktree's pane sub-rows per `LAYOUT-2.8`). The accent color is deterministic from the repo's path (hash → palette index) and stable across launches.

**TEAM-6.2** Right-clicking the team icon, the team accent stripe, or any team-enabled worktree's row shall include a *Show Team Members…* context-menu item. Selecting it shall display a popover listing each team member by name, branch, and role (lead / coworker), populated from the same source as `graftty team list`.
```

- [ ] **Step 2: Verify SPECS.md still parses cleanly**

Run: `grep -cE "^\\*\\*TEAM-[0-9]+\\.[0-9]+\\*\\*" SPECS.md`
Expected: `15` (count of TEAM-* requirements added — TEAM-1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 5.1, 5.2, 5.3, 5.4, 6.1, 6.2 — adjust if you've also added 5 status messages; should match what you wrote)

- [ ] **Step 3: Commit**

```bash
git add SPECS.md
git commit -m "specs: reserve TEAM-* requirement IDs for agent-teams feature"
```

---

### Task 2: `agentTeamsEnabled` settings flag + AgentTeamsSettingsPane

**Files:**
- Create: `Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift`
- Modify: `Sources/Graftty/Views/SettingsView.swift` (register the new pane in the Settings TabView)

This task introduces the `@AppStorage("agentTeamsEnabled")` flag (no separate storage struct — `@AppStorage` is the storage). It creates a Settings pane modeled on `Sources/Graftty/Views/Settings/ChannelsSettingsPane.swift`. It also implements the dependency from TEAM-1.2 (turning on team mode auto-enables Channels; turning off Channels auto-disables team mode).

- [ ] **Step 1: Create the new pane file with a failing UI test**

Write `Tests/GrafttyTests/Settings/AgentTeamsSettingsPaneTests.swift` (create the directory if needed):

```swift
import Testing
import SwiftUI
@testable import Graftty

@Suite("AgentTeamsSettingsPane Tests")
struct AgentTeamsSettingsPaneTests {

    @Test func enablingTeamsTurnsOnChannels() {
        let defaults = UserDefaults(suiteName: "AgentTeamsSettingsPaneTests-1")!
        defaults.removePersistentDomain(forName: "AgentTeamsSettingsPaneTests-1")
        defaults.set(false, forKey: "channelsEnabled")
        defaults.set(false, forKey: "agentTeamsEnabled")

        AgentTeamsSettingsPane.applyTeamModeToggleSideEffects(
            newValue: true,
            defaults: defaults
        )

        #expect(defaults.bool(forKey: "channelsEnabled") == true)
    }

    @Test func disablingChannelsAlsoDisablesTeamMode() {
        let defaults = UserDefaults(suiteName: "AgentTeamsSettingsPaneTests-2")!
        defaults.removePersistentDomain(forName: "AgentTeamsSettingsPaneTests-2")
        defaults.set(true, forKey: "channelsEnabled")
        defaults.set(true, forKey: "agentTeamsEnabled")

        AgentTeamsSettingsPane.applyChannelsToggleSideEffects(
            newValue: false,
            defaults: defaults
        )

        #expect(defaults.bool(forKey: "agentTeamsEnabled") == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AgentTeamsSettingsPaneTests`
Expected: FAIL — `AgentTeamsSettingsPane` undefined.

- [ ] **Step 3: Create the pane file**

Write `Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift`:

```swift
import SwiftUI

/// Settings pane that exposes the `agentTeamsEnabled` toggle.
///
/// Implements TEAM-1.1, TEAM-1.2, TEAM-1.3 from SPECS.md.
struct AgentTeamsSettingsPane: View {
    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false
    @AppStorage("channelsEnabled") private var channelsEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable agent teams", isOn: Binding(
                    get: { agentTeamsEnabled },
                    set: { newValue in
                        agentTeamsEnabled = newValue
                        Self.applyTeamModeToggleSideEffects(
                            newValue: newValue,
                            defaults: .standard
                        )
                    }
                ))
            } footer: {
                Text("Turning this on auto-enables Channels and locks the Default Command field. Each Claude pane Graftty launches in a multi-worktree repo will receive team-aware instructions on connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if agentTeamsEnabled {
                Section("Managed default command") {
                    Text("claude --dangerously-load-development-channels server:graftty-channel")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 240)
    }

    /// Applies the team-mode → channels-mode dependency (TEAM-1.2).
    /// Static so tests can drive it without a SwiftUI environment.
    static func applyTeamModeToggleSideEffects(
        newValue: Bool,
        defaults: UserDefaults
    ) {
        if newValue && !defaults.bool(forKey: "channelsEnabled") {
            defaults.set(true, forKey: "channelsEnabled")
        }
    }

    /// Applies the channels-mode → team-mode dependency (TEAM-1.2):
    /// turning off channels also turns off team mode, since team mode requires channels.
    static func applyChannelsToggleSideEffects(
        newValue: Bool,
        defaults: UserDefaults
    ) {
        if !newValue && defaults.bool(forKey: "agentTeamsEnabled") {
            defaults.set(false, forKey: "agentTeamsEnabled")
        }
    }
}
```

- [ ] **Step 4: Wire the pane into `SettingsView`**

Open `Sources/Graftty/Views/SettingsView.swift`. Find the existing `TabView` (or whatever UI shape registers Settings panes — look at how `ChannelsSettingsPane` is registered for reference). Add:

```swift
.tabItem {
    Label("Agent Teams", systemImage: "person.2.fill")
}
```

… as a new tab containing `AgentTeamsSettingsPane()`. Match the surrounding tab-registration pattern exactly.

Also, in the same file, find where `ChannelsSettingsPane`'s toggle is observed (the channels pane handles its own `channelsEnabled` toggle). The simplest correct hook for the channels-off → teams-off cascade is to add a `.onChange(of: channelsEnabled) { newValue in AgentTeamsSettingsPane.applyChannelsToggleSideEffects(newValue: newValue, defaults: .standard) }` modifier on whichever view owns the `channelsEnabled` `@AppStorage` binding. Read `ChannelsSettingsPane.swift` for the binding's location and wire `.onChange` there.

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter AgentTeamsSettingsPaneTests`
Expected: PASS (both tests).

- [ ] **Step 6: Run the existing test suite to verify nothing regressed**

Run: `swift test`
Expected: all existing tests still pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Graftty/Views/Settings/AgentTeamsSettingsPane.swift Sources/Graftty/Views/SettingsView.swift Tests/GrafttyTests/Settings/AgentTeamsSettingsPaneTests.swift
git commit -m "feat(teams): add Agent Teams settings pane (TEAM-1.*)"
```

---

### Task 3: TeamView — derive team state from AppState

**Files:**
- Create: `Sources/GrafttyKit/Teams/TeamView.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamViewTests.swift`

`TeamView` is a pure value type that, given an `AppState` and a worktree, returns the team that worktree belongs to (or nil). It encapsulates TEAM-2.* — the rules for what counts as a team, how the lead is identified, and how member names are derived.

- [ ] **Step 1: Write failing tests**

Write `Tests/GrafttyKitTests/Teams/TeamViewTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("TeamView Tests")
struct TeamViewTests {

    private func makeRepo(path: String, displayName: String, branches: [String]) -> RepoEntry {
        var repo = RepoEntry(
            id: UUID(),
            path: path,
            displayName: displayName,
            isCollapsed: false,
            worktrees: [],
            bookmark: nil
        )
        for (i, branch) in branches.enumerated() {
            let worktreePath = i == 0 ? path : "\(path)/.worktrees/\(branch.replacingOccurrences(of: "/", with: "-"))"
            repo.worktrees.append(WorktreeEntry(
                id: UUID(),
                path: worktreePath,
                branch: branch,
                state: .closed,
                attention: nil,
                paneAttention: [:],
                splitTree: SplitTree(root: .leaf(TerminalID())),
                focusedTerminalID: nil,
                offeredDeleteForMergedPR: nil
            ))
        }
        return repo
    }

    @Test func singleWorktreeRepoHasNoTeam() {
        let repo = makeRepo(path: "/r/single", displayName: "single", branches: ["main"])
        #expect(TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true) == nil)
    }

    @Test func multiWorktreeRepoHasTeamWhenEnabled() {
        let repo = makeRepo(path: "/r/multi", displayName: "multi", branches: ["main", "feature/login"])
        let view = TeamView.team(for: repo.worktrees[1], in: [repo], teamsEnabled: true)
        #expect(view != nil)
        #expect(view?.repoDisplayName == "multi")
        #expect(view?.members.count == 2)
    }

    @Test func teamModeOffMeansNoTeam() {
        let repo = makeRepo(path: "/r/multi", displayName: "multi", branches: ["main", "feature/login"])
        #expect(TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: false) == nil)
    }

    @Test func leadIsRootWorktree() {
        let repo = makeRepo(path: "/r/multi", displayName: "multi", branches: ["main", "feature/login"])
        let view = TeamView.team(for: repo.worktrees[1], in: [repo], teamsEnabled: true)!
        #expect(view.lead.worktreePath == "/r/multi")
        #expect(view.lead.role == .lead)
        let coworker = view.members.first(where: { $0.role == .coworker })!
        #expect(coworker.branch == "feature/login")
    }

    @Test func memberNameSanitizesBranch() {
        let repo = makeRepo(path: "/r/multi", displayName: "multi", branches: ["main", "feature/login-form"])
        let view = TeamView.team(for: repo.worktrees[1], in: [repo], teamsEnabled: true)!
        let coworker = view.members.first(where: { $0.role == .coworker })!
        // WorktreeNameSanitizer replaces "/" with "-" preservation rules; we expect
        // the sanitized form (the existing sanitizer keeps "/" — confirm in impl).
        // Here we just assert the name is set and matches the expected sanitization.
        #expect(coworker.name == "feature/login-form" || coworker.name == "feature-login-form")
    }

    @Test func peersOfMemberExcludesSelf() {
        let repo = makeRepo(path: "/r/multi", displayName: "multi", branches: ["main", "a", "b"])
        let view = TeamView.team(for: repo.worktrees[2], in: [repo], teamsEnabled: true)!
        let peers = view.peers(of: repo.worktrees[2])
        #expect(peers.count == 2)
        #expect(peers.allSatisfy { $0.worktreePath != repo.worktrees[2].path })
    }

    @Test func memberNamedFindsByName() {
        let repo = makeRepo(path: "/r/multi", displayName: "multi", branches: ["main", "alice", "bob"])
        let view = TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true)!
        #expect(view.memberNamed("alice")?.branch == "alice")
        #expect(view.memberNamed("nobody") == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamViewTests`
Expected: FAIL — `TeamView` undefined.

- [ ] **Step 3: Create `TeamView.swift`**

Write `Sources/GrafttyKit/Teams/TeamView.swift`:

```swift
import Foundation

public enum TeamRole: String, Codable, Sendable, Equatable {
    case lead
    case coworker
}

public struct TeamMember: Sendable, Equatable {
    public let name: String           // sanitized branch
    public let worktreePath: String
    public let branch: String
    public let role: TeamRole
    public let isRunning: Bool

    public init(
        name: String,
        worktreePath: String,
        branch: String,
        role: TeamRole,
        isRunning: Bool
    ) {
        self.name = name
        self.worktreePath = worktreePath
        self.branch = branch
        self.role = role
        self.isRunning = isRunning
    }
}

/// Read-only view over `AppState` that describes the team a worktree belongs to.
///
/// Implements TEAM-2.* from SPECS.md. There is no persisted team registry —
/// membership is derived live from `RepoEntry.worktrees`.
public struct TeamView: Sendable, Equatable {
    public let repoPath: String
    public let repoDisplayName: String
    public let members: [TeamMember]   // members[0] is always the lead

    public var lead: TeamMember {
        members.first(where: { $0.role == .lead })
            ?? members[0]   // safety: should never fall through given construction below
    }

    public func memberNamed(_ name: String) -> TeamMember? {
        members.first(where: { $0.name == name })
    }

    public func peers(of worktree: WorktreeEntry) -> [TeamMember] {
        members.filter { $0.worktreePath != worktree.path }
    }

    /// Resolves the team for a given worktree. Returns nil when team mode is
    /// off, the worktree's repo is not in `repos`, or the repo has fewer than
    /// two worktrees (a one-worktree repo has no team).
    public static func team(
        for worktree: WorktreeEntry,
        in repos: [RepoEntry],
        teamsEnabled: Bool
    ) -> TeamView? {
        guard teamsEnabled else { return nil }
        guard let repo = repos.first(where: { $0.worktrees.contains(where: { $0.id == worktree.id }) }) else {
            return nil
        }
        guard repo.worktrees.count >= 2 else { return nil }

        let members = repo.worktrees.map { wt -> TeamMember in
            TeamMember(
                name: WorktreeNameSanitizer.sanitize(wt.branch),
                worktreePath: wt.path,
                branch: wt.branch,
                role: wt.path == repo.path ? .lead : .coworker,
                isRunning: wt.state == .running
            )
        }.sorted { lhs, rhs in
            // Lead first, then coworkers in worktree-add order (preserve repo.worktrees order)
            if lhs.role != rhs.role { return lhs.role == .lead }
            return false
        }

        return TeamView(
            repoPath: repo.path,
            repoDisplayName: repo.displayName,
            members: members
        )
    }
}
```

The reference to `WorktreeNameSanitizer.sanitize(_:)` assumes the existing sanitizer (per GIT-5.1) exposes a static method by that name. If the actual API differs (e.g., it's `WorktreeNameSanitizer().sanitize(_:)` or a free function), adjust. Run `grep -nE "WorktreeNameSanitizer" Sources/` to confirm before changing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TeamViewTests`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamView.swift Tests/GrafttyKitTests/Teams/TeamViewTests.swift
git commit -m "feat(teams): TeamView derives team state from AppState (TEAM-2.*)"
```

---

### Task 4: TeamChannelEvents — Codable types for `team_*` events

**Files:**
- Create: `Sources/GrafttyKit/Teams/TeamChannelEvents.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamChannelEventsTests.swift`

This task adds the four new `team_*` event types as static constants on `ChannelEventType`, plus typed builders that produce the corresponding `ChannelServerMessage.event(...)` instances. We don't subclass anything; we just provide convenient constructors so callers (the next several tasks) don't repeat the attribute-key strings.

- [ ] **Step 1: Write failing tests**

Write `Tests/GrafttyKitTests/Teams/TeamChannelEventsTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("TeamChannelEvents Tests")
struct TeamChannelEventsTests {

    @Test func teamMessageEventShape() {
        let event = TeamChannelEvents.teamMessage(
            team: "acme-web",
            from: "main",
            text: "hello"
        )
        guard case let .event(type, attrs, body) = event else {
            Issue.record("expected .event variant")
            return
        }
        #expect(type == "team_message")
        #expect(attrs["team"] == "acme-web")
        #expect(attrs["from"] == "main")
        #expect(body == "hello")
    }

    @Test func memberJoinedEventShape() {
        let event = TeamChannelEvents.memberJoined(
            team: "acme-web",
            member: "feature-login",
            branch: "feature/login",
            worktree: "/r/acme/.worktrees/feature-login"
        )
        guard case let .event(type, attrs, body) = event else {
            Issue.record("expected .event variant")
            return
        }
        #expect(type == "team_member_joined")
        #expect(attrs["team"] == "acme-web")
        #expect(attrs["member"] == "feature-login")
        #expect(attrs["branch"] == "feature/login")
        #expect(attrs["worktree"] == "/r/acme/.worktrees/feature-login")
        #expect(body.contains("feature-login"))   // body is human-readable summary
    }

    @Test func memberLeftReasonRendered() {
        let removed = TeamChannelEvents.memberLeft(team: "t", member: "m", reason: .removed)
        let exited  = TeamChannelEvents.memberLeft(team: "t", member: "m", reason: .exited)
        guard case let .event(_, removedAttrs, _) = removed,
              case let .event(_, exitedAttrs, _) = exited else {
            Issue.record("expected .event variants")
            return
        }
        #expect(removedAttrs["reason"] == "removed")
        #expect(exitedAttrs["reason"] == "exited")
    }

    @Test func prMergedFullPayload() {
        let event = TeamChannelEvents.prMerged(
            team: "acme-web",
            member: "feature-login",
            prNumber: 42,
            branch: "feature/login",
            mergeSha: "abcd1234"
        )
        guard case let .event(type, attrs, _) = event else {
            Issue.record("expected .event variant")
            return
        }
        #expect(type == "team_pr_merged")
        #expect(attrs["pr_number"] == "42")
        #expect(attrs["merge_sha"] == "abcd1234")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamChannelEventsTests`
Expected: FAIL — `TeamChannelEvents` undefined.

- [ ] **Step 3: Create `TeamChannelEvents.swift`**

Write `Sources/GrafttyKit/Teams/TeamChannelEvents.swift`:

```swift
import Foundation

/// Builders for the four `team_*` channel event types described in TEAM-5.* of SPECS.md.
///
/// These are thin constructors over `ChannelServerMessage.event(...)` so callers don't
/// duplicate the `type` string and attribute-key conventions.
public enum TeamChannelEvents {

    // MARK: - team_message (TEAM-5.1)

    public static func teamMessage(
        team: String,
        from sender: String,
        text: String
    ) -> ChannelServerMessage {
        .event(
            type: "team_message",
            attrs: ["team": team, "from": sender],
            body: text
        )
    }

    // MARK: - team_member_joined (TEAM-5.2)

    public static func memberJoined(
        team: String,
        member: String,
        branch: String,
        worktree: String
    ) -> ChannelServerMessage {
        .event(
            type: "team_member_joined",
            attrs: [
                "team": team,
                "member": member,
                "branch": branch,
                "worktree": worktree,
            ],
            body: "Coworker \"\(member)\" joined."
        )
    }

    // MARK: - team_member_left (TEAM-5.3)

    public enum LeaveReason: String, Sendable, Equatable {
        case removed
        case exited
    }

    public static func memberLeft(
        team: String,
        member: String,
        reason: LeaveReason
    ) -> ChannelServerMessage {
        .event(
            type: "team_member_left",
            attrs: [
                "team": team,
                "member": member,
                "reason": reason.rawValue,
            ],
            body: "Coworker \"\(member)\" left (\(reason.rawValue))."
        )
    }

    // MARK: - team_pr_merged (TEAM-5.4)

    public static func prMerged(
        team: String,
        member: String,
        prNumber: Int,
        branch: String,
        mergeSha: String
    ) -> ChannelServerMessage {
        .event(
            type: "team_pr_merged",
            attrs: [
                "team": team,
                "member": member,
                "pr_number": String(prNumber),
                "branch": branch,
                "merge_sha": mergeSha,
            ],
            body: "Coworker \"\(member)\"'s PR #\(prNumber) (\(branch)) merged."
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TeamChannelEventsTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamChannelEvents.swift Tests/GrafttyKitTests/Teams/TeamChannelEventsTests.swift
git commit -m "feat(teams): add team_* channel event constructors (TEAM-5.*)"
```

---

### Task 5: TeamInstructionsRenderer — render the lead/coworker prompt variants

**Files:**
- Create: `Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift`

This task renders the team-aware MCP instructions template described in the design doc's Data Model § "Team-aware MCP-instructions template," producing two variants (lead, coworker). Pure function: `(TeamView, TeamMember) -> String`.

- [ ] **Step 1: Write failing tests**

Write `Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift`:

```swift
import Testing
@testable import GrafttyKit

@Suite("TeamInstructionsRenderer Tests")
struct TeamInstructionsRendererTests {

    private func makeView() -> TeamView {
        TeamView(
            repoPath: "/r/acme",
            repoDisplayName: "acme-web",
            members: [
                TeamMember(name: "main", worktreePath: "/r/acme", branch: "main",
                           role: .lead, isRunning: true),
                TeamMember(name: "feature-login",
                           worktreePath: "/r/acme/.worktrees/feature-login",
                           branch: "feature/login",
                           role: .coworker, isRunning: false),
                TeamMember(name: "feature-signup",
                           worktreePath: "/r/acme/.worktrees/feature-signup",
                           branch: "feature/signup",
                           role: .coworker, isRunning: true),
            ]
        )
    }

    @Test func leadVariantNamesItself() {
        let view = makeView()
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.lead)
        #expect(prompt.contains("\"main\""))
        #expect(prompt.contains("LEAD"))
        #expect(prompt.contains("acme-web"))
    }

    @Test func leadVariantListsAllCoworkers() {
        let view = makeView()
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.lead)
        #expect(prompt.contains("\"feature-login\""))
        #expect(prompt.contains("\"feature-signup\""))
    }

    @Test func leadVariantDocumentsTeamEvents() {
        let view = makeView()
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.lead)
        #expect(prompt.contains("team_member_joined"))
        #expect(prompt.contains("team_member_left"))
        #expect(prompt.contains("team_pr_merged"))
        #expect(prompt.contains("team_message"))
    }

    @Test func coworkerVariantNamesLead() {
        let view = makeView()
        let me = view.members.first(where: { $0.name == "feature-login" })!
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: me)
        #expect(prompt.contains("\"feature-login\""))
        #expect(prompt.contains("\"main\""))    // lead is named
        #expect(prompt.contains("coworker"))
    }

    @Test func coworkerVariantListsPeerCoworkers() {
        let view = makeView()
        let me = view.members.first(where: { $0.name == "feature-login" })!
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: me)
        // Peer coworkers (not me, not lead) should be named:
        #expect(prompt.contains("\"feature-signup\""))
    }

    @Test func coworkerVariantStatesItDoesNotReceiveStatusEvents() {
        let view = makeView()
        let me = view.members.first(where: { $0.name == "feature-login" })!
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: me)
        #expect(prompt.contains("do NOT receive status events"))
    }

    @Test func neitherVariantPrescribesPolicy() {
        // Cleanup verification: prompts describe mechanism only, no "you must…" / "you should…"
        let view = makeView()
        let leadPrompt = TeamInstructionsRenderer.render(team: view, viewer: view.lead)
        let cw = view.members.first(where: { $0.name == "feature-login" })!
        let cwPrompt = TeamInstructionsRenderer.render(team: view, viewer: cw)
        for prompt in [leadPrompt, cwPrompt] {
            #expect(!prompt.contains("MUST proactively"))
            #expect(!prompt.contains("You should "))   // case-sensitive "You should" sentence-start
            #expect(!prompt.contains("you should "))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamInstructionsRendererTests`
Expected: FAIL — `TeamInstructionsRenderer` undefined.

- [ ] **Step 3: Create `TeamInstructionsRenderer.swift`**

Write `Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift`:

```swift
import Foundation

/// Renders the team-aware MCP instructions text described in the agent-teams design doc.
///
/// Implements TEAM-3.1 / TEAM-3.2. Mechanism only — no behavioral prescription;
/// coordination policy is the user's to define.
public enum TeamInstructionsRenderer {

    public static func render(team: TeamView, viewer: TeamMember) -> String {
        switch viewer.role {
        case .lead:    return renderLead(team: team, viewer: viewer)
        case .coworker: return renderCoworker(team: team, viewer: viewer)
        }
    }

    // MARK: - Lead variant

    private static func renderLead(team: TeamView, viewer: TeamMember) -> String {
        let coworkers = team.members.filter { $0.role == .coworker }
        let coworkerLines = coworkers
            .map { "  - \"\($0.name)\" — branch \($0.branch), worktree \($0.worktreePath)" }
            .joined(separator: "\n")

        return """
        You are "\(viewer.name)" — the LEAD worktree of Graftty agent team for repo \
        "\(team.repoDisplayName)", running in worktree \(viewer.worktreePath) on branch \(viewer.branch).

        Your coworkers (other worktrees of this repo with a Claude session):
        \(coworkerLines.isEmpty ? "  (none yet)" : coworkerLines)

        To send a message to any teammate, run this shell command:
          graftty team msg <teammate-name> "<your message>"

        You will receive these channel events that coworkers do NOT receive directly \
        (routed to the lead so the user has a single point to define team-wide \
        coordination policy):
          - team_member_joined — a new coworker joined; attrs: team, member, branch, worktree.
          - team_member_left   — a coworker left; attrs: team, member, reason (removed | exited).
          - team_pr_merged     — a coworker's PR merged; attrs: team, member, pr_number, branch, merge_sha.

        You will also receive direct messages from coworkers (or from the user) as:
          <channel source="graftty-channel" type="team_message" from="<sender>">…text…</channel>

        To see the current roster at any time:
          graftty team list
        """
    }

    // MARK: - Coworker variant

    private static func renderCoworker(team: TeamView, viewer: TeamMember) -> String {
        let lead = team.lead
        let peerCoworkers = team.members.filter {
            $0.role == .coworker && $0.worktreePath != viewer.worktreePath
        }
        let peerLines = peerCoworkers
            .map { "  - \"\($0.name)\" — branch \($0.branch), worktree \($0.worktreePath)" }
            .joined(separator: "\n")

        return """
        You are "\(viewer.name)" — a coworker on Graftty agent team for repo \
        "\(team.repoDisplayName)", running in worktree \(viewer.worktreePath) on branch \(viewer.branch).

        Your lead: "\(lead.name)" — worktree \(lead.worktreePath), branch \(lead.branch).
        Your peer coworkers (you may message these directly too):
        \(peerLines.isEmpty ? "  (none)" : peerLines)

        To send a message to the lead or any peer, run this shell command:
          graftty team msg <recipient-name> "<your message>"

        You will receive incoming messages as:
          <channel source="graftty-channel" type="team_message" from="<sender>">…text…</channel>

        You do NOT receive status events about other coworkers — those route to the lead.

        To see the current roster at any time:
          graftty team list
        """
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TeamInstructionsRendererTests`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift
git commit -m "feat(teams): render lead/coworker MCP instructions variants (TEAM-3.*)"
```

---

### Task 6: ChannelRouter integration — per-worktree team instructions + team-event dispatch

**Files:**
- Modify: `Sources/GrafttyKit/Channels/ChannelRouter.swift`
- Modify: `Sources/Graftty/Channels/ChannelSettingsObserver.swift`
- Test: `Tests/GrafttyKitTests/Channels/ChannelRouterTeamIntegrationTests.swift` (new)

The existing `ChannelRouter` accepts a `promptProvider: () -> String` closure. Team-aware instructions are per-worktree, so we evolve the closure to `promptProvider: (worktreePath: String) -> String`. The provider — wired up in `ChannelSettingsObserver` — composes the user's `channelPrompt` with team context (when applicable) per TEAM-3.3.

We also add a `dispatchToLead(of: RepoEntry, message:)` helper that simplifies the "addressed to lead's worktree" routing pattern used by status events.

- [ ] **Step 1: Write failing test for per-worktree provider**

Add to `Tests/GrafttyKitTests/Channels/ChannelRouterTeamIntegrationTests.swift`:

```swift
import XCTest
@testable import GrafttyKit

@MainActor
final class ChannelRouterTeamIntegrationTests: XCTestCase {

    private var socketPath: String!

    override func setUp() async throws {
        socketPath = "/tmp/graftty-channel-test-\(UUID().uuidString).sock"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testProviderReceivesPerWorktreeContext() async throws {
        var calls: [String] = []
        let router = ChannelRouter(
            socketPath: socketPath,
            promptProvider: { wt in
                calls.append(wt)
                return "prompt-for-\(wt)"
            }
        )
        try router.start()
        defer { router.stop() }

        // Simulate two subscribers from two different worktrees
        let client1 = try ChannelSocketClient(socketPath: socketPath)
        try client1.sendSubscribe(worktree: "/r/a")
        let client2 = try ChannelSocketClient(socketPath: socketPath)
        try client2.sendSubscribe(worktree: "/r/b")

        // Allow async pump to deliver the initial instructions event
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(calls.contains("/r/a"))
        XCTAssertTrue(calls.contains("/r/b"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ChannelRouterTeamIntegrationTests`
Expected: FAIL — `promptProvider` signature is `() -> String`, not `(String) -> String`.

- [ ] **Step 3: Evolve `ChannelRouter` to per-worktree provider**

Open `Sources/GrafttyKit/Channels/ChannelRouter.swift`. Change the stored `promptProvider` from `() -> String` to `(_ worktreePath: String) -> String`. Update the `init` signature, the `onSubscribe` callback that emits the initial `instructions` event (it already has the worktree path — just pass it to the provider), and `broadcastInstructions()` (it now needs to render once per subscriber rather than encoding once and sharing the bytes).

Concretely:

```swift
// init signature change
public init(
    socketPath: String,
    promptProvider: @escaping (_ worktreePath: String) -> String
) {
    // ...
}

// onSubscribe: existing flow has the worktreePath in scope; pass it to provider
let prompt = self.promptProvider(worktreePath)

// broadcastInstructions: re-render per subscriber
public func broadcastInstructions() {
    for (worktreePath, conn) in subscribers {
        let prompt = self.promptProvider(worktreePath)
        // ... encode and write per subscriber ...
    }
}
```

Update every existing call site that constructs a `ChannelRouter` to pass the new signature. Find them with: `grep -rn "ChannelRouter(socketPath" Sources/`. For sites that currently pass `promptProvider: { return userPrompt }`, change to `promptProvider: { _ in return userPrompt }` as a transitional shim (Task 6 Step 5 wires the real per-worktree composer).

- [ ] **Step 4: Add `dispatchToLead` helper on `ChannelRouter`**

Inside `ChannelRouter`, add:

```swift
/// Dispatches a `ChannelServerMessage` addressed to the lead worktree of `repo`,
/// per TEAM-2.3 (lead = worktree where path == repo.path).
public func dispatchToLead(of repo: RepoEntry, message: ChannelServerMessage) {
    guard isEnabled else { return }
    dispatch(worktreePath: repo.path, message: message)
}
```

- [ ] **Step 5: Wire the real team-aware provider in `ChannelSettingsObserver`**

Open `Sources/Graftty/Channels/ChannelSettingsObserver.swift`. Find where it constructs the `ChannelRouter`. Replace the existing prompt-provider closure with one that composes user-prompt + team context per TEAM-3.3. Sketch:

```swift
// in ChannelSettingsObserver, where router is created:
self.router = ChannelRouter(
    socketPath: socketPath,
    promptProvider: { [weak self] worktreePath in
        guard let self else { return "" }
        return self.composedPrompt(forWorktree: worktreePath)
    }
)

// new method on ChannelSettingsObserver:
private func composedPrompt(forWorktree worktreePath: String) -> String {
    let userPrompt = UserDefaults.standard.string(forKey: "channelPrompt") ?? ""
    let teamsEnabled = UserDefaults.standard.bool(forKey: "agentTeamsEnabled")

    guard teamsEnabled,
          let appState = self.appStateProvider?(),
          let worktree = appState.findWorktree(byPath: worktreePath),
          let team = TeamView.team(for: worktree, in: appState.repos, teamsEnabled: true),
          let me = team.members.first(where: { $0.worktreePath == worktreePath })
    else {
        return userPrompt
    }

    let teamInstructions = TeamInstructionsRenderer.render(team: team, viewer: me)
    if userPrompt.isEmpty {
        return teamInstructions
    }
    return teamInstructions + "\n\n" + userPrompt
}
```

This requires `ChannelSettingsObserver` to have access to `AppState` (so it can derive teams). Wire an `appStateProvider: () -> AppState?` closure parameter to `ChannelSettingsObserver`'s init, defaulting to `nil` (so existing tests keep compiling). The Graftty app-level wiring (`GrafttyApp`) provides `{ appState }` when constructing the observer; tests that don't care about teams pass `nil`.

Add a small extension `extension AppState { func findWorktree(byPath path: String) -> WorktreeEntry? }` if one doesn't already exist.

Also add a KVO bridge for `agentTeamsEnabled`: `UserDefaults.standard.publisher(for: \.agentTeamsEnabled)` triggering `router.broadcastInstructions()` (so toggling team mode mid-session updates all running subscribers). This mirrors how `channelPrompt` and `channelsEnabled` are observed.

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: PASS — including the new `ChannelRouterTeamIntegrationTests` and all existing `ChannelRouterTests`.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Channels/ChannelRouter.swift Sources/Graftty/Channels/ChannelSettingsObserver.swift Tests/GrafttyKitTests/Channels/ChannelRouterTeamIntegrationTests.swift
git commit -m "feat(teams): per-worktree team-aware channel instructions (TEAM-3.*)"
```

---

### Task 7: Socket protocol additions — `teamMessage` and `teamList`

**Files:**
- Modify: `Sources/GrafttyKit/Notification/NotificationMessage.swift`
- Test: `Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift` (extend)

This task adds two new request types and the response shape for `teamList`. Codable round-trip tests follow the existing pattern in `NotificationMessageTests.swift`.

- [ ] **Step 1: Write failing tests**

Append to `Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift`:

```swift
@Test func encodeTeamMessage() throws {
    let msg: NotificationMessage = .teamMessage(callerWorktree: "/r/a", recipient: "alice", text: "hi")
    let data = try JSONEncoder().encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "team_message")
    #expect(json["caller_worktree"] as? String == "/r/a")
    #expect(json["recipient"] as? String == "alice")
    #expect(json["text"] as? String == "hi")
}

@Test func decodeTeamMessage() throws {
    let json = #"{"type":"team_message","caller_worktree":"/r/a","recipient":"alice","text":"hi"}"#
    let msg = try JSONDecoder().decode(NotificationMessage.self, from: Data(json.utf8))
    guard case let .teamMessage(caller, recipient, text) = msg else {
        Issue.record("expected .teamMessage")
        return
    }
    #expect(caller == "/r/a")
    #expect(recipient == "alice")
    #expect(text == "hi")
}

@Test func encodeTeamList() throws {
    let msg: NotificationMessage = .teamList(callerWorktree: "/r/a")
    let data = try JSONEncoder().encode(msg)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "team_list")
    #expect(json["caller_worktree"] as? String == "/r/a")
}

@Test func encodeTeamListResponse() throws {
    let resp: ResponseMessage = .teamList(
        teamName: "acme-web",
        members: [
            .init(name: "main", branch: "main", worktreePath: "/r/a", role: "lead", isRunning: true),
            .init(name: "alice", branch: "alice", worktreePath: "/r/a/.worktrees/alice", role: "coworker", isRunning: false),
        ]
    )
    let data = try JSONEncoder().encode(resp)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    #expect(json["type"] as? String == "team_list")
    #expect(json["team_name"] as? String == "acme-web")
    let members = json["members"] as! [[String: Any]]
    #expect(members.count == 2)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotificationMessageTests`
Expected: FAIL — `.teamMessage`, `.teamList`, and the response variant are undefined.

- [ ] **Step 3: Add the cases to `NotificationMessage`**

Open `Sources/GrafttyKit/Notification/NotificationMessage.swift`. Add to the request enum:

```swift
case teamMessage(callerWorktree: String, recipient: String, text: String)
case teamList(callerWorktree: String)
```

Add to the encode-`switch`:

```swift
case .teamMessage(let path, let recipient, let text):
    try container.encode("team_message", forKey: .type)
    try container.encode(path, forKey: .callerWorktree)
    try container.encode(recipient, forKey: .recipient)
    try container.encode(text, forKey: .text)

case .teamList(let path):
    try container.encode("team_list", forKey: .type)
    try container.encode(path, forKey: .callerWorktree)
```

Add to the decode-`switch`:

```swift
case "team_message":
    let path = try container.decode(String.self, forKey: .callerWorktree)
    let recipient = try container.decode(String.self, forKey: .recipient)
    let text = try container.decode(String.self, forKey: .text)
    self = .teamMessage(callerWorktree: path, recipient: recipient, text: text)

case "team_list":
    let path = try container.decode(String.self, forKey: .callerWorktree)
    self = .teamList(callerWorktree: path)
```

Add the new `CodingKeys` cases:

```swift
case callerWorktree = "caller_worktree"
case recipient
case text
case teamName = "team_name"
case members
```

Add the `ResponseMessage.teamList` variant + a small `TeamListMember` Codable struct:

```swift
public struct TeamListMember: Codable, Sendable, Equatable {
    public let name: String
    public let branch: String
    public let worktreePath: String
    public let role: String   // "lead" | "coworker"
    public let isRunning: Bool

    public init(name: String, branch: String, worktreePath: String, role: String, isRunning: Bool) {
        self.name = name
        self.branch = branch
        self.worktreePath = worktreePath
        self.role = role
        self.isRunning = isRunning
    }

    enum CodingKeys: String, CodingKey {
        case name, branch
        case worktreePath = "worktree_path"
        case role
        case isRunning = "is_running"
    }
}

// In ResponseMessage:
case teamList(teamName: String, members: [TeamListMember])

// In encode switch:
case .teamList(let teamName, let members):
    try container.encode("team_list", forKey: .type)
    try container.encode(teamName, forKey: .teamName)
    try container.encode(members, forKey: .members)

// In decode switch:
case "team_list":
    let teamName = try container.decode(String.self, forKey: .teamName)
    let members = try container.decode([TeamListMember].self, forKey: .members)
    self = .teamList(teamName: teamName, members: members)
```

Update the existing `expectOk` helper in `Sources/GrafttyCLI/CLI.swift` (the helper that errors on non-`.ok` responses) — add a `case .teamList:` that errors with `"Unexpected team_list response"` to keep `expectOk` exhaustive.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NotificationMessageTests`
Expected: PASS (existing tests + 4 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Notification/NotificationMessage.swift Sources/GrafttyCLI/CLI.swift Tests/GrafttyKitTests/Notification/NotificationMessageTests.swift
git commit -m "feat(teams): teamMessage/teamList socket protocol cases (TEAM-4.*)"
```

---

### Task 8: `graftty team` CLI subcommand group

**Files:**
- Create: `Sources/GrafttyCLI/Team.swift`
- Modify: `Sources/GrafttyCLI/CLI.swift` (register the `Team` subcommand)
- Test: `Tests/GrafttyCLITests/TeamCLITests.swift`

This task adds the `graftty team` subcommand group with `msg` and `list` subcommands per TEAM-4.*. The subcommands send the new socket messages from Task 7, and the app-side handler is added in this task too (since otherwise `swift test` won't pass end-to-end).

- [ ] **Step 1: Add app-side handlers in `GrafttyApp`**

Find where the existing `addPane` / `closePane` socket handlers live (search: `grep -rn "case .addPane" Sources/`). Open that file (likely `Sources/Graftty/GrafttyApp.swift` or a SocketServer dispatcher within `Sources/GrafttyKit/Notification/`). Add handler branches:

```swift
case .teamMessage(let callerPath, let recipient, let text):
    // Resolve caller's team
    guard UserDefaults.standard.bool(forKey: "agentTeamsEnabled") else {
        respond(.error("team mode is disabled"))
        return
    }
    guard let callerWt = appState.findWorktree(byPath: callerPath) else {
        respond(.error("not inside a tracked worktree"))
        return
    }
    guard let team = TeamView.team(for: callerWt, in: appState.repos, teamsEnabled: true) else {
        respond(.error("your repo has no other team members yet"))
        return
    }
    guard let senderMember = team.members.first(where: { $0.worktreePath == callerPath }) else {
        respond(.error("internal error: caller not in resolved team"))
        return
    }
    guard let recipientMember = team.memberNamed(recipient) else {
        let names = team.members.map { $0.name }.filter { $0 != senderMember.name }
        respond(.error("\(recipient) is not a teammate of this worktree; current teammates: \(names.joined(separator: ", "))"))
        return
    }
    channelRouter.dispatch(
        worktreePath: recipientMember.worktreePath,
        message: TeamChannelEvents.teamMessage(
            team: team.repoDisplayName,
            from: senderMember.name,
            text: text
        )
    )
    respond(.ok)

case .teamList(let callerPath):
    guard UserDefaults.standard.bool(forKey: "agentTeamsEnabled") else {
        respond(.error("team mode is disabled"))
        return
    }
    guard let callerWt = appState.findWorktree(byPath: callerPath),
          let team = TeamView.team(for: callerWt, in: appState.repos, teamsEnabled: true) else {
        respond(.error("not in a team"))
        return
    }
    let members = team.members.map { m in
        TeamListMember(
            name: m.name, branch: m.branch, worktreePath: m.worktreePath,
            role: m.role.rawValue, isRunning: m.isRunning
        )
    }
    respond(.teamList(teamName: team.repoDisplayName, members: members))
```

The exact name of `appState`, `channelRouter`, `respond(_:)` will depend on the dispatcher's local variable conventions. Match what the existing `addPane` handler already uses.

- [ ] **Step 2: Write failing CLI tests**

Write `Tests/GrafttyCLITests/TeamCLITests.swift`. The existing `Notify` and `Pane` CLI tests likely use a stub-socket fixture; mirror that pattern.

```swift
import Testing
import Foundation
@testable import GrafttyCLI

@Suite("Team CLI Tests")
struct TeamCLITests {
    // Use a test fixture that boots a stub Graftty socket server
    // (mirror the pattern used by NotifyTests / PaneTests in this target).
    // ...

    @Test func msgRequiresArguments() async throws {
        // Run `graftty team msg` with no args; expect non-zero exit + usage error.
    }

    @Test func msgErrorsWhenTeamModeDisabled() async throws {
        // Stub responds with .error("team mode is disabled");
        // expect the CLI to print the message to stderr and exit non-zero.
    }

    @Test func listPrintsHeader() async throws {
        // Stub responds with .teamList(teamName: "acme-web", members: [...]);
        // expect stdout to begin with `team=acme-web  members=2`.
    }
}
```

If the existing CLI test target uses a different style (e.g., spawning the binary as a subprocess), match that exactly — write the tests in whatever shape the existing `NotifyTests` use. Read `Tests/GrafttyCLITests/` to see the convention before authoring.

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter TeamCLITests`
Expected: FAIL — `Team` subcommand undefined.

- [ ] **Step 4: Create `Sources/GrafttyCLI/Team.swift`**

```swift
import ArgumentParser
import Foundation
import GrafttyKit

struct Team: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Coordinate with teammates in a Graftty agent team",
        subcommands: [TeamMsg.self, TeamList.self]
    )
}

struct TeamMsg: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msg",
        abstract: "Send a message to a teammate by name"
    )

    @Argument(help: "Member name (sanitized branch name) of the teammate to message")
    var member: String

    @Argument(help: "Message text")
    var text: String

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(
            .teamMessage(callerWorktree: worktreePath, recipient: member, text: text)
        )
        try CLIEnv.expectOk(response)
    }
}

struct TeamList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the members of this worktree's team"
    )

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(.teamList(callerWorktree: worktreePath))
        switch response {
        case .teamList(let teamName, let members):
            print("team=\(teamName)  members=\(members.count)")
            for m in members {
                print("\(m.name)  branch=\(m.branch)  worktree=\(m.worktreePath)  role=\(m.role)  running=\(m.isRunning)")
            }
        case .error(let msg):
            CLIEnv.printError(msg)
            throw ExitCode(1)
        case .ok, .paneList:
            CLIEnv.printError("Unexpected response for team list")
            throw ExitCode(1)
        }
    }
}
```

Register `Team.self` in `Sources/GrafttyCLI/CLI.swift`:

```swift
subcommands: [Notify.self, Pane.self, MCPChannel.self, Team.self]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter TeamCLITests`
Expected: PASS.

Then run the full suite: `swift test`. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyCLI/Team.swift Sources/GrafttyCLI/CLI.swift Tests/GrafttyCLITests/TeamCLITests.swift
git add Sources/Graftty/GrafttyApp.swift   # or wherever the dispatcher modifications landed
git commit -m "feat(teams): graftty team msg/list CLI + app-side handlers (TEAM-4.*)"
```

---

### Task 9: AppState — fire `team_member_joined` / `team_member_left` on worktree change

**Files:**
- Modify: `Sources/Graftty/AppState.swift` (or whichever module owns `RepoEntry.worktrees` mutations)
- Modify: `Sources/Graftty/AddWorktreeFlow.swift` (the worktree-add success path)
- Modify: `Sources/Graftty/RemoveWorktreeFlow.swift` (or equivalent — find via `grep -rn "removeWorktree\|deleteWorktree" Sources/`)
- Test: `Tests/GrafttyKitTests/Teams/TeamMembershipEventsTests.swift` (new)

When a worktree is added to a multi-worktree-or-becoming-multi-worktree repo (team mode on), fire `team_member_joined` to the lead. When a worktree is removed from a team-enabled repo, fire `team_member_left` to the lead. Also fire on `agentTeamsEnabled` toggle on/off (each existing coworker counts as joined/left to the lead).

- [ ] **Step 1: Write failing test**

Write `Tests/GrafttyKitTests/Teams/TeamMembershipEventsTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("Team membership events")
struct TeamMembershipEventsTests {

    @Test func joiningAddsRoutedEventForLead() {
        // Use a TestChannelRouter spy that captures dispatch calls.
        // Call TeamMembershipEvents.fireJoined(repo:newWorktree:via:) and assert:
        //   - one dispatch was made
        //   - the dispatch target was the lead's worktree path
        //   - the event type was "team_member_joined"
    }

    @Test func joinDoesNotFireIfRepoOnlyHasOneWorktreeAfterAdd() {
        // If repo had 0 worktrees and we just added the first (still 1 total), no event fires.
        // (TEAM-2.1 — a repo with one worktree has no team.)
    }

    @Test func joinDoesNotFireWhenJoinerIsTheLeadAndOnlyMember() {
        // The first worktree (which becomes the lead) has nobody to notify.
    }

    @Test func leaveFiresEventForLeadEvenWhenLeavingMemberWasLead() {
        // If the root worktree is removed (rare but possible), the team is collapsing;
        // we still attempt to dispatch but the lead will be the new root or there is no team.
        // Spec: leaver = lead and only one worktree remaining → no event (no peers to notify).
        // Document the edge case in the assertion.
    }
}
```

Pick a small in-tree spy approach for `ChannelRouter`. The simplest: add `protocol ChannelEventDispatcher { func dispatch(worktreePath: String, message: ChannelServerMessage) }` and have `ChannelRouter` conform; tests substitute a spy implementation. If you don't want to introduce a protocol, accept a closure parameter `dispatch: (String, ChannelServerMessage) -> Void` to the helper function.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamMembershipEventsTests`
Expected: FAIL — helper undefined.

- [ ] **Step 3: Create the helper**

Add to `Sources/GrafttyKit/Teams/TeamMembershipEvents.swift`:

```swift
import Foundation

public enum TeamMembershipEvents {

    public static func fireJoined(
        repo: RepoEntry,
        joinerWorktreePath: String,
        teamsEnabled: Bool,
        dispatch: (String, ChannelServerMessage) -> Void
    ) {
        guard teamsEnabled, repo.worktrees.count >= 2 else { return }
        guard let joiner = repo.worktrees.first(where: { $0.path == joinerWorktreePath }) else { return }
        // The lead is the root worktree. If joiner is the root, there is nobody to notify.
        guard repo.path != joinerWorktreePath else { return }

        let event = TeamChannelEvents.memberJoined(
            team: repo.displayName,
            member: WorktreeNameSanitizer.sanitize(joiner.branch),
            branch: joiner.branch,
            worktree: joiner.path
        )
        dispatch(repo.path, event)
    }

    public static func fireLeft(
        repo: RepoEntry,
        leaverBranch: String,
        leaverPath: String,
        reason: TeamChannelEvents.LeaveReason,
        teamsEnabled: Bool,
        dispatch: (String, ChannelServerMessage) -> Void
    ) {
        // After removal, repo.worktrees has one fewer entry. We still want to notify the lead
        // if the repo still has the lead and at least one other peer (i.e., team still exists).
        guard teamsEnabled, repo.worktrees.count >= 1 else { return }
        // If the leaver was the lead and only the lead is gone, no team to notify.
        guard repo.worktrees.contains(where: { $0.path == repo.path }) else { return }

        let event = TeamChannelEvents.memberLeft(
            team: repo.displayName,
            member: WorktreeNameSanitizer.sanitize(leaverBranch),
            reason: reason
        )
        dispatch(repo.path, event)
    }
}
```

- [ ] **Step 4: Wire the helper into `AddWorktreeFlow.add(...)`**

In `Sources/Graftty/AddWorktreeFlow.swift`, after the new worktree is appended to `appState.repos[repoIdx].worktrees` (search for the line where the array gets `append`-ed; the explorer noted lines ~104–115), call:

```swift
TeamMembershipEvents.fireJoined(
    repo: appState.repos[repoIdx],
    joinerWorktreePath: discoveredWorktreePath,
    teamsEnabled: UserDefaults.standard.bool(forKey: "agentTeamsEnabled"),
    dispatch: { path, msg in channelRouter.dispatch(worktreePath: path, message: msg) }
)
```

`channelRouter` is the existing instance — pass it through to `AddWorktreeFlow.add(...)` if it isn't already (extend the static-method signature).

- [ ] **Step 5: Wire the helper into the worktree-removal path**

Find the worktree-removal handler. In Graftty this is likely in the sidebar's "Remove Worktree" / "Delete Worktree" action handler — use `grep -rn "removeWorktree\|deleteWorktree\|worktrees.remove" Sources/Graftty/` to locate it. Insert a `TeamMembershipEvents.fireLeft(...)` call right after the worktree is removed from `appState`.

For abnormal pane exit, add a similar call in the existing `WorktreeMonitor` deletion-event handler (which transitions worktrees to `.stale`). Use `reason: .exited` for the abnormal-exit path, `reason: .removed` for explicit user removal.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter TeamMembershipEventsTests`
Expected: PASS.

Then run the full suite: `swift test`. Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamMembershipEvents.swift Sources/Graftty/AddWorktreeFlow.swift Sources/Graftty/AppState.swift  # plus any removal-flow file you touched
git add Tests/GrafttyKitTests/Teams/TeamMembershipEventsTests.swift
git commit -m "feat(teams): fire team_member_joined/left on worktree changes (TEAM-5.2, TEAM-5.3)"
```

---

### Task 10: PR-merge integration — fire `team_pr_merged`

**Files:**
- Modify: `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`
- Test: `Tests/GrafttyKitTests/PRStatus/TeamPRMergedDispatchTests.swift` (new)

Hook into the existing `pr_state_changed` transition handler (per the channels-design.md `onTransition` callback). When a transition's destination is `.merged` and the worktree's repo currently has a team, additionally enqueue a `team_pr_merged` event addressed to the lead.

- [ ] **Step 1: Write failing test**

Write `Tests/GrafttyKitTests/PRStatus/TeamPRMergedDispatchTests.swift`. Mirror the existing `PRStatusStore` test style. The test simulates a state transition for a PR in a team-enabled repo and asserts that `team_pr_merged` was dispatched to the lead's worktree path with the correct attrs.

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("Team PR-merged dispatch")
struct TeamPRMergedDispatchTests {
    @Test func mergeFiresEventToLead() {
        // Build a stub repo (multi-worktree, team-enabled), trigger PR-state transition to .merged
        // for the coworker's worktree, and assert one dispatched event:
        //   - target path == repo.path (the lead's path)
        //   - type == "team_pr_merged"
        //   - attrs.member == the coworker's sanitized branch name
        //   - attrs.pr_number, branch, merge_sha set
    }

    @Test func mergeDoesNotFireIfTeamModeOff() {
        // Same setup, teamsEnabled=false → no team_pr_merged event dispatched.
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TeamPRMergedDispatchTests`
Expected: FAIL.

- [ ] **Step 3: Hook into `PRStatusStore`**

In `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`, find the existing transition dispatcher (the `onTransition` callback that the channels feature uses to dispatch `pr_state_changed`). Right next to where it dispatches `pr_state_changed`, add:

```swift
if newInfo.state == .merged,
   UserDefaults.standard.bool(forKey: "agentTeamsEnabled"),
   let repo = appStateProvider().repos.first(where: { $0.path == repoPath }),
   repo.worktrees.count >= 2,
   let merger = repo.worktrees.first(where: { $0.path == worktreePath })
{
    let event = TeamChannelEvents.prMerged(
        team: repo.displayName,
        member: WorktreeNameSanitizer.sanitize(merger.branch),
        prNumber: newInfo.number,
        branch: merger.branch,
        mergeSha: newInfo.mergeSha ?? ""
    )
    channelRouter.dispatch(worktreePath: repo.path, message: event)
}
```

Adjust property names to match the actual `PRInfo` shape (`mergeSha` may be `mergeCommitSha` or similar). Search the existing `PRInfo` definition for the field name.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TeamPRMergedDispatchTests`
Expected: PASS.

Then full suite: `swift test`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/PRStatus/PRStatusStore.swift Tests/GrafttyKitTests/PRStatus/TeamPRMergedDispatchTests.swift
git commit -m "feat(teams): fire team_pr_merged when team-enabled PR merges (TEAM-5.4)"
```

---

### Task 11: Sidebar team styling — accent stripe + Show Team Members popover

**Files:**
- Create: `Sources/Graftty/Sidebar/TeamRepoBadge.swift`
- Modify: `Sources/Graftty/Views/SidebarView.swift`

This task is presentation-only. Build a small `TeamRepoBadge` view that renders the team icon next to the repo's disclosure header, and wire an accent-stripe overlay on each team-enabled worktree row. Add the *Show Team Members…* context-menu item that opens a popover.

- [ ] **Step 1: Create `TeamRepoBadge.swift`**

```swift
import SwiftUI
import GrafttyKit

/// Small SF-symbol icon shown next to a team-enabled repo's disclosure header.
/// Implements TEAM-6.1.
struct TeamRepoBadge: View {
    let repoPath: String

    var body: some View {
        Image(systemName: "person.2.fill")
            .foregroundStyle(accentColor)
            .help("Agent team")
    }

    /// Deterministic accent color derived from the repo path.
    var accentColor: Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .indigo]
        let hash = repoPath.hashValue
        let idx = abs(hash) % palette.count
        return palette[idx]
    }
}
```

Note: `String.hashValue` isn't deterministic across launches. For real determinism use a stable hash:

```swift
var accentColor: Color {
    let bytes = Array(repoPath.utf8)
    var sum: UInt32 = 5381
    for b in bytes { sum = sum &* 33 &+ UInt32(b) }
    let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .yellow, .indigo]
    return palette[Int(sum) % palette.count]
}
```

Use the deterministic version.

- [ ] **Step 2: Modify `SidebarView.swift`**

In the repo header rendering (currently the `DisclosureGroup` label, lines ~80–88), conditionally insert `TeamRepoBadge(repoPath: repo.path)` when:

```swift
UserDefaults.standard.bool(forKey: "agentTeamsEnabled") && repo.worktrees.count >= 2
```

Read the `@AppStorage("agentTeamsEnabled")` directly in the view, mirroring how `ChannelsSettingsPane` reads its own `@AppStorage` flags.

For the accent stripe on each worktree row: add a `.overlay(alignment: .leading)` modifier on the worktree row view (the `WorktreeRow` Button at lines ~144–163) that draws a 3pt-wide rounded rect in the same color as the badge — only when the team conditions are met.

For the *Show Team Members…* context menu item: add inside `worktreeContextMenu(...)` (lines ~209–233):

```swift
if UserDefaults.standard.bool(forKey: "agentTeamsEnabled"),
   TeamView.team(for: worktree, in: appState.repos, teamsEnabled: true) != nil {
    Button("Show Team Members…") {
        // Set @State popover-binding to true; the popover content lists members.
    }
}
```

Implement the popover with a small inline `View` that displays each member's name, branch, role. The popover does **not** need its own dedicated file — keep it inside `SidebarView.swift` for v1.

- [ ] **Step 3: Verify the app builds**

Run: `swift build`
Expected: success.

- [ ] **Step 4: Manually verify in the Graftty app (cannot be unit-tested without a running app)**

Start Graftty, create a repo with two worktrees, enable Agent Teams in Settings. Verify:

- The team icon appears next to the repo header.
- An accent stripe shows on each worktree row.
- Right-clicking a worktree shows a *Show Team Members…* item.
- Clicking the item opens a popover listing the members.

Document this as a manual-test note since SwiftUI views with `@AppStorage` are awkward to unit-test cleanly.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Sidebar/TeamRepoBadge.swift Sources/Graftty/Views/SidebarView.swift
git commit -m "feat(teams): sidebar team styling + Show Team Members popover (TEAM-6.*)"
```

---

### Task 12: Lock the Default Command field + override launch line when team mode is on

**Files:**
- Modify: `Sources/Graftty/Views/SettingsView.swift` (UI lock — TEAM-1.3)
- Modify: `Sources/GrafttyKit/DefaultCommandDecision.swift` (runtime override — TEAM-1.4)
- Test: `Tests/GrafttyKitTests/DefaultCommandDecisionTests.swift` (extend with team-mode override tests)

Per TEAM-1.3 the Settings field becomes read-only. Per TEAM-1.4 the actual launched command is overridden — what the user has stored is ignored while team mode is on; Graftty types the canonical channel-aware line. Both pieces are needed: without the override, enabling team mode wouldn't change anything actually launched.

- [ ] **Step 1: Write failing tests for the launch-line override**

Append to `Tests/GrafttyKitTests/DefaultCommandDecisionTests.swift`:

```swift
func testTeamModeOverridesUserCommand() {
    let decision = defaultCommandDecision(
        defaultCommand: "zsh",                       // user's stored value
        firstPaneOnly: false,
        isFirstPane: true,
        wasRehydrated: false,
        agentTeamsEnabled: true                      // new parameter
    )
    XCTAssertEqual(
        decision,
        .type("claude --dangerously-load-development-channels server:graftty-channel")
    )
}

func testTeamModeOffPreservesUserCommand() {
    let decision = defaultCommandDecision(
        defaultCommand: "zsh",
        firstPaneOnly: false,
        isFirstPane: true,
        wasRehydrated: false,
        agentTeamsEnabled: false
    )
    XCTAssertEqual(decision, .type("zsh"))
}

func testTeamModeStillSkipsRehydratedPanes() {
    let decision = defaultCommandDecision(
        defaultCommand: "zsh",
        firstPaneOnly: false,
        isFirstPane: true,
        wasRehydrated: true,                         // already running under zmx
        agentTeamsEnabled: true
    )
    XCTAssertEqual(decision, .skip)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DefaultCommandDecisionTests`
Expected: FAIL — `defaultCommandDecision` doesn't accept `agentTeamsEnabled`.

- [ ] **Step 3: Add the override to `DefaultCommandDecision.swift`**

Open `Sources/GrafttyKit/DefaultCommandDecision.swift`. Extend the function signature:

```swift
public let teamModeManagedCommand =
    "claude --dangerously-load-development-channels server:graftty-channel"

public func defaultCommandDecision(
    defaultCommand: String,
    firstPaneOnly: Bool,
    isFirstPane: Bool,
    wasRehydrated: Bool,
    agentTeamsEnabled: Bool = false
) -> DefaultCommandDecision {
    if wasRehydrated { return .skip }
    if firstPaneOnly && !isFirstPane { return .skip }

    let resolved: String
    if agentTeamsEnabled {
        resolved = teamModeManagedCommand
    } else {
        let trimmed = defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .skip }
        resolved = trimmed
    }
    return .type(resolved)
}
```

The `agentTeamsEnabled` parameter has a default of `false` so existing call sites keep compiling without modification. Then update the single non-test call site in `Sources/Graftty/GrafttyApp.swift` (find with `grep -rn "defaultCommandDecision(" Sources/`) to read `UserDefaults.standard.bool(forKey: "agentTeamsEnabled")` and pass it as the new argument.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DefaultCommandDecisionTests`
Expected: PASS — including all pre-existing tests.

- [ ] **Step 5: Lock the Settings field**

Open `Sources/Graftty/Views/SettingsView.swift`. Find the Default Command `TextField` (`grep -n defaultCommand` in that file). Replace with a conditional:

```swift
@AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false
@AppStorage("defaultCommand")    private var defaultCommand: String = ""

// in the body, where the field currently lives:
if agentTeamsEnabled {
    HStack {
        Text(teamModeManagedCommand)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
    Text("Locked: Agent Teams manages this. Disable it in Settings → Agent Teams to edit your custom command.")
        .font(.caption)
        .foregroundStyle(.secondary)
} else {
    TextField("Default command", text: $defaultCommand)
}
```

Match the surrounding form-section styling. Use the `teamModeManagedCommand` constant exported from `DefaultCommandDecision.swift` so the displayed value and the launched value can never drift.

- [ ] **Step 6: Build the full project**

Run: `swift build`
Expected: success.

- [ ] **Step 7: Manually verify**

Start the app:

1. With Agent Teams off, set Default Command to `zsh`. Open a new pane → confirm `zsh` is typed.
2. Toggle Agent Teams on. Default Command field becomes read-only and shows the canonical line. Open a new pane → confirm `claude --dangerously-load-development-channels server:graftty-channel` is typed (regardless of the previously-stored `zsh`).
3. Toggle Agent Teams off. Default Command field is editable again, restored to `zsh`.

- [ ] **Step 8: Commit**

```bash
git add Sources/GrafttyKit/DefaultCommandDecision.swift Sources/Graftty/Views/SettingsView.swift Sources/Graftty/GrafttyApp.swift Tests/GrafttyKitTests/DefaultCommandDecisionTests.swift
git commit -m "feat(teams): lock + override Default Command while team mode is on (TEAM-1.3, TEAM-1.4)"
```

---

## Verification (after all tasks complete)

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: every test passes.

- [ ] **Step 2: Build the app bundle**

Run: `swift build`
Expected: success, no warnings.

- [ ] **Step 3: Manual end-to-end (cannot be automated)**

In the running Graftty app:

1. Enable **Agent Teams** in Settings; verify Channels turned on automatically.
2. Open a repo with at least two worktrees. Confirm the team icon appears beside the repo header in the sidebar.
3. Open a Claude pane in the lead worktree, another in a coworker. From the lead's pane run `graftty team list` — confirm both members are listed with `role=lead` / `role=coworker`.
4. From the lead pane run `graftty team msg <coworker-name> "test message"`. Switch to the coworker's pane; on its next turn the agent should see `<channel source="graftty-channel" type="team_message" from="<lead-name>">test message</channel>`.
5. Add a third worktree via the existing Add Worktree sheet. Verify a `team_member_joined` event arrives in the lead's session on its next turn.
6. Trigger a PR merge for the coworker's branch (or simulate by tweaking `PRStatusStore` state in a test build). Verify a `team_pr_merged` event arrives in the lead's session.

- [ ] **Step 4: `/simplify`**

After all tasks land, run `/simplify` per the project's standard finishing workflow.

- [ ] **Step 5: Open PR and confirm CI passes.**

```bash
gh pr create --title "feat: agent teams (TEAM-*)" --body "$(cat <<'EOF'
## Summary
Implements the Agent Teams feature per `docs/superpowers/specs/2026-04-26-agent-teams-design.md` and the new SPECS.md `TEAM-*` requirements.

- Settings toggle (auto-enables Channels, locks Default Command)
- TeamView derives team state from RepoEntry+WorktreeEntry
- Per-worktree team-aware MCP instructions (lead / coworker variants) on subscribe
- Four `team_*` channel events: `team_message`, `team_member_joined`, `team_member_left`, `team_pr_merged`
- `graftty team msg` and `graftty team list` CLI subcommands
- Sidebar accent + Show Team Members popover for team-enabled repos

## Test plan
- [x] `swift test` passes
- [x] Manual end-to-end verified per plan §Verification
- [ ] CI green
EOF
)"
```

Confirm CI green before reporting work complete.
