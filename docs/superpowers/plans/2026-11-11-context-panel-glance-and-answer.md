# Context Panel: Glance and Answer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Context panel answer "what is this agent asking me, and what should I say?" at a glance, and let the user answer from it on Mac and mobile.

**Architecture:** Agents may attach 2–4 `options` to a question in their Attention recap. The shared `WorktreeContextPanel` (GrafttyCommandUI, used by the Mac inspector and the mobile drawer) becomes a pinned title bar over one bottom-anchored scroll ending in the present state and an ask block. Tapping an option or sending a reply issues a new `answerRequest` management request; the host types the text into the stopped agent's pane through the same send-pane path Explain more uses.

**Tech Stack:** Swift 6, SwiftUI (macOS + iOS), Swift Testing, SwiftPM via `scripts/swiftpm`.

**Spec:** `docs/superpowers/specs/2026-11-11-context-panel-glance-and-answer-design.md`

## Global Constraints

- Every new or changed requirement is a `@spec` in a Swift Testing title using EARS phrasing; regenerate `SPECS.md` with `scripts/generate-specs.py`; no literal `\"` in titles.
- New CONTEXT IDs start at CONTEXT-58; new AGENT IDs start at AGENT-3.49.
- `options`: 2 to 4 entries; `label` required, ≤ 40 characters, distinct; `cost` optional, ≤ 80; `suggested` on at most one; only valid with `need`.
- Existing recap length limits do not change.
- `TeamHookRenderer.recapGuidance` must end no longer than 1269 characters (its length today).
- One accent colour (orange, as today's "Waiting for you"), used only for "Waiting for you".
- Timeline order stays oldest to newest.
- Build and test with `scripts/swiftpm`; never `--skip-build`. Mobile changes also need the iOS compile (see memory: macOS `swift test` misses UIKit code).
- This is a public repository: no private data in fixtures or commits.

## Review Focus

1. A question that changes or clears between drawing and tapping → the host refuses with "This request has changed or already cleared." and the panel shows it. Test in Task 3.
2. A reply containing newlines → sent as one line (newlines become spaces) so Enter submits once. Test in Task 3.
3. A harness-owned prompt (provider permission/question) → no options, no reply field; "Answer in the agent's terminal". Test in Task 5.
4. A recap with `options` but no `need`, or with two suggested options → rejected with the options-specific CLI message. Test in Task 1.
5. An older host that cannot decode `answer_request` → "Update Graftty on this Mac to answer from here." Test in Task 5 (response mapping).

---

### Task 1: Recap `options`

**Files:**
- Modify: `Sources/GrafttyProtocol/SidebarNavigation.swift` (`AttentionRecap`)
- Modify: `Sources/GrafttyCLI/Attention.swift` (`decodeRecap`)
- Modify: `Sources/GrafttyCommandUI/SidebarWorktreeContext.swift`
- Test: `Tests/GrafttyProtocolTests/AttentionRecapOptionsTests.swift` (new), `Tests/GrafttyCLITests/` existing attention decode tests

**Interfaces:**
- Produces: `AttentionRecap.Option { label: String; cost: String?; suggested: Bool? }` (Codable, Sendable, Hashable); `AttentionRecap.options: [Option]?`; `AttentionRecap.hasValidOptions: Bool` (true when nil); `isValid` includes it.
- Produces: `SidebarWorktreeContext.questionOptions: [AttentionRecap.Option]` (empty unless the question came from a stopped turn) and `questionOccurrence: SidebarAttentionOccurrence?` (`questionItem?.occurrence`).

- [ ] **Step 1: Failing tests** — `@Test("@spec AGENT-3.49: When an agent reports a question with options, the application shall accept two to four options with distinct labels of at most 40 characters, optional costs of at most 80 characters, and at most one suggested option, reject options without a question, and decode older recaps without options.")` asserting: valid 2-option recap round-trips through JSON; 1 and 5 options invalid; 41-char label invalid; 81-char cost invalid; duplicate labels invalid; two `suggested: true` invalid; options without `need` invalid; JSON without `options` decodes with `options == nil`. A CLI test: `decodeRecap` of options-without-need throws a message containing `"options"`. A context test: a stopped-turn recap with options yields `questionOptions.count == 2`; a provider request yields `[]`.
- [ ] **Step 2: Run** `scripts/swiftpm test --filter AttentionRecapOptions` — expect compile failure / FAIL.
- [ ] **Step 3: Implement.** Add the field to `init` as a defaulted parameter. In `decodeRecap`, check `hasValidOptions` before the generic `isValid` guard and throw `"\"options\" needs a \"need\" and 2 to 4 choices, each with a distinct label of at most 40 characters, an optional cost of at most 80, and at most one suggested"`. Add the two context properties.
- [ ] **Step 4: Run** the filter again — PASS.
- [ ] **Step 5: Commit** `Accept answer options in agent recaps`.

### Task 2: Report instructions

**Files:**
- Modify: `Sources/GrafttyKit/Teams/TeamHookRenderer.swift` (`recapGuidance`)
- Modify: `Sources/GrafttyKit/AgentPlugins/{claude,codex}/plugins/graftty/skills/graftty/SKILL.md`
- Modify: `Sources/GrafttyCLI/Attention.swift` (`--stdin` help and decode error list `options`)
- Test: `Tests/GrafttyKitTests/Teams/AskCatchUpGuidanceTests.swift`

- [ ] **Step 1: Rewrite AGENT-3.41's suite title** to: `@spec AGENT-3.41: When the application renders agent recap guidance, it shall ask for a one-sentence plain completed state, short plain history headlines, and, for a question with clear choices, options with a few words of cost each in place of a catch-up paragraph, without lengthening the per-turn guidance.` Tests: `recapGuidance` contains `` `options` `` and does not contain `Explain more`; `recapGuidance.count <= 1269`; each skill contains `- Optional \`options\`` once, an example with `"options"`, no `Explain more`, and keeps `- Optional \`catchUp\`` once.
- [ ] **Step 2: Run** `scripts/swiftpm test --filter AskCatchUpGuidance` — FAIL.
- [ ] **Step 3: Edit text.** Skill: `completed` → one plain sentence on where things stand; `historyEntry.headline` → a short plain phrase (about 60 characters), with hashes, job counts and internal names moved to `detail`; `title` bad/good example; new `- Optional \`options\`` bullet with the limits above and an example `"need":"Hold 0.8.0 or ship it?","options":[{"label":"Hold","cost":"Sidebar fix waits a few days","suggested":true},{"label":"Ship","cost":"27.0.1 users may still crash"}]`; tell agents to end the turn with options instead of the harness's own picker; `catchUp` becomes one or two optional sentences of background, required only when no options are given; delete the Explain more bullet. Hook: replace the need/catchUp/Explain-more sentences with one sentence asking for `need` with `options` (a few words of cost each, one suggested) when choices are clear, otherwise `need` with a short `catchUp`.
- [ ] **Step 4: Run** the filter plus `--filter TeamHookRenderer` and `--filter WorktreeDrawingGuidance` and `--filter InstructionHookDelivery` — PASS (update any assertion that pinned the removed Explain-more sentence).
- [ ] **Step 5: Commit** `Ask agents for short reports and answer options`.

### Task 3: Answer delivery on the host

**Files:**
- Modify: `Sources/GrafttyProtocol/WorktreeManagementEnvelope.swift`
- Modify: `Sources/GrafttyKit/Notification/AttentionExplainDelivery.swift`
- Modify: `Sources/GrafttyKit/Host/HeadlessHostControl.swift`, `Sources/Graftty/App/GrafttyApp+WebRTCHostChannels.swift`, `Sources/Graftty/Remote/MacToMac/RemoteMacsModel.swift`
- Test: `Tests/GrafttyKitTests/Notification/AttentionExplainDeliveryTests.swift`, envelope round-trip test beside existing ones

**Interfaces:**
- Produces: `WorktreeManagementRequest.answerRequest(worktreeID: String, paneID: String, occurrence: SidebarAttentionOccurrence, text: String)`, wire type `"answer_request"`, worktree-scoped for relay checks.
- Produces: `AttentionAnswerDelivery.deliver(worktreeID:paneID:occurrence:text:platform:) async -> WorktreeManagementResponse` (`@MainActor`), in the same file as explain delivery, sharing its pane lookup and send.

- [ ] **Step 1: Failing tests** — `@Test("@spec AGENT-3.50: When a client answers a stopped agent's question, the host shall type the answer as one line into that agent's pane and submit it, and shall refuse when the question has changed or cleared, the pane is gone, or the pane is waiting at its harness's own prompt.")` using the existing explain-delivery test platform fake: success sends `sendPane(... text: "Hold", pressEnter: true)`; `"a\nb"` sends `"a b"`; mismatched occurrence returns `.error(code: "occurrence-changed", message: "This request has changed or already cleared.", …)`; empty text returns an error; missing pane returns `not-found`. Envelope test: `answerRequest` encodes and decodes losslessly.
- [ ] **Step 2: Run** `scripts/swiftpm test --filter AttentionExplainDelivery` — FAIL.
- [ ] **Step 3: Implement.** The occurrence matches when `worktree.unseenAgentStop?.occurrence == occurrence` and its `question != nil`. Normalise text: newlines → spaces, trim, cap 2000 characters. Route the request in the three host/relay switches exactly as `explainRequest` is routed.
- [ ] **Step 4: Run** the filter — PASS.
- [ ] **Step 5: Commit** `Let clients answer a stopped agent's question`.

### Task 4: Panel layout

**Files:**
- Modify: `Sources/GrafttyCommandUI/WorktreeContextPanel.swift`, `TimelineFollow.swift`, `WorktreeHistoryContent.swift`
- Create: `Sources/GrafttyCommandUI/WorktreeContextNow.swift` (present state, details disclosure)
- Modify: `Sources/GrafttyMobileKit/UI/MobileWorktreeContextDrawer.swift` (drop `collapsesBrief`)
- Test: `Tests/GrafttyCommandUITests/WorktreeContextPanelTests.swift`, `TimelineFollowTests.swift`

- [ ] **Step 1: Rewrite tests.** Replace CONTEXT-27's title with `@spec CONTEXT-27: When Context is opened on Mac or mobile, the application shall show the worktree's title in a pinned header in place of a static Context label, and every other section in one scroll that opens at its latest content.` asserting exactly one `NSScrollView`, opened at its bottom, and the header contains the brief title text (accessibility identifier `worktree.context.title`). Add `@spec CONTEXT-58: While Context shows a brief on Mac or mobile, the application shall end the scroll with the present state, its completed sentence above a dimmer Next line, after the timeline.` and `@spec CONTEXT-59: When the user activates the Context title on Mac or mobile, the application shall show or hide the worktree path, purpose, decisions and completed agents above the timeline, hidden by default.` and `@spec CONTEXT-60: While Context history shows an explicit history entry on Mac or mobile, the application shall show its headline on one row with its time and reveal its detail and decisions only when the row is activated.` Delete CONTEXT-29, CONTEXT-46 and CONTEXT-54 tests and the collapse tests; keep CONTEXT-28 and the worktree-switch test.
- [ ] **Step 2: Run** `scripts/swiftpm test --filter WorktreeContextPanel` — FAIL.
- [ ] **Step 3: Implement.** Header: title button (`lineLimit(2)`, `.headline`, chevron), host label, close. Scroll content, top to bottom: details (when expanded; completed agents without their inner `ScrollView`), `WorktreeContextHistory`, hairline, present state (`completed` `.body` medium in foreground; `next` `.callout` secondary prefixed by a caption "Next"), empty state text when no brief, ask block slot (Task 5), status line (`Agent working · Updated <relative>` italic caption secondary), latest anchor. Remove `CappedBriefLayout`, the resize divider, brief height state, and `TimelineFollow`'s collapse API. In `WorktreeHistoryContent.eventRow`, explicit entries (`event.isExplicitEntry`) render headline `.callout` + time; detail and decisions shown on tap via `expandedGroups`.
- [ ] **Step 4: Run** `scripts/swiftpm test --filter "WorktreeContextPanel|TimelineFollow|WorktreeHistoryContent"` — PASS; fix other CONTEXT tests that referenced removed identifiers.
- [ ] **Step 5: Commit** `Make Context one glanceable column`.

### Task 5: Ask block and client wiring

**Files:**
- Create: `Sources/GrafttyCommandUI/WorktreeContextAsk.swift`
- Modify: `Sources/GrafttyCommandUI/WorktreeContextActions.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`, `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`, `Sources/GrafttyMobileKit/UI/MobileWorktreeContextDrawer.swift`
- Test: `Tests/GrafttyCommandUITests/WorktreeContextAskTests.swift` (new)

**Interfaces:**
- Consumes: Task 1 context properties; Task 3 request.
- Produces: `struct AttentionAnswer { worktree: WorktreePanes; paneID: String; occurrence: SidebarAttentionOccurrence; text: String }`; `WorktreeContextActions.answerQuestion: (@MainActor (AttentionAnswer) async -> String?)?` (nil result = sent, string = failure message); `WorktreeContextAskModel` (`@MainActor @Observable`) with `state: idle | sending | sent | failed(String)`, reset when the occurrence changes; `static func message(for: WorktreeManagementResponse) -> String?` mapping `.ok` → nil, `malformed-request` → "Update Graftty on this Mac to answer from here.", other errors → their message.

- [ ] **Step 1: Failing tests** — `@spec CONTEXT-61: While an agent has stopped with a question, Context on Mac and mobile shall end with the question under a Waiting for you label, one row per reported option showing its cost and marking the suggested one, a Why this is being asked disclosure for the catch-up, and a reply field, and shall offer only Answer in the agent's terminal for a prompt the harness owns.` (model-level: which affordances are present for stopped vs provider question). `@spec CONTEXT-62: When the user picks an option or sends a reply in Context, the application shall send it to the asking agent, disable the question while sending, show Sent until the question changes, and show the host's message and re-enable on failure.` (drive the model with a fake answer closure; assert states and that the old-host error maps to the update message).
- [ ] **Step 2: Run** `scripts/swiftpm test --filter WorktreeContextAsk` — FAIL.
- [ ] **Step 3: Implement** the view and model; panel places it before the status line. Mac: `GrafttyApp` provides `\.localAttentionAnswer` running `AttentionAnswerDelivery.deliver` on a `SocketRequestRouter`; `MainWindow` builds `answerQuestion` from it, or from `remoteMacsModel.sendWorktreeManagement` when a remote Mac is selected. Mobile: `RootView` sends through `feed.provider(for:)` + `RelayedWorktreeManagementClient.send`; the drawer forwards `answerQuestion` in `navigationActions`.
- [ ] **Step 4: Run** the filter, then the iOS compile — PASS.
- [ ] **Step 5: Commit** `Answer agent questions from Context`.

### Task 6: Inspector below the tab row

**Files:**
- Modify: `Sources/Graftty/Views/MainWindowDetailLayout.swift`, `Sources/Graftty/Views/MainWindow.swift`
- Test: `Tests/GrafttyTests/Views/MainWindowDetailLayoutTests.swift`

- [ ] **Step 1: Rewrite CONTEXT-55** to `@spec CONTEXT-55: While Context is open on desktop, the application shall reserve its width alongside the terminal below the breadcrumb, and below the tab row beside a workspace, shrink the terminal when it opens, and restore that width when it closes without overlaying terminal content.` Add the argument `inset: [0, 36]` and assert `inspector.minY >= 30 + inset` and height `670 - inset`.
- [ ] **Step 2: Run** `scripts/swiftpm test --filter MainWindowDetailLayout` — FAIL.
- [ ] **Step 3: Implement** `MainWindowDetailLayout(inspectorTopInset: CGFloat = 0, …)` applying `.padding(.top, inspectorTopInset)` to the inspector; `MainWindow` passes `WorktreeHeaderWash.tabRowHeight` when local or remote workspace content is shown.
- [ ] **Step 4: Run** the filter — PASS.
- [ ] **Step 5: Commit** `Start the Context panel below the tab row`.

### Task 7: Finish

- [ ] Run `scripts/generate-specs.py`; commit `SPECS.md`.
- [ ] Run `scripts/swiftpm test`; confirm each new spec test's own pass line.
- [ ] Run `/code-review xhigh --fix`, re-run tests.
- [ ] Push and open the PR; confirm CI.
