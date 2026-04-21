# Claude Code Channels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v1 of the Claude Code Channels feature per `docs/superpowers/specs/2026-04-21-claude-channels-design.md` — a new Settings tab with an editable prompt, an MCP subprocess bridge (`graftty mcp-channel`), and a `ChannelRouter` that forwards `PRStatusStore` transitions into running Claude sessions.

**Architecture:** Graftty.app runs a new `ChannelRouter` on `graftty-channels.sock` that maintains a `worktreePath → connection` subscriber map; each Claude session runs a `graftty mcp-channel` subprocess that subscribes on startup (via `git rev-parse`) and translates JSON socket events into MCP `notifications/claude/channel`. The user's editable prompt propagates live via `type=instructions` fan-out on a 500ms debounce.

**Tech Stack:** Swift 5.10+ / macOS 14+ / `@AppStorage` / `swift-argument-parser` / XCTest (with `-warnings-as-errors` in debug). No new dependencies.

---

## Pre-work: file structure

**New files:**
- `Sources/GrafttyKit/Channels/ChannelEvent.swift` — Codable types for wire messages
- `Sources/GrafttyKit/Channels/ChannelSocketServer.swift` — long-lived-connection socket server
- `Sources/GrafttyKit/Channels/ChannelRouter.swift` — subscriber map + event fanout + prompt debounce
- `Sources/GrafttyKit/Channels/ChannelPluginInstaller.swift` — writes plugin config into `~/.claude/plugins/`
- `Sources/GrafttyKit/Channels/MCPStdioServer.swift` — hand-rolled MCP JSON-RPC (library; CLI shim wraps it)
- `Sources/GrafttyCLI/MCPChannel.swift` — `graftty mcp-channel` subcommand (thin shell)
- `Sources/Graftty/Views/Settings/ChannelsSettingsPane.swift` — Channels tab SwiftUI view
- `Resources/plugins/graftty-channel/plugin.json` — plugin manifest
- `Resources/plugins/graftty-channel/mcp.json.template` — MCP config template (no leading dot in the template filename — Swift resource bundling strips dotfiles)
- `Tests/GrafttyKitTests/Channels/ChannelEventTests.swift`
- `Tests/GrafttyKitTests/Channels/ChannelSocketServerTests.swift`
- `Tests/GrafttyKitTests/Channels/ChannelRouterTests.swift`
- `Tests/GrafttyKitTests/Channels/ChannelPluginInstallerTests.swift`
- `Tests/GrafttyKitTests/Channels/MCPStdioServerTests.swift`
- `Tests/GrafttyKitTests/Channels/ChannelCommandComposerTests.swift`

**Modified files:**
- `Sources/GrafttyKit/Notification/SocketPathResolver.swift` — add `resolveChannels()`
- `Sources/GrafttyKit/PRStatus/PRStatusStore.swift` — add `onTransition` callback + detection
- `Sources/GrafttyKit/DefaultCommandDecision.swift` — add channel-flag composition
- `Sources/GrafttyCLI/CLI.swift` — register `MCPChannel` subcommand
- `Sources/Graftty/Views/SettingsView.swift` — add Channels tab
- `Sources/Graftty/GrafttyApp.swift` — wire `ChannelRouter` + plugin installer
- `Package.swift` — add `Resources/plugins` to Graftty target
- `SPECS.md` — add CHANNELS section

---

## Task 1: `ChannelEvent` types and Codable round-trips

Defines the wire schema for the channels socket and the event-type taxonomy used throughout the code.

**Files:**
- Create: `Sources/GrafttyKit/Channels/ChannelEvent.swift`
- Create: `Tests/GrafttyKitTests/Channels/ChannelEventTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/GrafttyKitTests/Channels/ChannelEventTests.swift`:
```swift
import XCTest
@testable import GrafttyKit

final class ChannelEventTests: XCTestCase {
    func testSubscribeMessageRoundTrip() throws {
        let original = ChannelClientMessage.subscribe(
            worktree: "/repos/acme-web/feature/login",
            version: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChannelClientMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPRStateChangedEventRoundTrip() throws {
        let original = ChannelServerMessage.event(
            type: "pr_state_changed",
            attrs: [
                "pr_number": "42",
                "from": "open",
                "to": "merged",
                "provider": "github",
                "repo": "acme/web",
                "worktree": "/repos/acme-web/feature/login",
                "pr_url": "https://github.com/acme/web/pull/42",
            ],
            body: "PR #42 merged by @alice"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChannelServerMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testInstructionsEventRoundTrip() throws {
        let original = ChannelServerMessage.event(
            type: "instructions",
            attrs: [:],
            body: "You receive events from Graftty..."
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChannelServerMessage.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownClientMessageTypeRejected() {
        let json = #"{"type": "nonsense", "worktree": "/x"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(ChannelClientMessage.self, from: json))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChannelEventTests 2>&1 | head -30`

Expected: compilation failure — `ChannelClientMessage`/`ChannelServerMessage` not defined.

- [ ] **Step 3: Write the implementation**

`Sources/GrafttyKit/Channels/ChannelEvent.swift`:
```swift
import Foundation

/// Messages sent BY channel subscribers (subprocess) TO the router.
public enum ChannelClientMessage: Codable, Equatable, Sendable {
    case subscribe(worktree: String, version: Int)

    private enum CodingKeys: String, CodingKey {
        case type, worktree, version
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .subscribe(worktree, version):
            try c.encode("subscribe", forKey: .type)
            try c.encode(worktree, forKey: .worktree)
            try c.encode(version, forKey: .version)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "subscribe":
            self = .subscribe(
                worktree: try c.decode(String.self, forKey: .worktree),
                version: try c.decode(Int.self, forKey: .version)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown ChannelClientMessage type: \(type)"
            )
        }
    }
}

/// Messages sent BY the router TO channel subscribers.
public enum ChannelServerMessage: Codable, Equatable, Sendable {
    case event(type: String, attrs: [String: String], body: String)

    private enum CodingKeys: String, CodingKey {
        case type, attrs, body
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .event(type, attrs, body):
            try c.encode(type, forKey: .type)
            try c.encode(attrs, forKey: .attrs)
            try c.encode(body, forKey: .body)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let attrs = try c.decodeIfPresent([String: String].self, forKey: .attrs) ?? [:]
        let body = try c.decode(String.self, forKey: .body)
        self = .event(type: type, attrs: attrs, body: body)
    }
}

/// Well-known event type names. Constants rather than an enum so the router
/// and subprocess can round-trip unknown types (forward-compat for v2).
public enum ChannelEventType {
    public static let prStateChanged = "pr_state_changed"
    public static let ciConclusionChanged = "ci_conclusion_changed"
    public static let mergeStateChanged = "merge_state_changed"
    public static let instructions = "instructions"
    public static let channelError = "channel_error"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ChannelEventTests 2>&1 | tail -10`
Expected: `Test Suite 'ChannelEventTests' passed`.

- [ ] **Step 5: Commit**
```bash
git add Sources/GrafttyKit/Channels/ChannelEvent.swift Tests/GrafttyKitTests/Channels/ChannelEventTests.swift
git commit -m "feat(channels): add ChannelEvent wire types

Codable representations for the graftty-channels.sock protocol:
ChannelClientMessage.subscribe from the MCP subprocess, and
ChannelServerMessage.event pushed by the router.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `SocketPathResolver` — channel socket path

Extends the existing resolver with a second path for the channels socket, distinct from the control socket.

**Files:**
- Modify: `Sources/GrafttyKit/Notification/SocketPathResolver.swift`
- Create: `Tests/GrafttyKitTests/Channels/SocketPathResolverChannelsTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/GrafttyKitTests/Channels/SocketPathResolverChannelsTests.swift`:
```swift
import XCTest
@testable import GrafttyKit

final class SocketPathResolverChannelsTests: XCTestCase {
    func testChannelsPathDefaultsToApplicationSupportSubdirectory() {
        let tempDir = URL(fileURLWithPath: "/tmp/GrafttyTest")
        let path = SocketPathResolver.resolveChannels(
            environment: [:],
            defaultDirectory: tempDir
        )
        XCTAssertEqual(path, "/tmp/GrafttyTest/graftty-channels.sock")
    }

    func testChannelsPathHonorsGRAFTTYChannelsSockEnvironment() {
        let path = SocketPathResolver.resolveChannels(
            environment: ["GRAFTTY_CHANNELS_SOCK": "/custom/chan.sock"],
            defaultDirectory: URL(fileURLWithPath: "/unused")
        )
        XCTAssertEqual(path, "/custom/chan.sock")
    }

    func testEmptyEnvironmentValueFallsBackToDefault() {
        let path = SocketPathResolver.resolveChannels(
            environment: ["GRAFTTY_CHANNELS_SOCK": ""],
            defaultDirectory: URL(fileURLWithPath: "/tmp/GrafttyTest")
        )
        XCTAssertEqual(path, "/tmp/GrafttyTest/graftty-channels.sock")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SocketPathResolverChannelsTests 2>&1 | head -20`
Expected: compilation failure — `resolveChannels` undefined.

- [ ] **Step 3: Extend the resolver**

Edit `Sources/GrafttyKit/Notification/SocketPathResolver.swift` — add the `resolveChannels` static method directly below `resolve`:

```swift
    /// Path for the channels socket — distinct from the control socket so
    /// the two can evolve independently. Long-lived subscribers connect
    /// here and stay connected for the life of their Claude session.
    public static func resolveChannels(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultDirectory: URL = AppState.defaultDirectory
    ) -> String {
        if let v = environment["GRAFTTY_CHANNELS_SOCK"], !v.isEmpty {
            return v
        }
        return defaultDirectory.appendingPathComponent("graftty-channels.sock").path
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SocketPathResolverChannelsTests 2>&1 | tail -10`
Expected: `Test Suite 'SocketPathResolverChannelsTests' passed`.

- [ ] **Step 5: Commit**
```bash
git add Sources/GrafttyKit/Notification/SocketPathResolver.swift Tests/GrafttyKitTests/Channels/SocketPathResolverChannelsTests.swift
git commit -m "feat(channels): SocketPathResolver.resolveChannels

Adds a second resolver for the channels socket, keyed by
GRAFTTY_CHANNELS_SOCK with the same empty-value semantics as
the control resolver.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `PRStatusStore` transition detection + callback

Adds the event-emitting hook the router listens on. Reuses existing `PRInfo` state for comparison — no new polling code.

**Files:**
- Modify: `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`
- Create: `Tests/GrafttyKitTests/PRStatus/PRStatusStoreTransitionTests.swift`

- [ ] **Step 1: Read `PRStatusStore.swift` end-to-end** to understand `PRInfo`, where `infos[path]` is written, and how `onPRMerged` is already wired. The new `onTransition` fires in the same write path.

Run: `cat Sources/GrafttyKit/PRStatus/PRStatusStore.swift | head -200`

- [ ] **Step 2: Write the failing test**

`Tests/GrafttyKitTests/PRStatus/PRStatusStoreTransitionTests.swift`:
```swift
import XCTest
@testable import GrafttyKit

@MainActor
final class PRStatusStoreTransitionTests: XCTestCase {
    func testStateChangeFromOpenToMergedFiresPrStateChangedEvent() async {
        let store = PRStatusStore(
            executor: MockExecutor(),
            fetcherFor: { _ in nil },
            detectHost: { _ in nil }
        )
        var received: [(String, ChannelServerMessage)] = []
        store.onTransition = { path, message in
            received.append((path, message))
        }

        store.applyTransitionForTest(
            worktreePath: "/wt/a",
            previous: .open(number: 42, url: "https://ex/42", title: "T", author: "alice"),
            current: .merged(number: 42, url: "https://ex/42", title: "T"),
            provider: "github",
            repo: "acme/web"
        )

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].0, "/wt/a")
        guard case let .event(type, attrs, _) = received[0].1 else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(type, ChannelEventType.prStateChanged)
        XCTAssertEqual(attrs["from"], "open")
        XCTAssertEqual(attrs["to"], "merged")
        XCTAssertEqual(attrs["pr_number"], "42")
        XCTAssertEqual(attrs["provider"], "github")
    }

    func testIdempotentPollDoesNotFire() async {
        let store = PRStatusStore(
            executor: MockExecutor(),
            fetcherFor: { _ in nil },
            detectHost: { _ in nil }
        )
        var calls = 0
        store.onTransition = { _, _ in calls += 1 }

        let state: PRInfo = .open(number: 1, url: "u", title: "t", author: "a")
        store.applyTransitionForTest(
            worktreePath: "/wt/b",
            previous: state, current: state,
            provider: "github", repo: "r/r"
        )
        XCTAssertEqual(calls, 0)
    }

    func testCiConclusionChangeFires() async {
        let store = PRStatusStore(
            executor: MockExecutor(),
            fetcherFor: { _ in nil },
            detectHost: { _ in nil }
        )
        var received: [ChannelServerMessage] = []
        store.onTransition = { _, m in received.append(m) }

        store.applyTransitionForTest(
            worktreePath: "/wt/c",
            previous: .open(number: 1, url: "u", title: "t", author: "a", ciConclusion: "pending"),
            current: .open(number: 1, url: "u", title: "t", author: "a", ciConclusion: "failure"),
            provider: "github", repo: "r/r"
        )
        guard case let .event(type, attrs, _) = received.first else {
            return XCTFail("expected event")
        }
        XCTAssertEqual(type, ChannelEventType.ciConclusionChanged)
        XCTAssertEqual(attrs["from"], "pending")
        XCTAssertEqual(attrs["to"], "failure")
    }

    private final class MockExecutor: CLIExecutor {
        func run(_ command: String, args: [String], input: Data?, cwd: String?) async throws -> CLIResult {
            return CLIResult(exitCode: 0, stdout: Data(), stderr: Data())
        }
    }
}
```

> **Note:** The test depends on a `PRInfo` API that the existing code may not expose exactly as written (`.open(…)` / `.merged(…)` convenience constructors with a `ciConclusion` parameter). The subagent implementing Task 3 MUST first audit `PRStatusStore.swift` and rewrite this test to match the actual `PRInfo` type. The test's job is to verify the transition semantics; constructor shape is an adapter concern.

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter PRStatusStoreTransitionTests 2>&1 | head -30`
Expected: compilation failure — `onTransition`, `applyTransitionForTest`, and `ChannelEventType` likely referenced incorrectly; adapt per Step 2 note.

- [ ] **Step 4: Add the callback + transition detection**

Modifications to `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`:

1. Add public callback near `onPRMerged`:
```swift
    /// Fires on PR state, CI conclusion, or merge-state transitions.
    /// Consumed by ChannelRouter to deliver channel events. Idempotent
    /// polls (same state twice) do not fire. The callback is invoked on
    /// the main actor; dispatch to another queue inside if needed.
    @ObservationIgnored public var onTransition: (@MainActor (_ worktreePath: String, _ message: ChannelServerMessage) -> Void)?
```

2. Add an internal `applyTransitionForTest` seam for tests (idiomatic for this file, see `testableCompareInfos` elsewhere). Use `internal` so it's reachable from `@testable import`:
```swift
    internal func applyTransitionForTest(
        worktreePath: String,
        previous: PRInfo,
        current: PRInfo,
        provider: String,
        repo: String
    ) {
        detectAndFireTransitions(
            worktreePath: worktreePath,
            previous: previous,
            current: current,
            provider: provider,
            repo: repo
        )
    }
```

3. Add the detection routine (private):
```swift
    private func detectAndFireTransitions(
        worktreePath: String,
        previous: PRInfo,
        current: PRInfo,
        provider: String,
        repo: String
    ) {
        guard let onTransition else { return }

        let common: [String: String] = [
            "pr_number": String(current.number),
            "pr_url": current.url,
            "provider": provider,
            "repo": repo,
            "worktree": worktreePath,
        ]

        // pr_state_changed
        if previous.stateLabel != current.stateLabel {
            var attrs = common
            attrs["from"] = previous.stateLabel
            attrs["to"] = current.stateLabel
            attrs["pr_title"] = current.title
            let body = "PR #\(current.number) state changed: \(previous.stateLabel) → \(current.stateLabel)"
            onTransition(worktreePath, .event(
                type: ChannelEventType.prStateChanged, attrs: attrs, body: body
            ))
        }

        // ci_conclusion_changed
        if previous.ciConclusion != current.ciConclusion {
            var attrs = common
            attrs["from"] = previous.ciConclusion ?? "none"
            attrs["to"] = current.ciConclusion ?? "none"
            let body = "CI conclusion changed on PR #\(current.number): \(attrs["from"]!) → \(attrs["to"]!)"
            onTransition(worktreePath, .event(
                type: ChannelEventType.ciConclusionChanged, attrs: attrs, body: body
            ))
        }

        // merge_state_changed
        if previous.mergeState != current.mergeState {
            var attrs = common
            attrs["from"] = previous.mergeState ?? "unknown"
            attrs["to"] = current.mergeState ?? "unknown"
            let body = "Merge state changed on PR #\(current.number): \(attrs["from"]!) → \(attrs["to"]!)"
            onTransition(worktreePath, .event(
                type: ChannelEventType.mergeStateChanged, attrs: attrs, body: body
            ))
        }
    }
```

4. Call `detectAndFireTransitions` in the write path — wherever `performFetch` writes a new `PRInfo` into `infos[worktreePath]`. The subagent must read the current code and add the call just BEFORE the write so `previous` is still correct.

> **Note:** `PRInfo.stateLabel` / `.ciConclusion` / `.mergeState` may not exist yet as properties. Audit the current type; add computed properties if missing (they're cheap string getters). Keep them `@frozen internal` unless needed wider.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter PRStatusStoreTransitionTests 2>&1 | tail -10`
Expected: all three tests green.

- [ ] **Step 6: Commit**
```bash
git add Sources/GrafttyKit/PRStatus/PRStatusStore.swift Tests/GrafttyKitTests/PRStatus/PRStatusStoreTransitionTests.swift
git commit -m "feat(channels): PRStatusStore onTransition callback

Emits ChannelServerMessage events on PR state, CI conclusion, or
merge-state transitions for a tracked worktree. Idempotent polls
(same state twice) are silent. Consumed by ChannelRouter.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `ChannelSocketServer` — long-lived-connection Unix socket server

Accepts long-lived connections (unlike `SocketServer` which is request/response), reads a `subscribe` line, then keeps the connection open for server-push events.

**Files:**
- Create: `Sources/GrafttyKit/Channels/ChannelSocketServer.swift`
- Create: `Tests/GrafttyKitTests/Channels/ChannelSocketServerTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/GrafttyKitTests/Channels/ChannelSocketServerTests.swift`:
```swift
import XCTest
@testable import GrafttyKit

final class ChannelSocketServerTests: XCTestCase {
    var socketPath: String!

    override func setUp() {
        super.setUp()
        socketPath = "/tmp/graftty-test-channels-\(UUID().uuidString).sock"
    }

    override func tearDown() {
        unlink(socketPath)
        super.tearDown()
    }

    func testSubscribeDeliversSubscribeMessageToHandler() throws {
        let server = ChannelSocketServer(socketPath: socketPath)
        let expectation = self.expectation(description: "subscribe received")
        server.onSubscribe = { message, _ in
            if case let .subscribe(worktree, _) = message {
                XCTAssertEqual(worktree, "/wt/a")
                expectation.fulfill()
            }
        }
        try server.start()
        defer { server.stop() }

        let client = try ChannelTestClient.connect(path: socketPath)
        try client.send(#"{"type":"subscribe","worktree":"/wt/a","version":1}\#n"#)

        wait(for: [expectation], timeout: 2.0)
    }

    func testServerPushEventReachesClient() throws {
        let server = ChannelSocketServer(socketPath: socketPath)
        var capturedConn: ChannelSocketServer.Connection?
        let subscribed = self.expectation(description: "subscribed")
        server.onSubscribe = { _, conn in
            capturedConn = conn
            subscribed.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let client = try ChannelTestClient.connect(path: socketPath)
        try client.send(#"{"type":"subscribe","worktree":"/wt/a","version":1}\#n"#)
        wait(for: [subscribed], timeout: 2.0)

        let event = ChannelServerMessage.event(type: "ping", attrs: [:], body: "hi")
        try capturedConn?.write(event)

        let received = try client.readLine(timeout: 2.0)
        XCTAssertTrue(received.contains("\"type\":\"ping\""))
    }

    func testClientDisconnectRemovesConnection() throws {
        let server = ChannelSocketServer(socketPath: socketPath)
        let subscribed = self.expectation(description: "subscribed")
        let disconnected = self.expectation(description: "disconnected")
        server.onSubscribe = { _, _ in subscribed.fulfill() }
        server.onDisconnect = { _ in disconnected.fulfill() }
        try server.start()
        defer { server.stop() }

        var client: ChannelTestClient? = try ChannelTestClient.connect(path: socketPath)
        try client!.send(#"{"type":"subscribe","worktree":"/wt/a","version":1}\#n"#)
        wait(for: [subscribed], timeout: 2.0)

        client = nil  // drop the client — underlying fd closed by deinit
        wait(for: [disconnected], timeout: 2.0)
    }
}

/// Minimal Unix-socket test client. Only used by channel tests.
final class ChannelTestClient {
    private let fd: Int32
    private init(fd: Int32) { self.fd = fd }
    deinit { close(fd) }

    static func connect(path: String) throws -> ChannelTestClient {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: 104) {
                    _ = strlcpy($0, ptr, 104)
                }
            }
        }
        let res = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if res != 0 { close(fd); throw NSError(domain: "ChannelTestClient", code: Int(errno)) }
        return ChannelTestClient(fd: fd)
    }

    func send(_ line: String) throws {
        try line.withCString { ptr in
            let len = strlen(ptr)
            let written = Darwin.write(fd, ptr, len)
            if written != len {
                throw NSError(domain: "ChannelTestClient", code: Int(errno))
            }
        }
    }

    func readLine(timeout: TimeInterval) throws -> String {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { throw NSError(domain: "ChannelTestClient", code: Int(errno)) }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChannelSocketServerTests 2>&1 | head -20`
Expected: compilation failure — `ChannelSocketServer` undefined.

- [ ] **Step 3: Implement the server**

`Sources/GrafttyKit/Channels/ChannelSocketServer.swift`:
```swift
import Foundation

/// Long-lived-connection Unix socket server for the channels transport.
/// Each connection is expected to send one `ChannelClientMessage.subscribe`
/// line, then stays open for server-pushed `ChannelServerMessage` events.
public final class ChannelSocketServer: @unchecked Sendable {
    public final class Connection: @unchecked Sendable {
        fileprivate let fd: Int32
        fileprivate let queue: DispatchQueue
        public internal(set) var worktree: String = ""

        fileprivate init(fd: Int32, queue: DispatchQueue) {
            self.fd = fd
            self.queue = queue
        }

        public func write(_ message: ChannelServerMessage) throws {
            let data = try JSONEncoder().encode(message)
            var payload = data
            payload.append(0x0A)  // newline
            try payload.withUnsafeBytes { buf in
                guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                try SocketIO.writeAll(fd: fd, bytes: base, count: buf.count)
            }
        }

        fileprivate func close_() {
            Darwin.close(fd)
        }
    }

    private let socketPath: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.graftty.channels-server", attributes: .concurrent)
    private let connLock = NSLock()
    private var connections: [ObjectIdentifier: Connection] = [:]

    public var onSubscribe: ((ChannelClientMessage, Connection) -> Void)?
    public var onDisconnect: ((Connection) -> Void)?

    public init(socketPath: String) { self.socketPath = socketPath }
    deinit { stop() }

    public func start() throws {
        let pathBytes = socketPath.utf8.count
        guard pathBytes <= SocketServer.maxPathBytes else {
            throw SocketServerError.socketPathTooLong(bytes: pathBytes, maxBytes: SocketServer.maxPathBytes)
        }
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw SocketServerError.socketCreationFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strlcpy($0, ptr, 104) }
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindResult == 0 else { close(listenFD); throw SocketServerError.bindFailed(errno: errno) }
        guard Darwin.listen(listenFD, 64) == 0 else { close(listenFD); throw SocketServerError.listenFailed(errno: errno) }

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.setCancelHandler { [weak self] in if let fd = self?.listenFD, fd >= 0 { close(fd) } }
        src.resume()
        self.source = src
    }

    public func stop() {
        source?.cancel(); source = nil
        connLock.lock()
        for conn in connections.values { conn.close_() }
        connections.removeAll()
        connLock.unlock()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    public func allConnections() -> [Connection] {
        connLock.lock(); defer { connLock.unlock() }
        return Array(connections.values)
    }

    private func accept() {
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        let conn = Connection(fd: clientFD, queue: queue)
        connLock.lock(); connections[ObjectIdentifier(conn)] = conn; connLock.unlock()
        queue.async { [weak self] in self?.handle(conn) }
    }

    private func handle(_ conn: Connection) {
        defer {
            conn.close_()
            connLock.lock()
            connections.removeValue(forKey: ObjectIdentifier(conn))
            connLock.unlock()
            if let cb = onDisconnect {
                DispatchQueue.main.async { cb(conn) }
            }
        }

        guard let firstLine = readLine(fd: conn.fd) else { return }
        guard let data = firstLine.data(using: .utf8),
              let message = try? JSONDecoder().decode(ChannelClientMessage.self, from: data) else {
            return
        }
        if case let .subscribe(worktree, _) = message {
            conn.worktree = worktree
        }
        if let cb = onSubscribe {
            DispatchQueue.main.async { cb(message, conn) }
        }

        // Keep the connection open until the peer closes.
        var buf = [UInt8](repeating: 0, count: 256)
        while true {
            let n = Darwin.read(conn.fd, &buf, buf.count)
            if n <= 0 { return }
        }
    }

    private func readLine(fd: Int32) -> String? {
        var line = Data()
        var ch: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &ch, 1)
            if n <= 0 { return line.isEmpty ? nil : String(data: line, encoding: .utf8) }
            if ch == 0x0A { return String(data: line, encoding: .utf8) }
            line.append(ch)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ChannelSocketServerTests 2>&1 | tail -15`
Expected: all three tests green.

- [ ] **Step 5: Commit**
```bash
git add Sources/GrafttyKit/Channels/ChannelSocketServer.swift Tests/GrafttyKitTests/Channels/ChannelSocketServerTests.swift
git commit -m "feat(channels): ChannelSocketServer for long-lived subscribers

Unix-socket server that accepts long-lived connections, reads one
subscribe line, and keeps the connection open for server-pushed
events. Distinct from SocketServer (request/response) by design.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `ChannelRouter` core — subscriber map + fanout + initial instructions

Owns the `ChannelSocketServer`, maintains the subscriber map, routes transition events to the matching worktree, and sends the initial `instructions` event on subscribe.

**Files:**
- Create: `Sources/GrafttyKit/Channels/ChannelRouter.swift`
- Create: `Tests/GrafttyKitTests/Channels/ChannelRouterTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/GrafttyKitTests/Channels/ChannelRouterTests.swift`:
```swift
import XCTest
@testable import GrafttyKit

@MainActor
final class ChannelRouterTests: XCTestCase {
    var socketPath: String!

    override func setUp() async throws {
        socketPath = "/tmp/graftty-test-router-\(UUID().uuidString).sock"
    }
    override func tearDown() async throws { unlink(socketPath) }

    func testSubscriberReceivesInitialInstructions() async throws {
        let router = ChannelRouter(socketPath: socketPath, promptProvider: { "hello prompt" })
        try router.start()
        defer { router.stop() }

        let client = try ChannelTestClient.connect(path: socketPath)
        try client.send(#"{"type":"subscribe","worktree":"/wt/a","version":1}\#n"#)

        let line = try client.readLine(timeout: 2.0)
        XCTAssertTrue(line.contains("\"type\":\"instructions\""))
        XCTAssertTrue(line.contains("hello prompt"))
    }

    func testEventIsRoutedOnlyToMatchingWorktree() async throws {
        let router = ChannelRouter(socketPath: socketPath, promptProvider: { "P" })
        try router.start()
        defer { router.stop() }

        let clientA = try ChannelTestClient.connect(path: socketPath)
        try clientA.send(#"{"type":"subscribe","worktree":"/wt/a","version":1}\#n"#)
        _ = try clientA.readLine(timeout: 2.0)  // drain initial instructions

        let clientB = try ChannelTestClient.connect(path: socketPath)
        try clientB.send(#"{"type":"subscribe","worktree":"/wt/b","version":1}\#n"#)
        _ = try clientB.readLine(timeout: 2.0)

        try await Task.sleep(nanoseconds: 200_000_000)  // let subscriptions settle

        router.dispatch(
            worktreePath: "/wt/a",
            message: .event(type: "pr_state_changed", attrs: ["pr_number": "1"], body: "X")
        )

        let aReceived = try clientA.readLine(timeout: 2.0)
        XCTAssertTrue(aReceived.contains("pr_state_changed"))

        // B should NOT receive anything; expect read timeout.
        XCTAssertThrowsError(try clientB.readLine(timeout: 0.5))
    }

    func testPromptBroadcastReachesAllSubscribers() async throws {
        var currentPrompt = "P1"
        let router = ChannelRouter(socketPath: socketPath, promptProvider: { currentPrompt })
        try router.start()
        defer { router.stop() }

        let c1 = try ChannelTestClient.connect(path: socketPath)
        try c1.send(#"{"type":"subscribe","worktree":"/wt/1","version":1}\#n"#)
        _ = try c1.readLine(timeout: 2.0)

        let c2 = try ChannelTestClient.connect(path: socketPath)
        try c2.send(#"{"type":"subscribe","worktree":"/wt/2","version":1}\#n"#)
        _ = try c2.readLine(timeout: 2.0)

        try await Task.sleep(nanoseconds: 200_000_000)

        currentPrompt = "P2"
        router.broadcastInstructions()

        let r1 = try c1.readLine(timeout: 2.0)
        let r2 = try c2.readLine(timeout: 2.0)
        XCTAssertTrue(r1.contains("P2"))
        XCTAssertTrue(r2.contains("P2"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChannelRouterTests 2>&1 | head -15`
Expected: compilation failure.

- [ ] **Step 3: Implement the router**

`Sources/GrafttyKit/Channels/ChannelRouter.swift`:
```swift
import Foundation
import Observation

@MainActor
@Observable
public final class ChannelRouter {
    @ObservationIgnored private let server: ChannelSocketServer
    @ObservationIgnored private let promptProvider: () -> String
    @ObservationIgnored private var subscribers: [String: ChannelSocketServer.Connection] = [:]

    public var subscriberCount: Int { subscribers.count }
    public var isEnabled: Bool = true

    public init(socketPath: String, promptProvider: @escaping () -> String) {
        self.server = ChannelSocketServer(socketPath: socketPath)
        self.promptProvider = promptProvider

        server.onSubscribe = { [weak self] message, conn in
            Task { @MainActor [weak self] in self?.onSubscribe(message: message, conn: conn) }
        }
        server.onDisconnect = { [weak self] conn in
            Task { @MainActor [weak self] in self?.onDisconnect(conn: conn) }
        }
    }

    public func start() throws { try server.start() }
    public func stop() { server.stop(); subscribers.removeAll() }

    /// Route a transition event to the matching subscriber, if any.
    public func dispatch(worktreePath: String, message: ChannelServerMessage) {
        guard isEnabled else { return }
        guard let conn = subscribers[worktreePath] else { return }
        writeOrPrune(conn: conn, message: message, worktreePath: worktreePath)
    }

    /// Fan out the current prompt as a `type=instructions` event to every
    /// subscriber. Called after the Settings prompt edit debounce fires.
    public func broadcastInstructions() {
        let body = promptProvider()
        let message = ChannelServerMessage.event(type: ChannelEventType.instructions, attrs: [:], body: body)
        for (worktree, conn) in subscribers {
            writeOrPrune(conn: conn, message: message, worktreePath: worktree)
        }
    }

    private func onSubscribe(message: ChannelClientMessage, conn: ChannelSocketServer.Connection) {
        guard case let .subscribe(worktree, _) = message else { return }
        subscribers[worktree] = conn
        let initial = ChannelServerMessage.event(
            type: ChannelEventType.instructions, attrs: [:], body: promptProvider()
        )
        try? conn.write(initial)
    }

    private func onDisconnect(conn: ChannelSocketServer.Connection) {
        subscribers = subscribers.filter { $0.value !== conn }
    }

    private func writeOrPrune(conn: ChannelSocketServer.Connection, message: ChannelServerMessage, worktreePath: String) {
        do {
            try conn.write(message)
        } catch {
            subscribers.removeValue(forKey: worktreePath)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ChannelRouterTests 2>&1 | tail -15`
Expected: all three tests green.

- [ ] **Step 5: Commit**
```bash
git add Sources/GrafttyKit/Channels/ChannelRouter.swift Tests/GrafttyKitTests/Channels/ChannelRouterTests.swift
git commit -m "feat(channels): ChannelRouter subscriber map + fanout

Routes PRStatusStore transition events to the matching worktree
subscriber, sends the current prompt as an initial instructions
event on subscribe, and fans out prompt updates on broadcast.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `MCPStdioServer` — hand-rolled MCP JSON-RPC

The stdin/stdout side of the MCP subprocess. Handles `initialize` handshake and emits `notifications/claude/channel`.

**Files:**
- Create: `Sources/GrafttyKit/Channels/MCPStdioServer.swift`
- Create: `Tests/GrafttyKitTests/Channels/MCPStdioServerTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/GrafttyKitTests/Channels/MCPStdioServerTests.swift`:
```swift
import XCTest
@testable import GrafttyKit

final class MCPStdioServerTests: XCTestCase {
    func testInitializeRequestProducesCapabilitiesAndInstructions() throws {
        var out = Data()
        let sink: (Data) -> Void = { out.append($0) }
        let server = MCPStdioServer(name: "graftty-channel", version: "0.1.0", instructions: "hello", output: sink)

        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#
        server.handleLine(request)

        let response = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(response.contains("\"jsonrpc\":\"2.0\""))
        XCTAssertTrue(response.contains("\"id\":1"))
        XCTAssertTrue(response.contains("\"claude/channel\""))
        XCTAssertTrue(response.contains("\"graftty-channel\""))
        XCTAssertTrue(response.contains("\"hello\""))
    }

    func testNotificationEmitsSingleLineJSONRPC() throws {
        var out = Data()
        let server = MCPStdioServer(name: "n", version: "0", instructions: "", output: { out.append($0) })

        server.emitChannelNotification(
            content: "PR #1 merged",
            meta: ["type": "pr_state_changed", "pr_number": "1"]
        )

        let response = String(data: out, encoding: .utf8) ?? ""
        let lines = response.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(response.contains("\"method\":\"notifications/claude/channel\""))
        XCTAssertTrue(response.contains("\"content\":\"PR #1 merged\""))
        XCTAssertTrue(response.contains("\"pr_number\":\"1\""))
    }

    func testUnknownMethodReturnsJSONRPCError() throws {
        var out = Data()
        let server = MCPStdioServer(name: "n", version: "0", instructions: "", output: { out.append($0) })

        server.handleLine(#"{"jsonrpc":"2.0","id":2,"method":"bogus","params":{}}"#)

        let response = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(response.contains("\"error\""))
        XCTAssertTrue(response.contains("\"id\":2"))
    }

    func testMalformedJSONDoesNotCrash() throws {
        var out = Data()
        let server = MCPStdioServer(name: "n", version: "0", instructions: "", output: { out.append($0) })
        server.handleLine("not json")  // just verify no throw / no crash
        XCTAssertTrue(out.isEmpty || String(data: out, encoding: .utf8)?.contains("error") == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MCPStdioServerTests 2>&1 | head -15`
Expected: compilation failure.

- [ ] **Step 3: Implement the server**

`Sources/GrafttyKit/Channels/MCPStdioServer.swift`:
```swift
import Foundation

/// Minimal hand-rolled MCP JSON-RPC 2.0 server for the channels capability.
/// stdin reads are newline-delimited; stdout writes are single-line JSON.
public final class MCPStdioServer {
    private let name: String
    private let version: String
    private let instructions: String
    private let output: (Data) -> Void

    public init(name: String, version: String, instructions: String, output: @escaping (Data) -> Void) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.output = output
    }

    public func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            // Malformed input — drop silently (no id to reply to).
            return
        }
        let id = obj["id"]
        switch method {
        case "initialize":
            respondToInitialize(id: id)
        case "notifications/initialized", "notifications/cancelled":
            break  // no-op
        default:
            if id != nil {
                respondWithMethodNotFound(id: id, method: method)
            }
        }
    }

    /// Emit a notifications/claude/channel event with the given body and meta attributes.
    public func emitChannelNotification(content: String, meta: [String: String]) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/claude/channel",
            "params": [
                "content": content,
                "meta": meta,
            ] as [String: Any],
        ]
        writeJSON(payload)
    }

    // MARK: private

    private func respondToInitialize(id: Any?) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "experimental": [
                        "claude/channel": [:] as [String: Any],
                    ],
                ],
                "serverInfo": [
                    "name": name,
                    "version": version,
                ],
                "instructions": instructions,
            ] as [String: Any],
        ]
        writeJSON(response)
    }

    private func respondWithMethodNotFound(id: Any?, method: String) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": -32601,
                "message": "Method not found: \(method)",
            ] as [String: Any],
        ]
        writeJSON(response)
    }

    private func writeJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        var out = data
        out.append(0x0A)
        output(out)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter MCPStdioServerTests 2>&1 | tail -15`
Expected: all four tests green.

- [ ] **Step 5: Commit**
```bash
git add Sources/GrafttyKit/Channels/MCPStdioServer.swift Tests/GrafttyKitTests/Channels/MCPStdioServerTests.swift
git commit -m "feat(channels): MCPStdioServer hand-rolled JSON-RPC

Minimal MCP 2024-11-05 server implementing initialize handshake
with claude/channel capability and emitting notifications/
claude/channel events. ~130 LOC, no SDK dependency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `graftty mcp-channel` subcommand

The thin CLI shim that wires stdin/stdout to `MCPStdioServer` and the channels socket to `ChannelSocketClient` (a new minimal client class).

**Files:**
- Create: `Sources/GrafttyKit/Channels/ChannelSocketClient.swift`
- Create: `Sources/GrafttyCLI/MCPChannel.swift`
- Modify: `Sources/GrafttyCLI/CLI.swift`

- [ ] **Step 1: Create the socket client class**

`Sources/GrafttyKit/Channels/ChannelSocketClient.swift`:
```swift
import Foundation

/// Client-side of the channels socket, used by `graftty mcp-channel`.
/// Blocking reads; one line at a time.
public final class ChannelSocketClient {
    private let fd: Int32
    public init(fd: Int32) { self.fd = fd }

    public static func connect(path: String) throws -> ChannelSocketClient {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.socketError("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: 104) {
                    _ = strlcpy($0, ptr, 104)
                }
            }
        }
        let res = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if res != 0 {
            close(fd)
            throw CLIError.appNotRunning
        }
        return ChannelSocketClient(fd: fd)
    }

    public func sendSubscribe(worktree: String) throws {
        let msg = ChannelClientMessage.subscribe(worktree: worktree, version: 1)
        var data = try JSONEncoder().encode(msg)
        data.append(0x0A)
        try data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            try SocketIO.writeAll(fd: fd, bytes: base, count: buf.count)
        }
    }

    public func readServerMessage() throws -> ChannelServerMessage {
        var line = Data()
        var ch: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &ch, 1)
            if n <= 0 { throw CLIError.socketError("read EOF") }
            if ch == 0x0A { break }
            line.append(ch)
        }
        return try JSONDecoder().decode(ChannelServerMessage.self, from: line)
    }

    deinit { if fd >= 0 { close(fd) } }
}
```

> **Note:** `CLIError` currently lives in `Sources/GrafttyCLI/WorktreeResolver.swift`. The subagent should move `CLIError` into GrafttyKit (so it's accessible from `ChannelSocketClient` without re-importing the CLI target), OR duplicate the needed cases. The simpler route is a small `ChannelClientError` enum in this new file — mention as a trade-off in the commit.

- [ ] **Step 2: Create the subcommand**

`Sources/GrafttyCLI/MCPChannel.swift`:
```swift
import ArgumentParser
import Foundation
import GrafttyKit

struct MCPChannel: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-channel",
        abstract: "MCP channel bridge — invoked by Claude Code, not directly by humans."
    )

    func run() throws {
        let worktreePath: String
        do {
            worktreePath = try WorktreeResolver.resolve()
        } catch {
            emitChannelError("Not inside a tracked worktree")
            throw ExitCode(1)
        }

        let socketPath = SocketPathResolver.resolveChannels()
        let client: ChannelSocketClient
        do {
            client = try ChannelSocketClient.connect(path: socketPath)
        } catch {
            emitChannelError("Graftty channel socket unreachable: \(error)")
            throw ExitCode(1)
        }

        try client.sendSubscribe(worktree: worktreePath)

        let stdout = FileHandle.standardOutput
        let mcp = MCPStdioServer(
            name: "graftty-channel",
            version: "0.1.0",
            instructions: """
            Events from this channel arrive as <channel source="graftty-channel" type="..."> \
            tags. Your operative behavioral guidance is delivered within the channel stream \
            as events with type="instructions"; the most recent such event's body supersedes \
            earlier ones. If no instructions event has arrived yet, act conservatively and \
            wait.
            """,
            output: { stdout.write($0) }
        )

        // Socket → stdout pump (background thread).
        let socketThread = Thread {
            while true {
                do {
                    let message = try client.readServerMessage()
                    if case let .event(type, attrs, body) = message {
                        var meta = attrs
                        meta["type"] = type
                        mcp.emitChannelNotification(content: body, meta: meta)
                    }
                } catch {
                    mcp.emitChannelNotification(
                        content: "Graftty channel disconnected; exiting.",
                        meta: ["type": ChannelEventType.channelError]
                    )
                    Darwin.exit(0)
                }
            }
        }
        socketThread.start()

        // Stdin → MCP pump (main thread).
        let stdin = FileHandle.standardInput
        var buffer = Data()
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(data: buffer[..<nl], encoding: .utf8) ?? ""
                buffer.removeSubrange(...nl)
                mcp.handleLine(line)
            }
        }
    }

    private func emitChannelError(_ text: String) {
        let mcp = MCPStdioServer(name: "graftty-channel", version: "0.1.0", instructions: "",
                                 output: { FileHandle.standardOutput.write($0) })
        mcp.emitChannelNotification(content: text, meta: ["type": ChannelEventType.channelError])
    }
}
```

- [ ] **Step 3: Register in CLI.swift**

Edit `Sources/GrafttyCLI/CLI.swift` — add `MCPChannel.self` to the `subcommands` list:
```swift
        subcommands: [Notify.self, Pane.self, MCPChannel.self]
```

- [ ] **Step 4: Verify the CLI builds**

Run: `swift build 2>&1 | tail -20`
Expected: clean build (no warnings, no errors — `-warnings-as-errors` is on in debug).

- [ ] **Step 5: Smoke-test the subcommand via stdin/stdout**

Run:
```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}' | swift run graftty-cli mcp-channel 2>&1 | head -5
```

Expected: first line of output contains `"claude/channel"` and `"graftty-channel"`. (The subcommand will fail on socket connect since Graftty isn't running in this test harness — exit is OK; what matters is the initialize response lands on stdout before exit.)

- [ ] **Step 6: Commit**
```bash
git add Sources/GrafttyKit/Channels/ChannelSocketClient.swift Sources/GrafttyCLI/MCPChannel.swift Sources/GrafttyCLI/CLI.swift
git commit -m "feat(channels): graftty mcp-channel subcommand

Wires MCPStdioServer (stdin/stdout) to ChannelSocketClient
(channels.sock) so Claude Code can launch the subprocess via
the plugin's .mcp.json. Worktree identity comes from
WorktreeResolver (git rev-parse + state.json check).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `ChannelPluginInstaller` — write plugin config to `~/.claude/plugins/`

Creates the plugin directory structure Claude Code reads at startup.

**Files:**
- Create: `Sources/GrafttyKit/Channels/ChannelPluginInstaller.swift`
- Create: `Tests/GrafttyKitTests/Channels/ChannelPluginInstallerTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/GrafttyKitTests/Channels/ChannelPluginInstallerTests.swift`:
```swift
import XCTest
@testable import GrafttyKit

final class ChannelPluginInstallerTests: XCTestCase {
    func testInstallWritesMCPJSONWithSubstitutedPath() throws {
        let tmp = URL(fileURLWithPath: "/tmp/GrafttyChannelInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pluginsRoot = tmp.appendingPathComponent("plugins")
        let cliPath = "/Applications/Graftty.app/Contents/Resources/graftty"
        let manifest = #"{"name":"graftty-channel","version":"0.1.0"}"#
        let mcpTemplate = #"{"mcpServers":{"graftty-channel":{"command":"{{CLI_PATH}}","args":["mcp-channel"]}}}"#

        try ChannelPluginInstaller.install(
            pluginsRoot: pluginsRoot,
            cliPath: cliPath,
            manifest: manifest,
            mcpTemplate: mcpTemplate
        )

        let mcpJSON = try String(contentsOf: pluginsRoot
            .appendingPathComponent("graftty-channel")
            .appendingPathComponent(".mcp.json"))
        XCTAssertTrue(mcpJSON.contains(cliPath))
        XCTAssertFalse(mcpJSON.contains("{{CLI_PATH}}"))

        let pluginJSON = try String(contentsOf: pluginsRoot
            .appendingPathComponent("graftty-channel")
            .appendingPathComponent("plugin.json"))
        XCTAssertEqual(pluginJSON, manifest)
    }

    func testInstallIsIdempotent() throws {
        let tmp = URL(fileURLWithPath: "/tmp/GrafttyChannelInstallerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pluginsRoot = tmp.appendingPathComponent("plugins")
        for _ in 0..<3 {
            try ChannelPluginInstaller.install(
                pluginsRoot: pluginsRoot,
                cliPath: "/x",
                manifest: "{}",
                mcpTemplate: "{}"
            )
        }

        let entries = try FileManager.default.contentsOfDirectory(atPath: pluginsRoot
            .appendingPathComponent("graftty-channel").path)
        XCTAssertEqual(Set(entries), Set([".mcp.json", "plugin.json"]))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChannelPluginInstallerTests 2>&1 | head -15`
Expected: compilation failure.

- [ ] **Step 3: Implement the installer**

`Sources/GrafttyKit/Channels/ChannelPluginInstaller.swift`:
```swift
import Foundation

public enum ChannelPluginInstaller {
    public static let pluginName = "graftty-channel"

    /// Install the plugin into `pluginsRoot/graftty-channel/`. Pure — takes
    /// the manifest/template/cli-path as parameters so the caller decides
    /// where the resources come from (bundle at runtime, fixtures in
    /// tests). Idempotent.
    public static func install(
        pluginsRoot: URL,
        cliPath: String,
        manifest: String,
        mcpTemplate: String
    ) throws {
        let dir = pluginsRoot.appendingPathComponent(pluginName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let mcpRendered = mcpTemplate.replacingOccurrences(of: "{{CLI_PATH}}", with: cliPath)
        try mcpRendered.write(
            to: dir.appendingPathComponent(".mcp.json"),
            atomically: true, encoding: .utf8
        )
        try manifest.write(
            to: dir.appendingPathComponent("plugin.json"),
            atomically: true, encoding: .utf8
        )
    }

    /// Default pluginsRoot: `~/.claude/plugins/`.
    public static func defaultPluginsRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude").appendingPathComponent("plugins")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ChannelPluginInstallerTests 2>&1 | tail -10`
Expected: both tests green.

- [ ] **Step 5: Commit**
```bash
git add Sources/GrafttyKit/Channels/ChannelPluginInstaller.swift Tests/GrafttyKitTests/Channels/ChannelPluginInstallerTests.swift
git commit -m "feat(channels): ChannelPluginInstaller writes ~/.claude/plugins

Pure installer takes manifest/template/cli-path as parameters so
tests can use fixtures and runtime callers pass the bundle
resources + absolute CLI path. Idempotent.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Plugin resource files

The static files bundled inside Graftty.app.

**Files:**
- Create: `Resources/plugins/graftty-channel/plugin.json`
- Create: `Resources/plugins/graftty-channel/mcp.json.template`
- Modify: `Package.swift` (add resources to Graftty target)

- [ ] **Step 1: Create the manifest**

`Resources/plugins/graftty-channel/plugin.json`:
```json
{
  "name": "graftty-channel",
  "version": "0.1.0",
  "description": "Graftty-provided channel: PR state, CI conclusion, and merge-state events for the Claude session's worktree.",
  "author": {
    "name": "Graftty"
  }
}
```

- [ ] **Step 2: Create the MCP config template**

`Resources/plugins/graftty-channel/mcp.json.template`:
```json
{
  "mcpServers": {
    "graftty-channel": {
      "command": "{{CLI_PATH}}",
      "args": ["mcp-channel"]
    }
  }
}
```

> **Note:** Filename omits the leading dot because Swift Package Manager resource bundling silently drops dotfiles. At install time, the installer writes the rendered output to `.mcp.json` (with the dot).

- [ ] **Step 3: Wire resources into `Package.swift`**

Edit `Package.swift` — add a `resources:` entry to the `Graftty` executable target:
```swift
        .executableTarget(
            name: "Graftty",
            dependencies: [
                "GrafttyKit",
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ],
            resources: [
                .copy("../../Resources/plugins"),
            ],
            swiftSettings: strictWarnings
        ),
```

> **Note:** SPM resolves resource paths relative to the target root (`Sources/Graftty`). Since `Resources/plugins` lives at repo root, we use `../../Resources/plugins`. If SPM rejects relative paths outside the target root, move the resource dir to `Sources/Graftty/PluginResources/` and adjust `.copy("PluginResources")` accordingly.

- [ ] **Step 4: Verify build picks up resources**

Run: `swift build 2>&1 | tail -10`
Expected: clean build. Then check the built bundle:

```bash
ls -la .build/debug/Graftty_Graftty.bundle/Contents/Resources/plugins/graftty-channel/ 2>/dev/null || ls -la .build/debug/Graftty.bundle/Contents/Resources/plugins/graftty-channel/
```
Expected: sees `plugin.json` and `mcp.json.template`.

- [ ] **Step 5: Commit**
```bash
git add Resources Package.swift
git commit -m "feat(channels): bundle graftty-channel plugin resources

Static plugin.json + mcp.json.template shipped inside Graftty.app.
At install time, ChannelPluginInstaller renders the template with
the absolute CLI path and writes it as .mcp.json under
~/.claude/plugins/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: `DefaultCommandDecision` — channel flag composition

Extends the decision function to prepend channel flags to a `claude`-family command when `channelsEnabled` is true.

**Files:**
- Modify: `Sources/GrafttyKit/DefaultCommandDecision.swift`
- Modify: `Tests/GrafttyKitTests/DefaultCommandDecisionTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Tests/GrafttyKitTests/DefaultCommandDecisionTests.swift`:
```swift
    func testChannelsEnabledInsertsFlagsAfterClaudeBinaryName() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false,
            channelsEnabled: true
        )
        XCTAssertEqual(decision, .type(
            "claude --channels plugin:graftty-channel --dangerously-load-development-channels plugin:graftty-channel"
        ))
    }

    func testChannelsEnabledWithExistingArgsInsertsFlagsBeforeArgs() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude --model opus",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false,
            channelsEnabled: true
        )
        XCTAssertEqual(decision, .type(
            "claude --channels plugin:graftty-channel --dangerously-load-development-channels plugin:graftty-channel --model opus"
        ))
    }

    func testChannelsEnabledForNonClaudeCommandLeavesUnchanged() {
        let decision = defaultCommandDecision(
            defaultCommand: "zsh",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false,
            channelsEnabled: true
        )
        XCTAssertEqual(decision, .type("zsh"))
    }

    func testChannelsDisabledLeavesCommandUnchanged() {
        let decision = defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: true,
            isFirstPane: true,
            wasRehydrated: false,
            channelsEnabled: false
        )
        XCTAssertEqual(decision, .type("claude"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter DefaultCommandDecisionTests 2>&1 | head -20`
Expected: compilation failure on the new `channelsEnabled:` parameter.

- [ ] **Step 3: Extend the function signature**

Edit `Sources/GrafttyKit/DefaultCommandDecision.swift`:
```swift
public func defaultCommandDecision(
    defaultCommand: String,
    firstPaneOnly: Bool,
    isFirstPane: Bool,
    wasRehydrated: Bool,
    channelsEnabled: Bool = false
) -> DefaultCommandDecision {
    let trimmed = defaultCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .skip }
    if wasRehydrated { return .skip }
    if firstPaneOnly && !isFirstPane { return .skip }

    let composed = composeWithChannelFlags(command: trimmed, channelsEnabled: channelsEnabled)
    return .type(composed)
}

/// Inserts channel flags between the `claude` binary name and any args,
/// when channelsEnabled is true and the command begins with `claude`.
/// For non-claude commands or when disabled, returns the command unchanged.
internal func composeWithChannelFlags(command: String, channelsEnabled: Bool) -> String {
    guard channelsEnabled else { return command }
    // Split on the first whitespace run to find the binary name.
    let parts = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    guard let binary = parts.first, binary == "claude" else { return command }
    let flags = "--channels plugin:graftty-channel --dangerously-load-development-channels plugin:graftty-channel"
    if parts.count == 1 {
        return "claude \(flags)"
    } else {
        return "claude \(flags) \(parts[1])"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter DefaultCommandDecisionTests 2>&1 | tail -10`
Expected: all tests green (new + existing).

- [ ] **Step 5: Commit**
```bash
git add Sources/GrafttyKit/DefaultCommandDecision.swift Tests/GrafttyKitTests/DefaultCommandDecisionTests.swift
git commit -m "feat(channels): DefaultCommandDecision adds channel flags

When channelsEnabled is true and defaultCommand starts with
'claude', insert --channels plugin:graftty-channel and the
development-channels bypass flag between the binary and any
user args.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: `ChannelsSettingsPane` SwiftUI view + Settings tab integration

**Files:**
- Create: `Sources/Graftty/Views/Settings/ChannelsSettingsPane.swift`
- Modify: `Sources/Graftty/Views/SettingsView.swift`

- [ ] **Step 1: Create the Channels pane**

`Sources/Graftty/Views/Settings/ChannelsSettingsPane.swift`:
```swift
import SwiftUI
import GrafttyKit

struct ChannelsSettingsPane: View {
    @AppStorage("channelsEnabled") private var channelsEnabled: Bool = false
    @AppStorage("channelPrompt") private var channelPrompt: String = ChannelsSettingsPane.defaultPrompt
    @EnvironmentObject private var routerBox: ChannelRouterBox

    var body: some View {
        Form {
            Section {
                Toggle("Enable GitHub/GitLab channel", isOn: $channelsEnabled)
                Text("Claude sessions in tracked worktrees receive events for their PR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if channelsEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Research preview — launches Claude with a development flag", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.subheadline.bold())
                        Text(verbatim: "This prepends --dangerously-load-development-channels plugin:graftty-channel to your Claude launch. The flag bypasses Claude Code's channel allowlist only for this plugin. Events originate from Graftty's local polling — no external senders.")
                            .font(.caption)
                        Link("Learn more →", destination: URL(string: "https://docs.claude.com/en/channels")!)
                            .font(.caption)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.orange.opacity(0.4))
                    )
                }

                Section("Prompt") {
                    Text("Applied to every Claude session with channels enabled. Edits propagate immediately to running sessions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $channelPrompt)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 200)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                    HStack {
                        Text("\(routerBox.router?.subscriberCount ?? 0) Claude sessions subscribed")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restore default") {
                            channelPrompt = Self.defaultPrompt
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .frame(width: 480)
    }

    static let defaultPrompt: String = """
    You receive events from Graftty when state changes on the PR associated with your current worktree. Each event arrives as a <channel source="graftty-channel" type="..."> tag with attributes (pr_number, provider, repo, worktree, pr_url) and a short body.

    When you see:
    - type=pr_state_changed, to=merged: The PR merged. Briefly acknowledge. Don't take destructive actions (e.g. delete the worktree) without explicit confirmation.
    - type=ci_conclusion_changed, to=failure: Read the failing check log via the pr_url if accessible, summarize what failed, and propose a fix. Don't commit without confirmation.
    - type=ci_conclusion_changed, to=success: Brief acknowledgement. If the PR is now mergeable, mention it.
    - type=merge_state_changed, to=has_conflicts: The branch conflicts with base. Propose a rebase strategy — don't execute without confirmation.

    Keep replies short. The user is working in the same terminal; noisy output is disruptive.
    """
}

/// Observable box that lets Settings read the current ChannelRouter's
/// subscriberCount. The Router lives in AppServices; the box is injected
/// as a SwiftUI environment object.
@MainActor
final class ChannelRouterBox: ObservableObject {
    @Published var router: ChannelRouter?
}
```

- [ ] **Step 2: Wire the tab into `SettingsView`**

Edit `Sources/Graftty/Views/SettingsView.swift`:
```swift
import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultCommand") private var defaultCommand: String = ""
    @AppStorage("defaultCommandFirstPaneOnly") private var firstPaneOnly: Bool = true

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
            ChannelsSettingsPane()
                .tabItem { Label("Channels", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .frame(width: 480)
        .padding(20)
    }

    private var generalTab: some View {
        Form {
            TextField("Default command:", text: $defaultCommand, prompt: Text("e.g., claude"))
                .textFieldStyle(.roundedBorder)
            Toggle("Run in first pane only", isOn: $firstPaneOnly)
            Text("Runs automatically when a worktree opens. Leave empty to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: clean build.

- [ ] **Step 4: Commit**
```bash
git add Sources/Graftty/Views/SettingsView.swift Sources/Graftty/Views/Settings/ChannelsSettingsPane.swift
git commit -m "feat(channels): Channels Settings tab

Adds the Channels tab to SettingsView with an enable toggle, a
flag-disclosure banner (visible when enabled), the prompt
textarea with default content, and a subscribers-count caption.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Wire `ChannelRouter` + plugin installer into `GrafttyApp`

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Read `GrafttyApp.swift` fully**

Run: `cat Sources/Graftty/GrafttyApp.swift | head -200`
Note where `AppServices.init` is called and where `socketServer.onRequest` is set.

- [ ] **Step 2: Extend `AppServices` with `channelRouter`**

In `Sources/Graftty/GrafttyApp.swift`, modify `AppServices`:
```swift
@MainActor
final class AppServices {
    let socketServer: SocketServer
    let channelRouter: ChannelRouter
    let worktreeMonitor: WorktreeMonitor
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    var worktreeMonitorBridge: WorktreeMonitorBridge?

    init(socketPath: String) {
        self.socketServer = SocketServer(socketPath: socketPath)
        let channelSocketPath = SocketPathResolver.resolveChannels()
        self.channelRouter = ChannelRouter(
            socketPath: channelSocketPath,
            promptProvider: {
                UserDefaults.standard.string(forKey: "channelPrompt")
                    ?? ChannelsSettingsPane.defaultPrompt
            }
        )
        self.worktreeMonitor = WorktreeMonitor()
        self.statsStore = WorktreeStatsStore()
        self.prStatusStore = PRStatusStore()

        // Wire PRStatusStore → ChannelRouter.
        self.prStatusStore.onTransition = { [weak channelRouter] worktreePath, message in
            channelRouter?.dispatch(worktreePath: worktreePath, message: message)
        }
    }
}
```

- [ ] **Step 3: Start the router + install the plugin at app launch**

In `GrafttyApp.startup()` (or wherever the existing `socketServer.start()` is called), add:
```swift
        // Start the channels socket when enabled.
        if UserDefaults.standard.bool(forKey: "channelsEnabled") {
            try? services.channelRouter.start()
            // Install plugin config (idempotent).
            if let pluginBundleDir = Bundle.main.url(forResource: "plugins/graftty-channel", withExtension: nil),
               let cliPath = Self.bundledCLIPath() {
                let manifest = (try? String(contentsOf: pluginBundleDir.appendingPathComponent("plugin.json"))) ?? "{}"
                let template = (try? String(contentsOf: pluginBundleDir.appendingPathComponent("mcp.json.template"))) ?? "{}"
                try? ChannelPluginInstaller.install(
                    pluginsRoot: ChannelPluginInstaller.defaultPluginsRoot(),
                    cliPath: cliPath,
                    manifest: manifest,
                    mcpTemplate: template
                )
            }
        }
```

And add a helper:
```swift
    static func bundledCLIPath() -> String? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/graftty")
            .path
    }
```

> **Note:** The subagent may find that `Bundle.main.url(forResource:withExtension:)` doesn't match a subdirectory the way this code assumes. Look at how `webResourcesURL` is resolved in `WebServerController` or equivalent; mirror that pattern for the plugin bundle lookup.

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: clean build.

- [ ] **Step 5: Commit**
```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "feat(channels): wire ChannelRouter + plugin installer

AppServices owns the router alongside the existing socket server.
On app launch with channelsEnabled=true, install the plugin
config into ~/.claude/plugins/ and start the router. The
PRStatusStore.onTransition callback routes events to the
router's subscriber-matched fanout.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Channels-enabled observer — prompt debounce + router enable/disable + installer rerun

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift` (or new `Sources/Graftty/Channels/ChannelSettingsObserver.swift`)

- [ ] **Step 1: Add a settings observer**

Create `Sources/Graftty/Channels/ChannelSettingsObserver.swift`:
```swift
import Foundation
import Combine
import GrafttyKit

/// Observes channelPrompt and channelsEnabled UserDefaults, debounces
/// prompt edits (500ms) and fans out on every change. When
/// channelsEnabled flips, starts or stops the router and re-runs the
/// plugin installer on every true→something transition (to keep the
/// CLI path current if the .app is moved).
@MainActor
final class ChannelSettingsObserver {
    private let router: ChannelRouter
    private var promptTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(router: ChannelRouter) {
        self.router = router

        UserDefaults.standard.publisher(for: \.channelPrompt)
            .dropFirst()
            .sink { [weak self] _ in self?.schedulePromptBroadcast() }
            .store(in: &cancellables)

        UserDefaults.standard.publisher(for: \.channelsEnabled)
            .dropFirst()
            .sink { [weak self] enabled in self?.apply(enabled: enabled) }
            .store(in: &cancellables)
    }

    private func schedulePromptBroadcast() {
        promptTimer?.invalidate()
        promptTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.router.broadcastInstructions() }
        }
    }

    private func apply(enabled: Bool) {
        router.isEnabled = enabled
        if enabled {
            try? router.start()
        }
    }
}

extension UserDefaults {
    @objc dynamic var channelPrompt: String {
        string(forKey: "channelPrompt") ?? ""
    }
    @objc dynamic var channelsEnabled: Bool {
        bool(forKey: "channelsEnabled")
    }
}
```

- [ ] **Step 2: Wire the observer into `AppServices`**

Add to `AppServices`:
```swift
    let channelSettingsObserver: ChannelSettingsObserver

    // inside init, after channelRouter:
    self.channelSettingsObserver = ChannelSettingsObserver(router: channelRouter)
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: clean build.

- [ ] **Step 4: Commit**
```bash
git add Sources/Graftty/Channels/ChannelSettingsObserver.swift Sources/Graftty/GrafttyApp.swift
git commit -m "feat(channels): settings observer for prompt debounce

Watches channelPrompt (debounces 500ms → broadcastInstructions)
and channelsEnabled (start/stop router). Prompt edits propagate
to all active subscribers live.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: `TerminalManager` / surface-launch callsite — pass `channelsEnabled` to `defaultCommandDecision`

**Files:**
- Modify: whichever file calls `defaultCommandDecision` (the existing argument site; likely `Sources/Graftty/Terminal/TerminalManager.swift` per the default-command spec)

- [ ] **Step 1: Find the existing callsite**

Run: `grep -rn "defaultCommandDecision" Sources/`

- [ ] **Step 2: Pass `channelsEnabled`**

At the callsite, add:
```swift
let channelsEnabled = UserDefaults.standard.bool(forKey: "channelsEnabled")
let decision = defaultCommandDecision(
    defaultCommand: defaultCommand,
    firstPaneOnly: firstPaneOnly,
    isFirstPane: isFirstPane,
    wasRehydrated: wasRehydrated,
    channelsEnabled: channelsEnabled
)
```

- [ ] **Step 3: Verify build + all tests pass**

Run: `swift test 2>&1 | tail -20`
Expected: full test suite green.

- [ ] **Step 4: Commit**
```bash
git add Sources/Graftty/Terminal/TerminalManager.swift  # adjust path as needed
git commit -m "feat(channels): thread channelsEnabled to launch decision

When the user's defaultCommand is 'claude' and channels are
enabled, the composed launch string gets the channel flags
prepended automatically.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 15: SPECS.md — add CHANNELS section

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Append the CHANNELS section**

Append to `SPECS.md` (verbatim from design spec Section "SPECS.md requirements"):

```markdown
## CHANNELS — Claude Code channels integration

**CHANNELS-1.1** While `channelsEnabled` is true and the user's `defaultCommand` begins with the `claude` binary name, the application shall insert `--channels plugin:graftty-channel --dangerously-load-development-channels plugin:graftty-channel` between the binary name and any user-supplied arguments for all subsequently launched sessions. If `defaultCommand` does not begin with `claude`, the launch string shall be unchanged.

**CHANNELS-1.2** While channels are enabled, the application shall rewrite `~/.claude/plugins/graftty-channel/.mcp.json` on every app launch with the current absolute path to the bundled `graftty` CLI binary.

**CHANNELS-1.3** When channels are disabled via the Settings toggle, the application shall stop forwarding events to existing subscribers but shall not close their sockets.

**CHANNELS-1.4** Existing `claude` sessions shall continue with their original launch flags when channels are enabled or disabled mid-session; only newly launched sessions shall pick up the change.

**CHANNELS-2.1** When `PRStatusStore` detects a PR state transition (`open`/`merged`/`closed`), CI conclusion change, or merge-state change for a worktree with an active channel subscriber, the application shall forward exactly one event to that subscriber.

**CHANNELS-2.2** Events shall not be sent to subscribers whose worktree path does not match the worktree that produced the transition.

**CHANNELS-2.3** Event attributes `worktree`, `provider`, `repo`, `pr_number`, and `pr_url` shall be present on every `pr_state_changed`, `ci_conclusion_changed`, and `merge_state_changed` event.

**CHANNELS-2.4** Events shall not be sent for idempotent polls where the previous and current state are identical.

**CHANNELS-3.1** When the user edits the channels prompt in Settings, the application shall fan out a `type=instructions` event to every connected subscriber after a 500ms debounce.

**CHANNELS-3.2** On first socket connection from a subscriber, the application shall immediately send a `type=instructions` event carrying the current prompt, before any other events.

**CHANNELS-4.1** If `WorktreeResolver.resolve()` fails during subprocess startup, the subprocess shall emit a single `type=channel_error` MCP notification and exit with status 1.

**CHANNELS-4.2** If the channel socket connection closes mid-session, the subprocess shall emit a single `type=channel_error` MCP notification and exit with status 1.

**CHANNELS-4.3** If a subscriber's socket write fails (e.g., `EPIPE` after the claude process exited), the router shall remove that subscriber from its subscriber map.

**CHANNELS-4.4** When a `PRStatusStore` fetch fails, no event shall be sent to any subscriber for that polling cycle.

**CHANNELS-5.1** The channel socket shall be located at the standard Graftty socket directory as resolved by `SocketPathResolver`, named `graftty-channels.sock`, distinct from the control socket at `graftty.sock`.

**CHANNELS-5.2** The channel socket and the control socket shall operate independently; a failure on one shall not disrupt the other.
```

- [ ] **Step 2: Commit**
```bash
git add SPECS.md
git commit -m "docs: add CHANNELS requirements to SPECS.md

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 16: Full build + test sweep + manual sanity

- [ ] **Step 1: Full build**

Run: `swift build 2>&1 | tail -15`
Expected: clean build, no warnings.

- [ ] **Step 2: Full test suite**

Run: `swift test 2>&1 | tail -30`
Expected: all tests pass.

- [ ] **Step 3: Check for any residual TODOs or `XXX`**

Run: `grep -rn "XXX\|TODO.*channel" Sources/ Tests/ 2>&1 | head -20`
Expected: empty output.

- [ ] **Step 4: Launch the app (manual) and exercise the Settings UI**

Run: `swift run Graftty &`

Then manually: open Settings (⌘,), click Channels tab, toggle enable, edit prompt, toggle disable. Check no crashes.

- [ ] **Step 5: Commit any small fixups discovered during smoke**

Stop here if smoke passes. If issues found, fix inline, re-run tests, commit.

---

## Summary

Fifteen tasks shipping the end-to-end Claude channels feature. Each task TDD-driven, each committed separately. Final touch passes: `/simplify` for cleanup, PR open.
