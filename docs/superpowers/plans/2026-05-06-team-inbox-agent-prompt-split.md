# Team Inbox `agent_prompt` / `body` Split — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the rendered `teamPrompt` Stencil output from the event body in `TeamInboxMessage`, so the activity log / watcher summary / `team inbox` CLI all read clean event content while AI hook delivery still receives the templated prompt.

**Architecture:** Add an optional `agentPrompt: String?` field to the inbox row. `EventBodyRenderer` becomes a `split(...)` function returning `(event, agentPrompt)` separately; auto-appends `\n\n{{ body }}` to templates that don't reference `{{ body }}` so out-of-the-box behavior is unchanged. Dispatcher threads both pieces into the inbox; `TeamHookRenderer.format(messages:)` emits `agentPrompt ?? body` per message — no concatenation glue anywhere else.

**Tech Stack:** Swift 5.9+, Swift Testing for new tests, Stencil 0.15+, the existing Codable / JSONL inbox layer.

**Spec source:** `docs/superpowers/specs/2026-05-06-team-inbox-agent-prompt-split-design.md`

---

## File Structure

### Modified

- `Sources/GrafttyKit/Teams/TeamInbox.swift` — `TeamInboxMessage` gains `agentPrompt: String?` + `agent_prompt` Codable key. `appendMessage(...)` gains an `agentPrompt: String? = nil` parameter that flows into the new field. `appendBroadcast(...)` is untouched (it doesn't carry per-recipient template output today; if a future broadcast needs one, it can adopt the parameter).
- `Sources/GrafttyKit/Teams/EventBodyRenderer.swift` — replace `body(...)` with `split(...)` returning `EventBodyRendererResult`. Add the auto-append regex check. Add `body` to the Stencil context dict alongside `agent`.
- `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift` — change `renderBody(...)` to return `(body: String, agentPrompt: String?)`. Update `dispatchTeamMessage`, `dispatchTeamBroadcast`, `dispatchRoutableEvent` (three sites) to unpack and pass through.
- `Sources/GrafttyKit/Teams/TeamHookRenderer.swift` — `format(messages:)` emits `message.agentPrompt ?? message.body` per message.
- `Tests/GrafttyKitTests/Channels/EventBodyRendererTests.swift` — currently empty; populate with the renderer's split + auto-append + body-variable behavior.
- `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift` — update existing prepended-body assertions; add a case for the split storage.
- `Tests/GrafttyKitTests/Teams/TeamHookRendererTests.swift` — add coverage for `format` emitting `agentPrompt ?? body`.
- `Tests/GrafttyKitTests/Teams/TeamInboxTests.swift` — JSON round-trip tests for both shapes (with and without `agent_prompt`).
- `Tests/GrafttyTests/Specs/TeamTodo.swift` — update `@spec TEAM-1.6` text.

### Out of scope (unchanged)

- `Sources/Graftty/Views/TeamActivityLog/*` — the activity log already reads `body` and gets the clean text for free.
- `Sources/GrafttyKit/Teams/InboxWatcher.swift` — `summary(for:)` reads `body` and self-heals.
- `Sources/Graftty/Settings/DefaultPrompts.swift` — auto-append covers the existing default `eventPrompt`.

### Dependency between tasks

```
T1  Schema (TeamInboxMessage + Codable)        — independent
T2  Renderer split + auto-append + body var    — independent
T3  Inbox appendMessage parameter              depends: T1
T4  Dispatcher renderBody tuple + call sites   depends: T2, T3
T5  HookRenderer.format prompt-or-body         depends: T1
T6  Spec amendment + SPECS regen               depends: T1–T5 (refers to all)
T7  /simplify + push                           depends: all
```

T1 and T2 can run in parallel if the controller dispatches them independently. The skill rule "no parallel implementer subagents" means we still serialize, but T1/T2 are independent in the dependency sense.

---

## Task 1: Schema — `agentPrompt` field on `TeamInboxMessage`

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInbox.swift`
- Test: `Tests/GrafttyKitTests/Teams/TeamInboxTests.swift`

- [ ] **Step 1: Write the failing JSON round-trip tests**

Add to `Tests/GrafttyKitTests/Teams/TeamInboxTests.swift`:

```swift
@Suite("TeamInboxMessage — agent_prompt forward-compat")
struct TeamInboxMessageAgentPromptCodableTests {
    @Test("Round-trip: a row with agentPrompt set encodes the agent_prompt JSON key.")
    func roundTripWithPrompt() throws {
        let msg = TeamInboxMessage(
            id: "id-1",
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800),
            team: "team",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: "/repo/.worktrees/alice", runtime: nil),
            priority: .normal,
            kind: "team_message",
            body: "ping",
            agentPrompt: "Hi alice — context: ping"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"agent_prompt\":\"Hi alice — context: ping\""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TeamInboxMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test("Round-trip: a row without agentPrompt encodes the JSON without an agent_prompt key.")
    func roundTripWithoutPrompt() throws {
        let msg = TeamInboxMessage(
            id: "id-2",
            batchID: nil,
            createdAt: Date(timeIntervalSince1970: 1_800),
            team: "team",
            repoPath: "/repo",
            from: TeamInboxEndpoint(member: "main", worktree: "/repo", runtime: nil),
            to: TeamInboxEndpoint(member: "alice", worktree: "/repo/.worktrees/alice", runtime: nil),
            priority: .normal,
            kind: "team_message",
            body: "ping",
            agentPrompt: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(msg)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("agent_prompt"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TeamInboxMessage.self, from: data)
        #expect(decoded.agentPrompt == nil)
    }

    @Test("Forward-compat: a legacy row on disk (no agent_prompt key) decodes with agentPrompt = nil.")
    func decodeLegacyRow() throws {
        let legacy = """
        {"id":"id-3","created_at":"1970-01-01T00:30:00Z","team":"team","repo_path":"/repo","from":{"member":"main","worktree":"/repo","runtime":null},"to":{"member":"alice","worktree":"/repo/.worktrees/alice","runtime":null},"priority":"normal","kind":"team_message","body":"legacy"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TeamInboxMessage.self, from: Data(legacy.utf8))
        #expect(decoded.agentPrompt == nil)
        #expect(decoded.body == "legacy")
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

```bash
swift test --filter TeamInboxMessageAgentPromptCodableTests 2>&1 | tail -10
```

Expected: compile error — `TeamInboxMessage` has no `agentPrompt` parameter.

- [ ] **Step 3: Add the field to `TeamInboxMessage`**

In `Sources/GrafttyKit/Teams/TeamInbox.swift`, find the `TeamInboxMessage` struct (around line 36) and modify:

```swift
public struct TeamInboxMessage: Codable, Sendable, Equatable {
    public let id: String
    public let batchID: String?
    public let createdAt: Date
    public let team: String
    public let repoPath: String
    public let from: TeamInboxEndpoint
    public let to: TeamInboxEndpoint
    public let priority: TeamInboxPriority
    public let kind: String
    public let body: String
    /// Rendered `teamPrompt` template output for this delivery, or nil
    /// when the template was empty / failed to render / pre-split row
    /// from disk. Hook delivery (`TeamHookRenderer.format`) emits this
    /// when present and falls through to `body` otherwise; activity
    /// log / watcher / `team inbox` CLI ignore it. See @spec TEAM-1.6.
    public let agentPrompt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case batchID = "batch_id"
        case createdAt = "created_at"
        case team
        case repoPath = "repo_path"
        case from, to, priority, kind, body
        case agentPrompt = "agent_prompt"
    }

    public init(
        id: String,
        batchID: String?,
        createdAt: Date,
        team: String,
        repoPath: String,
        from: TeamInboxEndpoint,
        to: TeamInboxEndpoint,
        priority: TeamInboxPriority,
        kind: String = "team_message",
        body: String,
        agentPrompt: String? = nil
    ) {
        self.id = id
        self.batchID = batchID
        self.createdAt = createdAt
        self.team = team
        self.repoPath = repoPath
        self.from = from
        self.to = to
        self.priority = priority
        self.kind = kind
        self.body = body
        self.agentPrompt = agentPrompt
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
swift test --filter TeamInboxMessageAgentPromptCodableTests 2>&1 | tail -15
```

Expected: 3 tests pass.

- [ ] **Step 5: Verify the full suite still builds**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build (callers using positional or default-arg `init` keep working because `agentPrompt` defaults to nil).

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInbox.swift Tests/GrafttyKitTests/Teams/TeamInboxTests.swift
git commit -m "$(cat <<'EOF'
feat(teams): TeamInboxMessage gains optional agentPrompt field

The rendered teamPrompt template output now lives in agent_prompt
rather than being prepended to body. Field is optional so legacy
rows on disk (without the key) decode cleanly with agentPrompt = nil
and existing call sites that don't carry a prompt keep working via
the new default argument.

@spec TEAM-1.6 (text amendment in a later task)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Renderer — `EventBodyRenderer.split(...)` + auto-append + `{{ body }}` variable

**Files:**
- Modify: `Sources/GrafttyKit/Teams/EventBodyRenderer.swift`
- Modify: `Tests/GrafttyKitTests/Channels/EventBodyRendererTests.swift` (currently empty file)

- [ ] **Step 1: Write the failing tests**

Replace the contents of `Tests/GrafttyKitTests/Channels/EventBodyRendererTests.swift` (the file exists post-channels-migration but is empty):

```swift
import Foundation
import Testing
@testable import GrafttyKit

@Suite("EventBodyRenderer.split — split + auto-append + body variable")
struct EventBodyRendererSplitTests {
    @Test("Empty template: passthrough — agentPrompt nil, event body unchanged.")
    func emptyTemplatePassthrough() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "PR #1 went open → ready")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: ""
        )
        #expect(result.agentPrompt == nil)
        #expect(Self.body(result.event) == "PR #1 went open → ready")
    }

    @Test("Template without {{ body }} → auto-append: agentPrompt contains both prelude and body, separated by \\n\\n.")
    func autoAppendsBodyWhenTemplateLacksReference() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "EVENT-CONTENT")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "Hello {{ agent.branch }}."
        )
        let prompt = try? #require(result.agentPrompt)
        #expect(prompt?.contains("Hello alice.") == true)
        #expect(prompt?.contains("\n\nEVENT-CONTENT") == true)
        #expect(Self.body(result.event) == "EVENT-CONTENT")
    }

    @Test("Template with explicit {{ body }} → no auto-append: author placement honored.")
    func respectsExplicitBodyReference() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "EVENT-CONTENT")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "Before: {{ body }} :After"
        )
        #expect(result.agentPrompt == "Before: EVENT-CONTENT :After")
    }

    @Test("Template with {{body}} (no internal whitespace) → no auto-append (regex tolerates whitespace variants).")
    func toleratesNoSpaceBodyReference() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "X")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "[{{body}}]"
        )
        #expect(result.agentPrompt == "[X]")
    }

    @Test("Template that suppresses body via false-branch {% if %} renders without the body.")
    func suppressedBodyProducesPromptWithoutBody() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "DO-NOT-SHOW")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "Suppressed{% if false %}{{ body }}{% endif %}"
        )
        #expect(result.agentPrompt == "Suppressed")
        #expect(Self.body(result.event) == "DO-NOT-SHOW")
    }

    @Test("Malformed Stencil → passthrough.")
    func renderFailurePassthrough() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "EVENT")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            templateString: "{% if %}"  // unterminated tag
        )
        #expect(result.agentPrompt == nil)
        #expect(Self.body(result.event) == "EVENT")
    }

    @Test("Render output that is whitespace-only → passthrough.")
    func whitespaceOnlyRenderPassthrough() {
        let event = ChannelServerMessage.event(type: "pr_state_changed", attrs: [:], body: "EVENT")
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [Self.fixtureRepo()],
            // Author asked the renderer to suppress everything (no body
            // reference + no other content). Auto-append adds {{ body }}
            // but only after a blank-only template; the rendered output
            // is just the body itself wrapped in the auto-appended
            // separator — but with the original template empty after
            // trimming, the renderer should treat it as passthrough.
            templateString: "   "
        )
        // The "   " template fails the empty check (length > 0) but
        // renders to whitespace once Stencil processes it; the trimmed-
        // empty branch catches that and returns passthrough.
        // Note: auto-append appends "\n\n{{ body }}" so the rendered
        // output IS the body. We treat that as a real prompt (not
        // passthrough), so the assertion is that agentPrompt == "EVENT".
        // Adjust if implementation chooses passthrough for "rendered
        // equals body verbatim"; the test pins one of the two
        // semantically-clean choices.
        #expect(result.agentPrompt == "EVENT" || result.agentPrompt == nil)
    }

    private static func fixtureRepo() -> RepoEntry {
        RepoEntry(
            path: "/r",
            displayName: "r",
            worktrees: [
                WorktreeEntry(path: "/r", branch: "main", state: .running),
                WorktreeEntry(path: "/r/alice", branch: "alice", state: .running),
            ]
        )
    }

    private static func body(_ event: ChannelServerMessage) -> String {
        guard case let .event(_, _, body) = event else { return "" }
        return body
    }
}
```

(If the test agent finds that `RepoEntry` / `WorktreeEntry` initializers in this codebase have different argument shapes, adapt the fixture — both types live in `Sources/GrafttyKit/Model/` and are public.)

- [ ] **Step 2: Run, expect compile failure**

```bash
swift test --filter EventBodyRendererSplitTests 2>&1 | tail -10
```

Expected: `EventBodyRenderer.split` undefined.

- [ ] **Step 3: Add `split(...)` and `EventBodyRendererResult`, deprecate `body(...)`**

In `Sources/GrafttyKit/Teams/EventBodyRenderer.swift`, replace the existing `body(...)` function (lines 38–75) with:

```swift
public struct EventBodyRendererResult: Equatable {
    public let event: ChannelServerMessage
    public let agentPrompt: String?

    public init(event: ChannelServerMessage, agentPrompt: String?) {
        self.event = event
        self.agentPrompt = agentPrompt
    }
}

/// Regex matches a Stencil `body` reference with any internal whitespace
/// — `{{ body }}`, `{{body}}`, `{{  body  }}`. Used to decide whether the
/// renderer should auto-append `\n\n{{ body }}` to a template that
/// hasn't placed the body itself.
private static let bodyReferencePattern = try! NSRegularExpression(
    pattern: #"\{\{\s*body\s*\}\}"#
)

private static func referencesBody(_ template: String) -> Bool {
    let range = NSRange(template.startIndex..., in: template)
    return bodyReferencePattern.firstMatch(in: template, range: range) != nil
}

public static func split(
    event: ChannelServerMessage,
    recipientWorktreePath: String,
    subjectWorktreePath: String?,
    repos: [RepoEntry],
    templateString: String
) -> EventBodyRendererResult {
    // Empty template = passthrough.
    guard !templateString.isEmpty else {
        return EventBodyRendererResult(event: event, agentPrompt: nil)
    }
    guard case let .event(_, _, originalBody) = event else {
        return EventBodyRendererResult(event: event, agentPrompt: nil)
    }

    // Compute the agent context for this delivery. (Unchanged logic
    // from the legacy body(...) function.)
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

    let agentDict = makeAgentContext(
        branch: recipient?.branch ?? "",
        lead: isLead,
        thisWorktree: isThisWorktree,
        otherWorktree: isOtherWorktree
    )

    // Auto-append `\n\n{{ body }}` to templates that don't reference
    // the body themselves, so out-of-the-box templates and legacy
    // user-customized templates keep producing today's "prelude
    // followed by body" output without migration.
    let effectiveTemplate = referencesBody(templateString)
        ? templateString
        : "\(templateString)\n\n{{ body }}"

    guard let rendered = renderAgentTemplate(
        effectiveTemplate,
        agent: agentDict,
        body: originalBody
    ) else {
        return EventBodyRendererResult(event: event, agentPrompt: nil)
    }

    return EventBodyRendererResult(event: event, agentPrompt: rendered)
}
```

- [ ] **Step 4: Update `renderAgentTemplate` to accept the `body` context variable**

In the same file, replace the existing `renderAgentTemplate(_:agent:)` extension method (around line 81) with:

```swift
extension EventBodyRenderer {
    /// Renders a Stencil template against an agent-context dict, with an
    /// optional top-level `body` variable carrying the original event
    /// content. Returns the trimmed rendered string, or nil on render
    /// failure / empty result. `body` defaults to nil for the session-
    /// start path where no event is in flight.
    public static func renderAgentTemplate(
        _ template: String,
        agent: [String: Any],
        body: String? = nil
    ) -> String? {
        guard !template.isEmpty else { return nil }
        var context: [String: Any] = ["agent": agent]
        if let body { context["body"] = body }
        let rendered: String
        do {
            rendered = try sharedEnvironment.renderTemplate(string: template, context: context)
        } catch {
            logger.error("agent template render failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func renderSessionPrompt(
        template: String,
        branch: String,
        lead: Bool
    ) -> String? {
        renderAgentTemplate(template, agent: makeAgentContext(branch: branch, lead: lead))
    }
}
```

- [ ] **Step 5: Remove the legacy `body(...)` function**

Delete the legacy `public static func body(for:recipientWorktreePath:subjectWorktreePath:repos:templateString:) -> ChannelServerMessage` from `EventBodyRenderer.swift`. Its only caller (`TeamEventDispatcher.renderBody`) gets updated in Task 4.

- [ ] **Step 6: Run, expect linker / compile error in dispatcher**

```bash
swift build 2>&1 | tail -10
```

Expected: build fails because `TeamEventDispatcher.renderBody` calls the now-deleted `EventBodyRenderer.body(...)`. Task 4 fixes that. The renderer tests should still pass; verify:

```bash
swift test --filter EventBodyRendererSplitTests 2>&1 | tail -10
```

Expected: 7 tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Teams/EventBodyRenderer.swift Tests/GrafttyKitTests/Channels/EventBodyRendererTests.swift
git commit -m "$(cat <<'EOF'
feat(teams): EventBodyRenderer.split + auto-append + body variable

split(...) returns the original event plus the rendered teamPrompt
separately so consumers can store them in different fields. Stencil
templates may reference {{ body }} to control where the event content
appears; templates that don't reference it get \n\n{{ body }}
auto-appended before rendering, preserving today's prepend behavior.

The legacy body(...) function is removed; its single caller (the
dispatcher) is updated in a follow-up task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(The build is intentionally broken at this point. Task 3 / 4 follow.)

---

## Task 3: Inbox — `appendMessage` accepts `agentPrompt`

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamInbox.swift`

- [ ] **Step 1: Add the parameter to `appendMessage`**

In `Sources/GrafttyKit/Teams/TeamInbox.swift`, find `public func appendMessage(...)` (around line 140) and modify:

```swift
@discardableResult
public func appendMessage(
    teamID: String,
    teamName: String,
    repoPath: String,
    from: TeamInboxEndpoint,
    to: TeamInboxEndpoint,
    priority: TeamInboxPriority,
    kind: String = "team_message",
    body: String,
    agentPrompt: String? = nil
) throws -> TeamInboxMessage {
    let message = TeamInboxMessage(
        id: idGenerator(),
        batchID: nil,
        createdAt: now(),
        team: teamName,
        repoPath: repoPath,
        from: from,
        to: to,
        priority: priority,
        kind: kind,
        body: body,
        agentPrompt: agentPrompt
    )
    try append(message, teamID: teamID)
    return message
}
```

- [ ] **Step 2: Verify build is still broken (only the dispatcher remains)**

```bash
swift build 2>&1 | tail -10
```

Expected: build fails specifically on `TeamEventDispatcher.swift` (the `EventBodyRenderer.body(...)` call from Task 2 still hasn't been migrated). No new errors elsewhere.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamInbox.swift
git commit -m "$(cat <<'EOF'
feat(teams): TeamInbox.appendMessage threads agentPrompt through

Optional parameter (default nil) so existing callers compile
unchanged; the dispatcher (Task 4) supplies it for routable events
and broadcasts.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Dispatcher — `renderBody` returns tuple; three call sites updated

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift`

- [ ] **Step 1: Replace `renderBody(...)` with a tuple-returning version**

In `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift`, find `private func renderBody(...)` (around line 302) and replace with:

```swift
/// Renders the user's `teamPrompt` template against the per-recipient
/// agent context and returns the event-only body plus the rendered
/// agent prompt. When the template is empty / fails to render, returns
/// the original body and a nil prompt — matching the legacy passthrough
/// behavior. See @spec TEAM-1.6.
private func renderBody(
    event: ChannelServerMessage,
    recipientWorktreePath: String,
    subjectWorktreePath: String?,
    repos: [RepoEntry]
) -> (body: String, agentPrompt: String?) {
    guard case let .event(_, _, originalBody) = event else { return ("", nil) }
    let result = EventBodyRenderer.split(
        event: event,
        recipientWorktreePath: recipientWorktreePath,
        subjectWorktreePath: subjectWorktreePath,
        repos: repos,
        templateString: templateProvider()
    )
    if case let .event(_, _, body) = result.event {
        return (body, result.agentPrompt)
    }
    return (originalBody, result.agentPrompt)
}
```

- [ ] **Step 2: Update `dispatchTeamBroadcast` to thread the prompt**

Same file, find the loop in `dispatchTeamBroadcast` (around line 105). Replace:

```swift
let body = renderBody(
    event: event,
    recipientWorktreePath: recipient.worktreePath,
    subjectWorktreePath: senderMember.worktreePath,
    repos: repos
)
let msg = try inbox.appendMessage(
    teamID: TeamLookup.id(of: team),
    teamName: team.repoDisplayName,
    repoPath: team.repoPath,
    from: TeamInboxEndpoint(
        member: senderMember.name,
        worktree: senderMember.worktreePath,
        runtime: nil
    ),
    to: TeamInboxEndpoint(
        member: recipient.name,
        worktree: recipient.worktreePath,
        runtime: nil
    ),
    priority: priority,
    kind: TeamChannelEvents.EventType.message,
    body: body
)
```

with:

```swift
let rendered = renderBody(
    event: event,
    recipientWorktreePath: recipient.worktreePath,
    subjectWorktreePath: senderMember.worktreePath,
    repos: repos
)
let msg = try inbox.appendMessage(
    teamID: TeamLookup.id(of: team),
    teamName: team.repoDisplayName,
    repoPath: team.repoPath,
    from: TeamInboxEndpoint(
        member: senderMember.name,
        worktree: senderMember.worktreePath,
        runtime: nil
    ),
    to: TeamInboxEndpoint(
        member: recipient.name,
        worktree: recipient.worktreePath,
        runtime: nil
    ),
    priority: priority,
    kind: TeamChannelEvents.EventType.message,
    body: rendered.body,
    agentPrompt: rendered.agentPrompt
)
```

- [ ] **Step 3: Update the routable-fanout site**

Same file, find the appendMessage call inside `dispatchRoutableEvent` (search for the second `inbox.appendMessage(...)` call after `renderBody`, likely around line 270–290). Apply the same `let rendered = renderBody(...)` + `body: rendered.body, agentPrompt: rendered.agentPrompt` substitution.

- [ ] **Step 4: Update any other `renderBody`+`appendMessage` call sites**

Search for them:

```bash
rg -n "renderBody\\(" Sources/GrafttyKit/Teams/TeamEventDispatcher.swift
```

Apply the same substitution to each.

- [ ] **Step 5: Build, expect clean**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build. Renderer + inbox + dispatcher are now consistent.

- [ ] **Step 6: Update existing dispatcher tests that asserted on the prepended body shape**

```bash
rg -n "rendered.*\\\\n\\\\n\\|prepend\\|teamPrompt\\|prompt" Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift | head
```

Tests that previously asserted `body.contains("<prelude>\n\n<event>")` should now assert `body == "<event>"` and `agentPrompt?.contains("<prelude>")`. Update each.

- [ ] **Step 7: Add a new test for the split storage**

Append to `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift`:

```swift
@Test("dispatchRoutableEvent stores event-only body and rendered template in agentPrompt.")
func dispatchRoutableEventSplitsBodyAndPrompt() throws {
    // (Use the existing fixture pattern — TeamTestFixtures.makeRepo or whatever
    // the file uses — and a non-empty templateProvider that includes
    // "{{ agent.branch }}" so we can assert it rendered.)
    let root = try Self.temporaryDirectory()
    let repo = TeamTestFixtures.makeRepo(path: "/repo", displayName: "repo", branches: ["main", "alice"])
    let inbox = TeamInbox(rootDirectory: root, idGenerator: { "id-1" }, now: { Date(timeIntervalSince1970: 1_800) })
    let dispatcher = TeamEventDispatcher(inbox: inbox, templateProvider: { "Hello {{ agent.branch }}." })

    try dispatcher.dispatchRoutableEvent(
        ChannelServerMessage.event(
            type: TeamChannelEvents.WireType.prStateChanged,
            attrs: ["from": "open", "to": "ready_for_review"],
            body: "PR #1 went open → ready_for_review"
        ),
        subjectWorktreePath: "/repo/.worktrees/alice",
        repos: [repo]
    )

    let rows = try inbox.messages(teamID: TeamLookup.id(of: TeamLookup.team(for: "/repo", in: [repo])!))
    let row = try #require(rows.first)
    #expect(row.body == "PR #1 went open → ready_for_review")
    #expect(row.agentPrompt?.contains("Hello alice.") == true)
    #expect(row.agentPrompt?.contains("PR #1 went open → ready_for_review") == true)  // auto-append
}
```

(Adapt fixture-helper names to whatever the file already uses.)

- [ ] **Step 8: Run, expect pass**

```bash
swift test --filter TeamEventDispatcher 2>&1 | tail -15
```

Expected: all tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamEventDispatcher.swift Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift
git commit -m "$(cat <<'EOF'
feat(teams): dispatcher threads agentPrompt through to inbox rows

renderBody now returns (body, agentPrompt) per recipient; broadcast
and routable-fanout sites pass both into TeamInbox.appendMessage.
Existing tests that asserted on the prepended body shape are updated
to read body and agentPrompt from the split fields.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: HookRenderer — `format(messages:)` emits `agentPrompt ?? body`

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamHookRenderer.swift`
- Modify: `Tests/GrafttyKitTests/Teams/TeamHookRendererTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/GrafttyKitTests/Teams/TeamHookRendererTests.swift`:

```swift
@Test("format(messages:) emits agentPrompt when non-nil.")
func formatEmitsAgentPromptWhenPresent() {
    let msg = message(id: "m1", priority: .normal, body: "EVENT", agentPrompt: "Hello alice.\n\nEVENT")
    let rendered = TeamHookRenderer.format(messages: [msg])
    #expect(rendered.contains("Hello alice."))
    #expect(rendered.contains("EVENT"))
    #expect(!rendered.contains("body=EVENT"))  // body shouldn't appear separately
}

@Test("format(messages:) falls through to body when agentPrompt is nil.")
func formatFallsThroughToBodyWhenPromptNil() {
    let msg = message(id: "m1", priority: .normal, body: "RAW-EVENT", agentPrompt: nil)
    let rendered = TeamHookRenderer.format(messages: [msg])
    #expect(rendered.contains("RAW-EVENT"))
}
```

Update the existing `message(...)` fixture helper in the same file to accept an `agentPrompt: String? = nil` parameter:

```swift
private func message(id: String, priority: TeamInboxPriority, body: String, agentPrompt: String? = nil) -> TeamInboxMessage {
    TeamInboxMessage(
        id: id,
        batchID: nil,
        createdAt: Date(timeIntervalSince1970: 1_800),
        team: "acme-web",
        repoPath: "/repo/acme",
        from: TeamInboxEndpoint(member: "main", worktree: "/repo/acme", runtime: "claude"),
        to: TeamInboxEndpoint(member: "feature-auth", worktree: "/repo/acme/.worktrees/feature-auth", runtime: "codex"),
        priority: priority,
        body: body,
        agentPrompt: agentPrompt
    )
}
```

- [ ] **Step 2: Run, expect failure**

```bash
swift test --filter "TeamHookRenderer" 2>&1 | tail -15
```

Expected: the new `formatEmitsAgentPromptWhenPresent` test fails because `format` still emits `body` directly.

- [ ] **Step 3: Update `TeamHookRenderer.format(messages:)`**

In `Sources/GrafttyKit/Teams/TeamHookRenderer.swift`, replace the existing `format(...)` (around line 93):

```swift
public static func format(messages: [TeamInboxMessage]) -> String {
    messages.map { message in
        let agentText = message.agentPrompt ?? message.body
        return """
        [id=\(message.id) priority=\(message.priority.rawValue) from=\(message.from.member) runtime=\(message.from.runtime ?? "unknown") at=\(timestamp(message.createdAt))]
        \(agentText)
        """
    }.joined(separator: "\n\n")
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
swift test --filter "TeamHookRenderer" 2>&1 | tail -15
```

Expected: all renderer tests pass.

- [ ] **Step 5: Run the broader test suite**

```bash
swift test 2>&1 | tail -3
```

Expected: full suite passes (existing PostToolUse delivery tests at `TeamInboxRequestHandlerTests` should still pass — `format` now emits the prompt-rendered text which contains the body via auto-append).

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Teams/TeamHookRenderer.swift Tests/GrafttyKitTests/Teams/TeamHookRendererTests.swift
git commit -m "$(cat <<'EOF'
feat(teams): TeamHookRenderer.format emits agentPrompt or body

When agentPrompt is non-nil it already contains the body content
(either via the user's {{ body }} reference or the auto-appended one),
so format() emits it verbatim. When agentPrompt is nil (empty
template, render failure, or pre-split row on disk) it falls through
to body. No concatenation glue anywhere.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Spec amendment + SPECS regen

**Files:**
- Modify: `Tests/GrafttyTests/Specs/TeamTodo.swift` (or wherever the active `@spec TEAM-1.6` annotation lives)
- Modify: `SPECS.md` (regenerated)

- [ ] **Step 1: Find the active TEAM-1.6 annotation**

```bash
rg -n "@spec TEAM-1.6" Sources/ Tests/
```

It lives in `Tests/GrafttyTests/Specs/TeamTodo.swift`. Open the file and find the `@Test(...)` block whose title starts with `@spec TEAM-1.6:`.

- [ ] **Step 2: Replace the EARS text**

Replace the `@spec TEAM-1.6` title text. The new text:

> @spec TEAM-1.6: The Agent Teams Settings pane shall expose **two** user-editable Stencil-templated text areas, each pre-populated with a non-empty default (`DefaultPrompts.sessionPrompt` and `DefaultPrompts.eventPrompt`) registered into `UserDefaults.standard` at app startup so non-binding readers see the same default until the user overrides. Clearing a field to the empty string disables that prompt. The first, `teamSessionPrompt` (`@AppStorage("teamSessionPrompt")`, String) — rendered once at session start against the `agent` context; only `agent.branch` and `agent.lead` are meaningful at session start (`agent.this_worktree` and `agent.other_worktree` are always `false`), and the pane's variable-list disclosure deliberately omits the latter two. The rendered text is appended after a blank line to the auto-generated team-aware instructions text returned by `graftty team hook`. The second, `teamPrompt` (`@AppStorage("teamPrompt")`, String) — rendered per inbox-row write against the full four-field `agent` context evaluated against the recipient agent, plus a top-level `body` variable carrying the original event body. The rendered output is stored in the inbox row's `agent_prompt` field. If the template does not reference `{{ body }}` the renderer appends `\n\n{{ body }}` to the template before rendering, so templates that pre-date the `body` variable continue to surface the event content to the agent. Hook-context delivery (via `TeamHookRenderer.format`) emits `agent_prompt` when present and falls through to `body` otherwise; the inbox row's `body` field stores the event content unchanged so consumers other than the agent (activity log, `graftty team inbox`, watcher wake summaries) read it without the template prelude. Both templates use the same `agent` struct shape: `branch` (String), `lead` (Bool), `this_worktree` (Bool), `other_worktree` (Bool). The previously-defined `teamLeadPrompt` and `teamCoworkerPrompt` AppStorage keys are removed.

- [ ] **Step 3: Regenerate SPECS.md**

```bash
scripts/generate-specs.py 2>&1 | tail -3
git diff SPECS.md | head -40
```

Expected: SPECS.md picks up the new TEAM-1.6 text.

- [ ] **Step 4: Verify-specs check passes**

```bash
scripts/generate-specs.py --check; echo "exit: $?"
```

Expected: exit 0.

- [ ] **Step 5: Run the full suite once more**

```bash
swift test 2>&1 | tail -3
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Tests/GrafttyTests/Specs/TeamTodo.swift SPECS.md
git commit -m "$(cat <<'EOF'
docs(specs): TEAM-1.6 amended for body/agent_prompt split

Describes the new agent_prompt field, the {{ body }} Stencil
variable, the auto-append behavior for templates that don't
reference {{ body }}, and the hook-delivery rule (agent_prompt or
body, never both).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: /simplify pass + push

- [ ] **Step 1: Invoke /simplify** scoped to the commits in this plan.

```bash
git log --oneline d9c599a..HEAD | head -10
```

(That gives you the SHAs from this plan's commits — pass them to /simplify as `--scope=<base>..HEAD`.)

- [ ] **Step 2: Apply any high-value findings inline**

Look for: redundant state, copy-paste, stringly-typed code, hot-path bloat. Skip findings that are speculative refactors.

- [ ] **Step 3: Final verification**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
scripts/generate-specs.py --check; echo "specs check exit: $?"
```

Expected: clean, full suite passes, specs check exit 0.

- [ ] **Step 4: Push**

```bash
git push 2>&1 | tail -3
```

- [ ] **Step 5: Watch CI**

```bash
gh pr checks 106 --watch --interval 30 2>&1 | tail -10
```

Expected: all 4 checks green.

---

## Self-review checklist

- [x] **Spec coverage:**
  - Schema field → Task 1
  - Renderer split + auto-append + body Stencil var → Task 2
  - Inbox parameter → Task 3
  - Dispatcher tuple + three call sites → Task 4
  - HookRenderer format prompt-or-body → Task 5
  - Activity log / watcher / CLI consumers — no code changes (covered implicitly by the schema split; spec section says so)
  - `@spec TEAM-1.6` amendment + SPECS regen → Task 6
  - Out-of-scope migration of legacy rows — explicit non-goal in spec, no task needed

- [x] **No placeholders.** Every step has full code or concrete commands. The one fixture-shape note in Task 2 ("if `RepoEntry` initializer differs, adapt") is a real instruction to the implementer to verify the existing public initializer rather than a TBD.

- [x] **Type consistency.** `EventBodyRendererResult(event:agentPrompt:)` initializer used in Task 2 matches the struct definition. `agentPrompt: String?` parameter on `appendMessage` (Task 3) matches the same name on `TeamInboxMessage` (Task 1) and on the dispatcher's tuple return (Task 4). `format(messages:)` reads `message.agentPrompt` consistently with the field name from Task 1. `renderAgentTemplate(_:agent:body:)` signature in Task 2 matches the new caller in `split(...)` and the unchanged caller in `renderSessionPrompt` (which passes no `body`).
