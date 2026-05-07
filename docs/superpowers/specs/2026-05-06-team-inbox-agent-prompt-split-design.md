# Team Inbox — `agent_prompt` / `body` Schema Split

**Date:** 2026-05-06
**Status:** Design approved; ready for implementation planning

## Motivation

Today, `EventBodyRenderer.body(...)` renders the user's `teamPrompt` Stencil template against a recipient agent context, then prepends the rendered output to the original event body with a blank-line separator. The concatenated string is what gets written to `TeamInboxMessage.body` and reread by every downstream consumer.

That works for the AI-facing hook-delivery path — agents see the prelude *and* the event content — but it leaks into every other consumer:

- The **Team Activity Log** transcript shows the boilerplate prelude on every system event row, drowning the event-specific content (e.g., "CI on PR #106: pending → success") below two paragraphs of identical scaffolding ("A Graftty automated team event was just delivered to you.", "This event is about your own worktree.").
- The **`InboxWatcher` wake-summary** reads `body` and surfaces the prelude as the asyncRewake stderr; the actual event content gets pushed past the truncation point. The user observes a wake "from main: A Graftty automated team event was just delivered to you." with no apparent content, when the actual message body was `hi`.
- The **`graftty team inbox` CLI** prints the prelude verbatim on every row.

Splitting the field — one for the clean event content, one for the rendered agent prompt — fixes every consumer with one schema change. The hook-delivery path re-emits the prompt when shipping context to the agent runtime; everything else reads `body` and ignores `agent_prompt`.

A second goal of this design: give template authors control over where the event content appears in the prelude. Today's renderer always puts the body *after* the template with a fixed blank-line separator. Adding `{{ body }}` as a Stencil context variable lets authors interleave conditional headers, suppress the body for events they want to silence, or place it inline with other text. To preserve today's behavior for templates that don't reference `{{ body }}`, the renderer auto-appends `\n\n{{ body }}` to those templates before rendering. Out-of-the-box templates and pre-existing user-customized templates keep producing today's output without migration.

## Scope

### In scope

- Add an optional `agentPrompt: String?` field to `TeamInboxMessage` (JSON key: `agent_prompt`).
- Replace `EventBodyRenderer.body(...)` with `EventBodyRenderer.split(...)` returning a typed result that exposes the rendered template and the event-only body separately.
- Add `body` as a Stencil context variable alongside the existing `agent.*` fields.
- Auto-append `"\n\n{{ body }}"` to template strings that do not reference `{{ body }}` so existing templates produce today's output.
- Plumb the split through `TeamEventDispatcher` (broadcast, single-send, routable-fanout) and `TeamInbox.appendMessage(...)`.
- Re-emit the prompt at the AI boundary in `TeamHookRenderer.format(messages:)` — emit `agent_prompt` if non-nil, else fall through to `body`. No concatenation glue anywhere.
- Amend `@spec TEAM-1.6` to describe the split.

### Out of scope

- **Migration of existing rows on disk.** Rows already in `messages.jsonl` keep the legacy concatenated `body`. They self-resolve as the inbox ages. New rows are clean.
- Changes to `DefaultPrompts.eventPrompt` or `DefaultPrompts.sessionPrompt` — auto-append handles backward-compat for the default `eventPrompt`. The session prompt is a separate code path that lives outside this split.
- Activity log row layout (already shipped; just gets a clean `body` for free).
- The `team inbox` CLI's listing format (already prints `body` verbatim; just gets a clean string).

## Schema

`TeamInboxMessage` gains one optional field:

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
    public let body: String          // event-only; no template prelude
    public let agentPrompt: String?  // ← new; rendered teamPrompt or nil

    enum CodingKeys: String, CodingKey {
        // existing keys ...
        case agentPrompt = "agent_prompt"
    }
}
```

Forward-compat is automatic: rows on disk that predate this change have no `agent_prompt` key in their JSON, so `Codable` decodes them with `agentPrompt = nil`. The hook-delivery formatter falls through to `body` for nil prompts, so old rows keep delivering the same content they always did (still concatenated in the legacy `body`, just without re-concatenation at delivery time).

## Renderer

`EventBodyRenderer.body(...)` is replaced by:

```swift
public struct EventBodyRendererResult: Equatable {
    public let event: ChannelServerMessage   // body field is event-only (no prelude)
    public let agentPrompt: String?          // rendered template, or nil for passthrough
}

public static func split(
    event: ChannelServerMessage,
    recipientWorktreePath: String,
    subjectWorktreePath: String?,
    repos: [RepoEntry],
    templateString: String
) -> EventBodyRendererResult
```

Inside `split(...)`:

1. **Empty template:** if `templateString.isEmpty`, return `event` unchanged + `agentPrompt = nil`. (Same passthrough today's empty-prompt users get.)
2. **Auto-append:** if `templateString` does not contain a Stencil reference to `body` (regex: `\{\{\s*body\s*\}\}`), append `"\n\n{{ body }}"` to it. Otherwise leave it unchanged.
3. **Render** the (possibly-appended) template against the existing `agent.*` context plus a new top-level `body: <originalBody>` Stencil variable.
4. **Render failure or whitespace-only render:** return `event` unchanged + `agentPrompt = nil`.
5. **Otherwise** return `event` with body unchanged + `agentPrompt = <rendered>`.

The pre-render template-text check (step 2) is deterministic and tolerant of whitespace inside the braces (`{{ body }}` and `{{body}}` both detected). It does not run against the rendered output, so an event body that happens to literally contain the string `{{ body }}` doesn't trigger a false positive.

`renderAgentTemplate(...)` (the helper that actually invokes Stencil) accepts the new `body` variable in its context dictionary alongside `agent`. Existing call sites keep their `agent.*` references; new templates may add `{{ body }}` (or rely on auto-append).

## Dispatcher

`TeamEventDispatcher.renderBody(...)` becomes:

```swift
private func renderBody(
    event: ChannelServerMessage,
    recipientWorktreePath: String,
    subjectWorktreePath: String?,
    repos: [RepoEntry]
) -> (body: String, agentPrompt: String?)
```

Returns the event-only body (extracted from the result's `event`) and the rendered `agentPrompt`. Three call sites adapt:

- `dispatchTeamMessage` (single direct message)
- `dispatchTeamBroadcast` (one row per recipient)
- `dispatchRoutableEvent` (PR / CI / merge fan-out)

Each unpacks the tuple and passes both into `inbox.appendMessage(...)`.

## Inbox

`TeamInbox.appendMessage(...)` gains a new optional parameter:

```swift
public func appendMessage(
    teamID: String,
    teamName: String,
    repoPath: String,
    from: TeamInboxEndpoint,
    to: TeamInboxEndpoint,
    priority: TeamInboxPriority,
    kind: String = "team_message",
    body: String,
    agentPrompt: String? = nil   // ← new
) throws -> TeamInboxMessage
```

Defaulting `nil` keeps existing call sites that don't carry a prompt working unchanged; only the dispatcher passes a non-nil value.

## Hook delivery

`TeamHookRenderer.format(messages:)` is the only place the AI-facing concatenation happens, and the rule is "no concatenation":

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

When `agentPrompt` is non-nil it already contains the body content (either via the user's `{{ body }}` reference or the auto-appended one). When `agentPrompt` is nil the renderer fell through (empty template, render failure, or pre-split row on disk) so the body itself is the right text to ship.

## Activity log, watcher, CLI

No code changes — these consumers already read `body`. They get the clean event content automatically once `body` stops carrying the prelude.

## Tests

### `EventBodyRendererTests` (currently empty after the channels-to-inbox migration; this populates it)

- Empty template → passthrough: `agentPrompt == nil`, event body unchanged.
- Template without `{{ body }}` → auto-append: rendered output contains `originalBody` and the rendered template prelude appears before it.
- Template with explicit `{{ body }}` → no auto-append: rendered output respects template-author placement.
- Template with `{{body}}` (no internal whitespace) → no auto-append.
- Stencil render failure (malformed template) → passthrough.
- Render output that is whitespace-only → passthrough.

### `TeamEventDispatcherTests`

- `dispatchTeamBroadcast` writes rows where `body` is event-only and `agentPrompt` is the rendered template.
- `dispatchRoutableEvent` (PR / CI / merge fan-out) writes rows where `body` is event-only and `agentPrompt` is the rendered template.
- Pre-existing tests asserting on the prepended body shape get updated to assert against the new split.

### `TeamHookRendererTests`

- `format(messages:)` emits `agentPrompt` when non-nil.
- `format(messages:)` falls through to `body` when `agentPrompt` is nil (forward-compat for pre-split rows).

### `TeamInboxTests`

- JSON round-trip for a row with `agentPrompt` set.
- JSON round-trip for a row without `agentPrompt` (decodes as nil; encoder omits the key).

### `TeamInboxRequestHandlerTests`

- Existing PostToolUse delivery test stays green: `additionalContext` still contains the message body (it now lives inside `agentPrompt` via auto-append rather than being concatenated at format-time).

## Spec amendment

`@spec TEAM-1.6` text changes from:

> The second, `teamPrompt` (`@AppStorage("teamPrompt")`, String) — rendered per inbox-row write against the full four-field `agent` context evaluated against the recipient agent; the rendered text is prepended after a blank line to the inbox row's body before the row is appended to the recipient's `messages.jsonl`.

to:

> The second, `teamPrompt` (`@AppStorage("teamPrompt")`, String) — rendered per inbox-row write against the full four-field `agent` context evaluated against the recipient agent, **plus a top-level `body` variable carrying the original event body**. The rendered output is stored in the inbox row's `agent_prompt` field. **If the template does not reference `{{ body }}` the renderer appends `\n\n{{ body }}` to the template before rendering**, so templates that pre-date the `body` variable continue to surface the event content to the agent. Hook-context delivery emits `agent_prompt` when present and falls through to `body` otherwise; the inbox row's `body` field stores the event content unchanged so consumers other than the agent (activity log, `graftty team inbox`, watcher wake summaries) read it without the template prelude.

The `agent` Stencil context shape is unchanged.

## Architectural decisions

- **One concatenation site, then zero.** Today's design has one site that prepends template + body (`EventBodyRenderer.body:75`) and every consumer reads the joined string. The split lifts the concatenation responsibility to the template author (via `{{ body }}`) with a backward-compat auto-append that exactly reproduces today's behavior. After the change, no code anywhere concatenates prompt + body — the template owns the agent-facing message verbatim.
- **No retroactive migration.** Rows already on disk keep their legacy `body` (with the prelude inlined). They self-resolve as the inbox ages out. The pure-data alternative (re-render the user's *current* template against each row's recipient context, find the resulting prefix in the body, strip it, rewrite the file) was rejected because the template may have changed between when each row was written and when the migration runs — a strip that succeeds for some rows and fails for others is worse than uniform "old rows show duplication, new rows are clean."
- **Detection on the template text, not on the rendered output.** The auto-append decision is made before Stencil ever runs (regex check against the source template). Doing it post-render — "does the rendered output contain `originalBody` somewhere?" — would hit false negatives when the body coincidentally appears in the prelude text and false positives when the template intentionally suppresses the body.

## Open questions / future work

- **Default template revision.** `DefaultPrompts.eventPrompt` doesn't reference `{{ body }}` and relies on auto-append. We could revise it to `{{ body }}` explicitly for clarity once this lands, but the current default is fine and changing it has zero behavioral impact.
- **Watcher summary improvements.** Once `body` is clean, `InboxWatcher.summary(for:)` produces a useful wake stderr without changes. A follow-up could trim/format the summary further, but that's separate from this split.
- **`session_prompt` field.** The session prompt (`teamSessionPrompt`) is rendered once at hook session start in a different code path (the `TeamHookRenderer.codexSessionStart` `teamContext` argument). It doesn't write to inbox rows at all, so it's untouched by this design. If a similar "store-once, deliver-many" pattern emerges for session prompts, it'd get its own design.

## Files to modify

- `Sources/GrafttyKit/Teams/TeamInbox.swift` — add `agentPrompt` field + `CodingKeys`; add the parameter to `appendMessage(...)`.
- `Sources/GrafttyKit/Teams/EventBodyRenderer.swift` — replace `body(...)` with `split(...)`; add `body` to the Stencil context dict; add the auto-append regex check.
- `Sources/GrafttyKit/Teams/TeamEventDispatcher.swift` — change `renderBody(...)` to return `(body, agentPrompt)`; update three dispatch call sites.
- `Sources/GrafttyKit/Teams/TeamHookRenderer.swift` — change `format(messages:)` to emit `agentPrompt ?? body` per message.
- `Tests/GrafttyKitTests/Channels/EventBodyRendererTests.swift` — populate (currently empty).
- `Tests/GrafttyKitTests/Teams/TeamEventDispatcherTests.swift` — assert split storage; update prepended-body assertions.
- `Tests/GrafttyKitTests/Teams/TeamHookRendererTests.swift` — assert `format` emits prompt-or-body.
- `Tests/GrafttyKitTests/Teams/TeamInboxTests.swift` — JSON round-trip for both shapes.
- `Tests/GrafttyTests/Specs/TeamTodo.swift` (or wherever TEAM-1.6 lives today) — update the `@spec` text.
- `SPECS.md` — regenerated last from the updated `@spec` annotations.
