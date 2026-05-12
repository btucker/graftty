# GrafttyMobile Battery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut GrafttyMobile's battery cost when foregrounded-idle and after `.inactive`/`.background`, by implementing IOS-7.4 reconnect-with-backoff, treating `.inactive` like `.background` for teardown, lowering the preview cap, and idle-pausing the libghostty renderer when no PTY bytes have flowed for 30s.

**Architecture:** All three components live in `Sources/GrafttyMobileKit`. The core mechanism is leveraging libghostty's existing `didMoveToWindow(window: nil)` lifecycle hook to stop its display link — we never need to fork the package. State machines for connection and render-activity sit on `SessionClient` and are surfaced through `@Observable`; the SwiftUI tree branches on them.

**Tech Stack:** Swift 5.10, SwiftUI, Swift Testing, `@Observable`, `URLSessionWebSocketTask`, libghostty-spm, Foundation `Task`/async-await.

**Spec reference:** `docs/superpowers/specs/2026-05-12-grafttymobile-battery-design.md`.

---

## Phase 0: Branch verification (sanity)

### Task 0: Confirm clean baseline

**Files:** none.

- [ ] **Step 1: Verify build + tests pass on `main` parity**

Run:
```bash
swift build 2>&1 | tail -20
swift test --filter "GrafttyMobileKitTests" 2>&1 | tail -30
```
Expected: both succeed. If `swift test` reports anything red on this branch *before* changes, stop and escalate — we must start from green.

---

## Phase 1 — Component 1: IOS-7.4 reconnect with exponential backoff

### Task 1: Extend `Clock` with `sleep(for:)`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Auth/Clock.swift`
- Test: `Tests/GrafttyMobileKitTests/Auth/ClockTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyMobileKitTests/Auth/ClockTests.swift`:

```swift
#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
struct ClockTests {
    @Test
    func systemClockSleepResolvesAfterRequestedInterval() async throws {
        let clock = SystemClock()
        let start = clock.now
        try await clock.sleep(for: 0.05)
        let elapsed = clock.now.timeIntervalSince(start)
        #expect(elapsed >= 0.04)  // small jitter tolerance
    }
}
#endif
```

- [ ] **Step 2: Run test to verify it fails (compile error)**

Run: `swift test --filter ClockTests`
Expected: compile error — `sleep(for:)` not on `Clock`.

- [ ] **Step 3: Add the protocol requirement + impl**

Replace `Sources/GrafttyMobileKit/Auth/Clock.swift` with:

```swift
#if canImport(UIKit)
import Foundation

public protocol Clock: Sendable {
    var now: Date { get }
    func sleep(for duration: TimeInterval) async throws
}

public struct SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for duration: TimeInterval) async throws {
        guard duration > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
    }
}
#endif
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClockTests`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Auth/Clock.swift Tests/GrafttyMobileKitTests/Auth/ClockTests.swift
git commit -m "feat(mobile): extend Clock protocol with sleep(for:)"
```

---

### Task 2: Add `VirtualClock` test helper

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Auth/VirtualClock.swift`

VirtualClock lets tests advance time on demand. Used by reconnect-backoff and idle-watchdog tests.

- [ ] **Step 1: Write the helper**

Create `Tests/GrafttyMobileKitTests/Auth/VirtualClock.swift`:

```swift
#if canImport(UIKit)
import Foundation
@testable import GrafttyMobileKit

/// Test-only Clock whose `sleep(for:)` only resolves when the test
/// explicitly calls `advance(by:)`. Lets us assert backoff timing
/// without real time passing.
final class VirtualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var sleepers: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    init(start: Date = Date(timeIntervalSince1970: 1_000_000_000)) {
        self._now = start
    }

    var now: Date { lock.withLock { _now } }

    func sleep(for duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                let deadline = _now.addingTimeInterval(duration)
                sleepers.append((deadline, continuation))
            }
        }
    }

    /// Move clock forward and resume any sleepers whose deadlines fell within
    /// the elapsed window. Resumes outside the lock so continuations are free
    /// to call back into the clock.
    func advance(by duration: TimeInterval) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            _now = _now.addingTimeInterval(duration)
            let due = sleepers.filter { $0.deadline <= _now }
            sleepers.removeAll { $0.deadline <= _now }
            return due.map(\.continuation)
        }
        for cont in ready { cont.resume() }
    }

    /// Count of pending sleepers — useful for asserting "the watchdog
    /// is currently parked waiting for time to pass."
    var pendingSleepCount: Int { lock.withLock { sleepers.count } }
}
#endif
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build --target GrafttyMobileKitTests` (or `swift test --filter ClockTests` — anything that compiles the test target).
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyMobileKitTests/Auth/VirtualClock.swift
git commit -m "test(mobile): add VirtualClock helper for testing time-based behavior"
```

---

### Task 3: Refactor `SessionClient` init to take a `webSocketFactory`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift`
- Modify: `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift`

Goal: change the primary init to take a factory closure (so reconnect can mint fresh WSes), preserve the existing `webSocket:` init as a convenience that wraps a single instance.

- [ ] **Step 1: Update `SessionClient` init signatures**

In `Sources/GrafttyMobileKit/Session/SessionClient.swift`, find the existing init starting at line ~91:

```swift
public init(
    sessionName: String,
    webSocket: WebSocketClient,
    role: Role = .fullscreen
) {
    self.sessionName = sessionName
    self.ws = webSocket
    self.role = role
    ...
}
```

Replace it with two inits:

```swift
nonisolated private let webSocketFactory: @Sendable () -> WebSocketClient
nonisolated internal let clock: any Clock
nonisolated internal let backoffSchedule: [TimeInterval]
private var ws: WebSocketClient?  // now optional — minted at start()

public init(
    sessionName: String,
    webSocketFactory: @Sendable @escaping () -> WebSocketClient,
    clock: any Clock = SystemClock(),
    backoffSchedule: [TimeInterval] = HostController.backoffSchedule(attempts: 6),
    role: Role = .fullscreen
) {
    self.sessionName = sessionName
    self.webSocketFactory = webSocketFactory
    self.clock = clock
    self.backoffSchedule = backoffSchedule
    self.role = role

    final class Box {
        var onBytes: (@Sendable (Data) -> Void)?
        var onResize: (@Sendable (InMemoryTerminalViewport) -> Void)?
    }
    let box = Box()
    self.session = InMemoryTerminalSession(
        write: { data in box.onBytes?(data) },
        resize: { viewport in box.onResize?(viewport) }
    )
    box.onBytes = { [weak self] data in
        guard let self else { return }
        if self.role == .preview { return }
        let isSoftReturn = data.count == 1 && data.first == 0x0A
        self.sendBinary(isSoftReturn ? Self.cr : data)
        Task { @MainActor [weak self] in
            self?.claimLeadershipIfNeeded()
        }
    }
    box.onResize = { [weak self] viewport in
        Task { @MainActor [weak self] in
            self?.handleViewport(viewport)
        }
    }
}

/// Backward-compatible convenience for tests that pass a single WS instance.
public convenience init(
    sessionName: String,
    webSocket: WebSocketClient,
    role: Role = .fullscreen
) {
    self.init(
        sessionName: sessionName,
        webSocketFactory: { webSocket },
        role: role
    )
}
```

Then update the existing `ws` declaration:

```swift
nonisolated private let ws: WebSocketClient
```

becomes (it now needs to be a `var` so the reconnect loop can rebind):

```swift
nonisolated(unsafe) private var ws: WebSocketClient?
```

Update the two send paths to guard:

```swift
nonisolated private func sendBinary(_ data: Data) {
    Task { [ws] in try? await ws?.send(.binary(data)) }
}

nonisolated private func sendText(_ text: String) {
    Task { [ws] in try? await ws?.send(.text(text)) }
}
```

Update `stop()` to close optionally:

```swift
public func stop() {
    guard !stopped else { return }
    stopped = true
    receiveTask?.cancel()
    receiveTask = nil
    ws?.close()
    ws = nil
}
```

Update the existing `start()` body — we'll completely replace it in Task 5, but for now, gate on `ws` so this task compiles:

```swift
public func start() {
    receiveTask = Task { @MainActor [weak self] in
        guard let self else { return }
        self.ws = self.webSocketFactory()
        while !self.stopped {
            guard let ws = self.ws else { break }
            do {
                let frame = try await ws.receive()
                switch frame {
                case .binary(let data):
                    self.session.receive(data)
                case .text(let text):
                    self.handleTextFrame(text)
                }
            } catch {
                break
            }
        }
    }
}
```

This preserves *existing* behavior (silent break on error) — Task 5 will replace it with the reconnect loop.

- [ ] **Step 2: Update the single production caller**

In `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift`, replace the `SessionClient.live` body (around line 31):

```swift
static func live(
    baseURL: URL,
    sessionName: String,
    role: Role = .fullscreen
) -> SessionClient {
    SessionClient(
        sessionName: sessionName,
        webSocketFactory: {
            let wsURL = RootView.makeWebSocketURL(base: baseURL, session: sessionName)
            return URLSessionWebSocketClient(url: wsURL)
        },
        role: role
    )
}
```

- [ ] **Step 3: Build + run existing tests**

Run:
```bash
swift test --filter SessionClientTests 2>&1 | tail -30
```
Expected: all existing tests pass (the convenience init keeps them green).

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/SessionClient.swift Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift
git commit -m "refactor(mobile): SessionClient takes a webSocket factory so reconnect can mint fresh sockets"
```

---

### Task 4: Add `ConnectionState` enum + observable property

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift`

- [ ] **Step 1: Add the enum + property**

In `SessionClient.swift`, near the top of the class body (after `cellWidthPoints`), add:

```swift
public enum ConnectionState: Equatable, Sendable {
    case live
    case reconnecting(attempt: Int)
}

/// @spec IOS-7.4
/// Whether the WebSocket is currently connected and exchanging frames,
/// or in a reconnect-backoff cycle. The view layer renders a banner
/// when this is `.reconnecting`.
public private(set) var connectionState: ConnectionState = .live
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -10`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/SessionClient.swift
git commit -m "feat(mobile): add ConnectionState enum + observable property to SessionClient"
```

---

### Task 5: Implement reconnect-with-backoff loop in `start()`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift`
- Create: `Tests/GrafttyMobileKitTests/Session/SessionReconnectTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/GrafttyMobileKitTests/Session/SessionReconnectTests.swift`:

```swift
#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
@MainActor
struct SessionReconnectTests {

    /// A WebSocketClient whose `receive()` throws immediately. Models a
    /// hard network failure between frames.
    final class FailingWS: WebSocketClient, @unchecked Sendable {
        let id: Int
        init(id: Int) { self.id = id }
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame {
            throw URLError(.networkConnectionLost)
        }
        func close() {}
    }

    /// A WebSocketClient whose `receive()` parks forever. Models a healthy
    /// open connection that simply hasn't sent us anything yet.
    final class IdleWS: WebSocketClient, @unchecked Sendable {
        let id: Int
        init(id: Int) { self.id = id }
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
        func close() {}
    }

    final class FactoryRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _creations = 0
        var creations: Int { lock.withLock { _creations } }
        var nextProvider: @Sendable (Int) -> WebSocketClient = { id in IdleWS(id: id) }
        func make() -> WebSocketClient {
            lock.withLock {
                _creations += 1
                return nextProvider(_creations)
            }
        }
    }

    /// Wait briefly so the spawned receive Task reaches the await point.
    /// 50ms is plenty for an in-memory factory call + one async hop.
    func quiesce() async {
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    @Test("""
    @spec IOS-7.4: On WebSocket failure (upgrade failure, read/write error, or close frame not initiated by the app) for a pane whose session name is still listed in `/sessions`, the application shall display a per-pane "disconnected" banner with "Reconnect" and "Back to sessions" buttons. While the host view is visible, the application shall retry automatically with exponential backoff: the delay starts at 1 second, doubles after each successive failure, and is capped at 30 seconds. Each successful connect resets the delay to 1 second. When the host view is not visible, no automatic retry shall occur.
    """)
    func receiveErrorTransitionsToReconnecting() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        factory.nextProvider = { id in FailingWS(id: id) }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [1, 2, 4, 8, 16, 30]
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        #expect(client.connectionState == .reconnecting(attempt: 1))
        #expect(factory.creations == 1)
    }

    @Test
    func backoffEscalatesAcrossRepeatedFailures() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        factory.nextProvider = { _ in FailingWS(id: 0) }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [1, 2, 4]
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        // After first failure, attempt 1 with 1s delay pending.
        #expect(client.connectionState == .reconnecting(attempt: 1))
        clock.advance(by: 1.0)
        await quiesce()
        // Second WS attempted, fails, attempt 2 with 2s delay pending.
        #expect(client.connectionState == .reconnecting(attempt: 2))
        #expect(factory.creations == 2)
        clock.advance(by: 2.0)
        await quiesce()
        #expect(client.connectionState == .reconnecting(attempt: 3))
        #expect(factory.creations == 3)
    }

    @Test
    func successfulConnectResetsAttemptCounter() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        var calls = 0
        factory.nextProvider = { id in
            calls += 1
            return calls == 1 ? FailingWS(id: id) : IdleWS(id: id)
        }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [1, 2, 4]
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        #expect(client.connectionState == .reconnecting(attempt: 1))
        clock.advance(by: 1.0)
        await quiesce()
        // Second WS is IdleWS — receive parks → state is .live.
        #expect(client.connectionState == .live)
    }

    @Test
    func stopDuringBackoffCancelsCleanly() async throws {
        let clock = VirtualClock()
        let factory = FactoryRecorder()
        factory.nextProvider = { _ in FailingWS(id: 0) }
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: factory.make,
            clock: clock,
            backoffSchedule: [10]  // long enough we'd never reach it
        )
        client.start()
        await quiesce()
        #expect(client.connectionState == .reconnecting(attempt: 1))
        client.stop()
        await quiesce()
        // No additional factory calls after stop.
        let snapshot = factory.creations
        clock.advance(by: 10.0)
        await quiesce()
        #expect(factory.creations == snapshot)
    }
}
#endif
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionReconnectTests 2>&1 | tail -40`
Expected: failures — current `start()` silently breaks on error, never sets `connectionState` and never mints a second WS.

- [ ] **Step 3: Replace `start()` with the reconnect loop**

In `Sources/GrafttyMobileKit/Session/SessionClient.swift`, replace the `start()` body added in Task 3 with:

```swift
public func start() {
    receiveTask = Task { @MainActor [weak self] in
        guard let self else { return }
        var attempt = 0
        while !self.stopped {
            self.ws = self.webSocketFactory()
            self.connectionState = .live
            attempt = 0
            do {
                try await self.runReceiveLoop()
            } catch is CancellationError {
                return
            } catch {
                // fall through to backoff
            }
            if self.stopped { return }
            let delayIndex = min(attempt, self.backoffSchedule.count - 1)
            let delay = self.backoffSchedule[delayIndex]
            attempt += 1
            self.connectionState = .reconnecting(attempt: attempt)
            do {
                try await self.clock.sleep(for: delay)
            } catch {
                return  // cancelled mid-sleep
            }
        }
    }
}

@MainActor
private func runReceiveLoop() async throws {
    guard let ws = self.ws else {
        throw URLError(.cannotConnectToHost)
    }
    while !self.stopped {
        let frame = try await ws.receive()
        switch frame {
        case .binary(let data):
            self.session.receive(data)
        case .text(let text):
            self.handleTextFrame(text)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
swift test --filter SessionReconnectTests 2>&1 | tail -40
swift test --filter SessionClientTests 2>&1 | tail -40
```
Expected: both green.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/SessionClient.swift Tests/GrafttyMobileKitTests/Session/SessionReconnectTests.swift
git commit -m "feat(mobile): IOS-7.4 implement WS reconnect-with-backoff in SessionClient"
```

---

### Task 6: Add `forceReconnectNow()` and test

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift`
- Modify: `Tests/GrafttyMobileKitTests/Session/SessionReconnectTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/GrafttyMobileKitTests/Session/SessionReconnectTests.swift` inside the `@Suite` struct:

```swift
@Test
func forceReconnectNowCancelsBackoffSleep() async throws {
    let clock = VirtualClock()
    let factory = FactoryRecorder()
    factory.nextProvider = { _ in FailingWS(id: 0) }
    let client = SessionClient(
        sessionName: "s",
        webSocketFactory: factory.make,
        clock: clock,
        backoffSchedule: [30]  // long enough we won't auto-trigger
    )
    defer { client.stop() }
    client.start()
    await quiesce()
    #expect(client.connectionState == .reconnecting(attempt: 1))
    let beforeForce = factory.creations
    client.forceReconnectNow()
    await quiesce()
    #expect(factory.creations == beforeForce + 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "forceReconnectNowCancelsBackoffSleep"`
Expected: fail — `forceReconnectNow` doesn't exist.

- [ ] **Step 3: Implement**

In `SessionClient.swift`, add a property to track the backoff continuation and a method to cancel it. Replace the backoff sleep section in `start()` with one that exposes the cancellation handle.

Add to the class:

```swift
@ObservationIgnored
private var backoffCancellationHandle: Task<Void, Never>?

public func forceReconnectNow() {
    guard !stopped else { return }
    // Cancel the existing receive Task so the outer loop drops out of
    // any sleep or receive() and starts a fresh attempt with a fresh
    // WS. Then re-enter start().
    receiveTask?.cancel()
    receiveTask = nil
    backoffCancellationHandle?.cancel()
    backoffCancellationHandle = nil
    self.start()
}
```

Note: this is the simplest implementation — cancel the existing task entirely and restart. It works because `start()` reuses the same `SessionClient` state (session, observable properties), only rebuilds the receive Task.

Wait — there's a subtle issue. The existing `receiveTask` is the one that owns the backoff sleep. Cancelling the task throws CancellationError into the sleep, which the outer loop catches and `return`s. So we need to spawn a new task with start(). But `start()` only spawns if `!stopped`. Good.

Also: cancellation propagates from `Task.cancel()` into `Clock.sleep`. `SystemClock.sleep` uses `Task.sleep(nanoseconds:)` which respects cancellation. `VirtualClock.sleep` uses `withCheckedThrowingContinuation` — that does NOT automatically cancel.

To make `VirtualClock.sleep` honor cancellation, change it to use `withTaskCancellationHandler`:

```swift
func sleep(for duration: TimeInterval) async throws {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                let deadline = _now.addingTimeInterval(duration)
                sleepers.append((deadline, continuation))
            }
        }
    } onCancel: {
        // Cannot resolve the continuation directly here because we don't
        // know which entry to pluck. Mark all sleepers as cancelled by
        // resuming them with CancellationError. In tests we only ever
        // have one inflight sleep, so this is acceptable.
        let toCancel = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            let conts = sleepers.map(\.continuation)
            sleepers.removeAll()
            return conts
        }
        for c in toCancel { c.resume(throwing: CancellationError()) }
    }
}
```

Update `Tests/GrafttyMobileKitTests/Auth/VirtualClock.swift` to use this implementation (replace the existing `sleep(for:)` method).

- [ ] **Step 4: Run tests**

Run: `swift test --filter SessionReconnectTests 2>&1 | tail -40`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/SessionClient.swift Tests/GrafttyMobileKitTests/Auth/VirtualClock.swift Tests/GrafttyMobileKitTests/Session/SessionReconnectTests.swift
git commit -m "feat(mobile): add SessionClient.forceReconnectNow() to skip backoff on user demand"
```

---

### Task 7: Reconnect banner in `SingleSessionView`

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`

- [ ] **Step 1: Add banner overlay**

In `SingleSessionView.body`, find the existing `.overlay(alignment: .topLeading)` block for the back button (around line 174). Add a new overlay below it:

```swift
.overlay(alignment: .top) {
    if let client, client.connectionState != .live {
        reconnectBanner(client: client)
            .padding(.top, 64)
            .padding(.horizontal, 16)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
```

Add the helper view inside `SingleSessionView`:

```swift
@ViewBuilder
private func reconnectBanner(client: SessionClient) -> some View {
    HStack(spacing: 12) {
        Image(systemName: "wifi.exclamationmark")
        VStack(alignment: .leading, spacing: 2) {
            Text("Reconnecting…")
                .font(.subheadline.weight(.semibold))
            if case .reconnecting(let attempt) = client.connectionState {
                Text("Attempt \(attempt)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Spacer()
        Button("Reconnect") { client.forceReconnectNow() }
            .buttonStyle(.bordered)
            .controlSize(.small)
        Button("Back") { popToParent() }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
    )
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -10`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/App/RootView.swift
git commit -m "feat(mobile): show reconnect banner with Reconnect/Back actions when WS is in backoff"
```

---

## Phase 2 — Component 2: `.inactive` teardown + preview cap

### Task 8: Add `LiveSessionReadiness.shouldTearDown(scene:)`

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift`
- Modify: `Tests/GrafttyMobileKitTests/App/SessionLifecycleTests.swift`

- [ ] **Step 1: Write the failing test**

Add to the existing `@Suite struct LiveSessionReadinessTests` in `Tests/GrafttyMobileKitTests/App/SessionLifecycleTests.swift`:

```swift
@Test("""
@spec IOS-10.1: While `scenePhase` is `.inactive` or `.background`, the application shall tear down active WebSocket connections and unmount live `TerminalPaneView` instances so libghostty's display link stops.
""")
func shouldTearDownOnInactiveAndBackground() {
    #expect(!LiveSessionReadiness.shouldTearDown(scene: .active))
    #expect(LiveSessionReadiness.shouldTearDown(scene: .inactive))
    #expect(LiveSessionReadiness.shouldTearDown(scene: .background))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter shouldTearDownOnInactiveAndBackground`
Expected: fail — function doesn't exist.

- [ ] **Step 3: Implement**

In `Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift`, add to `LiveSessionReadiness`:

```swift
public enum LiveSessionReadiness {
    public static func isActive(scene: ScenePhase, gateUnlocked: Bool) -> Bool {
        scene == .active && gateUnlocked
    }

    /// @spec IOS-10.1
    /// Returns true when the application should release WSes and unmount
    /// live terminal views. `.inactive` is included so that lock-screen
    /// pulls / Control Center / app-switcher windows don't keep
    /// libghostty's display link ticking at 120 Hz.
    public static func shouldTearDown(scene: ScenePhase) -> Bool {
        scene == .inactive || scene == .background
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LiveSessionReadinessTests 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/App/SessionLifecycleEnvironment.swift Tests/GrafttyMobileKitTests/App/SessionLifecycleTests.swift
git commit -m "feat(mobile): add LiveSessionReadiness.shouldTearDown(scene:) (IOS-10.1)"
```

---

### Task 9: Use `shouldTearDown` in `RootView` and `WorktreeDetailView`

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`
- Modify: `Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift`

- [ ] **Step 1: Update `SingleSessionView.driveConnection`**

In `Sources/GrafttyMobileKit/App/RootView.swift`, find `driveConnection()` (around line 242). Replace:

```swift
if scenePhase == .background {
    client?.stop()
    client = nil
    if connection != .ended { connection = .suspended }
    return
}
```

with:

```swift
if LiveSessionReadiness.shouldTearDown(scene: scenePhase) {
    client?.stop()
    client = nil
    if connection != .ended { connection = .suspended }
    return
}
```

- [ ] **Step 2: Update `WorktreeDetailView.driveLifecycle`**

In `Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift`, find `driveLifecycle()` (around line 78). Replace:

```swift
if scenePhase == .background {
    previews?.stopAll()
    return
}
```

with:

```swift
if LiveSessionReadiness.shouldTearDown(scene: scenePhase) {
    previews?.stopAll()
    return
}
```

- [ ] **Step 3: Build + run tests**

Run:
```bash
swift build 2>&1 | tail -10
swift test --filter GrafttyMobileKitTests 2>&1 | tail -10
```
Expected: build green, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/App/RootView.swift Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift
git commit -m "feat(mobile): tear down WS + previews on .inactive, not only .background (IOS-10.1)"
```

---

### Task 10: Lower `maxLivePanePreviews` to 1

**Files:**
- Modify: `Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift`

- [ ] **Step 1: Write the spec test**

Append to `Tests/GrafttyMobileKitTests/UI/`:

Create `Tests/GrafttyMobileKitTests/UI/PreviewCapTests.swift`:

```swift
#if canImport(UIKit)
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite
@MainActor
struct PreviewCapTests {

    final class StubPreview: PanePreviewClienting {
        let sessionName: String
        var started = false
        init(sessionName: String) { self.sessionName = sessionName }
        func start() { started = true }
        func stop() { started = false }
    }

    @Test("""
    @spec IOS-10.2: The `WorktreeDetailView` preview pool shall keep at most one live preview `SessionClient`.
    """)
    func poolKeepsAtMostOneLivePreviewWhenCappedAtOne() {
        var made: [String] = []
        let pool = PanePreviewClientPool<StubPreview> { name in
            made.append(name)
            return StubPreview(sessionName: name)
        }
        let leaves = [
            PaneLayoutNode.pane(.init(sessionName: "a", title: "A")),
            PaneLayoutNode.pane(.init(sessionName: "b", title: "B")),
            PaneLayoutNode.pane(.init(sessionName: "c", title: "C")),
        ]
        let layout = PaneLayoutNode.hsplit(leaves)
        pool.update(layout: layout, maxLivePreviews: 1)
        #expect(pool.clients.count == 1)
        #expect(pool.clients["a"]?.started == true)
    }
}
#endif
```

Note: if `PaneLayoutNode.hsplit`/`.pane`/`.init` don't match the actual types in `GrafttyProtocol`, adjust the construction to use the actual API — read `Sources/GrafttyProtocol/PaneLayoutNode.swift` if needed and update. The test asserts the *cap*, not the layout topology.

- [ ] **Step 2: Run test to verify it fails or passes appropriately**

Run: `swift test --filter PreviewCapTests`

Two outcomes are acceptable here: the test passes already (because `update(layout:, maxLivePreviews:)` already honors the cap and we're effectively testing existing behavior — that's fine and worth keeping as a regression guard for IOS-10.2), or it surfaces a missing type and needs adjusting.

If the test passes already, that confirms the pool plumbing — we just need to update the call site.

- [ ] **Step 3: Lower the cap in WorktreeDetailView**

In `Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift`, line 6, change:

```swift
private let maxLivePanePreviews = 2
```

to:

```swift
/// @spec IOS-10.2
private let maxLivePanePreviews = 1
```

- [ ] **Step 4: Run all mobile tests**

Run: `swift test --filter GrafttyMobileKitTests 2>&1 | tail -20`
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/UI/WorktreeDetailView.swift Tests/GrafttyMobileKitTests/UI/PreviewCapTests.swift
git commit -m "feat(mobile): cap live preview SessionClients to 1 (IOS-10.2)"
```

---

## Phase 3 — Component 3: Idle-pause renderer

### Task 11: Add `RenderActivity` enum + activity tracking on `SessionClient`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift`
- Create: `Tests/GrafttyMobileKitTests/Session/SessionIdleRendererTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/GrafttyMobileKitTests/Session/SessionIdleRendererTests.swift`:

```swift
#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
@MainActor
struct SessionIdleRendererTests {

    final class IdleWS: WebSocketClient, @unchecked Sendable {
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        }
        func close() {}
    }

    func quiesce() async { try? await Task.sleep(nanoseconds: 50_000_000) }

    @Test("""
    @spec IOS-10.3: When a `SessionClient` has received no PTY bytes and processed no user input for ≥ `idleThreshold` (default 30s), the application shall transition its `renderActivity` to `.idle`.
    """)
    func renderActivityFlipsToIdleAfterThreshold() async throws {
        let clock = VirtualClock()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            idleThreshold: 30,
            idleCheckInterval: 5
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        #expect(client.renderActivity == .active)
        // 30 seconds with nothing happening -> idle
        clock.advance(by: 31)
        await quiesce()
        #expect(client.renderActivity == .idle)
    }

    @Test
    func userInputBumpsActivityAndKeepsActive() async throws {
        let clock = VirtualClock()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            idleThreshold: 30,
            idleCheckInterval: 5
        )
        defer { client.stop() }
        client.start()
        // Tick forward 28s, send input, then tick 28s again — total 56s but
        // the input reset the timer.
        await quiesce()
        clock.advance(by: 28)
        await quiesce()
        client.sendEscape()
        await quiesce()
        clock.advance(by: 28)
        await quiesce()
        #expect(client.renderActivity == .active)
    }

    @Test("""
    @spec IOS-10.5: When a `SessionClient` is `.idle` and a new PTY byte is received, the application shall transition its `renderActivity` to `.active` and remount `TerminalPaneView` within one runloop tick.
    """)
    func wakeRendererFlipsBackToActive() async throws {
        let clock = VirtualClock()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            idleThreshold: 30,
            idleCheckInterval: 5
        )
        defer { client.stop() }
        client.start()
        await quiesce()
        clock.advance(by: 31)
        await quiesce()
        #expect(client.renderActivity == .idle)
        client.wakeRenderer()
        await quiesce()
        #expect(client.renderActivity == .active)
    }

    @Test
    func stopCancelsIdleWatchdog() async throws {
        let clock = VirtualClock()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { IdleWS() },
            clock: clock,
            idleThreshold: 30,
            idleCheckInterval: 5
        )
        client.start()
        await quiesce()
        client.stop()
        await quiesce()
        let pending = clock.pendingSleepCount
        clock.advance(by: 100)
        await quiesce()
        // After stop, no new sleepers should have been re-registered.
        #expect(clock.pendingSleepCount <= pending)
    }
}
#endif
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionIdleRendererTests`
Expected: compile errors — `renderActivity`, `idleThreshold`, `idleCheckInterval`, `wakeRenderer` don't exist.

- [ ] **Step 3: Implement on `SessionClient`**

In `Sources/GrafttyMobileKit/Session/SessionClient.swift`:

Add near the other public enums:

```swift
public enum RenderActivity: Equatable, Sendable {
    case active
    case idle
}
```

Update the primary init signature to accept the new knobs:

```swift
public init(
    sessionName: String,
    webSocketFactory: @Sendable @escaping () -> WebSocketClient,
    clock: any Clock = SystemClock(),
    backoffSchedule: [TimeInterval] = HostController.backoffSchedule(attempts: 6),
    idleThreshold: TimeInterval = 30,
    idleCheckInterval: TimeInterval = 5,
    role: Role = .fullscreen
)
```

Store them:

```swift
nonisolated internal let idleThreshold: TimeInterval
nonisolated internal let idleCheckInterval: TimeInterval
```

And in the init body, after the existing assignments, set:

```swift
self.idleThreshold = idleThreshold
self.idleCheckInterval = idleCheckInterval
self.lastActivityAt = clock.now
```

Add the properties:

```swift
/// @spec IOS-10.3
/// `.active` while libghostty is mounted and rendering at full rate.
/// `.idle` once `idleThreshold` has elapsed with no PTY bytes or user
/// input — the view layer swaps in a static snapshot, which detaches
/// the UITerminalView and stops the display link.
public private(set) var renderActivity: RenderActivity = .active

@ObservationIgnored
private var lastActivityAt: Date = .distantPast

@ObservationIgnored
private var idleWatchdogTask: Task<Void, Never>?
```

Update the convenience init to pass through the new defaults:

```swift
public convenience init(
    sessionName: String,
    webSocket: WebSocketClient,
    role: Role = .fullscreen
) {
    self.init(
        sessionName: sessionName,
        webSocketFactory: { webSocket },
        role: role
    )
}
```

(unchanged — uses the defaults)

Update `start()` to also start the idle watchdog (add at the top of the existing implementation, before the reconnect-loop Task):

```swift
public func start() {
    lastActivityAt = clock.now
    startIdleWatchdog()
    receiveTask = Task { @MainActor [weak self] in
        // ... existing reconnect-loop body unchanged ...
    }
}

@MainActor
private func startIdleWatchdog() {
    idleWatchdogTask?.cancel()
    idleWatchdogTask = Task { @MainActor [weak self] in
        while let self, !self.stopped {
            do {
                try await self.clock.sleep(for: self.idleCheckInterval)
            } catch {
                return
            }
            if self.stopped { return }
            let elapsed = self.clock.now.timeIntervalSince(self.lastActivityAt)
            if self.renderActivity == .active, elapsed >= self.idleThreshold {
                self.renderActivity = .idle
            }
        }
    }
}

@MainActor
private func recordActivity() {
    lastActivityAt = clock.now
    if renderActivity == .idle {
        renderActivity = .active
    }
}

/// @spec IOS-10.4
/// Called from the idle-snapshot view's tap handler to wake the
/// renderer without delivering a stray keystroke to the shell.
public func wakeRenderer() {
    recordActivity()
}
```

Add `recordActivity()` calls to existing input methods. In each of these (already in `SessionClient.swift`), add `recordActivity()` as the first line of the body:
- `insertNewline()`
- `submitReturn()`
- `sendSoftwareKeyboardText(_:)`
- `deleteBackward()`
- `sendEscape()`
- `sendTab()`
- `sendArrow(_:)`
- `sendControl(_:)`

In `runReceiveLoop()`, after the `let frame = try await ws.receive()` line, add:

```swift
self.recordActivity()
```

Update `stop()` to cancel the watchdog:

```swift
public func stop() {
    guard !stopped else { return }
    stopped = true
    receiveTask?.cancel()
    receiveTask = nil
    idleWatchdogTask?.cancel()
    idleWatchdogTask = nil
    ws?.close()
    ws = nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
swift test --filter SessionIdleRendererTests 2>&1 | tail -30
swift test --filter SessionReconnectTests 2>&1 | tail -10
swift test --filter SessionClientTests 2>&1 | tail -10
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/SessionClient.swift Tests/GrafttyMobileKitTests/Session/SessionIdleRendererTests.swift
git commit -m "feat(mobile): idle-pause renderer state machine on SessionClient (IOS-10.3, 10.5)"
```

---

### Task 12: Add `idleSnapshot` property and `IdleSnapshotView`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Session/SessionClient.swift`
- Create: `Sources/GrafttyMobileKit/UI/IdleSnapshotView.swift`

- [ ] **Step 1: Add the snapshot property**

In `SessionClient.swift`, near `renderActivity`:

```swift
/// @spec IOS-10.4
/// Last live frame captured by the view layer just before transitioning
/// to `.idle`. Nil before the first snapshot is taken; the
/// `IdleSnapshotView` falls back to a stylized placeholder when nil.
public private(set) var idleSnapshot: UIImage?

public func setIdleSnapshot(_ image: UIImage?) {
    self.idleSnapshot = image
}
```

(`import UIKit` is already imported via `#if canImport(UIKit)` block.)

- [ ] **Step 2: Create `IdleSnapshotView`**

Create `Sources/GrafttyMobileKit/UI/IdleSnapshotView.swift`:

```swift
#if canImport(UIKit)
import SwiftUI
import UIKit

/// @spec IOS-10.4
/// Replaces a live `TerminalPaneView` while its `SessionClient` is in
/// `.idle` so libghostty's display link can stop. Renders the captured
/// last frame if available, falls back to a stylized dim placeholder
/// otherwise. A full-bleed tap target invokes `onWake`.
struct IdleSnapshotView: View {
    let snapshot: UIImage?
    let onWake: () -> Void

    var body: some View {
        ZStack {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                    .overlay(Color.black.opacity(0.05))
            } else {
                Color.black
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Label("Tap to wake", systemImage: "hand.tap")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onWake() }
    }
}
#endif
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -10`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Session/SessionClient.swift Sources/GrafttyMobileKit/UI/IdleSnapshotView.swift
git commit -m "feat(mobile): add idleSnapshot property + IdleSnapshotView (IOS-10.4)"
```

---

### Task 13: Branch terminal content on `renderActivity` in `SingleSessionView`

**Files:**
- Modify: `Sources/GrafttyMobileKit/App/RootView.swift`

- [ ] **Step 1: Update `terminalContent`**

In `SingleSessionView.terminalContent(containerSize:)` (around line 431), replace the body. The new structure shows `TerminalPaneView` for `.active`, `IdleSnapshotView` for `.idle`:

```swift
@ViewBuilder
private func terminalContent(containerSize: CGSize) -> some View {
    if let controller, let client {
        switch client.renderActivity {
        case .active:
            activeTerminal(client: client, controller: controller, containerSize: containerSize)
        case .idle:
            IdleSnapshotView(snapshot: client.idleSnapshot) {
                client.wakeRenderer()
            }
        }
    } else {
        loadingPlaceholder
    }
}

@ViewBuilder
private func activeTerminal(
    client: SessionClient,
    controller: TerminalController,
    containerSize: CGSize
) -> some View {
    let pane = TerminalPaneView(
        session: client.session,
        controller: controller,
        focusRequestCount: focusRequestCount,
        softwareKeyboardInput: .init(
            insertText: { text in client.sendSoftwareKeyboardText(text) },
            deleteBackward: { client.deleteBackward() }
        ),
        preferredInterfaceStyle: preferredStyle,
        onWillUnmount: { snapshot in client.setIdleSnapshot(snapshot) }
    )
    let cellWidth = client.cellWidthPoints ?? TerminalWidthLayout.fallbackCellWidth
    let decision = TerminalWidthLayout.decide(
        containerWidth: containerSize.width,
        serverCols: client.serverGrid?.cols,
        cellWidth: cellWidth
    )
    switch decision {
    case .fits:
        pane
    case let .scrollable(frameWidth):
        ScrollView(.horizontal, showsIndicators: true) {
            pane.frame(width: frameWidth, height: containerSize.height)
        }
    }
}
```

- [ ] **Step 2: Build (will fail — `onWillUnmount` doesn't exist yet)**

Run: `swift build 2>&1 | tail -10`
Expected: error about missing `onWillUnmount` parameter on `TerminalPaneView`. Continue to Task 14.

- [ ] **Step 3: Don't commit yet — Task 14 completes the wiring**

---

### Task 14: Add snapshot capture to `TerminalPaneView`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift`

- [ ] **Step 1: Extend `TerminalPaneView` with `onWillUnmount`**

In `Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift`, add a new field + init parameter and a `dismantleUIView` impl that captures the snapshot before the view tears down:

```swift
public struct TerminalPaneView: UIViewRepresentable {
    public struct SoftwareKeyboardInput {
        public let insertText: (String) -> Void
        public let deleteBackward: () -> Void

        public init(
            insertText: @escaping (String) -> Void,
            deleteBackward: @escaping () -> Void
        ) {
            self.insertText = insertText
            self.deleteBackward = deleteBackward
        }
    }

    public let session: InMemoryTerminalSession
    public let controller: TerminalController
    public let focusRequestCount: Int
    public let softwareKeyboardInput: SoftwareKeyboardInput?
    public let preferredInterfaceStyle: UIUserInterfaceStyle
    /// @spec IOS-10.4
    /// Invoked when SwiftUI is about to remove this representable from
    /// the tree — typically because `renderActivity` flipped to `.idle`.
    /// Passes a UIImage snapshot of the live view (best-effort; may be
    /// nil if the Metal layer cannot be captured) so the SessionClient
    /// can hand it to `IdleSnapshotView`.
    public let onWillUnmount: ((UIImage?) -> Void)?

    public init(
        session: InMemoryTerminalSession,
        controller: TerminalController,
        focusRequestCount: Int = 0,
        softwareKeyboardInput: SoftwareKeyboardInput? = nil,
        preferredInterfaceStyle: UIUserInterfaceStyle = .unspecified,
        onWillUnmount: ((UIImage?) -> Void)? = nil
    ) {
        self.session = session
        self.controller = controller
        self.focusRequestCount = focusRequestCount
        self.softwareKeyboardInput = softwareKeyboardInput
        self.preferredInterfaceStyle = preferredInterfaceStyle
        self.onWillUnmount = onWillUnmount
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var lastFocusRequest: Int = 0
        var onWillUnmount: ((UIImage?) -> Void)?
    }

    public func makeUIView(context: Context) -> TerminalInputContainerView {
        let view = TerminalInputContainerView()
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.terminalView.controller = controller
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.inputProxy.insertTextHandler = softwareKeyboardInput?.insertText
        view.inputProxy.deleteBackwardHandler = softwareKeyboardInput?.deleteBackward
        context.coordinator.lastFocusRequest = focusRequestCount
        context.coordinator.onWillUnmount = onWillUnmount
        return view
    }

    public func updateUIView(_ view: TerminalInputContainerView, context: Context) {
        view.overrideUserInterfaceStyle = preferredInterfaceStyle
        view.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.inputProxy.insertTextHandler = softwareKeyboardInput?.insertText
        view.inputProxy.deleteBackwardHandler = softwareKeyboardInput?.deleteBackward
        context.coordinator.onWillUnmount = onWillUnmount
        if context.coordinator.lastFocusRequest != focusRequestCount {
            context.coordinator.lastFocusRequest = focusRequestCount
            DispatchQueue.main.async {
                view.focusKeyboardInput()
            }
        }
    }

    /// Called by SwiftUI before the representable is removed from the
    /// view tree. We capture the current visible frame as a UIImage and
    /// forward it through `onWillUnmount` so the SessionClient can hand
    /// it to the `IdleSnapshotView` that's about to take this view's
    /// place. The capture is best-effort — Metal-backed CALayers may
    /// produce a black frame; the IdleSnapshotView gracefully falls
    /// back to a stylized placeholder when the image is empty or nil.
    public static func dismantleUIView(_ view: TerminalInputContainerView, coordinator: Coordinator) {
        guard let onWillUnmount = coordinator.onWillUnmount else { return }
        let snapshot = Self.captureSnapshot(of: view)
        onWillUnmount(snapshot)
    }

    private static func captureSnapshot(of view: UIView) -> UIImage? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { ctx in
            view.layer.render(in: ctx.cgContext)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -10`
Expected: no errors.

- [ ] **Step 3: Run all mobile tests**

Run: `swift test --filter GrafttyMobileKitTests 2>&1 | tail -30`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Terminal/TerminalPaneView.swift Sources/GrafttyMobileKit/App/RootView.swift
git commit -m "feat(mobile): capture last-frame snapshot before unmounting TerminalPaneView (IOS-10.4)"
```

---

### Task 15: Wire idle-pause into `PaneLayoutView` for preview tiles

**Files:**
- Modify: `Sources/GrafttyMobileKit/UI/PaneLayoutView.swift`

This task ensures previews also benefit from idle-pausing. Read the existing `PaneLayoutView.swift` first.

- [ ] **Step 1: Inspect the current preview rendering**

Run: `grep -n "TerminalPaneView\|previewClient" /Users/btucker/projects/graftty/.worktrees/grafttymobile-battery/Sources/GrafttyMobileKit/UI/PaneLayoutView.swift`

This shows where the file mounts a `TerminalPaneView` for previews.

- [ ] **Step 2: Apply the same `renderActivity` branch**

Locate the point in `PaneLayoutView` where a `TerminalPaneView` is constructed for a preview (the part using `previewClient` closure). Wrap it in the same `switch client.renderActivity` pattern as `SingleSessionView.terminalContent` (Task 13). For preview tiles, pass `onWillUnmount: { snapshot in client.setIdleSnapshot(snapshot) }` the same way.

If the existing code reads (illustrative — match the actual structure when editing):

```swift
if let client = previewClient(leaf.sessionName) {
    TerminalPaneView(
        session: client.session,
        controller: ...,
        ...
    )
}
```

change it to:

```swift
if let client = previewClient(leaf.sessionName) {
    switch client.renderActivity {
    case .active:
        TerminalPaneView(
            session: client.session,
            controller: ...,
            ...,
            onWillUnmount: { snapshot in client.setIdleSnapshot(snapshot) }
        )
    case .idle:
        IdleSnapshotView(snapshot: client.idleSnapshot) {
            client.wakeRenderer()
        }
    }
}
```

- [ ] **Step 3: Build + test**

Run:
```bash
swift build 2>&1 | tail -10
swift test --filter GrafttyMobileKitTests 2>&1 | tail -10
```
Expected: green.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/UI/PaneLayoutView.swift
git commit -m "feat(mobile): branch preview tiles on renderActivity (IOS-10.3, 10.4)"
```

---

## Phase 4 — Specs and final integration

### Task 16: Regenerate `SPECS.md`

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Run the spec generator**

Run:
```bash
python3 scripts/generate-specs.py 2>&1
```
Expected: succeeds; updates `SPECS.md` with the IOS-10.x section we annotated with `@spec` lines.

- [ ] **Step 2: Verify clean check**

Run:
```bash
python3 scripts/generate-specs.py --check 2>&1
```
Expected: succeeds (no drift between annotations and `SPECS.md`).

- [ ] **Step 3: Commit**

```bash
git add SPECS.md
git commit -m "docs: regenerate SPECS.md with IOS-7.4 implementation and new IOS-10.x section"
```

---

### Task 17: Full test sweep + build sanity

**Files:** none.

- [ ] **Step 1: Run all mobile tests**

Run:
```bash
swift test --filter GrafttyMobileKitTests 2>&1 | tail -40
```
Expected: all green. If any test fails, fix and re-commit before proceeding.

- [ ] **Step 2: Full package build**

Run:
```bash
swift build 2>&1 | tail -20
```
Expected: no errors, no new warnings (the package uses `-warnings-as-errors` in debug per `Package.swift`, so any new warning is a hard failure).

- [ ] **Step 3: Check git status**

Run:
```bash
git status --short
git log --oneline main..HEAD
```
Expected: clean working tree; ~13 commits ahead of main.

---

## Acceptance criteria

The branch is ready for `/simplify` and PR once:

- [ ] `swift test --filter GrafttyMobileKitTests` is green.
- [ ] `swift build` is green with no warnings.
- [ ] `python3 scripts/generate-specs.py --check` passes.
- [ ] On-device manual validation has confirmed the snapshot is rendered (or that the stylized fallback engages gracefully). This is a hand-off note for the PR description, not a code change.
- [ ] PR description references this plan + the design doc and lists the spec IDs touched: IOS-7.4, IOS-10.1, IOS-10.2, IOS-10.3, IOS-10.4, IOS-10.5.

## Notes for the subagent driver

- **Order matters.** Phase 1 → 2 → 3 → 4. The refactor in Task 3 is a hard prerequisite for everything that follows; do not parallelize across phases.
- **Within a phase, tasks are mostly sequential too.** Task 11 (state on SessionClient) must precede Tasks 12/13/14/15 because they reference its API.
- **If a test scaffolding question arises** (e.g., the exact `PaneLayoutNode` shape needed by `PreviewCapTests`), read the actual source under `Sources/GrafttyProtocol/` and adapt — the plan's test code is illustrative for the *cap*, not for the layout API specifics.
- **No new comments unless the WHY is non-obvious** per the project's CLAUDE.md. The `@spec` doc comments are the exception — they're the spec annotations.
- **Commits per task.** Keep the history clean for review; the project's PR review style assumes commit-granular review.
