# Agent Chat View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a viewer switch a running Codex agent tab between Chat and Terminal, in both directions, on Mac, iPad, and iPhone, with one conversation behind both views.

**Architecture:** The host joins the tab's existing Codex app-server thread as a second client (`CodexChatSession`) and shares that session among all viewers (`AgentChatHost`). `AgentChatService` binds a tab to its session and applies the display-ownership check. The Mac app calls the service directly; paired viewers reach it over a new SSH subsystem. One SwiftUI view in `GrafttyCommandUI` renders Chat everywhere through an `AgentChatConnection` of three closures.

**Tech Stack:** Swift 6 toolchain (language mode 5, warnings are errors in debug), SwiftUI (macOS 14, iOS 17), Swift Testing, NIOSSH subsystems, Codex app-server JSON-RPC (codex-cli 0.171.0).

**Spec:** `docs/superpowers/specs/2026-11-22-agent-composer-design.md`

## Global Constraints

- Build and test only through `scripts/swiftpm` (`scripts/swiftpm test --filter <Suite>`). Never pass `--skip-build`.
- Confirm a test by its own `passed` line, not by the exit code.
- A switch never emits input, starts a process, or starts a thread. Chat joins with `thread/resume` only.
- Chat is offered only for a Codex agent whose `status` is `running` or `waiting`, with a non-empty `providerSessionID` equal to the registered app-server record's `threadID`, and whose app-server PID still has the recorded start time. Every other tab is Terminal-only.
- Only the display controller may submit or answer. The host Mac may act on a session nobody has claimed. A paired device must match `ownerIdentity == "ssh-device:<deviceID>"`.
- Each viewer stores its own view choice. A choice never changes ownership.
- Host-side code in `GrafttyKit`, `GrafttyProtocol`, and `GrafttyHostAgent` must compile on Linux: no AppKit, no SwiftUI. `CodexAppServerProxyTransport` is the only macOS-only file.
- Requirements use `@spec` EARS titles with no literal quote characters. Promote `AGENT-6.166`–`6.173` out of `Tests/GrafttyTests/Specs/AgentTodo.swift` in the task that makes each one observable, delete the inventory entry in the same commit, and run `scripts/generate-specs.py`.
- User-facing copy uses "Chat" and "Terminal". No internal terms (binding, thread, app-server) appear in copy.
- Status cues are subtle: italic or dimmed text, no saturated color.

## Review Focus

1. **The agent changes conversations in its terminal** (`/new`, `/resume`) while Chat is open. Chat must stop accepting input for the old conversation and attach to the new one when reopened. Test in Task 2.
2. **A Codex tab that never registered an app-server** (started with a flag the wrapper passes through, or outside Graftty). The switch must not appear, and Chat opened by a stale choice must explain and offer Terminal. Test in Tasks 2 and 5.
3. **A viewer reconnects while an approval is pending.** The new snapshot must still carry the request, and an answer after it resolved must be refused. Test in Task 6.
4. **A long conversation.** A snapshot larger than the channel's frame bound must not fail the open. The snapshot carries the most recent 400 rows. Test in Task 6.
5. **An older host without the chat channel.** A paired viewer must see why Chat is unavailable and keep the terminal. Test in Task 7.

One behavior has no automated test: with an input method composing text, Return must commit the composition and not send. Check it by hand on Mac and iPad with a hardware keyboard in Task 5 and Task 9.

---

### Task 1: Commit the session core

Already written and passing in isolation: `Sources/GrafttyProtocol/AgentChat.swift`, `Sources/GrafttyKit/AgentChat/{CodexChatDecoder,CodexChatSession,CodexAppServerProxyTransport,AgentChatHost}.swift`, the long-lived reader change in `Sources/GrafttyKit/Teams/CodexAppServerClient.swift`, and their tests.

**Interfaces:**
- Produces: `AgentChatBinding`, `AgentChatItem`, `AgentChatPendingRequest`, `AgentChatDecision`, `AgentChatTurnState`, `AgentChatCommand(name:description:argumentHint:invocation:)`, `AgentChatSlashQuery(draft:commands:)` with `.matches` and `static draft(choosing:)`, `AgentChatSnapshot`, `AgentChatEvent`, `AgentChatUpdate`, `AgentChatTranscript.apply(_:)`, `AgentChatRejection`, `AgentChatSubmissionResult`, `AgentChatSubmission`, `AgentChatClientMessage`, `AgentChatServerMessage`.
- Produces: `AgentChatEndpoint(binding:socketPath:binaryPath:)`, `AgentChatResolution`, `actor AgentChatHost` with `open(_:) async throws -> (AgentChatSnapshot, AsyncStream<AgentChatUpdate>)`, `submit(_:current:isController:)`, `answer(binding:requestID:decision:current:isController:)`, `close(agentID:)`, and `static resolve(agent:record:appServerIsRunning:)`.

- [ ] **Step 1:** Run `scripts/swiftpm test --filter "AgentChatTranscriptTests|CodexChatDecoderTests|CodexChatSessionTests|AgentChatHostTests"`. Expected: each suite's `passed` line.
- [ ] **Step 2:** Run `scripts/swiftpm test`. Compare any failure against a run on a clean checkout of `main` before attributing it to this branch.
- [ ] **Step 3:** Commit: `feat: add the Codex chat session core`.

### Task 2: Host chat service

**Files:**
- Modify: `Sources/GrafttyProtocol/AgentChat.swift` (receive `AgentChatFeed` and `AgentChatConnection`)
- Modify: `Sources/GrafttyCommandUI/AgentChat/AgentChatModel.swift` (remove those two types)
- Create (written, uncompiled): `Sources/GrafttyKit/AgentChat/AgentChatService.swift`
- Test: `Tests/GrafttyKitTests/AgentChat/AgentChatServiceTests.swift`

**Interfaces:**
- Produces in `GrafttyProtocol`: `enum AgentChatFeed { case attached(AgentChatSnapshot, AsyncStream<AgentChatUpdate>); case unavailable(String) }` and `struct AgentChatConnection { var open: @Sendable () async -> AgentChatFeed; var submit: @Sendable (AgentChatSubmission) async -> AgentChatSubmissionResult; var answer: @Sendable (AgentChatBinding, String, AgentChatDecision) async -> Bool }`.
- Produces: `enum AgentChatViewer { case host; case device(String) }` and `@MainActor final class AgentChatService` with `init(host:storage:ownership:state:)`, `connection(worktreePath:agentID:viewer:) -> AgentChatConnection`, `open(worktreePath:agentID:)`, `submit(_:worktreePath:viewer:)`, `answer(binding:requestID:decision:worktreePath:viewer:)`, and `isAvailable(worktreePath:agentID:) async -> Bool`.

- [ ] **Step 1: Write failing tests** in `AgentChatServiceTests`, using `FakeCodexServer`, a temporary `CodexAppServerSessionStorage`, a real `SessionDisplayOwnershipStore`, and an `AppState` holding one repo, one worktree, and one Codex `ManagedAgent` with a pane session. Use the current process's PID and start time for the record so the liveness check passes.
  - `theHostMacSendsWhenNobodyHasClaimedTheSession`: `submit` as `.host` returns `.accepted`.
  - `aDeviceSendsOnlyWhileItOwnsTheDisplay`: as `.device("phone")` returns `.rejected(.notController)`; after the store records an owner with identity `ssh-device:phone`, returns `.accepted`; `.host` then returns `.rejected(.notController)`.
  - `aConversationChangedInTheTerminalRejectsTheOldDraft` (Review Focus 1): open, change the agent's `providerSessionID` and the record's `threadID` to `thread-2`, submit with the old binding → `.rejected(.staleBinding)`; a second `open` returns a snapshot whose `binding.conversationID == "thread-2"`.
  - `aTabWithNoRegisteredServerIsUnavailable` (Review Focus 2): delete the record → `open` returns `.unavailable`, `isAvailable` is false.
- [ ] **Step 2:** Run `scripts/swiftpm test --filter AgentChatServiceTests`. Expected: compile failure (`AgentChatFeed` not in scope).
- [ ] **Step 3:** Move the two types, add `isAvailable`, and give `AgentChatService` an internal initializer that accepts the `AgentChatHost` built with a fake `connect`.
- [ ] **Step 4:** Run the suite. Expected: `Suite "AgentChatService" passed`.
- [ ] **Step 5:** Commit: `feat: bind agent tabs to their chat session on the host`.

### Task 3: Chat model and view

**Files:**
- Written, uncompiled: `Sources/GrafttyCommandUI/AgentChat/{AgentChatModel,AgentChatView}.swift`, `Tests/GrafttyCommandUITests/AgentChatModelTests.swift`

**Interfaces:**
- Consumes: `AgentChatConnection`, `AgentChatFeed` (Task 2).
- Produces: `@MainActor @Observable final class AgentChatModel` with `snapshot`, `unavailable`, `notice`, `draft`, `slashMatches`, `canSend`, `run(_:)`, `choose(_:)`, `send(_:)`, `answer(_:_:_:)`; and `AgentChatView(model:tabID:connection:showTerminal:)`.

- [ ] **Step 1:** Run `scripts/swiftpm test --filter AgentChatModelTests`; fix compile errors. Expected: 7 tests pass.
- [ ] **Step 2:** Promote `AGENT-6.167` onto `choosingACommandEditsTheDraftAndSendsNothing` and `AGENT-6.166` onto `aCommandUpdateReplacesTheWholeList` in `AgentChatTranscriptTests`; delete both inventory entries; run `scripts/generate-specs.py`.
- [ ] **Step 3:** Commit: `feat: add the shared Chat view`.

### Task 4: Per-viewer view choice

**Files:**
- Modify: `Sources/GrafttyProtocol/WorkspaceLayout.swift`
- Test: `Tests/GrafttyProtocolTests/WorkspaceLayoutChatTests.swift`

**Interfaces:**
- Produces on `WorkspaceLayout<Session>`: `func showsChat(_ session: Session) -> Bool` and `mutating func setShowsChat(_ value: Bool, for session: Session)`, stored as `private(set) var chatSessions: Set<Session>?` (optional so saved layouts without it still decode).

- [ ] **Step 1: Write failing tests:** a new layout shows Terminal for every tab; `setShowsChat(true, for:)` then `showsChat` is true and survives an encode/decode round trip; `remove(_:)` forgets the choice; a layout encoded before this change (JSON without `chatSessions`) decodes; setting a choice leaves `focusedSession` and every group's `selected` unchanged.
- [ ] **Step 2:** Run `scripts/swiftpm test --filter WorkspaceLayoutChatTests`. Expected: compile failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: suite passes.
- [ ] **Step 5:** Commit: `feat: remember each viewer's Chat or Terminal choice per tab`.

### Task 5: Chat / Terminal switch on local Mac tabs

**Files:**
- Modify: `Sources/Graftty/App/AppServices.swift` (own one `AgentChatService`)
- Modify: `Sources/Graftty/GrafttyApp.swift` (inject it into the environment beside `agentWorkspaceRequest`)
- Modify: `Sources/Graftty/Views/WorkspaceContentView.swift` (`groupHeader(for:)`, the `paneContent` closure, `focus(_:activate:)`)
- Test: `Tests/GrafttyTests/Views/WorkspaceChatSwitchTests.swift`

**Interfaces:**
- Consumes: `AgentChatService.connection(worktreePath:agentID:viewer: .host)`, `isAvailable`, `AgentChatView`, `WorkspaceLayout.showsChat`.
- Produces: `EnvironmentValues.agentChatService: AgentChatService?`; in `WorkspaceContentView`, `func setView(_ slot: PaneSlotID, chat: Bool)` and `func showsChat(_ slot: PaneSlotID) -> Bool` (internal, for tests).

Behavior:
- The header shows a segmented `Chat | Terminal` picker at the trailing edge of the tab row when the group's selected tab holds an agent for which `isAvailable` is true. Refresh availability when the selected tab, its agent's status, or its `providerSessionID` changes.
- `paneContent` returns `AgentChatView` for a slot that `showsChat` and is available. The terminal surface stays alive in `TerminalManager`; only its wrapper unmounts.
- One `AgentChatModel` per slot is kept in view state for the life of the worktree view, so a draft survives switching.
- Selecting Chat calls `terminalManager.clearFocus()`. Selecting Terminal calls `onFocusTerminal` and `onActivateTerminal`. Neither writes to the PTY.
- `showTerminal` from the view (including **Answer in Terminal**) calls `setView(slot, chat: false)`.

- [ ] **Step 1: Write failing tests** following the existing `WorkspaceContentView` tests in `Tests/GrafttyTests`:
  - `@spec AGENT-6.169` title on `switchingViewsKeepsTheTabItsSessionAndItsAgent`: after `setView(slot, chat: true)` then `false`, the worktree's `agents`, `paneSessions`, and layout `selected` are equal to before, and the fake terminal manager recorded no input and no new surface.
  - `@spec AGENT-6.172` title on `eachViewKeepsItsOwnUnsentInput`: set the slot's model draft, switch to Terminal and back; the draft is unchanged and the fake connection recorded no submission.
  - `aTabWithoutChatSupportOffersNoSwitch` (Review Focus 2): with a Claude agent, `showsChat` stays false after `setView(slot, chat: true)`.
- [ ] **Step 2:** Run `scripts/swiftpm test --filter WorkspaceChatSwitchTests`. Expected: compile failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: suite passes. Delete the `AGENT-6.169` and `AGENT-6.172` inventory entries and run `scripts/generate-specs.py`.
- [ ] **Step 5:** Launch the app with the `run` skill. In a Codex tab: start a turn in Terminal, switch to Chat mid-output, send from Chat, switch back. Confirm both turns appear once in each view. Trigger an approval, answer it in Terminal, confirm the card leaves Chat. Check Return with an input method composing.
- [ ] **Step 6:** Commit: `feat: switch local Mac agent tabs between Chat and Terminal`.

### Task 6: Host side of the chat channel

**Files:**
- Modify: `Sources/GrafttyProtocol/SSHChannelTypes.swift` (add `agentChat = "agent-chat@graftty.dev"`)
- Create: `Sources/GrafttyHostAgent/SSH/Channels/AgentChatChannelHandler.swift`
- Modify: `Sources/GrafttyHostAgent/SSH/Channels/SubsystemDispatcher.swift` (`framedSubsystems` entry; refuse without a device ID or handler)
- Modify: `Sources/GrafttyHostAgent/SSH/SSHHostSessionConfiguration.swift`, `Sources/Graftty/App/GrafttyApp+WebRTCHostChannels.swift`, `Sources/GrafttyHost/HostService.swift` (supply the opener)
- Modify: `Sources/GrafttyKit/AgentChat/CodexChatSession.swift` (snapshot bound)
- Test: `Tests/GrafttyTests/Remote/SSH/AgentChatChannelHandlerTests.swift`, `Tests/GrafttyKitTests/AgentChat/CodexChatSessionTests.swift`

**Interfaces:**
- Consumes: `AgentChatClientMessage`, `AgentChatServerMessage`, `AgentChatConnection`.
- Produces: `typealias AgentChatOpener = @Sendable (_ deviceID: String, _ worktreePath: String, _ agentID: String) async -> AgentChatConnection`; `AgentChatChannelHandler(deviceID:opener:)`; dispatcher property `agentChatOpener: AgentChatOpener?`.

Behavior: one channel serves one tab. The first frame must be `.open`; the handler replies `.snapshot` or `.unavailable`, then forwards each update as `.update` in order, awaiting write admission as `PanesStateChannelHandler` does. `.submit` replies `.submitted(submissionID:result:)`; `.answer` replies `.answered(requestID:accepted:)`. A frame before `.open`, or a second `.open`, closes the channel. Channel close cancels the update task. `subscribe()` returns at most the last 400 items of the snapshot.

- [ ] **Step 1: Write failing tests** with `EmbeddedChannel`-style setup copied from `TeamChannelHandlerTests`/`PanesStateChannelHandlerTests`:
  - `openingSendsTheSnapshotThenUpdatesInOrder`.
  - `aSubmissionIsAnsweredWithItsOwnID`.
  - `aViewerThatReconnectsStillSeesThePendingRequest` (Review Focus 3): open, push an approval request through the fake server, close the channel, open a second channel → its snapshot's `requests` has the request; after `serverRequest/resolved`, `.answer` replies `accepted: false`.
  - `aFrameBeforeOpenClosesTheChannel`.
  - In `CodexChatSessionTests`, `aLongConversationOpensWithItsLatestRows` (Review Focus 4): history of 450 user messages → `subscribe()` snapshot has 400 items, the last one being the newest.
  - In `SubsystemDispatcherTests`, the subsystem is refused when `agentChatOpener` is nil.
- [ ] **Step 2:** Run the filters. Expected: compile failure.
- [ ] **Step 3:** Implement. On the Mac the opener is `{ deviceID, path, agentID in await MainActor.run { service.connection(worktreePath: path, agentID: agentID, viewer: .device(deviceID)) } }`. The headless host passes the same with its own `AgentChatService`; on Linux `AgentChatHost()` fails to connect and Chat reports unavailable.
- [ ] **Step 4:** Run. Expected: suites pass. Run `scripts/check-linux-test-allowlist.py`.
- [ ] **Step 5:** Commit: `feat: serve agent chat to paired viewers`.

### Task 7: Viewer side of the chat channel

**Files:**
- Create: `Sources/GrafttyRemoteClient/Remote/SSH/Channels/AgentChatChannelClient.swift`
- Modify: `Sources/GrafttyRemoteClient/Remote/RemoteHostLink.swift`, `RemoteHostConnection.swift`
- Test: `Tests/GrafttyRemoteClientTests/Remote/SSH/AgentChatChannelClientTests.swift`

**Interfaces:**
- Produces: `RemoteHostLink.agentChatConnection(worktreePath: String, agentID: String) -> AgentChatConnection`. Each `open` opens a fresh subsystem channel. `submit` and `answer` use the channel of the latest `open` and wait for the reply carrying the same ID through `SSHSubsystemReplyWaiter` (never `scheduleTask`).

- [ ] **Step 1: Write failing tests** over `InMemorySSHLink` with a host-side `AgentChatChannelHandler` and a scripted `AgentChatConnection`:
  - `aRemoteViewerReceivesTheSnapshotAndUpdates`.
  - `aRemoteSubmissionReturnsTheHostsResult` for `.accepted` and `.rejected(.notController)`.
  - `aLostAcknowledgmentIsReportedAsUncertain`: the channel closes after the submit frame is written and before a reply → `.uncertain`. A submit when no channel is open → `.rejected(.unavailable)`.
  - `anOlderHostExplainsWhyChatIsUnavailable` (Review Focus 5): the host refuses the subsystem → `open` returns `.unavailable("Update Graftty on this Mac to use Chat.")`.
- [ ] **Step 2:** Run `scripts/swiftpm test --filter AgentChatChannelClientTests`. Expected: compile failure.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: suite passes. Add an assertion to `aRemoteSubmissionReturnsTheHostsResult` that the host's scripted connection received the exact text `/review the last commit`, promote `AGENT-6.168` onto it, and delete the inventory entry.
- [ ] **Step 5:** Commit: `feat: reach agent chat from paired viewers`.

### Task 8: Mac remote viewer

**Files:**
- Modify: `Sources/GrafttyProtocol/AgentSessionInfo.swift` (add `chatAvailable: Bool?`), `Sources/GrafttyKit/Model/WorktreePanes+Projection.swift` (set it from the same rule as `AgentChatHost.resolve`, without reading the record: Codex, running or waiting, non-empty conversation ID)
- Modify: `Sources/Graftty/Views/RemoteWorkspaceContentView.swift`, `RemoteWorktreeViewerController.swift`, `Sources/Graftty/Remote/MacToMac/RemoteMacsModel.swift`
- Test: `Tests/GrafttyProtocolTests/AgentSessionInfoTests.swift`, `Tests/GrafttyTests/Views/RemoteWorkspaceChatSwitchTests.swift`

**Interfaces:**
- Consumes: `RemoteHostLink.agentChatConnection`, `AgentChatView`, `WorkspaceLayout.showsChat`.
- Produces: `RemoteMacsModel.agentChatConnection(hostID:worktreePath:agentID:) -> AgentChatConnection`.

- [ ] **Step 1: Write failing tests:** `chatAvailable` decodes as nil from an older host and round-trips; the remote view offers the switch only when `chatAvailable == true`; `@spec AGENT-6.173` title on `choosingAViewChangesOnlyThisViewer`: setting the choice writes only this viewer's stored layout and sends no pane-control or ownership request through the fake link.
- [ ] **Step 2–4:** Run, implement with the same header control and content swap as Task 5, run.
- [ ] **Step 5:** Commit: `feat: switch remote Mac agent tabs between Chat and Terminal`.

### Task 9: iPad and iPhone

**Files:**
- Modify: `Sources/GrafttyMobileKit/UI/MultiPaneDetailView.swift` (`tabHeader(_:)`, `render`), `Sources/GrafttyMobileKit/Terminal/SingleSessionView.swift` (content switch near the completed-agent branch, `compactFloatingHeader`), `Sources/GrafttyMobileKit/UI/CompactAgentBar.swift`, `Sources/GrafttyMobileKit/Remote/RemoteConnectionCoordinator.swift`
- Test: `Tests/GrafttyMobileKitTests/AgentChatSwitchTests.swift`

**Interfaces:**
- Consumes: `RemoteHostLink.agentChatConnection`, `AgentChatView`, `AgentSessionInfo.chatAvailable`.
- Produces: `RemoteConnectionCoordinator.agentChatConnection(worktreePath:agentID:)`. iPad stores the choice in `MobileWorkspaceStore`'s layout. iPhone stores it in UserDefaults under `"workspace.iphone.chat.<host>.<path>.<sessionName>"`.

Behavior: on compact width the switch sits in the floating header, above the keyboard. The retained terminal pane (`RetainedMobilePane`) stays attached while Chat shows. Switching to Terminal applies the normal size rules for this viewer; switching to Chat sends no resize.

- [ ] **Step 1: Write failing tests:** the choice persists per tab on each idiom; switching to Chat issues no resize and no input through the fake session client; a host without `chatAvailable` shows no switch.
- [ ] **Step 2–4:** Run with `scripts/swiftpm test --filter AgentChatSwitchTests`, implement, run. Then compile the iOS target (`xcodegen generate` in `Apps/GrafttyMobile`, then the simulator build command from project memory), because `swift test` does not compile UIKit-guarded code.
- [ ] **Step 5:** Check by hand in the simulator: switch above the keyboard, Return adds a line on the software keyboard, Send submits, VoiceOver reads the highlighted command.
- [ ] **Step 6:** Commit: `feat: switch agent tabs between Chat and Terminal on iPhone and iPad`.

### Task 10: Remaining requirements and review

- [ ] **Step 1:** Promote `AGENT-6.170` onto `aTurnEnteredInTheTerminalAppearsOnceForEverySubscriber` and `AGENT-6.171` onto `anApprovalIsAnsweredOnceAndClearedWhenTheProviderResolvesIt` in `CodexChatSessionTests`. `AgentTodo.swift` must hold none of `6.166`–`6.173`. Run `scripts/generate-specs.py --check`.
- [ ] **Step 2:** Update the design document's build order to mark each stage done.
- [ ] **Step 3:** Run `scripts/swiftpm test`, then `/code-review xhigh --fix`, then `/simplify`.
- [ ] **Step 4:** Open the PR and confirm CI, including `ios-build-and-test` and the Linux job.
