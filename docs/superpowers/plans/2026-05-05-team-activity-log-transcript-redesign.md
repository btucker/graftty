# Team Activity Log Transcript Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Team Activity Log's mixed chat-bubble / system-entry layout with a single Slack-inspired transcript grid: timestamp gutter on the left, worktree-as-actor for both chat and system events, centered markers for join/leave, day dividers at midnight.

**Architecture:** Pure data layer (`ActivityFeedRow` resolves a `TeamInboxMessage` to a typed variant; view-model annotates each variant with continuation context and inserts day dividers between local-midnight crossings) + three small SwiftUI views (`TranscriptRow`, `CenteredMarkerRow`, `DayDividerRow`) that render fully-resolved props. `TeamActivityLogRow` stays as the public entry point and dispatches to the right component.

**Tech Stack:** Swift 5.9+, SwiftUI, Swift Testing for new tests, XCTest for the existing `TeamActivityLogRowTests` reshape (matches the existing file's framework).

**Spec source:** `docs/superpowers/specs/2026-05-05-team-activity-log-transcript-redesign-design.md`

---

## File Structure

### New files

- `Sources/Graftty/Views/TeamActivityLog/ActivityFeedRow.swift` — variant model (`enum ActivityFeedRow { case chat(...); case system(...); case memberJoined(...); case memberLeft(...); case dayDivider(...) }`) + the pure `resolve(message:)` function that maps a `TeamInboxMessage` to a variant.
- `Sources/Graftty/Views/TeamActivityLog/RenderedFeedItem.swift` — the view-model output type. Wraps an `ActivityFeedRow` plus its annotation flags (`isContinuation: Bool`, derived from the previous item).
- `Sources/Graftty/Views/TeamActivityLog/TranscriptRow.swift` — the 2-column timestamp + content grid used for chat and system variants.
- `Sources/Graftty/Views/TeamActivityLog/CenteredMarkerRow.swift` — horizontal-rule marker with inline text (member joined/left).
- `Sources/Graftty/Views/TeamActivityLog/DayDividerRow.swift` — uppercase day-label divider (`TODAY`, `YESTERDAY`, `MAR 5`).
- `Tests/GrafttyTests/Views/ActivityFeedRowTests.swift` — Swift Testing suite for variant resolution.
- `Tests/GrafttyTests/Views/TeamActivityLogViewModelTests.swift` — Swift Testing suite for continuation / day-divider computation.

### Modified files

- `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift` — refactor to dispatch on `ActivityFeedRow` + `isContinuation`; the old `Style` enum + `ChatBubbleView` + `SystemEntryView` go away.
- `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogViewModel.swift` — add a `renderedItems: [RenderedFeedItem]` computed property that runs the messages through `ActivityFeedRow.resolve` and the continuation/day-divider passes.
- `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogWindow.swift` — iterate over `renderedItems` instead of raw `messages`.
- `Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift` — reshape to assert against the new component shape rather than the deleted `Style` enum.

### No changes

- `Sources/GrafttyKit/Teams/TeamInboxMessage.swift` — schema is untouched.
- `Sources/GrafttyKit/Teams/TeamInboxObserver.swift` — emit pipeline is untouched; the view-model still consumes raw `messages`.
- `SPECS.md` — no spec annotations are added or removed by this work; UI components don't generally carry `@spec` doc-comments here. (If the implementer adds new `@spec` tests, regenerate SPECS at the end.)

---

## Task 1: Variant model + resolution

**Goal:** Pure data: the mapping table from `TeamInboxMessage` to a `ActivityFeedRow` variant (the data-→-row table in spec section "Data → row mapping").

**Files:**
- Create: `Sources/Graftty/Views/TeamActivityLog/ActivityFeedRow.swift`
- Create: `Tests/GrafttyTests/Views/ActivityFeedRowTests.swift`

- [ ] **Step 1: Write the failing test file**

Create `Tests/GrafttyTests/Views/ActivityFeedRowTests.swift`:

```swift
import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("ActivityFeedRow.resolve — message → variant mapping")
struct ActivityFeedRowResolveTests {
    @Test("team_message from a non-system sender becomes a chat variant.")
    func teamMessageBecomesChat() {
        let msg = Self.message(
            kind: "team_message",
            from: .member("alice"),
            to: .member("bob"),
            body: "ping"
        )
        #expect(ActivityFeedRow.resolve(msg) == .chat(
            worktree: "alice",
            recipient: "bob",
            body: "ping",
            timestamp: msg.createdAt,
            isUrgent: false
        ))
    }

    @Test("team_message with priority urgent surfaces isUrgent=true.")
    func urgentChatFlag() {
        let msg = Self.message(
            kind: "team_message",
            from: .member("alice"),
            to: .member("bob"),
            priority: .urgent,
            body: "hold"
        )
        guard case let .chat(_, _, _, _, isUrgent) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected chat variant")
            return
        }
        #expect(isUrgent == true)
    }

    @Test("team_message where from == to drops the recipient suffix.")
    func selfMessageHasNoRecipient() {
        let msg = Self.message(
            kind: "team_message",
            from: .member("alice"),
            to: .member("alice"),
            body: "note"
        )
        guard case let .chat(_, recipient, _, _, _) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected chat variant")
            return
        }
        #expect(recipient == nil)
    }

    @Test("team_member_joined becomes a memberJoined centered marker.")
    func memberJoined() {
        let msg = Self.message(
            kind: "team_member_joined",
            from: .system,
            to: .member("alice"),
            body: ""
        )
        #expect(ActivityFeedRow.resolve(msg) == .memberJoined(worktree: "alice"))
    }

    @Test("team_member_left becomes a memberLeft centered marker.")
    func memberLeft() {
        let msg = Self.message(
            kind: "team_member_left",
            from: .system,
            to: .member("alice"),
            body: ""
        )
        #expect(ActivityFeedRow.resolve(msg) == .memberLeft(worktree: "alice"))
    }

    @Test("pr_state_changed becomes a system row scoped to to.member with the PR icon.")
    func prStateChanged() {
        let msg = Self.message(
            kind: "pr_state_changed",
            from: .system,
            to: .member("codex-hooks"),
            body: "PR #1234 went open → ready_for_review"
        )
        #expect(ActivityFeedRow.resolve(msg) == .system(
            worktree: "codex-hooks",
            iconName: "circle.fill",
            body: "PR #1234 went open → ready_for_review",
            timestamp: msg.createdAt
        ))
    }

    @Test("ci_conclusion_changed uses the CI icon.")
    func ciConclusionChanged() {
        let msg = Self.message(
            kind: "ci_conclusion_changed",
            from: .system,
            to: .member("codex-hooks"),
            body: "CI went pending → success"
        )
        guard case let .system(_, iconName, _, _) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected system variant")
            return
        }
        #expect(iconName == "checkmark.seal")
    }

    @Test("merge_state_changed uses the merge icon.")
    func mergeStateChanged() {
        let msg = Self.message(
            kind: "merge_state_changed",
            from: .system,
            to: .member("codex-hooks"),
            body: "Mergeability went unknown → clean"
        )
        guard case let .system(_, iconName, _, _) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected system variant")
            return
        }
        #expect(iconName == "arrow.triangle.merge")
    }

    @Test("Unknown kind falls back to a system row with the info-circle icon.")
    func unknownKindFallback() {
        let msg = Self.message(
            kind: "future_event_kind",
            from: .system,
            to: .member("codex-hooks"),
            body: "something happened"
        )
        guard case let .system(worktree, iconName, body, _) = ActivityFeedRow.resolve(msg) else {
            Issue.record("expected system variant")
            return
        }
        #expect(worktree == "codex-hooks")
        #expect(iconName == "info.circle")
        #expect(body == "something happened")
    }

    // MARK: - Fixtures

    private enum Endpoint {
        case member(String)
        case system
    }

    private static func message(
        kind: String,
        from: Endpoint,
        to: Endpoint,
        priority: TeamInboxPriority = .normal,
        body: String,
        createdAt: Date = Date()
    ) -> TeamInboxMessage {
        TeamInboxMessage(
            id: UUID().uuidString,
            batchID: nil,
            createdAt: createdAt,
            team: "team",
            repoPath: "/repo",
            from: endpoint(from),
            to: endpoint(to),
            priority: priority,
            kind: kind,
            body: body
        )
    }

    private static func endpoint(_ e: Endpoint) -> TeamInboxEndpoint {
        switch e {
        case .member(let name):
            return TeamInboxEndpoint(member: name, worktree: "/repo/\(name)", runtime: nil)
        case .system:
            return .system(repoPath: "/repo")
        }
    }
}
```

- [ ] **Step 2: Run, expect compile failure**

```bash
swift test --filter ActivityFeedRow 2>&1 | tail -10
```

Expected: `ActivityFeedRow` undefined.

- [ ] **Step 3: Implement `ActivityFeedRow.swift`**

Create `Sources/Graftty/Views/TeamActivityLog/ActivityFeedRow.swift`:

```swift
import Foundation
import GrafttyKit

/// Resolved variant for a row in the Team Activity Log. Computed once
/// from a `TeamInboxMessage` by `resolve(_:)`; the view layer renders
/// purely from this value.
enum ActivityFeedRow: Equatable {
    case chat(
        worktree: String,
        recipient: String?,
        body: String,
        timestamp: Date,
        isUrgent: Bool
    )

    case system(
        worktree: String,
        iconName: String,
        body: String,
        timestamp: Date
    )

    case memberJoined(worktree: String)
    case memberLeft(worktree: String)
    case dayDivider(label: String)

    /// Pure mapping. The window's view-model wraps this in a
    /// `RenderedFeedItem` that adds continuation flags and weaves in
    /// `dayDivider` rows between midnight crossings.
    static func resolve(_ message: TeamInboxMessage) -> ActivityFeedRow {
        switch message.kind {
        case "team_member_joined":
            return .memberJoined(worktree: message.to.member)
        case "team_member_left":
            return .memberLeft(worktree: message.to.member)
        case "team_message":
            // Self-message (where from == to) drops the recipient
            // suffix — the header reads as a one-actor entry.
            let recipient: String? = message.from.member == message.to.member
                ? nil
                : message.to.member
            return .chat(
                worktree: message.from.member,
                recipient: recipient,
                body: message.body,
                timestamp: message.createdAt,
                isUrgent: message.priority == .urgent
            )
        default:
            // PR / CI / merge events plus any future kind: scope to
            // the routed-to worktree, render with a kind-specific
            // icon, fall back to info.circle for unknown kinds.
            return .system(
                worktree: message.to.member,
                iconName: Self.iconName(forKind: message.kind),
                body: message.body,
                timestamp: message.createdAt
            )
        }
    }

    private static func iconName(forKind kind: String) -> String {
        switch kind {
        case "pr_state_changed": return "circle.fill"
        case "ci_conclusion_changed": return "checkmark.seal"
        case "merge_state_changed": return "arrow.triangle.merge"
        default: return "info.circle"
        }
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

```bash
swift test --filter ActivityFeedRow 2>&1 | tail -15
```

Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Views/TeamActivityLog/ActivityFeedRow.swift Tests/GrafttyTests/Views/ActivityFeedRowTests.swift
git commit -m "$(cat <<'EOF'
feat(activity-log): ActivityFeedRow variant model + resolve mapping

Pure data layer that maps each TeamInboxMessage to its rendered
variant (chat / system / memberJoined / memberLeft / dayDivider). The
view layer reads from this resolved type rather than from
TeamInboxMessage directly, so row rendering is decoupled from the
inbox schema.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: View-model annotation pass (continuation + day dividers)

**Goal:** Replace the raw `messages: [TeamInboxMessage]` consumption with a `renderedItems: [RenderedFeedItem]` computed property that walks the message list once, calling `ActivityFeedRow.resolve` and weaving in continuation flags + day-divider rows.

**Files:**
- Create: `Sources/Graftty/Views/TeamActivityLog/RenderedFeedItem.swift`
- Modify: `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogViewModel.swift`
- Create: `Tests/GrafttyTests/Views/TeamActivityLogViewModelTests.swift`

- [ ] **Step 1: Create `RenderedFeedItem.swift`**

```swift
import Foundation

/// One renderable entry in the Team Activity Log. Wraps a resolved
/// `ActivityFeedRow` with the small annotations the view layer needs
/// to know about — namely whether it should collapse the header line
/// because the previous row had the same actor within the
/// continuation window.
struct RenderedFeedItem: Equatable, Identifiable {
    let id: String
    let row: ActivityFeedRow
    let isContinuation: Bool

    init(id: String, row: ActivityFeedRow, isContinuation: Bool = false) {
        self.id = id
        self.row = row
        self.isContinuation = isContinuation
    }
}
```

- [ ] **Step 2: Write failing tests for the annotation logic**

Create `Tests/GrafttyTests/Views/TeamActivityLogViewModelTests.swift`:

```swift
import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("TeamActivityLogViewModel.renderedItems — continuation + day dividers")
struct TeamActivityLogViewModelRenderedItemsTests {
    @Test("Two chat messages from the same worktree within 5 minutes: second is a continuation.")
    func continuationWithinWindow() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "first", at: now),
            chatMessage(id: "m2", from: "alice", body: "second", at: now.addingTimeInterval(60)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        #expect(items.count == 2)
        #expect(items[0].isContinuation == false)
        #expect(items[1].isContinuation == true)
    }

    @Test("Two chat messages from the same worktree more than 5 minutes apart: not a continuation.")
    func continuationBeyondWindow() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "first", at: now),
            chatMessage(id: "m2", from: "alice", body: "second", at: now.addingTimeInterval(360)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        #expect(items[1].isContinuation == false)
    }

    @Test("A message from a different worktree breaks the continuation chain.")
    func differentWorktreeBreaksContinuation() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "a", at: now),
            chatMessage(id: "m2", from: "bob", body: "b", at: now.addingTimeInterval(60)),
            chatMessage(id: "m3", from: "alice", body: "c", at: now.addingTimeInterval(90)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        #expect(items[1].isContinuation == false)
        #expect(items[2].isContinuation == false)
    }

    @Test("A memberJoined marker between two same-worktree messages breaks the chain.")
    func markerBreaksContinuation() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "a", at: now),
            joinedMessage(id: "m2", member: "carol", at: now.addingTimeInterval(30)),
            chatMessage(id: "m3", from: "alice", body: "c", at: now.addingTimeInterval(60)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        // Continuation flag is only meaningful on chat/system rows.
        #expect(items[2].isContinuation == false)
    }

    @Test("Two messages straddling local midnight insert a day divider between them.")
    func dayDividerInsertedAtMidnight() {
        let cal = Calendar(identifier: .gregorian)
        // 2026-03-04 23:59:30 local
        let evening = DateComponents(
            calendar: cal, year: 2026, month: 3, day: 4, hour: 23, minute: 59, second: 30
        ).date!
        // 2026-03-05 00:00:30 local
        let morning = DateComponents(
            calendar: cal, year: 2026, month: 3, day: 5, hour: 0, minute: 0, second: 30
        ).date!
        let messages = [
            chatMessage(id: "m1", from: "alice", body: "a", at: evening),
            chatMessage(id: "m2", from: "alice", body: "b", at: morning),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: cal)
        #expect(items.count == 3)
        guard case .dayDivider = items[1].row else {
            Issue.record("expected day-divider variant at index 1, got \(items[1].row)")
            return
        }
        // Day-divider breaks continuation too.
        #expect(items[2].isContinuation == false)
    }

    @Test("System events get continuation collapsing on the same scope-worktree.")
    func systemContinuationByScopedWorktree() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            systemMessage(id: "m1", scope: "codex-hooks", kind: "pr_state_changed",
                          body: "open → ready", at: now),
            systemMessage(id: "m2", scope: "codex-hooks", kind: "ci_conclusion_changed",
                          body: "pending → success", at: now.addingTimeInterval(45)),
        ]
        let items = TeamActivityLogViewModel.renderedItems(from: messages, calendar: .current)
        #expect(items[1].isContinuation == true)
    }

    // MARK: - Fixtures

    private func chatMessage(id: String, from: String, body: String, at: Date) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id, batchID: nil, createdAt: at, team: "team", repoPath: "/repo",
            from: TeamInboxEndpoint(member: from, worktree: "/repo/\(from)", runtime: nil),
            to: TeamInboxEndpoint(member: from, worktree: "/repo/\(from)", runtime: nil),
            priority: .normal, kind: "team_message", body: body
        )
    }

    private func systemMessage(
        id: String, scope: String, kind: String, body: String, at: Date
    ) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id, batchID: nil, createdAt: at, team: "team", repoPath: "/repo",
            from: .system(repoPath: "/repo"),
            to: TeamInboxEndpoint(member: scope, worktree: "/repo/\(scope)", runtime: nil),
            priority: .normal, kind: kind, body: body
        )
    }

    private func joinedMessage(id: String, member: String, at: Date) -> TeamInboxMessage {
        TeamInboxMessage(
            id: id, batchID: nil, createdAt: at, team: "team", repoPath: "/repo",
            from: .system(repoPath: "/repo"),
            to: TeamInboxEndpoint(member: member, worktree: "/repo/\(member)", runtime: nil),
            priority: .normal, kind: "team_member_joined", body: ""
        )
    }
}
```

- [ ] **Step 3: Run, expect compile failure**

```bash
swift test --filter TeamActivityLogViewModelRenderedItemsTests 2>&1 | tail -10
```

Expected: `TeamActivityLogViewModel.renderedItems(from:calendar:)` undefined.

- [ ] **Step 4: Add the static `renderedItems` helper to `TeamActivityLogViewModel`**

Edit `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogViewModel.swift`. Add an extension below the existing class:

```swift
extension TeamActivityLogViewModel {
    /// Continuation window: messages from the same actor within this
    /// duration collapse their headers.
    static let continuationWindow: TimeInterval = 5 * 60

    /// Pure helper extracted for testability. Annotates each message
    /// with a `isContinuation` flag and weaves in `dayDivider` items
    /// at local-midnight crossings.
    static func renderedItems(
        from messages: [TeamInboxMessage],
        calendar: Calendar
    ) -> [RenderedFeedItem] {
        var out: [RenderedFeedItem] = []
        var prev: (actor: String, timestamp: Date, day: Date)?

        for msg in messages {
            let row = ActivityFeedRow.resolve(msg)
            let day = calendar.startOfDay(for: msg.createdAt)

            // Insert day-divider when local-day rolls over.
            if let previous = prev, previous.day != day {
                out.append(.init(
                    id: "day-\(day.timeIntervalSince1970)",
                    row: .dayDivider(label: dayLabel(for: day, calendar: calendar)),
                    isContinuation: false
                ))
                prev = nil  // Day boundary always breaks continuation.
            }

            switch row {
            case let .chat(worktree, _, _, ts, _),
                 let .system(worktree, _, _, ts):
                let isCont = prev.map { p in
                    p.actor == worktree
                        && ts.timeIntervalSince(p.timestamp) <= continuationWindow
                } ?? false
                out.append(.init(id: msg.id, row: row, isContinuation: isCont))
                prev = (worktree, ts, day)

            case .memberJoined, .memberLeft:
                out.append(.init(id: msg.id, row: row, isContinuation: false))
                prev = nil  // Markers reset the continuation chain.

            case .dayDivider:
                // resolve(_:) does not produce dayDivider; only the
                // weaving code above does.
                continue
            }
        }
        return out
    }

    /// Renders a `Date` as the day-divider label: "Today", "Yesterday",
    /// or "MMM d" for older days.
    private static func dayLabel(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "MMM d"
        return formatter.string(from: day)
    }

    /// View-side accessor — wraps the static helper using the system
    /// calendar at the actor's locale.
    var renderedItems: [RenderedFeedItem] {
        Self.renderedItems(from: messages, calendar: .current)
    }
}
```

- [ ] **Step 5: Run tests, expect pass**

```bash
swift test --filter TeamActivityLogViewModelRenderedItemsTests 2>&1 | tail -15
```

Expected: 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/Views/TeamActivityLog/RenderedFeedItem.swift Sources/Graftty/Views/TeamActivityLog/TeamActivityLogViewModel.swift Tests/GrafttyTests/Views/TeamActivityLogViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(activity-log): renderedItems annotates continuation + day dividers

Adds a static `renderedItems(from:calendar:)` helper on
TeamActivityLogViewModel that walks the messages list, annotates
each with an isContinuation flag (same actor, within 5 minutes), and
weaves in dayDivider items at local-midnight crossings. The view
layer now consumes RenderedFeedItem instead of TeamInboxMessage.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: TranscriptRow component

**Goal:** Build the SwiftUI 2-column grid that renders both `chat` and `system` variants — timestamp gutter on the left, header (suppressed on continuation) + body on the right.

**Files:**
- Create: `Sources/Graftty/Views/TeamActivityLog/TranscriptRow.swift`

- [ ] **Step 1: Implement `TranscriptRow.swift`**

```swift
import SwiftUI
import GrafttyKit

/// One transcript-grid row used for both chat and system events.
/// 2-column layout: 60pt timestamp gutter (right-aligned, dim,
/// tabular-nums) + content (header line + body). Header is
/// suppressed when `isContinuation` is true.
struct TranscriptRow: View {
    let row: ActivityFeedRow
    let isContinuation: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            timestampView
            contentView
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var timestampView: some View {
        Text(timestampString)
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: 60, alignment: .trailing)
            .opacity(isContinuation ? 0 : 1)
    }

    @ViewBuilder
    private var contentView: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !isContinuation {
                headerLine
            }
            bodyLine
        }
    }

    @ViewBuilder
    private var headerLine: some View {
        switch row {
        case let .chat(worktree, recipient, _, _, isUrgent):
            HStack(spacing: 6) {
                Text(worktree).fontWeight(.semibold)
                if let recipient {
                    Text("→ \(recipient)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                if isUrgent {
                    Spacer(minLength: 0)
                    Text("URGENT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.red)
                        .tracking(0.5)
                }
            }
        case let .system(worktree, _, _, _):
            Text(worktree).fontWeight(.semibold)
        case .memberJoined, .memberLeft, .dayDivider:
            EmptyView()
        }
    }

    @ViewBuilder
    private var bodyLine: some View {
        switch row {
        case let .chat(_, _, body, _, _):
            Text(body)
                .fixedSize(horizontal: false, vertical: true)
        case let .system(_, iconName, body, _):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, alignment: .center)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .memberJoined, .memberLeft, .dayDivider:
            EmptyView()
        }
    }

    private var timestampString: String {
        let date: Date
        switch row {
        case let .chat(_, _, _, ts, _),
             let .system(_, _, _, ts):
            date = ts
        case .memberJoined, .memberLeft, .dayDivider:
            return ""
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Views/TeamActivityLog/TranscriptRow.swift
git commit -m "$(cat <<'EOF'
feat(activity-log): TranscriptRow — 2-column grid for chat + system

Single SwiftUI view that renders both chat and system variants on the
same 60pt-timestamp + content grid. Header (worktree name, optional
"→ recipient" suffix, URGENT badge) is suppressed when isContinuation
is true; system body uses dim text + leading SF Symbol.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: CenteredMarkerRow + DayDividerRow components

**Goal:** Two small SwiftUI views for the non-grid rows (member join/leave + day boundary).

**Files:**
- Create: `Sources/Graftty/Views/TeamActivityLog/CenteredMarkerRow.swift`
- Create: `Sources/Graftty/Views/TeamActivityLog/DayDividerRow.swift`

- [ ] **Step 1: Implement `CenteredMarkerRow.swift`**

```swift
import SwiftUI

/// Centered horizontal-rule row used for member-joined / member-left
/// events. Distinct visual class from the timestamp-gutter grid: no
/// timestamp shown, the actor's name appears inline with the marker
/// text between two hairline rules.
struct CenteredMarkerRow: View {
    enum Kind: Equatable {
        case joined(worktree: String)
        case left(worktree: String)

        var actor: String {
            switch self {
            case .joined(let worktree), .left(let worktree):
                return worktree
            }
        }

        var trailingText: String {
            switch self {
            case .joined: return "joined the team"
            case .left: return "left the team"
            }
        }
    }

    let kind: Kind

    var body: some View {
        HStack(spacing: 12) {
            Divider()
            HStack(spacing: 4) {
                Text(kind.actor).foregroundStyle(.secondary)
                Text(kind.trailingText).foregroundStyle(.tertiary)
            }
            .font(.system(size: 11))
            .fixedSize()
            Divider()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}
```

- [ ] **Step 2: Implement `DayDividerRow.swift`**

```swift
import SwiftUI

/// Day-boundary marker. Same hairline-rule shape as
/// CenteredMarkerRow, but the centered label is uppercase and
/// styled like a section header — visually distinct so the day
/// rollover doesn't read as a member-join/leave event.
struct DayDividerRow: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Divider()
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.4)
                .padding(.horizontal, 8)
                .fixedSize()
            Divider()
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Views/TeamActivityLog/CenteredMarkerRow.swift Sources/Graftty/Views/TeamActivityLog/DayDividerRow.swift
git commit -m "$(cat <<'EOF'
feat(activity-log): CenteredMarkerRow + DayDividerRow

Two non-grid row variants: CenteredMarkerRow for team_member_joined /
team_member_left (worktree name + trailing text between hairline
rules) and DayDividerRow for local-midnight crossings (uppercase day
label).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: TeamActivityLogRow refactor + TeamActivityLogWindow wiring

**Goal:** Replace the old `Style`-driven row with a thin dispatcher that takes a `RenderedFeedItem` and routes to the right component. Update the window to consume `viewModel.renderedItems`.

**Files:**
- Modify: `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift`
- Modify: `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogWindow.swift`

- [ ] **Step 1: Replace `TeamActivityLogRow` with the new dispatcher**

Overwrite `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift`:

```swift
import SwiftUI
import GrafttyKit

/// Public entry point for one row in the Team Activity Log. Takes a
/// fully-resolved `RenderedFeedItem` and dispatches to the right
/// component (TranscriptRow for chat / system, CenteredMarkerRow for
/// member-joined / member-left, DayDividerRow for day boundaries).
struct TeamActivityLogRow: View {
    let item: RenderedFeedItem

    var body: some View {
        switch item.row {
        case .chat, .system:
            TranscriptRow(row: item.row, isContinuation: item.isContinuation)
        case let .memberJoined(worktree):
            CenteredMarkerRow(kind: .joined(worktree: worktree))
        case let .memberLeft(worktree):
            CenteredMarkerRow(kind: .left(worktree: worktree))
        case let .dayDivider(label):
            DayDividerRow(label: label)
        }
    }
}
```

- [ ] **Step 2: Update `TeamActivityLogWindow` to iterate over `renderedItems`**

In `Sources/Graftty/Views/TeamActivityLog/TeamActivityLogWindow.swift`, replace the `LazyVStack` body and the `.onChange` trigger:

```swift
} else {
    ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.renderedItems) { item in
                    TeamActivityLogRow(item: item).id(item.id)
                }
            }
            .padding(.vertical, 8)
        }
        // Auto-scroll to the newest row whenever the tail-id changes.
        .onChange(of: viewModel.renderedItems.last?.id) { _, newID in
            if let newID {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newID, anchor: .bottom)
                }
            }
        }
    }
}
```

(The outer `VStack`, title-bar `HStack`, and empty-state branch stay unchanged.)

- [ ] **Step 3: Build, expect compile errors from the existing tests**

```bash
swift build 2>&1 | tail -5
swift build --build-tests 2>&1 | tail -10
```

Expected: build passes, tests fail to compile because the old `TeamActivityLogRowTests` reference `TeamActivityLogRow.Style` and the old initializer. Task 6 fixes those.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Views/TeamActivityLog/TeamActivityLogRow.swift Sources/Graftty/Views/TeamActivityLog/TeamActivityLogWindow.swift
git commit -m "$(cat <<'EOF'
refactor(activity-log): wire TeamActivityLogRow to RenderedFeedItem

TeamActivityLogRow becomes a thin dispatcher: TranscriptRow for chat
/ system, CenteredMarkerRow for member events, DayDividerRow for day
boundaries. The window iterates over viewModel.renderedItems instead
of raw messages so continuation flags + day dividers flow through.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Reshape existing tests + final verification

**Goal:** Update `Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift` (XCTest) to assert against the new dispatcher rather than the deleted `Style` enum, then verify the full suite is green.

**Files:**
- Modify: `Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift`

- [ ] **Step 1: Inspect the current file**

```bash
cat Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift
```

- [ ] **Step 2: Replace its body with the new variant assertions**

Overwrite `Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift` so it covers the dispatcher's wiring without referencing the removed `Style` enum:

```swift
import XCTest
import SwiftUI
@testable import Graftty
@testable import GrafttyKit

/// The pure variant-resolution mapping is exercised by the
/// Swift Testing suite at `ActivityFeedRowTests`. This file keeps a
/// thin XCTest fixture asserting that `TeamActivityLogRow` accepts a
/// `RenderedFeedItem` for every `ActivityFeedRow` case without
/// crashing or rejecting any case at the SwiftUI body boundary.
final class TeamActivityLogRowTests: XCTestCase {
    func testRowRendersEveryVariant() {
        let cases: [ActivityFeedRow] = [
            .chat(
                worktree: "alice", recipient: "bob",
                body: "hi", timestamp: Date(), isUrgent: false
            ),
            .chat(
                worktree: "alice", recipient: nil,
                body: "self note", timestamp: Date(), isUrgent: true
            ),
            .system(
                worktree: "codex-hooks", iconName: "circle.fill",
                body: "PR #1234 went open → ready_for_review",
                timestamp: Date()
            ),
            .memberJoined(worktree: "carol"),
            .memberLeft(worktree: "carol"),
            .dayDivider(label: "TODAY"),
        ]

        for row in cases {
            let item = RenderedFeedItem(id: "test", row: row, isContinuation: false)
            // Hosting the SwiftUI view in an NSHostingController forces
            // body evaluation, surfacing any crash/precondition.
            let view = TeamActivityLogRow(item: item)
            let host = NSHostingController(rootView: view)
            XCTAssertNotNil(host.view, "row should render: \(row)")
        }
    }
}
```

- [ ] **Step 3: Run the affected tests**

```bash
swift test --filter "TeamActivityLogRowTests|ActivityFeedRow|TeamActivityLogViewModelRenderedItemsTests" 2>&1 | tail -15
```

Expected: all pass.

- [ ] **Step 4: Run the full suite**

```bash
swift test 2>&1 | tail -3
```

Expected: full suite passes.

- [ ] **Step 5: Commit**

```bash
git add Tests/GrafttyTests/Views/TeamActivityLogRowTests.swift
git commit -m "$(cat <<'EOF'
test(activity-log): reshape XCTest fixture to the new RenderedFeedItem API

The pure variant-resolution mapping is now exercised by the Swift
Testing suite at ActivityFeedRowTests; the XCTest fixture is reduced
to a body-evaluation smoke test that hosts each ActivityFeedRow case
through TeamActivityLogRow and asserts the SwiftUI view boundary
doesn't crash.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: /simplify pass + push

**Goal:** Run `/simplify` over the new and modified files, apply any worthwhile suggestions, then push the branch.

- [ ] **Step 1: Run /simplify**

Invoke the `simplify` skill on the new components and the view-model changes. Apply suggestions that improve clarity or remove duplication.

- [ ] **Step 2: Build and re-run tests**

```bash
swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
scripts/generate-specs.py --check; echo "specs check exit: $?"
```

Expected: build clean, full suite passes, specs check exit 0.

- [ ] **Step 3: Push**

```bash
git push 2>&1 | tail -3
```

Expected: branch pushes cleanly. CI runs.

---

## Self-review checklist

- [x] **Spec coverage:**
    - Visual model two-column grid → Task 3 (TranscriptRow).
    - Centered markers → Task 4 (CenteredMarkerRow).
    - Day dividers → Task 4 (DayDividerRow) + Task 2 (insertion in renderedItems).
    - Header line (worktree, recipient, urgent) → Task 3 + variant model in Task 1.
    - Body styling for chat vs system → Task 3.
    - Variant resolution mapping table → Task 1 (`ActivityFeedRow.resolve`).
    - Continuation collapsing → Task 2 (renderedItems).
    - Day-divider local-time labels (`Today` / `Yesterday` / `MMM d`) → Task 2 (`dayLabel`).
    - Self-message recipient suffix drop → Task 1 chat-resolution branch.
    - Component decomposition (TeamActivityLogRow / TranscriptRow / CenteredMarkerRow / DayDividerRow) → Tasks 3–5.
    - Tests: variant resolution → Task 1; continuation + day divider → Task 2; smoke / dispatcher → Task 6.

- [x] **No placeholders.** Every step has full code or an exact command + expected output.

- [x] **Type consistency.** `ActivityFeedRow` cases used in Task 1 (`.chat`, `.system`, `.memberJoined`, `.memberLeft`, `.dayDivider`) match consumers in Tasks 2, 3, 5, 6. `RenderedFeedItem(id:row:isContinuation:)` initializer used in Tasks 2, 5, 6 matches its definition in Task 2. `TeamActivityLogViewModel.renderedItems(from:calendar:)` static signature in Task 2 matches its callers in Task 5.
