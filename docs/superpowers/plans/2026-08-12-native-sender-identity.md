# Native Claude Sender Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native Claude peer deliveries identify their sender (`graftty/main#codex-96cd535bedd7`, `GitHub`, or `Graftty team`) instead of a constant label, and send plain bodies without the `<graftty-peer-message>` envelope.

**Architecture:** A pure name-derivation function reads fields already persisted on each inbox row (`team`, `from.member`, `from.agentID`, plus a new optional `source` stamped by the event dispatcher). `ClaudePeerDeliveryService` trims each frame to the leading run of rows sharing one derived name and sends unwrapped bodies; the envelope formatter stays for hook and Codex delivery. Spec: `docs/superpowers/specs/2026-08-12-native-sender-identity-design.md`.

**Tech Stack:** Swift 6, Swift Testing (`@Suite`/`@Test` with `@spec` EARS titles), `scripts/swiftpm` build wrapper, `scripts/generate-specs.py`.

## Global Constraints

- All SwiftPM commands go through `scripts/swiftpm` (never bare `swift test`, never `--skip-build`). Waiting on the shared build lock is expected.
- Every behavior change updates its `@spec` EARS text; a spec ID appears in at most one behavioral location.
- No literal `\"` escapes inside `@spec` test titles (silently truncates SPECS.md) — use `'…'` or backticks in titles instead.
- Run `scripts/generate-specs.py` and commit the regenerated `SPECS.md` alongside code (final task).
- TDD: write the failing test, watch it fail, implement, watch it pass, commit.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Persist SCM source on inbox rows (AGENT-6.20)

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInbox.swift` (TeamInboxMessage struct ~line 48; `appendMessage` ~line 194)
- Modify: `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift` (`dispatchRoutableEvent`'s `appendMessage` call, ~line 151)
- Test: `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift`

**Interfaces:**
- Produces: `TeamInboxMessage.source: String?` (Codable key `"source"`), `TeamInbox.appendMessage(..., source: String? = nil)`. Task 2 reads `message.source`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift`, inside the existing suite (model it on the `pr_state_changed` test at ~line 55, which builds `repo`, `inbox`, `prefs`, `dispatcher` — copy that arrangement):

```swift
@Test("""
@spec AGENT-6.20: When the dispatcher writes a routable-event system row that carries a provider attribute, the application shall persist that provider on the inbox row as its source.
""")
func routableEventPersistsProviderSource() throws {
    let root = try Self.temporaryDirectory()
    let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
    let inbox = TeamInbox(rootDirectory: root)
    let prefs = TeamEventRoutingPreferences(
        prStateChanged: [.worktree],
        prMerged: [],
        ciConclusionChanged: [],
        mergabilityChanged: []
    )
    let dispatcher = TeamEventDispatcher(
        inbox: inbox,
        preferencesProvider: { prefs },
        templateProvider: { "" }
    )
    let event = ChannelServerMessage.event(
        type: TeamChannelEvents.WireType.prStateChanged,
        attrs: ["worktree": "/repo/.worktrees/alice", "to": "open", "from": "draft", "pr_number": "42", "pr_url": "https://x", "provider": "github", "repo": "x/y"],
        body: "PR #42 state changed: draft → open"
    )

    try dispatcher.dispatchRoutableEvent(
        event,
        subjectWorktreePath: "/repo/.worktrees/alice",
        repos: [repo]
    )

    let messages = try inbox.messages(teamID: TeamLookup.id(forRepoPath: "/repo"))
    #expect(!messages.isEmpty)
    #expect(messages.allSatisfy { $0.source == "github" })
}
```

Note: check the suite's existing helpers first — if the `prefs` initializer arguments differ (e.g. no `mergabilityChanged` label), copy the exact argument list from the neighboring test.

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swiftpm test --filter TeamEventDispatcherTests`
Expected: COMPILE FAILURE — `value of type 'TeamInboxMessage' has no member 'source'`.

- [ ] **Step 3: Implement**

In `Sources/GrafttyKit/Teams/TeamInbox.swift`, inside `TeamInboxMessage`:

Add the stored property after `agentPrompt`:

```swift
    /// @spec AGENT-6.20
    /// When the dispatcher writes a routable-event system row that carries a
    /// provider attribute, the application shall persist that provider on the
    /// inbox row as its source.
    ///
    /// `"github"` / `"gitlab"` for forge-originated system rows; nil for
    /// authored messages and non-forge system rows. Optional and additive:
    /// rows written before this field decode with nil.
    public let source: String?
```

Add `case source` to `CodingKeys`, add `source: String? = nil` as the last parameter of `TeamInboxMessage.init`, and assign `self.source = source`.

In `appendMessage` (same file), add the parameter `source: String? = nil` after `agentPrompt` and pass `source: source` in the `TeamInboxMessage(...)` construction. Leave `appendBroadcast` alone (authored broadcasts have no source).

In `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`, in `dispatchRoutableEvent`'s `inbox.appendMessage(...)` call (the one with `kind: type`), add:

```swift
                agentPrompt: rendered.agentPrompt,
                source: attrs["provider"]
```

Do NOT touch the membership/member-left `appendMessage` calls — those events carry no provider.

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/swiftpm test --filter TeamEventDispatcherTests`
Expected: PASS (all tests in the suite, including pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInbox.swift Sources/GrafttyKit/Teams/TeamEventDispatcher.swift Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift
git commit -m "feat: persist SCM provider as inbox row source (AGENT-6.20)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Sender-name derivation (AGENT-6.18)

**Files:**
- Modify: `Sources/GrafttyKit/Teams/ClaudePeerDeliveryService.swift` (add a new public enum near `TeamPeerMessageFormatter` at the bottom)
- Create: `Tests/GrafttyKitTests/Teams/ClaudePeerSenderNameTests.swift`

**Interfaces:**
- Consumes: `TeamInboxMessage.source` from Task 1.
- Produces: `ClaudePeerSenderName.name(for message: TeamInboxMessage) -> String`. Task 3 calls it.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyKitTests/Teams/ClaudePeerSenderNameTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
    @spec AGENT-6.18: When the application delivers inbox rows through Claude's native peer socket, it shall identify the sender as `<team>/<worktree-member>#<agent-id>` for agent-authored rows (omitting the `#` suffix when no agent ID was persisted), as the originating SCM's display name for system rows with a persisted source, and as `Graftty team` for other system rows.
""")
struct ClaudePeerSenderNameTests {
    @Test func agentRowUsesTeamMemberAndAgentID() {
        let name = ClaudePeerSenderName.name(for: message(
            from: TeamInboxEndpoint(
                member: "main",
                worktree: "/repo",
                runtime: "codex",
                agentID: "codex-0123456789ab"
            )
        ))
        #expect(name == "repo/main#codex-0123456789ab")
    }

    @Test func agentRowWithoutAgentIDOmitsSuffix() {
        let name = ClaudePeerSenderName.name(for: message(
            from: TeamInboxEndpoint(member: "alice", worktree: "/repo/alice", runtime: nil)
        ))
        #expect(name == "repo/alice")
    }

    @Test func githubSystemRowUsesForgeDisplayName() {
        let name = ClaudePeerSenderName.name(for: message(
            from: .system(repoPath: "/repo"),
            source: "github"
        ))
        #expect(name == "GitHub")
    }

    @Test func gitlabSystemRowUsesForgeDisplayName() {
        let name = ClaudePeerSenderName.name(for: message(
            from: .system(repoPath: "/repo"),
            source: "gitlab"
        ))
        #expect(name == "GitLab")
    }

    @Test func unknownSourceIsCapitalized() {
        let name = ClaudePeerSenderName.name(for: message(
            from: .system(repoPath: "/repo"),
            source: "sourcehut"
        ))
        #expect(name == "Sourcehut")
    }

    @Test func sourcelessSystemRowStaysGrafttyTeam() {
        let name = ClaudePeerSenderName.name(for: message(
            from: .system(repoPath: "/repo")
        ))
        #expect(name == "Graftty team")
    }

    private func message(
        from: TeamInboxEndpoint,
        source: String? = nil
    ) -> TeamInboxMessage {
        TeamInboxMessage(
            id: "m1",
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800),
            team: "repo",
            repoPath: "/repo",
            from: from,
            to: TeamInboxEndpoint(
                member: "recipient",
                worktree: "/repo/recipient",
                runtime: "claude",
                agentID: "claude-abcdef012345"
            ),
            priority: .normal,
            body: "hello",
            source: source
        )
    }
}
```

Note: `TeamInboxMessage.init` from Task 1 has `source` as the last parameter (after `agentPrompt`); the call above relies on `agentPrompt` having a default. If the compiler complains about argument order, match the init's declared order exactly.

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/swiftpm test --filter ClaudePeerSenderNameTests`
Expected: COMPILE FAILURE — `cannot find 'ClaudePeerSenderName' in scope`.

- [ ] **Step 3: Implement**

In `Sources/GrafttyKit/Teams/ClaudePeerDeliveryService.swift`, add above `TeamPeerMessageFormatter`:

```swift
/// Derives the native cross-session sender label for one inbox row.
/// Agent rows: `<team>/<worktree-member>#<agent-id>`; the suffix minus the
/// team prefix is a routable `graftty team send` address. System rows: the
/// originating SCM's display name when a source was persisted, else the
/// generic team label.
public enum ClaudePeerSenderName {
    public static func name(for message: TeamInboxMessage) -> String {
        guard message.from.member != "system" else {
            guard let source = message.source, !source.isEmpty else {
                return "Graftty team"
            }
            switch source {
            case "github": return "GitHub"
            case "gitlab": return "GitLab"
            default: return source.prefix(1).uppercased() + source.dropFirst()
            }
        }
        let base = "\(message.team)/\(message.from.member)"
        guard let agentID = message.from.agentID else { return base }
        return "\(base)#\(agentID)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swiftpm test --filter ClaudePeerSenderNameTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/ClaudePeerDeliveryService.swift Tests/GrafttyKitTests/Teams/ClaudePeerSenderNameTests.swift
git commit -m "feat: derive native sender name from inbox row identity (AGENT-6.18)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Plain same-sender frames in native delivery (AGENT-6.19; amend AGENT-6.6, AGENT-6.17)

**Files:**
- Modify: `Sources/GrafttyKit/Teams/ClaudePeerDeliveryService.swift` (`deliverOnce`, ~lines 99–123)
- Modify: `Tests/GrafttyKitTests/Teams/ClaudePeerDeliveryServiceTests.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamPeerMessageEnvelopeTests.swift` (suite title only)

**Interfaces:**
- Consumes: `ClaudePeerSenderName.name(for:)` from Task 2.
- Produces: native frames whose body is `TeamHookRenderer.content(message:)` values joined by `"\n\n"`, one derived sender name per frame. No API changes.

- [ ] **Step 1: Update the fixture for multi-message tests**

In `Tests/GrafttyKitTests/Teams/ClaudePeerDeliveryServiceTests.swift`, the fixture's `idGenerator` always returns `"message-1"`, which breaks multi-row tests. Replace the `TeamInbox` construction in `Fixture.init`:

```swift
            let counter = IDCounter()
            let inbox = TeamInbox(rootDirectory: root, idGenerator: { counter.next() })
```

and add inside the test struct (next to `StubError`):

```swift
    private final class IDCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> String {
            lock.lock()
            defer { lock.unlock() }
            n += 1
            return "message-\(n)"
        }
    }
```

Also extend `Fixture.append` to accept a sender and source (defaults preserve existing call sites):

```swift
        func append(
            body: String,
            exact: Bool = true,
            from: TeamInboxEndpoint? = nil,
            source: String? = nil
        ) throws -> TeamInboxMessage {
            try inbox.appendMessage(
                teamID: teamID,
                teamName: "repo",
                repoPath: teamID,
                from: from ?? TeamInboxEndpoint(member: "main", worktree: teamID, runtime: nil),
                to: TeamInboxEndpoint(
                    member: "feature",
                    worktree: worktree,
                    runtime: "claude",
                    agentID: exact ? agentID : nil
                ),
                priority: .normal,
                body: body,
                source: source
            )
        }
```

- [ ] **Step 2: Write the failing tests**

In the same file:

(a) Amend the AGENT-6.6 test. Update its `@spec` title to the new EARS text and flip the envelope expectations:

```swift
    @Test("""
    @spec AGENT-6.6: When an inbox row is bound to a reachable protocol-v1 Claude agent, the application shall send the leading same-sender run of the pending exact-agent prefix through Claude's native peer socket and advance the shared worktree watermark only after the socket accepts the full frame; on discovery or transport failure, the row shall remain unread for wrapper fallback or retry.
    """)
    func exactAgentDeliveryAdvancesOnlyAfterAcceptance() async throws {
```

and replace the two body assertions at lines ~22–24 with:

```swift
        #expect(calls[0].body == "please review")
        #expect(!calls[0].body.contains("<graftty-peer-message"))
        #expect(calls[0].senderName == "repo/main")
```

(b) Add the AGENT-6.19 test:

```swift
    @Test("""
    @spec AGENT-6.19: When pending deliverable rows are sent through Claude's native peer socket, the application shall send only the leading run of rows sharing one derived sender name per frame, with bodies joined by a blank line and no per-message envelope, leaving later runs for subsequent frames.
    """)
    func mixedSendersSplitIntoPerSenderFrames() async throws {
        let fixture = try Fixture()
        let codexSender = TeamInboxEndpoint(
            member: "main",
            worktree: fixture.teamID,
            runtime: "codex",
            agentID: "codex-0123456789ab"
        )
        _ = try fixture.append(body: "first", from: codexSender)
        _ = try fixture.append(body: "second", from: codexSender)
        _ = try fixture.append(body: "PR #42 opened", from: .system(repoPath: fixture.teamID), source: "github")
        let last = try fixture.append(body: "roster changed", from: .system(repoPath: fixture.teamID))

        await fixture.service.onMessageArrival(
            team: fixture.teamID,
            worktree: fixture.worktree
        )

        let calls = await fixture.client.calls
        #expect(calls.count == 3)
        #expect(calls[0].body == "first\n\nsecond")
        #expect(calls[0].senderName == "repo/main#codex-0123456789ab")
        #expect(calls[1].body == "PR #42 opened")
        #expect(calls[1].senderName == "GitHub")
        #expect(calls[2].body == "roster changed")
        #expect(calls[2].senderName == "Graftty team")
        #expect(calls.allSatisfy { !$0.body.contains("<graftty-peer-message") })
        #expect(try fixture.inbox.worktreeWatermark(
            teamID: fixture.teamID,
            worktree: fixture.worktree
        )?.lastDeliveredToAnySessionID == last.id)
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `scripts/swiftpm test --filter ClaudePeerDeliveryServiceTests`
Expected: FAIL — the amended AGENT-6.6 test fails on `body == "please review"` (body still wrapped) and `senderName == "repo/main"` (still `"Graftty team"`); the new test fails on `calls.count == 3` (single wrapped frame today).

- [ ] **Step 4: Implement**

In `Sources/GrafttyKit/Teams/ClaudePeerDeliveryService.swift`, `deliverOnce`, after the `guard !pending.isEmpty else { return false }`:

```swift
        // One frame carries one native sender identity, so a frame may only
        // contain the leading run of rows that share a derived name; the
        // arrival loop redelivers, sending later runs in follow-up frames.
        let senderName = ClaudePeerSenderName.name(for: pending[0])
        let run = Array(pending.prefix(while: {
            ClaudePeerSenderName.name(for: $0) == senderName
        }))
```

Then in the send loop replace `var batch = pending` with `var batch = run`, and replace the `client.send` call's arguments:

```swift
                    _ = try await client.send(
                        body: batch.map { TeamHookRenderer.content(message: $0) }
                            .joined(separator: "\n\n"),
                        socketPath: socketPath,
                        replySocketPath: nil,
                        senderName: senderName
                    )
```

In the `catch` branch's `log(...)` call, change `messageIDs: pending.map(\.id)` to `messageIDs: run.map(\.id)` — the frame now only ever attempts the leading run, so the failure log should list the run's rows, not the whole prefix.

`TeamPeerMessageFormatter` and its import sites stay untouched (hook + Codex paths).

- [ ] **Step 5: Run tests to verify they pass**

Run: `scripts/swiftpm test --filter ClaudePeerDeliveryServiceTests`
Expected: PASS (all suite tests, including transport-failure and runtime-default tests).

- [ ] **Step 6: Amend AGENT-6.17's EARS text**

In `Tests/GrafttyKitTests/Teams/TeamPeerMessageEnvelopeTests.swift`, replace the `@Suite` title with:

```swift
@Suite("""
    @spec AGENT-6.17: When an agent sends a team message to `<canonical-worktree-path>#<agent-id>`, the application shall bind the inbox row to that exact reachable recipient, accept an XML-escaped envelope address unchanged as a reply target, persist the caller's canonical agent identity when available, and render every wrapper-path delivered row (hook and Codex app-server delivery) as one `<graftty-peer-message agent="<canonical-sender-address>">` element without a trust preamble.
""")
```

No test bodies change — they exercise `TeamPeerMessageFormatter` directly, which still backs the wrapper paths.

Run: `scripts/swiftpm test --filter TeamPeerMessageEnvelopeTests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Teams/ClaudePeerDeliveryService.swift Tests/GrafttyKitTests/Teams/ClaudePeerDeliveryServiceTests.swift Tests/GrafttyKitTests/Teams/TeamPeerMessageEnvelopeTests.swift
git commit -m "feat: send plain same-sender frames over Claude peer socket (AGENT-6.19)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Reply-guidance docs and plugin revision

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift` (~line 49)
- Modify: `Sources/GrafttyKit/AgentPlugins/claude/plugins/graftty-team/skills/graftty-team/SKILL.md` (~line 36)
- Modify: `Sources/GrafttyKit/Teams/AgentPluginInstaller.swift` (`integrationRevision`, line 96)
- Test: `Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift` (~line 172)

**Interfaces:**
- Consumes: naming scheme from Task 2 (documentation only; no code interfaces).

- [ ] **Step 1: Write the failing test change**

In `Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift` (~line 172), replace:

```swift
            #expect(prompt.contains("<graftty-peer-message agent=\"<address>\">"))
```

with:

```swift
            #expect(prompt.contains("<graftty-peer-message agent=\"<address>\">"))
            #expect(prompt.contains("<project>/<worktree>#<agent-id>"))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/swiftpm test --filter TeamInstructionsRendererTests`
Expected: FAIL on the new `<project>/<worktree>#<agent-id>` expectation.

- [ ] **Step 3: Implement**

In `Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift` (~line 49), replace the line:

```
    - Incoming messages use `<graftty-peer-message agent="<address>">`. Reply by passing that `agent` value unchanged to `graftty team send --stdin <address>`.
```

with:

```
    - Hook-delivered messages use `<graftty-peer-message agent="<address>">`. Reply by passing that `agent` value unchanged to `graftty team send --stdin <address>`.
    - Natively delivered messages name the sender `<project>/<worktree>#<agent-id>` instead of a wrapper. Reply to `<worktree>#<agent-id>` (drop the `<project>/` prefix), or copy the exact canonical address from `graftty team list --json`. Senders named for an SCM (e.g. GitHub) or `Graftty team` are automated notices with no reply target.
```

In `Sources/GrafttyKit/AgentPlugins/claude/plugins/graftty-team/skills/graftty-team/SKILL.md` (~line 36), replace:

```
Incoming messages use `<graftty-peer-message agent="<address>">`. Pass that `agent` value unchanged to `graftty team send --stdin` when replying, unless the task clearly belongs elsewhere.
```

with:

```
Hook-delivered messages use `<graftty-peer-message agent="<address>">`. Pass that `agent` value unchanged to `graftty team send --stdin` when replying, unless the task clearly belongs elsewhere.

Natively delivered messages name the sender `<project>/<worktree>#<agent-id>` instead of a wrapper. Reply to `<worktree>#<agent-id>` (drop the `<project>/` prefix), or copy the exact canonical address from `graftty team list --json`. Senders named for an SCM (e.g. GitHub) or `Graftty team` are automated notices with no reply target.
```

In `Sources/GrafttyKit/Teams/AgentPluginInstaller.swift` line 96, bump:

```swift
    public static let integrationRevision = 4
```

Then run `grep -rn "integrationRevision\|revision" Tests/GrafttyKitTests/Teams/AgentPluginInstallerTests.swift` — if any test pins the literal revision value or hashes plugin content, update it to match and note it in the report.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/swiftpm test --filter "TeamInstructionsRendererTests|AgentPluginInstallerTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInstructionsRenderer.swift Sources/GrafttyKit/AgentPlugins/claude/plugins/graftty-team/skills/graftty-team/SKILL.md Sources/GrafttyKit/Teams/AgentPluginInstaller.swift Tests/GrafttyKitTests/Teams/TeamInstructionsRendererTests.swift
git commit -m "docs: cover native sender naming in reply guidance; bump plugin revision

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(Include `Tests/GrafttyKitTests/Teams/AgentPluginInstallerTests.swift` in the `git add` if Step 3's grep required updating it.)

---

### Task 5: Full test run and SPECS.md regeneration

**Files:**
- Modify: `SPECS.md` (generated — never edit by hand)

**Interfaces:**
- Consumes: all `@spec` changes from Tasks 1–4.

- [ ] **Step 1: Run the full test suite**

Run: `scripts/swiftpm test`
Expected: PASS. Known environment flake: WEB-5.6 reconnect test can fail on a clean tree; if the only failure is unrelated to Teams/ClaudePeer code, rerun once and report it as pre-existing.

- [ ] **Step 2: Regenerate SPECS.md**

Run: `scripts/generate-specs.py`
Expected: exits 0; `git diff --stat SPECS.md` shows AGENT-6.6/6.17 text updates and new AGENT-6.18/6.19/6.20 entries. The script fails if a spec ID appears twice — that means a Task 1–4 spec title collided; fix the duplicate, don't renumber existing IDs.

- [ ] **Step 3: Commit**

```bash
git add SPECS.md
git commit -m "docs: regenerate SPECS.md for AGENT-6.18–6.20

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
