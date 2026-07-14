# iPad Active Workstation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make iPad regular-width Graftty behave like an active workstation: selection focuses and takes ownership, Ctrl+Tab switches worktrees, split controls are available, trackpad scroll works, Add Worktree submits on Return, and the sidebar visually matches the Mac background model.

**Architecture:** Reuse existing protocol and state seams. Expand `PaneControlRequest.SplitDirection` from coarse axes to semantic directions, then route iPad UI through the existing pane-control channel and host `splitPane` implementation. Keep iPhone compact navigation unchanged; all auto-ownership and Ctrl+Tab behavior lives in the iPad regular-width path.

**Tech Stack:** Swift 5.10, SwiftUI, UIKit, Swift Testing, XCTest, NIO SSH pane-control channel, GrafttyProtocol wire models.

---

## File Structure

- `Sources/GrafttyProtocol/PaneControlEnvelope.swift`: widen pane-control split direction to `right/down/left/up`, with decode compatibility for legacy `horizontal/vertical`.
- `Sources/Graftty/GrafttyApp.swift`: map semantic pane-control split directions to existing `PaneSplit` values.
- `Sources/GrafttyMobileKit/Remote/PaneControlClient.swift`: keep typed split facade, now accepting semantic directions.
- `Sources/GrafttyMobileKit/App/IPadAppState.swift`: add iPad focus/ownership request counters and latest sidebar snapshot storage.
- `Sources/GrafttyMobileKit/App/IPadRootLayout.swift`: add active-selection helpers, Ctrl+Tab keyboard actions, pane-control environment construction, split toolbar, and background model.
- `Sources/GrafttyMobileKit/App/RootView.swift`: let iPad detail `SingleSessionView` receive external focus and ownership request counters.
- `Sources/GrafttyMobileKit/UI/WorktreeListContent.swift`: tighten iPad row trailing insets via constants.
- `Sources/GrafttyMobileKit/UI/IPadWorktreeNavigation.swift` (new): pure attention-first navigation over `[WorktreePanes]`, mirroring Mac `AppState.nextWorktreePath(forward:)`.
- `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift`: configure terminal pan recognizers to accept indirect trackpad scroll.
- `Sources/GrafttyMobileKit/UI/AddWorktreeSheetView.swift`: add hardware Return/default Create submission.
- Tests:
  - `Tests/GrafttyProtocolTests/PaneControlEnvelopeTests.swift`
  - `Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift`
  - `Tests/GrafttyTests/Remote/SSH/PaneControlChannelHandlerTests.swift`
  - `Tests/GrafttyMobileKitTests/Remote/SSH/SSHPanesAndControlLoopbackTests.swift`
  - `Tests/GrafttyMobileKitTests/App/IPadAppStateTests.swift`
  - `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift`
  - `Tests/GrafttyMobileKitTests/UI/IPadWorktreeNavigationTests.swift` (new)
  - `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`
  - `Tests/GrafttyTests/Specs/IpadTodo.swift`

## Task 1: Semantic Four-Direction Pane-Control Protocol

**Files:**
- Modify: `Sources/GrafttyProtocol/PaneControlEnvelope.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/GrafttyMobileKit/Remote/PaneControlClient.swift`
- Modify: `Tests/GrafttyProtocolTests/PaneControlEnvelopeTests.swift`
- Modify: `Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift`
- Modify: `Tests/GrafttyTests/Remote/SSH/PaneControlChannelHandlerTests.swift`
- Modify: `Tests/GrafttyMobileKitTests/Remote/SSH/SSHPanesAndControlLoopbackTests.swift`

- [ ] **Step 1: Write failing protocol tests**

Update the existing `Tests/GrafttyProtocolTests/PaneControlEnvelopeTests.swift`:

```swift
import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("PaneControlRequest wire format")
struct PaneControlEnvelopeTests {
    @Test("@spec REMOTE-7.7: Pane-control split requests shall encode semantic directions right/down/left/up, and legacy horizontal/vertical split directions shall decode as right/down for compatibility.")
    func semanticDirectionsAndLegacyAxes() throws {
        let request = PaneControlRequest.split(target: "s", direction: .left)
        let encoded = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["direction"] as? String == "left")

        let legacyHorizontal = #"{"type":"split","target":"s","direction":"horizontal"}"#.data(using: .utf8)!
        let legacyVertical = #"{"type":"split","target":"s","direction":"vertical"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(PaneControlRequest.self, from: legacyHorizontal) == .split(target: "s", direction: .right))
        #expect(try JSONDecoder().decode(PaneControlRequest.self, from: legacyVertical) == .split(target: "s", direction: .down))
    }

    @Test func allSemanticDirectionsRoundTrip() throws {
        for direction in PaneControlRequest.SplitDirection.allCases {
            let original = PaneControlRequest.split(target: "session", direction: direction)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(PaneControlRequest.self, from: data) == original)
        }
    }
}
```

Update `PaneControlClientTests.splitForwardsAndReturnsOk` to use `.right`, and add one assertion for `.left`.

Update `PaneControlChannelHandlerTests.testDecodesAndDispatchesSplitRequest` to send `.down`, and add a second request/test for `.up`. Also update the `REMOTE-7.2` spec text in that file from `<axis>` / after-only language to semantic `right/down/left/up` behavior:

```swift
@spec REMOTE-7.2: When the host receives a `pane_control` request `{"type":"split","target":<sessionName>,"direction":<right|down|left|up>}`, the host shall replace the leaf whose `sessionName == target` with a new split node placed to the requested side of the original leaf, applied on the main actor, and reply `{"ok":true}` on success.
```

If there is a lightweight existing host-side seam around `GrafttyApp.splitPane` or its pane-control mutator, add one assertion that `.left` or `.up` uses before-placement rather than the old after-only insertion. If no such seam exists without launching app state, rely on the mapping test plus the existing `SplitTree.insertingBefore` coverage and note that in the task commit message.

Update `SSHPanesAndControlLoopbackTests` to use the semantic direction that matches the existing assertion (`.down` for the current vertical split case).

Before finishing this task, run this targeted grep and migrate every `PaneControlRequest.SplitDirection` call site that still references the old axis cases:

```bash
rg -n 'PaneControlRequest|pane_control|direction: \.(horizontal|vertical)' Sources Tests --glob '*.swift'
```

Do not migrate `SplitTree.SplitDirection`, `PaneLayoutNode.Split`, or terminal split-layout tests that still legitimately use `.horizontal` / `.vertical` for pane geometry.

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter PaneControlEnvelopeTests
swift test --filter PaneControlClientTests
swift test --filter PaneControlChannelHandlerTests
swift test --filter SSHPanesAndControlLoopbackTests
```

Expected: compile failures because `.left/.right/.up/.down` do not exist.

- [ ] **Step 3: Implement semantic direction enum**

In `PaneControlEnvelope.swift`, replace the nested enum with semantic cases and custom decode:

```swift
public enum SplitDirection: String, Sendable, CaseIterable {
    case right
    case down
    case left
    case up
}

extension PaneControlRequest.SplitDirection: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "right": self = .right
        case "down": self = .down
        case "left": self = .left
        case "up": self = .up
        case "horizontal": self = .right
        case "vertical": self = .down
        default:
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "unknown PaneControlRequest.SplitDirection: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
```

In `GrafttyApp.swift` pane-control mutator, replace axis mapping with semantic mapping:

```swift
let split: PaneSplit
switch direction {
case .right: split = .right
case .down: split = .down
case .left: split = .left
case .up: split = .up
}
```

- [ ] **Step 4: Run targeted tests to verify GREEN**

Run:

```bash
swift test --filter PaneControlEnvelopeTests
swift test --filter PaneControlClientTests
swift test --filter PaneControlChannelHandlerTests
swift test --filter SSHPanesAndControlLoopbackTests
```

Expected: all targeted tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyProtocol/PaneControlEnvelope.swift Sources/Graftty/GrafttyApp.swift Sources/GrafttyMobileKit/Remote/PaneControlClient.swift Tests/GrafttyProtocolTests/PaneControlEnvelopeTests.swift Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift Tests/GrafttyTests/Remote/SSH/PaneControlChannelHandlerTests.swift Tests/GrafttyMobileKitTests/Remote/SSH/SSHPanesAndControlLoopbackTests.swift
git commit -m "feat(ipad): support four pane split directions"
```

## Task 2: iPad Active Selection, Focus Requests, Ownership Requests, and Ctrl+Tab

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/IPadAppState.swift`
- Modify: `Sources/GrafttyMobileKit/App/IPadRootLayout.swift`
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`
- Create: `Sources/GrafttyMobileKit/UI/IPadWorktreeNavigation.swift`
- Modify: `Tests/GrafttyMobileKitTests/App/IPadAppStateTests.swift`
- Modify: `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift`
- Create: `Tests/GrafttyMobileKitTests/UI/IPadWorktreeNavigationTests.swift`

- [ ] **Step 1: Write failing pure navigation tests**

Create `Tests/GrafttyMobileKitTests/UI/IPadWorktreeNavigationTests.swift`:

```swift
#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("iPad worktree navigation")
struct IPadWorktreeNavigationTests {
    private func wt(_ path: String, attention: Bool = false, state: WorktreeWireState = .running) -> WorktreePanes {
        WorktreePanes(
            path: path,
            displayName: path,
            repoDisplayName: "repo",
            displayBranch: path,
            state: state,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: attention ? "needs input" : nil,
            layout: nil
        )
    }

    @Test("@spec IPAD-8.1: When the user presses next_tab on iPad and another selectable worktree has attention, the application shall select the next attention-carrying worktree in cyclic sidebar order.")
    func nextTabPrefersAttention() {
        #expect(IPadWorktreeNavigation.nextPath(
            in: [wt("/a"), wt("/b"), wt("/c", attention: true)],
            selectedPath: "/a",
            forward: true
        ) == "/c")
    }

    @Test("@spec IPAD-8.2: When no other iPad worktree has attention, next_tab and previous_tab shall cycle through selectable worktrees in sidebar order.")
    func cyclesWhenNoAttention() {
        let list = [wt("/a"), wt("/b"), wt("/c")]
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: "/a", forward: true) == "/b")
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: "/a", forward: false) == "/c")
    }

    @Test("@spec IPAD-8.3: iPad worktree navigation shall skip stale, creating, and deleting worktrees even when they carry attention.")
    func skipsNonSelectable() {
        let list = [wt("/a"), wt("/stale", attention: true, state: .stale), wt("/c")]
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: "/a", forward: true) == "/c")
    }

    @Test("@spec IPAD-8.6: When no current iPad worktree is selected, forward Ctrl+Tab shall start before the first selectable worktree and reverse Ctrl+Shift+Tab shall start after the last selectable worktree.")
    func startsAtEdgesWhenNothingSelected() {
        let list = [wt("/a"), wt("/b"), wt("/c")]
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: nil, forward: true) == "/a")
        #expect(IPadWorktreeNavigation.nextPath(in: list, selectedPath: nil, forward: false) == "/c")
    }

    @Test("@spec IPAD-8.4: Pane-scoped attention shall count for iPad attention-first worktree navigation, excluding the currently selected worktree.")
    func paneAttentionCountsAndCurrentExcluded() {
        let paneAttention = WorktreePanes(
            path: "/b",
            displayName: "b",
            repoDisplayName: "repo",
            displayBranch: "b",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: .leaf(sessionName: "s", title: "shell", attentionText: "ping", isBusy: false, attentionSource: .agentStop)
        )
        #expect(IPadWorktreeNavigation.nextPath(in: [wt("/a", attention: true), paneAttention], selectedPath: "/a", forward: true) == "/b")
    }
}
#endif
```

Add failing tests to `IPadAppStateTests` for new counters:

```swift
@Test("requesting active terminal focus and ownership increments separate counters")
func activeRequestCounters() {
    let state = IPadAppState(defaults: freshDefaults())
    #expect(state.focusRequestCount == 0)
    #expect(state.ownershipRequestCount == 0)
    state.requestActiveTerminal()
    #expect(state.focusRequestCount == 1)
    #expect(state.ownershipRequestCount == 1)
}
```

Add a failing construction test to `IPadRootLayoutSelectionTests` proving `SingleSessionView` has new init parameters:

```swift
    @Test("iPad detail session can receive external focus and ownership requests")
    func ipadDetailSessionReceivesActiveRequests() {
        let host = sampleHost()
        let step = SessionStep(host: host, sessionName: "s", title: "s")
        let view = SingleSessionView(
        step: step,
        navigationPath: .constant(NavigationPath()),
        isFullScreen: false,
        coordinator: nil,
        externalFocusRequestCount: 3,
        autoTakeControlRequestCount: 4
    )
        #expect(view.externalFocusRequestCount == 3)
        #expect(view.autoTakeControlRequestCount == 4)
    }

    @Test("@spec IPAD-8.5: iPad auto-ownership shall remain pending until the live session becomes takeable, but an already-owned pane shall fulfill the request as a no-op so stale selection requests cannot steal ownership back later.")
    func autoOwnershipRetriesWhenSessionBecomesTakeable() {
        var policy = SingleSessionView.AutoTakeControlPolicy()
        #expect(!policy.shouldTakeControl(requestCount: 1, isOwner: false, canTakeControl: false))
        #expect(policy.shouldTakeControl(requestCount: 1, isOwner: false, canTakeControl: true))
        #expect(!policy.shouldTakeControl(requestCount: 1, isOwner: false, canTakeControl: true))
        #expect(policy.shouldTakeControl(requestCount: 2, isOwner: false, canTakeControl: true))

        var alreadyOwnerPolicy = SingleSessionView.AutoTakeControlPolicy()
        #expect(!alreadyOwnerPolicy.shouldTakeControl(requestCount: 1, isOwner: true, canTakeControl: false))
        #expect(!alreadyOwnerPolicy.shouldTakeControl(requestCount: 1, isOwner: false, canTakeControl: true))
    }
```

- [ ] **Step 2: Run tests to verify RED**

```bash
swift test --filter IPadWorktreeNavigationTests
swift test --filter IPadAppStateTests
swift test --filter IPadRootLayoutSelectionTests
```

Expected: compile failures for missing helper/counters/initializer fields.

- [ ] **Step 3: Implement pure navigation and state counters**

Create `Sources/GrafttyMobileKit/UI/IPadWorktreeNavigation.swift`:

```swift
#if canImport(UIKit)
import GrafttyProtocol

public enum IPadWorktreeNavigation {
    public static func nextPath(in list: [WorktreePanes], selectedPath: String?, forward: Bool) -> String? {
        let selectable = list.filter { $0.state.hasOnDiskWorktree }
        guard selectable.count > 1 else { return nil }
        let selectedIndex = selectedPath.flatMap { path in selectable.firstIndex { $0.path == path } }
        let candidates = selectable.filter { $0.path != selectedPath && hasAttention($0) }
        if !candidates.isEmpty {
            return next(in: candidates, orderedBy: selectable, selectedIndex: selectedIndex, forward: forward)
        }
        return nextPlain(in: selectable, selectedIndex: selectedIndex, forward: forward)
    }

    private static func hasAttention(_ wt: WorktreePanes) -> Bool {
        if wt.attentionText != nil { return true }
        return wt.layout?.leaves.contains { $0.attentionText != nil } ?? false
    }

    private static func nextPlain(in selectable: [WorktreePanes], selectedIndex: Int?, forward: Bool) -> String? {
        if let selectedIndex {
            let next = forward
                ? (selectedIndex + 1) % selectable.count
                : (selectedIndex - 1 + selectable.count) % selectable.count
            return selectable[next].path
        }
        return forward ? selectable.first?.path : selectable.last?.path
    }

    private static func next(in candidates: [WorktreePanes], orderedBy selectable: [WorktreePanes], selectedIndex: Int?, forward: Bool) -> String? {
        let candidatePaths = Set(candidates.map(\.path))
        guard !candidatePaths.isEmpty else { return nil }
        let start = selectedIndex ?? (forward ? -1 : selectable.count)
        for offset in 1...selectable.count {
            let index = forward
                ? (start + offset + selectable.count) % selectable.count
                : (start - offset + selectable.count) % selectable.count
            let wt = selectable[index]
            if candidatePaths.contains(wt.path) { return wt.path }
        }
        return nil
    }
}
#endif
```

In `IPadAppState`, add:

```swift
public var latestWorktrees: [WorktreePanes] = []
public private(set) var focusRequestCount: Int = 0
public private(set) var ownershipRequestCount: Int = 0

public func requestActiveTerminal() {
    focusRequestCount &+= 1
    ownershipRequestCount &+= 1
}
```

Update `onWorktreeListChanged` to assign `appState.latestWorktrees = list`.

- [ ] **Step 4: Wire iPad selection and Ctrl+Tab**

In `IPadRootLayout.selectWorktree` and `selectPane`, call `appState.requestActiveTerminal()` after setting selection. For pane-row selection, also derive and set `selectedWorktreePath` if needed by adding a helper that finds the worktree containing the leaf in `appState.latestWorktrees`.

Add keyboard shortcuts to `IPadRootLayout`:

```swift
.overlay {
    Group {
        Button("Next Worktree") { navigateWorktree(forward: true) }
            .keyboardShortcut(.tab, modifiers: [.control])
        Button("Previous Worktree") { navigateWorktree(forward: false) }
            .keyboardShortcut(.tab, modifiers: [.control, .shift])
    }
    .opacity(0)
    .accessibilityHidden(true)
}
```

Implement:

```swift
private func navigateWorktree(forward: Bool) {
    guard let path = IPadWorktreeNavigation.nextPath(
        in: appState.latestWorktrees,
        selectedPath: appState.selectedWorktreePath,
        forward: forward
    ), let wt = appState.latestWorktrees.first(where: { $0.path == path }) else { return }
    selectWorktree(wt)
}
```

In `SingleSessionView`, add stored init parameters with defaults:

```swift
let externalFocusRequestCount: Int
let autoTakeControlRequestCount: Int
```

Pass `focusRequestCount &+ externalFocusRequestCount` to `TerminalPaneView`.

Add a small stored helper for retry-safe auto-ownership:

```swift
struct AutoTakeControlPolicy {
    private var fulfilledRequestCount = 0

    mutating func shouldTakeControl(
        requestCount: Int,
        isOwner: Bool,
        canTakeControl: Bool
    ) -> Bool {
        guard requestCount > fulfilledRequestCount else { return false }
        if isOwner {
            fulfilledRequestCount = requestCount
            return false
        }
        guard canTakeControl else { return false }
        fulfilledRequestCount = requestCount
        return true
    }
}
```

Store it as `@State private var autoTakeControlPolicy = AutoTakeControlPolicy()` in `SingleSessionView`, and implement:

```swift
private func attemptAutoTakeControl() {
    guard let client else { return }
    if autoTakeControlPolicy.shouldTakeControl(
        requestCount: autoTakeControlRequestCount,
        isOwner: client.isOwner,
        canTakeControl: client.canTakeControl
    ) {
        client.takeControl()
    }
}
```

Call `attemptAutoTakeControl()` from all state edges that can make the request newly actionable:

- `.onChange(of: autoTakeControlRequestCount, initial: true)`
- `.onChange(of: client?.canTakeControl ?? false)`
- `.onChange(of: client?.isOwner ?? false)`
- immediately after assigning `client = new` and `connection = .live` in `openWebSocket()`

This avoids the race where iPad selection increments the ownership request before the live `SessionClient` has received ownership metadata and started reporting `canTakeControl == true`. Treating `isOwner == true` as fulfilled prevents a stale selection request from stealing ownership back if another device becomes owner later. Do not call this in iPhone compact paths because they keep the default `0` value.

In `IPadDetailColumn`, pass `appState.focusRequestCount` and `appState.ownershipRequestCount` to `SingleSessionView`.

- [ ] **Step 5: Run targeted tests**

```bash
swift test --filter IPadWorktreeNavigationTests
swift test --filter IPadAppStateTests
swift test --filter IPadRootLayoutSelectionTests
```

Expected: targeted tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyMobileKit/App/IPadAppState.swift Sources/GrafttyMobileKit/App/IPadRootLayout.swift Sources/GrafttyMobileKit/App/RootView.swift Sources/GrafttyMobileKit/UI/IPadWorktreeNavigation.swift Tests/GrafttyMobileKitTests/App/IPadAppStateTests.swift Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift Tests/GrafttyMobileKitTests/UI/IPadWorktreeNavigationTests.swift
git commit -m "feat(ipad): make sidebar selection active"
```

## Task 3: Four-Direction Add Pane Toolbar

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/IPadRootLayout.swift`
- Modify: `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift` only if a focused pane-control-only helper is needed
- Modify: `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift`
- Modify: `Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift`

- [ ] **Step 1: Write failing toolbar policy tests**

In `IPadRootLayoutSelectionTests`, add pure policy tests:

```swift
@Test("@spec IPAD-3.7: While an iPad focused pane is available, the detail toolbar shall expose split actions for right, down, left, and up; when no pane is focused, split actions shall be disabled.")
func splitToolbarPolicy() {
    #expect(IPadRootLayout.availableSplitDirections(focusedPaneId: nil).isEmpty)
    #expect(IPadRootLayout.availableSplitDirections(focusedPaneId: "s") == [.right, .down, .left, .up])
}
```

In `PaneControlClientTests`, add:

```swift
@Test func splitLeftForwardsSemanticDirection() async throws {
    let fake = FakeDriver(response: .ok)
    let client = PaneControlClient(driver: fake)
    try await client.open()
    _ = try await client.split(target: "s1", direction: .left)
    #expect(fake.lastRequest == .split(target: "s1", direction: .left))
}
```

- [ ] **Step 2: Run tests to verify RED**

```bash
swift test --filter IPadRootLayoutSelectionTests/splitToolbarPolicy
swift test --filter PaneControlClientTests/splitLeftForwardsSemanticDirection
```

Expected: missing `availableSplitDirections` until implemented.

- [ ] **Step 3: Implement pane-control environment and toolbar**

In `IPadRootLayout`, add `@State private var paneEnvironment: PaneEnvironment = .empty`.

Add a `.task(id: selectedHost?.id)` that resolves the current remote connection through `coordinator.connection(for:)` and assigns `paneEnvironment = await buildPaneEnvironment(remoteHost: remoteHost)`. Clear to `.empty` when no host is selected.

Add:

```swift
public static func availableSplitDirections(focusedPaneId: String?) -> [PaneControlRequest.SplitDirection] {
    guard focusedPaneId != nil else { return [] }
    return [.right, .down, .left, .up]
}
```

In `IPadDetailColumn`, accept `paneEnvironment: PaneEnvironment` and add toolbar buttons/menu when `host`, `selectedWorktreePath`, and `focusedPaneId` are present. Use icon buttons with labels/accessibility:

```swift
Button { Task { await splitFocusedPane(.right) } } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
Button { Task { await splitFocusedPane(.down) } } label: { Label("Split Down", systemImage: "rectangle.split.1x2") }
Button { Task { await splitFocusedPane(.left) } } label: { Label("Split Left", systemImage: "rectangle.split.2x1") }
Button { Task { await splitFocusedPane(.up) } } label: { Label("Split Up", systemImage: "rectangle.split.1x2") }
```

Implementation:

```swift
private func splitFocusedPane(_ direction: PaneControlRequest.SplitDirection) async {
    guard let target = appState.focusedPaneId,
          let client = paneEnvironment.paneControlClient else { return }
    do {
        let response = try await client.split(target: target, direction: direction)
        if case .error(let code, _) = response, code != "conflict" {
            // Optional: leave user-visible error out for v1 unless an existing toast surface exists.
        }
    } catch {
        // Silent for v1; the absence of a snapshot means no change.
    }
}
```

Do not optimistically mutate `appState.latestWorktrees`; the next snapshot/HTTP refresh is authoritative.

- [ ] **Step 4: Run targeted tests**

```bash
swift test --filter IPadRootLayoutSelectionTests
swift test --filter PaneControlClientTests
```

Expected: targeted tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/App/IPadRootLayout.swift Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift
git commit -m "feat(ipad): add split pane toolbar"
```

## Task 4: iPad Trackpad Scroll Through Terminal Gesture Path

**Files:**
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift`
- Modify: `Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift`

- [ ] **Step 1: Write failing gesture tests**

In `TerminalPaneViewTests`, add:

```swift
@Test("@spec IOS-6.15: While a terminal pane is rendered on iPad with a trackpad, indirect pointer scroll gestures shall reach libghostty's terminal scroll/input recognizers rather than being blocked by GrafttyMobile's keyboard proxy or selection overlay.")
func terminalPanRecognizersAllowIndirectScrolling() {
    let container = TerminalInputContainerView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
    #expect(container.terminalPanRecognizersAllowIndirectScrollingForTesting)
}
```

- [ ] **Step 2: Run test to verify RED**

```bash
swift test --filter TerminalPaneViewTests/terminalPanRecognizersAllowIndirectScrolling
```

Expected: compile failure for missing test seam.

- [ ] **Step 3: Configure indirect scroll on terminal pan recognizers**

In `TerminalInputContainerView.setup()`, after adding subviews and before selection setup, call a helper:

```swift
configureTerminalPanRecognizersForIndirectScrolling()
```

Implement:

```swift
private func configureTerminalPanRecognizersForIndirectScrolling() {
    terminalView.gestureRecognizers?
        .compactMap { $0 as? UIPanGestureRecognizer }
        .forEach { recognizer in
            recognizer.allowedScrollTypesMask = [.continuous, .discrete]
        }
}
```

Add test seam:

```swift
var terminalPanRecognizersAllowIndirectScrollingForTesting: Bool {
    let pans = terminalView.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer } ?? []
    return !pans.isEmpty && pans.allSatisfy { $0.allowedScrollTypesMask.contains(.continuous) }
}
```

Do not change `selectionPanRecognizer`; it must stay touch-selection-specific.

- [ ] **Step 4: Run targeted tests**

```bash
swift test --filter TerminalPaneViewTests
swift test --filter TerminalSelectionControllerTests
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift Tests/GrafttyMobileKitTests/Terminal/TerminalPaneViewTests.swift
git commit -m "fix(ipad): allow trackpad terminal scrolling"
```

## Task 5: Add Worktree Return Submits Create on iPad and iOS

**Files:**
- Modify: `Sources/GrafttyMobileKit/UI/AddWorktreeSheetView.swift`
- Create: `Tests/GrafttyMobileKitTests/UI/AddWorktreeSheetViewTests.swift`

- [ ] **Step 1: Write failing submit-policy test**

Create `Tests/GrafttyMobileKitTests/UI/AddWorktreeSheetViewTests.swift`:

```swift
#if canImport(UIKit)
import Testing
@testable import GrafttyMobileKit

@Suite("AddWorktreeSheetView submit policy")
struct AddWorktreeSheetViewTests {
    @Test("@spec IOS-9.10: While the mobile Add Worktree sheet is valid and not submitting, pressing Return on a hardware keyboard shall submit Create; invalid or already-submitting forms shall ignore Return.")
    func returnSubmitPolicy() {
        #expect(AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: true, isSubmitting: false))
        #expect(!AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: false, isSubmitting: false))
        #expect(!AddWorktreeSheetView.shouldSubmitOnReturn(canSubmit: true, isSubmitting: true))
    }
}
#endif
```

- [ ] **Step 2: Run test to verify RED**

```bash
swift test --filter AddWorktreeSheetViewTests
```

Expected: compile failure for missing helper.

- [ ] **Step 3: Implement default submit**

In `AddWorktreeSheetView`, add:

```swift
public static func shouldSubmitOnReturn(canSubmit: Bool, isSubmitting: Bool) -> Bool {
    canSubmit && !isSubmitting
}
```

Apply to toolbar Create button:

```swift
Button("Create") { Task { await submit() } }
    .keyboardShortcut(.defaultAction)
    .disabled(!canSubmit)
```

Apply `.submitLabel(.done)` and `.onSubmit { submitFromReturn() }` to the form or each text field:

```swift
private func submitFromReturn() {
    guard Self.shouldSubmitOnReturn(canSubmit: canSubmit, isSubmitting: isSubmitting) else { return }
    Task { await submit() }
}
```

Ensure `submit()` still guards against invalid state before posting if it does not already.

- [ ] **Step 4: Run targeted tests**

```bash
swift test --filter AddWorktreeSheetViewTests
swift test --filter CreateWorktreeClientTests
```

Expected: tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/UI/AddWorktreeSheetView.swift Tests/GrafttyMobileKitTests/UI/AddWorktreeSheetViewTests.swift
git commit -m "fix(mobile): submit add worktree with return"
```

## Task 6: iPad Sidebar Density and Background Model

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/IPadRootLayout.swift`
- Modify: `Sources/GrafttyMobileKit/UI/WorktreeListContent.swift`
- Modify: `Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift`
- Modify: `Tests/GrafttyMobileKitTests/UI/WorktreeListContentTests.swift`

- [ ] **Step 1: Write failing layout policy tests**

In `WorktreeListContentTests`, add:

```swift
@Test("@spec IPAD-1.19: iPad sidebar worktree rows shall use a tight trailing inset so git divergence stats sit near the sidebar edge.")
func tightTrailingInset() {
    #expect(WorktreeListContent.iPadRowTrailingInset <= 4)
}
```

In `IPadRootLayoutSelectionTests`, add:

```swift
@Test("@spec IPAD-1.20: iPad shall paint the terminal theme background behind the sidebar while keeping terminal content bounded to the detail column.")
func backgroundPolicy() {
    #expect(IPadRootLayout.paintsTerminalBackgroundBehindSidebar == true)
}
```

- [ ] **Step 2: Run tests to verify RED**

```bash
swift test --filter WorktreeListContentTests/tightTrailingInset
swift test --filter IPadRootLayoutSelectionTests/backgroundPolicy
```

Expected: compile failures for missing constants.

- [ ] **Step 3: Implement constants and layout**

In `WorktreeListContent`, add public/static test constants:

```swift
public static let iPadRowTrailingInset: CGFloat = 2
private static let iPadRowLeadingInset: CGFloat = 10
```

Use them in `WorktreeBlock.listRowInsets`:

```swift
.listRowInsets(EdgeInsets(
    top: 4,
    leading: WorktreeListContent.iPadRowLeadingInset,
    bottom: 4,
    trailing: WorktreeListContent.iPadRowTrailingInset
))
```

If the inner `.padding(.horizontal, 6)` still pushes stats too far from the edge, split it into leading/trailing:

```swift
.padding(.leading, 6)
.padding(.trailing, 2)
```

In `IPadRootLayout`, wrap `NavigationSplitView` in a `ZStack`:

```swift
ZStack {
    appState.theme.background.ignoresSafeArea()
    NavigationSplitView(columnVisibility: Binding(
        get: { appState.columnVisibility },
        set: { appState.columnVisibility = $0 }
    )) {
        // existing sidebar content
    } detail: {
        // existing IPadDetailColumn content
    }
}
```

Keep terminal content bounded to detail by preserving the existing `SingleSessionView(isFullScreen: false)` path and `FullScreenChrome(enabled: false)` behavior.

Add:

```swift
public static let paintsTerminalBackgroundBehindSidebar = true
```

Keep `.themedSidebarSurface(appState.theme)` on the sidebar container so the sidebar remains an overlay-like themed surface rather than fully transparent terminal content.

- [ ] **Step 4: Run targeted tests**

```bash
swift test --filter WorktreeListContentTests
swift test --filter IPadRootLayoutSelectionTests
```

Expected: targeted tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/App/IPadRootLayout.swift Sources/GrafttyMobileKit/UI/WorktreeListContent.swift Tests/GrafttyMobileKitTests/App/IPadRootLayoutSelectionTests.swift Tests/GrafttyMobileKitTests/UI/WorktreeListContentTests.swift
git commit -m "style(ipad): tighten sidebar and extend background"
```

## Task 7: Specs, Full Verification, and Cleanup

**Files:**
- Modify: `SPECS.md`
- Modify: `Tests/GrafttyTests/Specs/IpadTodo.swift`
- Any files touched by formatting or compile fixes from prior tasks.

- [ ] **Step 1: Update disabled spec inventory**

In `Tests/GrafttyTests/Specs/IpadTodo.swift`, update the existing `IPAD-3.1` disabled spec from the old `Split Right`, `Split Down`, `Swap`, `Close` toolbar to the new current scope, so it does not contradict the implemented four-direction add-pane toolbar:

```swift
@spec IPAD-3.1: When `MultiPaneDetailView` has a focused leaf and the soft keyboard is hidden, the application shall expose a focused-pane toolbar containing Split Right, Split Down, Split Left, Split Up, Swap, and Close controls.
```

Then update the existing `IPAD-3.3` disabled spec from the old two-action/two-axis contract to the new four-direction contract:

```swift
@spec IPAD-3.3: When the user taps Split Right, Split Down, Split Left, or Split Up in the toolbar, the application shall send a `pane_control` RPC with `type: "split"`, `target` set to the focused leaf's `sessionName`, and `direction` set to `"right"`, `"down"`, `"left"`, or `"up"` respectively.
```

Confirm `Tests/GrafttyTests/Remote/SSH/PaneControlChannelHandlerTests.swift` has the updated `REMOTE-7.2` semantic-direction spec text from Task 1 before regenerating specs. These edits keep generated spec sources from contradicting `REMOTE-7.7` and the new iPad toolbar behavior.

- [ ] **Step 2: Regenerate specs**

Run:

```bash
scripts/generate-specs.py
```

Expected: `SPECS.md` updates with new `@spec` entries.

- [ ] **Step 3: Run full relevant test suite**

Run:

```bash
swift test
```

Expected: all tests pass. If full suite is too slow or environment-limited, at minimum run:

```bash
swift test --filter PaneControlEnvelopeTests
swift test --filter PaneControlClientTests
swift test --filter PaneControlChannelHandlerTests
swift test --filter SSHPanesAndControlLoopbackTests
swift test --filter IPadWorktreeNavigationTests
swift test --filter IPadAppStateTests
swift test --filter IPadRootLayoutSelectionTests
swift test --filter TerminalPaneViewTests
swift test --filter TerminalSelectionControllerTests
swift test --filter AddWorktreeSheetViewTests
swift test --filter WorktreeListContentTests
```

Also run the iOS simulator build/test path for the UIKit-gated mobile target:

```bash
xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -destination 'generic/platform=iOS Simulator' \
  build

xcodebuild \
  -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj \
  -scheme GrafttyMobile \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  test -only-testing:GrafttyMobileKitTests
```

If that named simulator is unavailable, choose an available iPad simulator from:

```bash
xcrun simctl list devices available | rg 'iPad'
```

- [ ] **Step 4: Inspect changed files**

Run:

```bash
git status --short
git diff --check
git diff --stat HEAD
```

Expected: no whitespace errors; only intentional files changed.

- [ ] **Step 5: Commit specs and final cleanup**

```bash
git add SPECS.md Tests/GrafttyTests/Specs/IpadTodo.swift
git commit -m "docs: update specs for ipad workstation behavior"
```

If `SPECS.md` did not change because all spec annotations were already present, skip this commit.
