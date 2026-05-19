# WebRTC M3 + M4 — `panes_state` and `pane_control` Channel Handlers

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two concrete `ChannelHandler` implementations on top of M1.4's `ChannelRouter`: `panes_state` (server-pushed snapshots of `[WorktreePanes]`) and `pane_control` (RPC for split/close/swap). Both ship on both sides (Mac handler + mobile client). No production wiring of `ChannelRouter` into `GrafttyApp` yet — that lands when M2 wires the terminal channel.

**Architecture:** Each channel type gets a small wire-types module in `GrafttyProtocol` (JSON shape for payload frames) and a per-side `ChannelHandler` conformance. Mobile-side adds a high-level façade actor that opens the channel and exposes a Swift-native API (`WorktreePanesStore` for M3, `PaneControlClient` for M4). Mac-side handlers take an injected callback / lambda so production wiring can hand them the real `worktreePanesProvider` / `panesSubscription` / splittree mutators — but the tests inject fakes.

**Tech Stack:** Pure Swift, JSON, no new SwiftPM deps. Reuses M1.4's `ChannelRouter`, `ChannelOutbox`, `ChannelHandler` protocol, and `ChannelFrameCoder`.

**Scope this PR explicitly does NOT include:**
- Production wiring of `ChannelRouter` into `GrafttyApp.startup()` — that's M2's responsibility (when retiring `/ws` is finally feasible after M1.3).
- The `terminal` channel handler (M2).
- The Noise handshake gating channel access (M1.3 — human crypto review).
- Capability enforcement (`terminal_control` capability per REMOTE-7.1) — checked when wiring is finalized; in this PR the handler factories accept all opens.
- Actual splittree mutation behavior for `pane_control` RPCs — the Mac-side handler invokes an injected mutator callback; production passes the real `TerminalManager.split` / `destroySurfaces`; tests pass fakes. This PR ships the protocol + dispatch, not the actual `AppState` plumbing (deferred until iPad UI lands, since that's where the mutators are consumed end-to-end).

---

## File Structure

**Files to create (in `GrafttyProtocol`):**
- `Sources/GrafttyProtocol/PanesStateEnvelope.swift` — `PanesStateMessage` enum: `.snapshot([WorktreePanes])`.
- `Sources/GrafttyProtocol/PaneControlEnvelope.swift` — `PaneControlRequest` enum (split / close / swap) + `PaneControlResponse` enum (ok / error).

**Files to create (in `GrafttyKit` — Mac-side handlers):**
- `Sources/GrafttyKit/Remote/PanesStateHandler.swift` — server-side handler. Accepts an injected `subscribe` callback that fires once with the initial snapshot and again on each change; serializes to `payload` frames.
- `Sources/GrafttyKit/Remote/PaneControlHandler.swift` — server-side handler. Decodes `payload` frames as `PaneControlRequest`, invokes an injected `mutator` callback, encodes the response back as a `payload` frame.

**Files to create (in `GrafttyMobileKit` — mobile-side clients):**
- `Sources/GrafttyMobileKit/Remote/WorktreePanesStore.swift` — `@Observable` actor that owns the `panes_state` subscription channel. Exposes `current: [WorktreePanes]`.
- `Sources/GrafttyMobileKit/Remote/PaneControlClient.swift` — actor that opens a `pane_control` channel and exposes typed `split(...)` / `close(...)` / `swap(...)` async methods.

**Files to create (tests):**
- `Tests/GrafttyProtocolTests/PanesStateEnvelopeTests.swift`
- `Tests/GrafttyProtocolTests/PaneControlEnvelopeTests.swift`
- `Tests/GrafttyKitTests/Remote/PanesStateHandlerTests.swift`
- `Tests/GrafttyKitTests/Remote/PaneControlHandlerTests.swift`
- `Tests/GrafttyMobileKitTests/Remote/WorktreePanesStoreTests.swift`
- `Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift`

**Files modified:** none. Pure additions.

---

## Task 1: `PanesStateMessage` wire type

**Files:**
- Create: `Sources/GrafttyProtocol/PanesStateEnvelope.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Wire shape of a single `payload` frame on a `panes_state` channel.
/// Tagged-union JSON so future message types (deltas, presence pings)
/// can extend without breaking compatibility.
public enum PanesStateMessage: Sendable, Equatable {
    case snapshot([WorktreePanes])
}

extension PanesStateMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, worktrees }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let worktrees):
            try c.encode("snapshot", forKey: .type)
            try c.encode(worktrees, forKey: .worktrees)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "snapshot":
            let worktrees = try c.decode([WorktreePanes].self, forKey: .worktrees)
            self = .snapshot(worktrees)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown PanesStateMessage type: \(type)"
            )
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyProtocol/PanesStateEnvelope.swift
git commit -m "feat(protocol): PanesStateMessage — snapshot envelope for panes_state channel payloads"
```

---

## Task 2: `PanesStateMessage` round-trip tests

**Files:**
- Create: `Tests/GrafttyProtocolTests/PanesStateEnvelopeTests.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("PanesStateMessage — snapshot encode/decode round-trip and unknown-type rejection.")
struct PanesStateEnvelopeTests {

    @Test
    func snapshotRoundTrips() throws {
        let layout: PaneLayoutNode = .leaf(sessionName: "abc", title: "shell", attentionText: nil)
        let worktree = WorktreePanes(
            path: "/repo/wt-1",
            displayName: "feature-branch",
            displayBranch: "feature-branch",
            repoDisplayName: "graftty",
            isMainCheckout: false,
            state: .running,
            stats: nil,
            prBadge: nil,
            attentionText: nil,
            layout: layout
        )
        let original: PanesStateMessage = .snapshot([worktree])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: data)
        #expect(decoded == original)
    }

    @Test
    func unknownTypeThrows() throws {
        let json = Data(#"{"type":"future-message-type","payload":42}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PanesStateMessage.self, from: json)
        }
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter PanesStateEnvelopeTests 2>&1 | tail -5`
Expected: 2 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyProtocolTests/PanesStateEnvelopeTests.swift
git commit -m "test(protocol): PanesStateMessage round-trip + unknown-type"
```

---

## Task 3: `PaneControlRequest` / `PaneControlResponse` wire types

**Files:**
- Create: `Sources/GrafttyProtocol/PaneControlEnvelope.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// RPC request shape on a `pane_control` channel. Tagged-union JSON.
public enum PaneControlRequest: Sendable, Equatable {
    case split(target: String, direction: SplitDirection)
    case close(target: String)
    case swap(source: String, target: String)

    public enum SplitDirection: String, Codable, Sendable, CaseIterable {
        case horizontal
        case vertical
    }
}

extension PaneControlRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, target, direction, source
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .split(let target, let direction):
            try c.encode("split", forKey: .type)
            try c.encode(target, forKey: .target)
            try c.encode(direction, forKey: .direction)
        case .close(let target):
            try c.encode("close", forKey: .type)
            try c.encode(target, forKey: .target)
        case .swap(let source, let target):
            try c.encode("swap", forKey: .type)
            try c.encode(source, forKey: .source)
            try c.encode(target, forKey: .target)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "split":
            self = .split(
                target: try c.decode(String.self, forKey: .target),
                direction: try c.decode(SplitDirection.self, forKey: .direction)
            )
        case "close":
            self = .close(target: try c.decode(String.self, forKey: .target))
        case "swap":
            self = .swap(
                source: try c.decode(String.self, forKey: .source),
                target: try c.decode(String.self, forKey: .target)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown PaneControlRequest type: \(type)"
            )
        }
    }
}

/// RPC response shape. Reply to every `PaneControlRequest`. Errors
/// carry a short `code` (e.g. `"conflict"`, `"unknown-target"`) plus a
/// human message.
public enum PaneControlResponse: Sendable, Equatable {
    case ok
    case error(code: String, message: String)
}

extension PaneControlResponse: Codable {
    private enum CodingKeys: String, CodingKey { case ok, error, code, message }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try c.encode(true, forKey: .ok)
        case .error(let code, let message):
            try c.encode(false, forKey: .ok)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try c.decode(Bool.self, forKey: .ok)
        if ok {
            self = .ok
        } else {
            let code = try c.decode(String.self, forKey: .code)
            let message = try c.decode(String.self, forKey: .message)
            self = .error(code: code, message: message)
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyProtocol/PaneControlEnvelope.swift
git commit -m "feat(protocol): PaneControlRequest/Response — RPC wire types for pane_control channel"
```

---

## Task 4: `PaneControlRequest` / `PaneControlResponse` round-trip tests

**Files:**
- Create: `Tests/GrafttyProtocolTests/PaneControlEnvelopeTests.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("PaneControlRequest/Response — encode/decode round-trip for every variant.")
struct PaneControlEnvelopeTests {

    @Test
    func splitRoundTrips() throws {
        let req: PaneControlRequest = .split(target: "session-a", direction: .horizontal)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test
    func closeRoundTrips() throws {
        let req: PaneControlRequest = .close(target: "session-b")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test
    func swapRoundTrips() throws {
        let req: PaneControlRequest = .swap(source: "session-a", target: "session-c")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test
    func unknownRequestTypeThrows() throws {
        let json = Data(#"{"type":"unknown-op","target":"x"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PaneControlRequest.self, from: json)
        }
    }

    @Test
    func okResponseRoundTrips() throws {
        let resp: PaneControlResponse = .ok
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(PaneControlResponse.self, from: data)
        #expect(decoded == resp)
    }

    @Test
    func errorResponseRoundTrips() throws {
        let resp: PaneControlResponse = .error(code: "conflict", message: "target already split")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(PaneControlResponse.self, from: data)
        #expect(decoded == resp)
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter PaneControlEnvelopeTests 2>&1 | tail -5`
Expected: 6 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyProtocolTests/PaneControlEnvelopeTests.swift
git commit -m "test(protocol): PaneControlRequest/Response round-trip"
```

---

## Task 5: `PanesStateHandler` (Mac-side)

**Files:**
- Create: `Sources/GrafttyKit/Remote/PanesStateHandler.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import GrafttyProtocol

/// Server-side handler for the `panes_state` channel. On open, emits an
/// initial snapshot and then re-emits whenever the injected
/// `subscribe(_:)` callback fires the supplied closure with a fresh
/// `[WorktreePanes]`. The handler owns the dispatch lifecycle: when the
/// channel closes (via `onClose` or `onError`), the subscription is
/// cancelled and no further frames are emitted.
///
/// Production wires `subscribe` to the same `WorktreeMonitor` change
/// pipeline the desktop sidebar consumes. Tests pass a fake that fires
/// the callback on demand.
public actor PanesStateHandler: ChannelHandler {
    public nonisolated let channelType = "panes_state"

    public typealias Snapshot = [WorktreePanes]
    public typealias Subscribe = @Sendable (
        _ onChange: @escaping @Sendable (Snapshot) async -> Void
    ) async -> Cancellable

    public struct Cancellable: Sendable {
        private let cancel: @Sendable () -> Void
        public init(cancel: @escaping @Sendable () -> Void) {
            self.cancel = cancel
        }
        public func callAsFunction() { cancel() }
    }

    private let subscribe: Subscribe
    private var cancellable: Cancellable?
    private var outbox: ChannelOutbox?
    private var channelID: ChannelID?

    public init(subscribe: @escaping Subscribe) {
        self.subscribe = subscribe
    }

    public func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.outbox = outbox
        self.channelID = id
        let cancellable = await subscribe { [weak self] snapshot in
            await self?.send(snapshot: snapshot)
        }
        self.cancellable = cancellable
    }

    public func onPayload(_ data: Data) async {
        // panes_state is server-pushed; clients should not send payload
        // frames. Silently drop — a future PR may reply with an error
        // frame, but at this scope ignore-and-continue is correct.
    }

    public func onClose() async {
        teardown()
    }

    public func onError(_ code: String, message: String) async {
        teardown()
    }

    private func teardown() {
        cancellable?()
        cancellable = nil
        outbox = nil
        channelID = nil
    }

    private func send(snapshot: Snapshot) async {
        guard let outbox, let channelID else { return }
        let envelope = PanesStateMessage.snapshot(snapshot)
        let body: Data
        do {
            body = try JSONEncoder().encode(envelope)
        } catch {
            return
        }
        try? await outbox.send(.payload(ChannelPayload(id: channelID), body))
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Remote/PanesStateHandler.swift
git commit -m "feat(remote): PanesStateHandler — Mac-side panes_state channel emits snapshots"
```

---

## Task 6: `PanesStateHandler` tests

**Files:**
- Create: `Tests/GrafttyKitTests/Remote/PanesStateHandlerTests.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("PanesStateHandler — emits initial snapshot on open + re-emits on each subscribe-callback fire.")
struct PanesStateHandlerTests {

    @Test
    func emitsInitialSnapshotOnOpen() async throws {
        let initial = makeWorktrees(count: 1)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateHandler(subscribe: subscription.subscribe)
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(7), outbox: outboxSpy.outbox)

        try await pollUntil(timeout: .seconds(2)) {
            await outboxSpy.framesCount == 1
        }
        let frames = await outboxSpy.frames
        guard case .payload(let meta, let body) = frames[0] else {
            Issue.record("expected payload frame, got \(frames[0])")
            return
        }
        #expect(meta.id == ChannelID(7))
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: body)
        #expect(decoded == .snapshot(initial))
    }

    @Test
    func reemitsOnFurtherSubscribeFires() async throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateHandler(subscribe: subscription.subscribe)
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(11), outbox: outboxSpy.outbox)
        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }

        let next = makeWorktrees(count: 2)
        await subscription.fire(next)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 2 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let body) = frames[1] else {
            Issue.record("expected payload frame")
            return
        }
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: body)
        #expect(decoded == .snapshot(next))
    }

    @Test
    func cancelsSubscriptionOnClose() async throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateHandler(subscribe: subscription.subscribe)
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(1), outbox: outboxSpy.outbox)
        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }

        await handler.onClose()
        #expect(await subscription.cancelled)
    }

    private func makeWorktrees(count: Int) -> [WorktreePanes] {
        (0..<count).map { idx in
            WorktreePanes(
                path: "/repo/wt-\(idx)",
                displayName: "wt-\(idx)",
                displayBranch: "branch-\(idx)",
                repoDisplayName: "graftty",
                isMainCheckout: false,
                state: .running,
                stats: nil,
                prBadge: nil,
                attentionText: nil,
                layout: .leaf(sessionName: "s\(idx)", title: "shell", attentionText: nil)
            )
        }
    }
}

private actor FakeSubscription {
    private(set) var cancelled = false
    private var onChange: (@Sendable ([WorktreePanes]) async -> Void)?
    private let initialSnapshot: [WorktreePanes]

    init(initialSnapshot: [WorktreePanes]) {
        self.initialSnapshot = initialSnapshot
    }

    nonisolated func subscribe(
        _ onChange: @escaping @Sendable ([WorktreePanes]) async -> Void
    ) async -> PanesStateHandler.Cancellable {
        await register(onChange)
        let initial = await self.initialSnapshot
        await onChange(initial)
        return PanesStateHandler.Cancellable { [weak self] in
            Task { await self?.markCancelled() }
        }
    }

    private func register(_ callback: @escaping @Sendable ([WorktreePanes]) async -> Void) {
        self.onChange = callback
    }

    func fire(_ snapshot: [WorktreePanes]) async {
        await onChange?(snapshot)
    }

    func markCancelled() {
        cancelled = true
    }
}

private actor OutboxSpy {
    var frames: [ChannelFrame] = []
    var framesCount: Int { frames.count }

    nonisolated var outbox: ChannelOutbox {
        ChannelOutbox { [weak self] frame in
            await self?.append(frame)
        }
    }

    func append(_ frame: ChannelFrame) {
        frames.append(frame)
    }
}

private struct PollTimeout: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "pollUntil timed out after \(timeout)" }
}

private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(20),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    throw PollTimeout(timeout: timeout)
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter PanesStateHandlerTests 2>&1 | tail -5`
Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyKitTests/Remote/PanesStateHandlerTests.swift
git commit -m "test(remote): PanesStateHandler — initial snapshot + re-emit + close cancels subscription"
```

---

## Task 7: `PaneControlHandler` (Mac-side)

**Files:**
- Create: `Sources/GrafttyKit/Remote/PaneControlHandler.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import GrafttyProtocol

/// Server-side handler for the `pane_control` channel. Decodes incoming
/// payload frames as `PaneControlRequest`, dispatches to an injected
/// `mutator` callback (which performs the splittree mutation), and
/// returns the `PaneControlResponse` as an outbound payload frame.
///
/// Production wires `mutator` to the real splittree operations on
/// `AppState`. Tests pass a fake that records the request and produces
/// a canned response.
public actor PaneControlHandler: ChannelHandler {
    public nonisolated let channelType = "pane_control"

    public typealias Mutator = @Sendable (PaneControlRequest) async -> PaneControlResponse

    private let mutator: Mutator
    private var outbox: ChannelOutbox?
    private var channelID: ChannelID?

    public init(mutator: @escaping Mutator) {
        self.mutator = mutator
    }

    public func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.outbox = outbox
        self.channelID = id
    }

    public func onPayload(_ data: Data) async {
        guard let outbox, let channelID else { return }
        let request: PaneControlRequest
        do {
            request = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        } catch {
            await reply(
                outbox: outbox,
                channelID: channelID,
                response: .error(
                    code: "malformed-request",
                    message: String(describing: error)
                )
            )
            return
        }
        let response = await mutator(request)
        await reply(outbox: outbox, channelID: channelID, response: response)
    }

    public func onClose() async {
        teardown()
    }

    public func onError(_ code: String, message: String) async {
        teardown()
    }

    private func teardown() {
        outbox = nil
        channelID = nil
    }

    private func reply(
        outbox: ChannelOutbox,
        channelID: ChannelID,
        response: PaneControlResponse
    ) async {
        let body: Data
        do {
            body = try JSONEncoder().encode(response)
        } catch {
            return
        }
        try? await outbox.send(.payload(ChannelPayload(id: channelID), body))
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Remote/PaneControlHandler.swift
git commit -m "feat(remote): PaneControlHandler — Mac-side pane_control RPC dispatch"
```

---

## Task 8: `PaneControlHandler` tests

**Files:**
- Create: `Tests/GrafttyKitTests/Remote/PaneControlHandlerTests.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("PaneControlHandler — decodes RPC requests, dispatches to mutator, replies with response.")
struct PaneControlHandlerTests {

    @Test
    func decodesAndDispatchesSplitRequest() async throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlHandler(mutator: recorder.handle)
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(3), outbox: outboxSpy.outbox)

        let request: PaneControlRequest = .split(target: "session-a", direction: .vertical)
        let body = try JSONEncoder().encode(request)
        await handler.onPayload(body)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let respBody) = frames[0] else {
            Issue.record("expected payload frame")
            return
        }
        let resp = try JSONDecoder().decode(PaneControlResponse.self, from: respBody)
        #expect(resp == .ok)
        #expect(await recorder.lastRequest == request)
    }

    @Test
    func malformedRequestRepliesWithError() async throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlHandler(mutator: recorder.handle)
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(4), outbox: outboxSpy.outbox)

        let garbage = Data("{}".utf8)
        await handler.onPayload(garbage)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let respBody) = frames[0] else {
            Issue.record("expected payload frame")
            return
        }
        let resp = try JSONDecoder().decode(PaneControlResponse.self, from: respBody)
        guard case .error(let code, _) = resp else {
            Issue.record("expected error response, got \(resp)")
            return
        }
        #expect(code == "malformed-request")
        #expect(await recorder.lastRequest == nil)
    }

    @Test
    func mutatorErrorPassesThroughToWire() async throws {
        let conflictResponder = ConflictResponder()
        let handler = PaneControlHandler(mutator: conflictResponder.handle)
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(8), outbox: outboxSpy.outbox)

        let body = try JSONEncoder().encode(PaneControlRequest.close(target: "session-z"))
        await handler.onPayload(body)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let respBody) = frames[0] else {
            Issue.record("expected payload frame")
            return
        }
        let resp = try JSONDecoder().decode(PaneControlResponse.self, from: respBody)
        #expect(resp == .error(code: "conflict", message: "target already busy"))
    }
}

private actor MutatorRecorder {
    var lastRequest: PaneControlRequest?

    nonisolated func handle(_ request: PaneControlRequest) async -> PaneControlResponse {
        await record(request)
        return .ok
    }

    private func record(_ request: PaneControlRequest) {
        self.lastRequest = request
    }
}

private struct ConflictResponder: Sendable {
    @Sendable func handle(_ request: PaneControlRequest) async -> PaneControlResponse {
        .error(code: "conflict", message: "target already busy")
    }
}

private actor OutboxSpy {
    var frames: [ChannelFrame] = []
    var framesCount: Int { frames.count }

    nonisolated var outbox: ChannelOutbox {
        ChannelOutbox { [weak self] frame in
            await self?.append(frame)
        }
    }

    func append(_ frame: ChannelFrame) {
        frames.append(frame)
    }
}

private struct PollTimeout: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "pollUntil timed out after \(timeout)" }
}

private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(20),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    throw PollTimeout(timeout: timeout)
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter PaneControlHandlerTests 2>&1 | tail -5`
Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyKitTests/Remote/PaneControlHandlerTests.swift
git commit -m "test(remote): PaneControlHandler — split RPC + malformed body + mutator error"
```

---

## Task 9: `WorktreePanesStore` (mobile-side observable)

**Files:**
- Create: `Sources/GrafttyMobileKit/Remote/WorktreePanesStore.swift`

- [ ] **Step 1: Write the file**

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side façade for the `panes_state` channel. Opens the channel on
/// the supplied `ChannelRouter`, decodes inbound snapshots, and exposes
/// `current: [WorktreePanes]` as actor-isolated observable state the
/// sidebar can read.
public actor WorktreePanesStore {

    public private(set) var current: [WorktreePanes] = []

    private let router: ChannelRouter
    private var channelID: ChannelID?

    public init(router: ChannelRouter) {
        self.router = router
    }

    /// Open the `panes_state` channel. Returns when the initial open
    /// frame has been sent — snapshot frames arrive asynchronously.
    public func subscribe() async throws {
        let handler = SubscriberHandler { [weak self] snapshot in
            await self?.applySnapshot(snapshot)
        }
        let id = try await router.open(type: "panes_state", handler: handler)
        self.channelID = id
    }

    public func unsubscribe() async {
        guard let id = channelID else { return }
        channelID = nil
        try? await router.close(id)
    }

    private func applySnapshot(_ snapshot: [WorktreePanes]) {
        self.current = snapshot
    }
}

/// Handler installed by `WorktreePanesStore.subscribe()`. Reads inbound
/// `payload` frames, decodes each as a `PanesStateMessage`, and forwards
/// `snapshot` payloads to the store.
private actor SubscriberHandler: ChannelHandler {
    nonisolated let channelType = "panes_state"

    private let onSnapshot: @Sendable ([WorktreePanes]) async -> Void

    init(onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void) {
        self.onSnapshot = onSnapshot
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        // No-op: the server pushes; the client doesn't send.
    }

    func onPayload(_ data: Data) async {
        let message: PanesStateMessage
        do {
            message = try JSONDecoder().decode(PanesStateMessage.self, from: data)
        } catch {
            return
        }
        switch message {
        case .snapshot(let worktrees):
            await onSnapshot(worktrees)
        }
    }

    func onClose() async {}
    func onError(_ code: String, message: String) async {}
}
#endif
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/WorktreePanesStore.swift
git commit -m "feat(remote): WorktreePanesStore — mobile-side panes_state subscriber"
```

---

## Task 10: `WorktreePanesStore` tests

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Remote/WorktreePanesStoreTests.swift`

- [ ] **Step 1: Write the file**

```swift
#if canImport(UIKit)
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("WorktreePanesStore — opens panes_state channel, applies decoded snapshot to current.")
struct WorktreePanesStoreTests {

    @Test
    func applySnapshotUpdatesCurrent() async throws {
        let pair = FakePair()
        let mobileRouter = ChannelRouter(transport: pair.aliceSide)
        let serverRouter = ChannelRouter(transport: pair.bobSide)
        await mobileRouter.start()
        await serverRouter.start()

        let initial = makeWorktrees(count: 1)
        let panes = PassThroughPanesSource(initial: initial)
        await serverRouter.register(type: "panes_state") {
            ServerSidePushHandler(source: panes)
        }

        let store = WorktreePanesStore(router: mobileRouter)
        try await store.subscribe()

        try await pollUntil(timeout: .seconds(2)) { await store.current.count == 1 }
        let current = await store.current
        #expect(current.first?.path == "/repo/wt-0")

        // Push a second snapshot from the server.
        let next = makeWorktrees(count: 3)
        await panes.fire(next)
        try await pollUntil(timeout: .seconds(2)) { await store.current.count == 3 }
    }

    @Test
    func unsubscribeCleansUp() async throws {
        let pair = FakePair()
        let mobileRouter = ChannelRouter(transport: pair.aliceSide)
        let serverRouter = ChannelRouter(transport: pair.bobSide)
        await mobileRouter.start()
        await serverRouter.start()

        let initial = makeWorktrees(count: 0)
        let panes = PassThroughPanesSource(initial: initial)
        await serverRouter.register(type: "panes_state") {
            ServerSidePushHandler(source: panes)
        }

        let store = WorktreePanesStore(router: mobileRouter)
        try await store.subscribe()
        try await pollUntil(timeout: .seconds(2)) {
            await store.current.isEmpty   // initial snapshot is empty by construction
        }

        await store.unsubscribe()
        try await pollUntil(timeout: .seconds(2)) { await panes.cancelled }
    }

    private func makeWorktrees(count: Int) -> [WorktreePanes] {
        (0..<count).map { idx in
            WorktreePanes(
                path: "/repo/wt-\(idx)",
                displayName: "wt-\(idx)",
                displayBranch: "branch-\(idx)",
                repoDisplayName: "graftty",
                isMainCheckout: false,
                state: .running,
                stats: nil,
                prBadge: nil,
                attentionText: nil,
                layout: .leaf(sessionName: "s\(idx)", title: "shell", attentionText: nil)
            )
        }
    }
}

/// Server-side mock that sends the initial snapshot on open, then any
/// snapshot the test pushes via `fire(_:)`.
private actor PassThroughPanesSource {
    private(set) var cancelled = false
    private var emit: (@Sendable ([WorktreePanes]) async -> Void)?
    private let initial: [WorktreePanes]

    init(initial: [WorktreePanes]) {
        self.initial = initial
    }

    func register(_ emit: @escaping @Sendable ([WorktreePanes]) async -> Void) async {
        self.emit = emit
        await emit(initial)
    }

    func fire(_ snapshot: [WorktreePanes]) async {
        await emit?(snapshot)
    }

    func markCancelled() {
        cancelled = true
    }
}

private actor ServerSidePushHandler: ChannelHandler {
    nonisolated let channelType = "panes_state"
    private let source: PassThroughPanesSource

    init(source: PassThroughPanesSource) {
        self.source = source
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        await source.register { snapshot in
            let envelope = PanesStateMessage.snapshot(snapshot)
            guard let data = try? JSONEncoder().encode(envelope) else { return }
            try? await outbox.send(.payload(ChannelPayload(id: id), data))
        }
    }

    func onPayload(_ data: Data) async {}
    func onClose() async {
        await source.markCancelled()
    }
    func onError(_ code: String, message: String) async {
        await source.markCancelled()
    }
}

private final class FakePair: Sendable {
    let aliceSide: AliceTransport
    let bobSide: BobTransport
    init() {
        let aliceToBob = FakeBridge()
        let bobToAlice = FakeBridge()
        self.aliceSide = AliceTransport(out: aliceToBob, in: bobToAlice)
        self.bobSide = BobTransport(out: bobToAlice, in: aliceToBob)
    }
}

private actor FakeBridge {
    var subscriber: (@Sendable (Data) async -> Void)?
    func subscribe(_ s: @escaping @Sendable (Data) async -> Void) { subscriber = s }
    func publish(_ data: Data) async { await subscriber?(data) }
}

private struct AliceTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
    }
}

private struct BobTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
    }
}

private struct PollTimeout: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "pollUntil timed out after \(timeout)" }
}

private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(20),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    throw PollTimeout(timeout: timeout)
}
#endif
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter WorktreePanesStoreTests 2>&1 | tail -5`
Expected: skipped on macOS (UIKit-guarded). Compile must be clean.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyMobileKitTests/Remote/WorktreePanesStoreTests.swift
git commit -m "test(remote): WorktreePanesStore — applies decoded snapshot + unsubscribe cleanup"
```

---

## Task 11: `PaneControlClient` (mobile-side RPC)

**Files:**
- Create: `Sources/GrafttyMobileKit/Remote/PaneControlClient.swift`

- [ ] **Step 1: Write the file**

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Mobile-side façade for the `pane_control` channel. Opens a single
/// pane_control channel on construction and exposes typed RPC methods
/// (`split`, `close`, `swap`). Each RPC awaits its response over the
/// channel before returning.
public actor PaneControlClient {

    public enum ClientError: Error, Equatable, Sendable {
        case notOpen
        case rpc(code: String, message: String)
        case unexpectedFrame
    }

    private let router: ChannelRouter
    private var outbox: ChannelOutbox?
    private var channelID: ChannelID?
    private var pendingResponse: CheckedContinuation<PaneControlResponse, Error>?

    public init(router: ChannelRouter) {
        self.router = router
    }

    public func open() async throws {
        let handler = ResponseHandler { [weak self] response in
            await self?.deliverResponse(response)
        }
        let id = try await router.open(type: "pane_control", handler: handler)
        self.channelID = id
        // Outbox is stored by the handler factory; for direct sends here
        // we use the router's `open` path. Subsequent sends use a fresh
        // payload frame built around this id.
    }

    public func close() async {
        guard let id = channelID else { return }
        channelID = nil
        try? await router.close(id)
    }

    public func split(target: String, direction: PaneControlRequest.SplitDirection) async throws -> PaneControlResponse {
        try await sendAndAwait(.split(target: target, direction: direction))
    }

    public func close(target: String) async throws -> PaneControlResponse {
        try await sendAndAwait(.close(target: target))
    }

    public func swap(source: String, target: String) async throws -> PaneControlResponse {
        try await sendAndAwait(.swap(source: source, target: target))
    }

    private func sendAndAwait(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        guard let outbox, let channelID else { throw ClientError.notOpen }
        let body = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PaneControlResponse, Error>) in
            self.pendingResponse = continuation
            Task {
                do {
                    try await outbox.send(.payload(ChannelPayload(id: channelID), body))
                } catch {
                    let c = pendingResponse
                    pendingResponse = nil
                    c?.resume(throwing: error)
                }
            }
        }
    }

    private func deliverResponse(_ response: PaneControlResponse) {
        let c = pendingResponse
        pendingResponse = nil
        c?.resume(returning: response)
    }

    func captureOutbox(_ outbox: ChannelOutbox) {
        self.outbox = outbox
    }
}

/// Handler stored on the `pane_control` channel. Captures the outbox at
/// open time so the client can send subsequent RPCs without going
/// through `router.open()` again, and forwards payload frames as
/// responses to the awaiting continuation.
private actor ResponseHandler: ChannelHandler {
    nonisolated let channelType = "pane_control"

    private let onResponse: @Sendable (PaneControlResponse) async -> Void

    init(onResponse: @escaping @Sendable (PaneControlResponse) async -> Void) {
        self.onResponse = onResponse
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        // The client also needs the outbox; in the test/loopback wiring
        // the `PaneControlClient` accesses outbox via the closure passed
        // in at construction time.
    }

    func onPayload(_ data: Data) async {
        let response: PaneControlResponse
        do {
            response = try JSONDecoder().decode(PaneControlResponse.self, from: data)
        } catch {
            response = .error(code: "malformed-response", message: String(describing: error))
        }
        await onResponse(response)
    }

    func onClose() async {}
    func onError(_ code: String, message: String) async {}
}
#endif
```

**Note on the outbox-capture pattern:** the comment block in Step 1 mentions that the client needs the outbox. The current `ChannelRouter.open(type:handler:)` API gives the outbox to the handler's `onOpen`, not back to the caller. To get the outbox into `PaneControlClient` cleanly, route it through a callback on the handler's init. **Update `PaneControlClient` to pass an outbox-capture closure into `ResponseHandler` at construction:**

Replace the `open()` and `ResponseHandler` body to thread the outbox via a captured-closure pattern. Here's the corrected `open()` + `ResponseHandler`:

```swift
    public func open() async throws {
        let handler = ResponseHandler(
            onOutbox: { [weak self] outbox in
                await self?.captureOutbox(outbox)
            },
            onResponse: { [weak self] response in
                await self?.deliverResponse(response)
            }
        )
        let id = try await router.open(type: "pane_control", handler: handler)
        self.channelID = id
    }
```

and

```swift
private actor ResponseHandler: ChannelHandler {
    nonisolated let channelType = "pane_control"

    private let onOutbox: @Sendable (ChannelOutbox) async -> Void
    private let onResponse: @Sendable (PaneControlResponse) async -> Void

    init(
        onOutbox: @escaping @Sendable (ChannelOutbox) async -> Void,
        onResponse: @escaping @Sendable (PaneControlResponse) async -> Void
    ) {
        self.onOutbox = onOutbox
        self.onResponse = onResponse
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        await onOutbox(outbox)
    }

    func onPayload(_ data: Data) async {
        let response: PaneControlResponse
        do {
            response = try JSONDecoder().decode(PaneControlResponse.self, from: data)
        } catch {
            response = .error(code: "malformed-response", message: String(describing: error))
        }
        await onResponse(response)
    }

    func onClose() async {}
    func onError(_ code: String, message: String) async {}
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/PaneControlClient.swift
git commit -m "feat(remote): PaneControlClient — mobile-side pane_control RPC façade"
```

---

## Task 12: `PaneControlClient` tests

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift`

- [ ] **Step 1: Write the file**

```swift
#if canImport(UIKit)
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("PaneControlClient — round-trips split/close/swap RPCs against a server-side echo handler.")
struct PaneControlClientTests {

    @Test
    func splitRoundTripReturnsOk() async throws {
        let env = try await loopback { _ in .ok }
        let response = try await env.client.split(target: "session-a", direction: .horizontal)
        #expect(response == .ok)
    }

    @Test
    func closeRoundTripReturnsOk() async throws {
        let env = try await loopback { _ in .ok }
        let response = try await env.client.close(target: "session-b")
        #expect(response == .ok)
    }

    @Test
    func swapRoundTripReturnsOk() async throws {
        let env = try await loopback { _ in .ok }
        let response = try await env.client.swap(source: "session-a", target: "session-c")
        #expect(response == .ok)
    }

    @Test
    func errorResponsePassesThrough() async throws {
        let env = try await loopback { _ in
            .error(code: "conflict", message: "concurrent split rejected")
        }
        let response = try await env.client.split(target: "session-a", direction: .vertical)
        #expect(response == .error(code: "conflict", message: "concurrent split rejected"))
    }

    private struct Env {
        let client: PaneControlClient
    }

    private func loopback(
        mutator: @escaping @Sendable (PaneControlRequest) async -> PaneControlResponse
    ) async throws -> Env {
        let pair = FakePair()
        let mobileRouter = ChannelRouter(transport: pair.aliceSide)
        let serverRouter = ChannelRouter(transport: pair.bobSide)
        await mobileRouter.start()
        await serverRouter.start()

        await serverRouter.register(type: "pane_control") {
            PaneControlHandlerProxy(mutator: mutator)
        }

        let client = PaneControlClient(router: mobileRouter)
        try await client.open()
        // Allow the open frame to ride across before the first RPC.
        try await Task.sleep(for: .milliseconds(50))
        return Env(client: client)
    }
}

/// In-test analogue of `PaneControlHandler` — same logic, but defined
/// here so the mobile-side test target doesn't need to import GrafttyKit
/// (it can't, target boundary).
private actor PaneControlHandlerProxy: ChannelHandler {
    nonisolated let channelType = "pane_control"
    private let mutator: @Sendable (PaneControlRequest) async -> PaneControlResponse
    private var outbox: ChannelOutbox?
    private var id: ChannelID?

    init(mutator: @escaping @Sendable (PaneControlRequest) async -> PaneControlResponse) {
        self.mutator = mutator
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.outbox = outbox
        self.id = id
    }

    func onPayload(_ data: Data) async {
        guard let outbox, let id else { return }
        let request: PaneControlRequest
        do {
            request = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        } catch {
            let body = try? JSONEncoder().encode(
                PaneControlResponse.error(code: "malformed-request", message: String(describing: error))
            )
            if let body { try? await outbox.send(.payload(ChannelPayload(id: id), body)) }
            return
        }
        let response = await mutator(request)
        guard let body = try? JSONEncoder().encode(response) else { return }
        try? await outbox.send(.payload(ChannelPayload(id: id), body))
    }

    func onClose() async {}
    func onError(_ code: String, message: String) async {}
}

private final class FakePair: Sendable {
    let aliceSide: AliceTransport
    let bobSide: BobTransport
    init() {
        let aliceToBob = FakeBridge()
        let bobToAlice = FakeBridge()
        self.aliceSide = AliceTransport(out: aliceToBob, in: bobToAlice)
        self.bobSide = BobTransport(out: bobToAlice, in: aliceToBob)
    }
}

private actor FakeBridge {
    var subscriber: (@Sendable (Data) async -> Void)?
    func subscribe(_ s: @escaping @Sendable (Data) async -> Void) { subscriber = s }
    func publish(_ data: Data) async { await subscriber?(data) }
}

private struct AliceTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
    }
}

private struct BobTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
    }
}
#endif
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter PaneControlClientTests 2>&1 | tail -5`
Expected: UIKit-guarded; skipped on macOS. Compile must be clean.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyMobileKitTests/Remote/PaneControlClientTests.swift
git commit -m "test(remote): PaneControlClient — split/close/swap round-trip + error pass-through"
```

---

## Task 13: Full suite verification

**Files:** none.

- [ ] **Step 1: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: pass. Newly added: 2 (envelope) + 6 (envelope) + 3 (panes_state handler) + 3 (pane_control handler) = 14 new tests visible on macOS, plus 2 + 4 UIKit-guarded tests (mobile clients) skipped on macOS. Total visible: 1924 + 14 = 1938. Pre-existing flakes don't count.

- [ ] **Step 2: Clean working tree**

Run: `git status --short`
Expected: empty (only the untracked `.claude/` directory is acceptable).

- [ ] **Step 3: Spec drift check**

Run: `python3 scripts/generate-specs.py --check`
Expected: exits 0.

---

## Self-Review

- **Spec coverage:** REMOTE-6.x (panes_state) and REMOTE-7.x (pane_control) get their protocol-layer implementations. No capability gating yet (deferred to when production wiring lands alongside iPad UI).
- **Placeholders:** none — every code block is complete code. The "production wires" comments are deferral notes, not placeholders.
- **Type consistency:** `PanesStateMessage`, `PaneControlRequest` (with `SplitDirection`), `PaneControlResponse`, `PanesStateHandler`, `PaneControlHandler`, `WorktreePanesStore`, `PaneControlClient` — all names consistent across Tasks 1-12.
- **Cross-target test fakes:** `FakePair` + `FakeBridge` + `AliceTransport` + `BobTransport` + `pollUntil` are duplicated in each mobile-side test file because they can't be shared cross-target. Same forced-by-SwiftPM constraint as M1.4 router tests.
- **iOS-only guards:** mobile-side façades and their tests carry `#if canImport(UIKit)`; Mac-side handlers and tests do not.
