# CLI Pane Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `graftty pane list|add|close` CLI subcommands that let users enumerate, create, and destroy panes in the PWD's worktree from the shell.

**Architecture:** Extend the existing `NotificationMessage`-over-Unix-domain-socket protocol with three new cases (`listPanes`, `addPane`, `closePane`) and introduce a small `ResponseMessage` reply channel so the CLI can get structured output back. The app-side handler reuses the existing `splitPane` / `closePane` static helpers in `GrafttyApp.swift` — the new branches just translate 1-based integer pane IDs to `TerminalID`s, look up the target worktree by PWD, and dispatch.

**Tech Stack:** Swift 5.10, SwiftUI/AppKit, swift-argument-parser, libghostty (GhosttyKit), Unix domain sockets, Swift Testing framework.

**Spec:** `docs/superpowers/specs/2026-04-17-cli-pane-commands-design.md`

---

## File Structure

**Modified:**
- `Sources/GrafttyKit/Notification/NotificationMessage.swift` — add three new `NotificationMessage` cases, `PaneSplitWire` enum, `ResponseMessage` enum, `PaneInfo` struct. Keep the wire protocol co-located.
- `Sources/GrafttyKit/Notification/SocketServer.swift` — add an `onRequest` callback; when set, the server calls it after `onMessage` and writes the returned `ResponseMessage` (if any) to the client before closing.
- `Sources/GrafttyCLI/SocketClient.swift` — add `sendExpectingResponse(_:) -> ResponseMessage` alongside `send(_:)`. The existing `send` stays fire-and-forget.
- `Sources/GrafttyCLI/CLI.swift` — register a `Pane` parent subcommand with three children: `PaneList`, `PaneAdd`, `PaneClose`.
- `Sources/Graftty/GrafttyApp.swift` — wire `services.socketServer.onRequest` in `startup()`; add three handler branches that reuse `splitPane` / `closePane`. `splitPane`'s signature changes to return `TerminalID?` so the `addPane` branch can address the newly-created pane when typing `--command` into it.

**New:**
- `Tests/GrafttyKitTests/Notification/PaneMessageTests.swift` — encoding/decoding round-trips for the three new message cases and `ResponseMessage`.
- `Tests/GrafttyKitTests/Notification/PaneIndexTests.swift` — unit tests for a small `leaf(atPaneID:in:)` helper that translates a 1-based ID to a `TerminalID` from a `SplitTree`.

---

## Task 1: Add `PaneSplitWire`, `PaneInfo`, and `ResponseMessage` types

**Files:**
- Modify: `Sources/GrafttyKit/Notification/NotificationMessage.swift`
- Test: `Tests/GrafttyKitTests/Notification/PaneMessageTests.swift` (new)

- [ ] **Step 1: Write the failing tests for new types**

Create `Tests/GrafttyKitTests/Notification/PaneMessageTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("Pane Message Types")
struct PaneMessageTests {
    @Test func paneSplitWireEncodesAsString() throws {
        let encoder = JSONEncoder()
        #expect(String(data: try encoder.encode(PaneSplitWire.right), encoding: .utf8) == "\"right\"")
        #expect(String(data: try encoder.encode(PaneSplitWire.left), encoding: .utf8) == "\"left\"")
        #expect(String(data: try encoder.encode(PaneSplitWire.up), encoding: .utf8) == "\"up\"")
        #expect(String(data: try encoder.encode(PaneSplitWire.down), encoding: .utf8) == "\"down\"")
    }

    @Test func paneSplitWireDecodesFromString() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(PaneSplitWire.self, from: "\"right\"".data(using: .utf8)!) == .right)
        #expect(try decoder.decode(PaneSplitWire.self, from: "\"down\"".data(using: .utf8)!) == .down)
    }

    @Test func paneInfoRoundTrip() throws {
        let info = PaneInfo(id: 2, title: "claude", focused: true)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(PaneInfo.self, from: data)
        #expect(decoded.id == 2)
        #expect(decoded.title == "claude")
        #expect(decoded.focused == true)
    }

    @Test func paneInfoEncodesNilTitleAsMissing() throws {
        let info = PaneInfo(id: 1, title: nil, focused: false)
        let data = try JSONEncoder().encode(info)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["title"] == nil)
    }

    @Test func responseOkEncoding() throws {
        let data = try JSONEncoder().encode(ResponseMessage.ok)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "ok")
    }

    @Test func responseErrorEncoding() throws {
        let data = try JSONEncoder().encode(ResponseMessage.error("bad id"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "error")
        #expect(json["message"] as? String == "bad id")
    }

    @Test func responsePaneListEncoding() throws {
        let panes = [
            PaneInfo(id: 1, title: "zsh", focused: false),
            PaneInfo(id: 2, title: nil, focused: true),
        ]
        let data = try JSONEncoder().encode(ResponseMessage.paneList(panes))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "pane_list")
        let list = json["panes"] as! [[String: Any]]
        #expect(list.count == 2)
        #expect(list[0]["id"] as? Int == 1)
        #expect(list[1]["focused"] as? Bool == true)
    }

    @Test func responseRoundTrip() throws {
        let original = ResponseMessage.paneList([
            PaneInfo(id: 1, title: "zsh", focused: true),
            PaneInfo(id: 2, title: "claude", focused: false),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
        guard case .paneList(let panes) = decoded else {
            Issue.record("Expected .paneList")
            return
        }
        #expect(panes.count == 2)
        #expect(panes[0].title == "zsh")
        #expect(panes[1].focused == false)
    }

    @Test func responseErrorRoundTrip() throws {
        let data = try JSONEncoder().encode(ResponseMessage.error("nope"))
        let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
        if case .error(let msg) = decoded {
            #expect(msg == "nope")
        } else { Issue.record("Expected .error") }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PaneMessageTests`
Expected: build errors — `PaneSplitWire`, `PaneInfo`, `ResponseMessage` do not exist yet.

- [ ] **Step 3: Add the types to NotificationMessage.swift**

Edit `Sources/GrafttyKit/Notification/NotificationMessage.swift`. At the bottom of the file, append:

```swift
/// Wire-level representation of a four-way pane split direction. Mirrors
/// the app-layer `PaneSplit` enum, but lives in GrafttyKit so the CLI can
/// encode/decode it without importing app-layer code.
public enum PaneSplitWire: String, Codable, Sendable {
    case right, left, up, down
}

/// One row in the response to a `listPanes` request. `id` is the 1-based
/// pane number within the worktree's split tree (see design spec). `title`
/// is the pane's OSC-0/OSC-2-reported title if any, otherwise nil.
public struct PaneInfo: Codable, Sendable, Equatable {
    public let id: Int
    public let title: String?
    public let focused: Bool

    public init(id: Int, title: String?, focused: Bool) {
        self.id = id
        self.title = title
        self.focused = focused
    }
}

/// Reply sent from the app back to the CLI after a request-style
/// `NotificationMessage`. `ok` covers successful fire-and-forget commands;
/// `error` carries a human-readable message printed to the CLI's stderr;
/// `paneList` is the response to `listPanes`.
public enum ResponseMessage: Sendable, Equatable {
    case ok
    case error(String)
    case paneList([PaneInfo])
}

extension ResponseMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, message, panes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode("ok", forKey: .type)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        case .paneList(let panes):
            try container.encode("pane_list", forKey: .type)
            try container.encode(panes, forKey: .panes)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ok":
            self = .ok
        case "error":
            let msg = try container.decode(String.self, forKey: .message)
            self = .error(msg)
        case "pane_list":
            let panes = try container.decode([PaneInfo].self, forKey: .panes)
            self = .paneList(panes)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown response type: \(type)"))
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter PaneMessageTests`
Expected: all tests in the suite pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Notification/NotificationMessage.swift Tests/GrafttyKitTests/Notification/PaneMessageTests.swift
git commit -m "feat(kit): add PaneSplitWire, PaneInfo, ResponseMessage wire types"
```

---

## Task 2: Add `listPanes`, `addPane`, `closePane` cases to `NotificationMessage`

**Files:**
- Modify: `Sources/GrafttyKit/Notification/NotificationMessage.swift`
- Test: `Tests/GrafttyKitTests/Notification/PaneMessageTests.swift`

- [ ] **Step 1: Append failing tests for the three new cases**

Append to `Tests/GrafttyKitTests/Notification/PaneMessageTests.swift`:

```swift
@Suite("NotificationMessage Pane Cases")
struct NotificationMessagePaneTests {
    @Test func encodeListPanes() throws {
        let msg = NotificationMessage.listPanes(path: "/tmp/wt")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "list_panes")
        #expect(json["path"] as? String == "/tmp/wt")
    }

    @Test func encodeAddPaneNoCommand() throws {
        let msg = NotificationMessage.addPane(path: "/tmp/wt", direction: .right, command: nil)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "add_pane")
        #expect(json["path"] as? String == "/tmp/wt")
        #expect(json["direction"] as? String == "right")
        #expect(json["command"] == nil)
    }

    @Test func encodeAddPaneWithCommand() throws {
        let msg = NotificationMessage.addPane(path: "/tmp/wt", direction: .down, command: "claude")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["direction"] as? String == "down")
        #expect(json["command"] as? String == "claude")
    }

    @Test func encodeClosePane() throws {
        let msg = NotificationMessage.closePane(path: "/tmp/wt", index: 2)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(json["type"] as? String == "close_pane")
        #expect(json["path"] as? String == "/tmp/wt")
        #expect(json["index"] as? Int == 2)
    }

    @Test func decodeListPanes() throws {
        let json = #"{"type":"list_panes","path":"/tmp/wt"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .listPanes(let path) = msg {
            #expect(path == "/tmp/wt")
        } else { Issue.record("Expected .listPanes") }
    }

    @Test func decodeAddPane() throws {
        let json = #"{"type":"add_pane","path":"/tmp/wt","direction":"left","command":"htop"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .addPane(let path, let direction, let command) = msg {
            #expect(path == "/tmp/wt")
            #expect(direction == .left)
            #expect(command == "htop")
        } else { Issue.record("Expected .addPane") }
    }

    @Test func decodeAddPaneWithoutCommand() throws {
        let json = #"{"type":"add_pane","path":"/tmp/wt","direction":"right"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .addPane(_, _, let command) = msg {
            #expect(command == nil)
        } else { Issue.record("Expected .addPane") }
    }

    @Test func decodeClosePane() throws {
        let json = #"{"type":"close_pane","path":"/tmp/wt","index":3}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .closePane(let path, let index) = msg {
            #expect(path == "/tmp/wt")
            #expect(index == 3)
        } else { Issue.record("Expected .closePane") }
    }

    @Test func existingNotifyStillDecodes() throws {
        // Regression: make sure adding cases didn't break the original two.
        let json = #"{"type":"notify","path":"/tmp/wt","text":"hi"}"#
        let msg = try JSONDecoder().decode(NotificationMessage.self, from: json.data(using: .utf8)!)
        if case .notify(_, let text, _) = msg {
            #expect(text == "hi")
        } else { Issue.record("Expected .notify") }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter NotificationMessagePaneTests`
Expected: compile failure — the enum cases don't exist.

- [ ] **Step 3: Extend the NotificationMessage enum**

Edit `Sources/GrafttyKit/Notification/NotificationMessage.swift`. Replace the `NotificationMessage` enum and its `Codable` conformance block entirely with:

```swift
public enum NotificationMessage: Sendable {
    case notify(path: String, text: String, clearAfter: TimeInterval? = nil)
    case clear(path: String)
    case listPanes(path: String)
    case addPane(path: String, direction: PaneSplitWire, command: String?)
    case closePane(path: String, index: Int)
}

extension NotificationMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, path, text, clearAfter, direction, command, index
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notify(let path, let text, let clearAfter):
            try container.encode("notify", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(clearAfter, forKey: .clearAfter)
        case .clear(let path):
            try container.encode("clear", forKey: .type)
            try container.encode(path, forKey: .path)
        case .listPanes(let path):
            try container.encode("list_panes", forKey: .type)
            try container.encode(path, forKey: .path)
        case .addPane(let path, let direction, let command):
            try container.encode("add_pane", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(direction, forKey: .direction)
            try container.encodeIfPresent(command, forKey: .command)
        case .closePane(let path, let index):
            try container.encode("close_pane", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(index, forKey: .index)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "notify":
            let path = try container.decode(String.self, forKey: .path)
            let text = try container.decode(String.self, forKey: .text)
            let clearAfter = try container.decodeIfPresent(TimeInterval.self, forKey: .clearAfter)
            self = .notify(path: path, text: text, clearAfter: clearAfter)
        case "clear":
            let path = try container.decode(String.self, forKey: .path)
            self = .clear(path: path)
        case "list_panes":
            let path = try container.decode(String.self, forKey: .path)
            self = .listPanes(path: path)
        case "add_pane":
            let path = try container.decode(String.self, forKey: .path)
            let direction = try container.decode(PaneSplitWire.self, forKey: .direction)
            let command = try container.decodeIfPresent(String.self, forKey: .command)
            self = .addPane(path: path, direction: direction, command: command)
        case "close_pane":
            let path = try container.decode(String.self, forKey: .path)
            let index = try container.decode(Int.self, forKey: .index)
            self = .closePane(path: path, index: index)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown message type: \(type)"))
        }
    }
}
```

- [ ] **Step 4: Run all notification tests to verify pass + no regressions**

Run: `swift test --filter NotificationMessageTests && swift test --filter NotificationMessagePaneTests && swift test --filter PaneMessageTests`
Expected: every test passes, including the two pre-existing `NotificationMessage Tests`.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Notification/NotificationMessage.swift Tests/GrafttyKitTests/Notification/PaneMessageTests.swift
git commit -m "feat(kit): add listPanes/addPane/closePane to NotificationMessage"
```

---

## Task 3: Add `onRequest` callback and response writing to `SocketServer`

**Files:**
- Modify: `Sources/GrafttyKit/Notification/SocketServer.swift`
- Test: `Tests/GrafttyKitTests/Notification/SocketIntegrationTests.swift`

- [ ] **Step 1: Write a failing integration test for request/response**

Append to `Tests/GrafttyKitTests/Notification/SocketIntegrationTests.swift` (inside the existing `@Suite`):

```swift
@Test func serverWritesResponseWhenOnRequestSet() async throws {
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-resp-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let socketPath = dir.appendingPathComponent("s").path
    let server = SocketServer(socketPath: socketPath)
    server.onRequest = { msg in
        guard case .listPanes = msg else { return .error("unexpected") }
        return .paneList([
            PaneInfo(id: 1, title: "zsh", focused: true),
            PaneInfo(id: 2, title: nil, focused: false),
        ])
    }
    try server.start()
    defer { server.stop() }
    try await Task.sleep(for: .milliseconds(100))

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    socketPath.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
        }
    }
    let connectResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    #expect(connectResult == 0)

    let req = #"{"type":"list_panes","path":"/tmp/wt"}"# + "\n"
    req.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }

    // Half-close the write side so the server's read-until-EOF terminates
    // and proceeds to send the response. Without SHUT_WR, the server would
    // block waiting for more bytes.
    _ = Darwin.shutdown(fd, Int32(SHUT_WR))

    var buffer = [UInt8](repeating: 0, count: 4096)
    let bytesRead = Darwin.read(fd, &buffer, 4096)
    close(fd)
    #expect(bytesRead > 0)

    let data = Data(buffer[0..<bytesRead])
    let line = String(data: data, encoding: .utf8)!
        .components(separatedBy: "\n")
        .first(where: { !$0.isEmpty })!
    let response = try JSONDecoder().decode(ResponseMessage.self, from: line.data(using: .utf8)!)
    guard case .paneList(let panes) = response else {
        Issue.record("Expected .paneList")
        return
    }
    #expect(panes.count == 2)
    #expect(panes[0].title == "zsh")
    #expect(panes[0].focused == true)
}

@Test func serverOmitsResponseWhenOnRequestUnset() async throws {
    // Fire-and-forget path must still work — notify/clear don't expect replies.
    let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("graftty-fnf-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let socketPath = dir.appendingPathComponent("s").path
    let received = MutableBox<NotificationMessage?>(nil)
    let server = SocketServer(socketPath: socketPath)
    server.onMessage = { msg in received.value = msg }
    // Intentionally no onRequest.
    try server.start()
    defer { server.stop() }
    try await Task.sleep(for: .milliseconds(100))

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    socketPath.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
        }
    }
    _ = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    let msg = #"{"type":"notify","path":"/tmp/wt","text":"hi"}"# + "\n"
    msg.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
    _ = Darwin.shutdown(fd, Int32(SHUT_WR))

    var buffer = [UInt8](repeating: 0, count: 1024)
    let bytesRead = Darwin.read(fd, &buffer, 1024)
    close(fd)
    // Server closes without writing anything; read returns 0 (EOF).
    #expect(bytesRead == 0)

    try await Task.sleep(for: .milliseconds(100))
    #expect(received.value != nil)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter SocketIntegrationTests`
Expected: compile failure — `server.onRequest` does not exist.

- [ ] **Step 3: Add `onRequest` to SocketServer and write responses**

Edit `Sources/GrafttyKit/Notification/SocketServer.swift`. Add the new public property below `onMessage`:

```swift
    /// Request/response variant of `onMessage`. When set, the server calls
    /// this after `onMessage` and, if the handler returns a non-nil
    /// `ResponseMessage`, writes it to the client (as JSON + newline)
    /// before closing the connection. Handlers are invoked on the same
    /// dispatch queue as `onMessage`; dispatch to the main actor inside
    /// the handler if your state requires it.
    public var onRequest: ((NotificationMessage) -> ResponseMessage?)?
```

Then modify `handleClient(fd:)`. Replace the loop body so that after dispatching to `onMessage`, if `onRequest` is set, compute the response and write it back synchronously on the queue:

```swift
    private func handleClient(fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = Darwin.read(fd, &chunk, 4096)
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
        }
        let lines = String(data: buffer, encoding: .utf8)?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(NotificationMessage.self, from: data) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }

            // Request/response path: if a handler is registered, run it on
            // the main actor and block the socket-queue worker on the
            // result so the reply is written before we close the fd.
            if let onRequest {
                let semaphore = DispatchSemaphore(value: 0)
                var response: ResponseMessage?
                DispatchQueue.main.async {
                    response = onRequest(message)
                    semaphore.signal()
                }
                semaphore.wait()
                if let response, let encoded = try? JSONEncoder().encode(response) {
                    var payload = encoded
                    payload.append(0x0A) // '\n'
                    payload.withUnsafeBytes { buf in
                        _ = Darwin.write(fd, buf.baseAddress, buf.count)
                    }
                }
            }
        }
    }
```

- [ ] **Step 4: Run socket tests to verify pass**

Run: `swift test --filter SocketIntegrationTests`
Expected: all five socket integration tests pass, including the two new ones.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Notification/SocketServer.swift Tests/GrafttyKitTests/Notification/SocketIntegrationTests.swift
git commit -m "feat(kit): support response messages in SocketServer via onRequest"
```

---

## Task 4: Add 1-based pane-ID resolver helper

**Files:**
- Modify: `Sources/GrafttyKit/Model/SplitTree.swift`
- Test: `Tests/GrafttyKitTests/Notification/PaneIndexTests.swift` (new)

We expose a small helper on `SplitTree` that translates a 1-based user-facing pane ID to a `TerminalID`. Living on `SplitTree` (not on `GrafttyApp`) lets us unit-test it without running the app.

- [ ] **Step 1: Write failing tests**

Create `Tests/GrafttyKitTests/Notification/PaneIndexTests.swift`:

```swift
import Testing
@testable import GrafttyKit

@Suite("Pane Index Resolution")
struct PaneIndexTests {
    @Test func emptyTreeReturnsNil() {
        let tree = SplitTree(root: nil)
        #expect(tree.leaf(atPaneID: 1) == nil)
    }

    @Test func singleLeafPaneID1Resolves() {
        let id = TerminalID()
        let tree = SplitTree(root: .leaf(id))
        #expect(tree.leaf(atPaneID: 1) == id)
        #expect(tree.leaf(atPaneID: 0) == nil)
        #expect(tree.leaf(atPaneID: 2) == nil)
    }

    @Test func splitTreeResolvesInAllLeavesOrder() {
        let a = TerminalID()
        let b = TerminalID()
        let c = TerminalID()
        // Tree: (a | (b / c)) — allLeaves order is [a, b, c].
        let inner = SplitTree.Node.split(.init(direction: .vertical, ratio: 0.5, left: .leaf(b), right: .leaf(c)))
        let root = SplitTree.Node.split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(a), right: inner))
        let tree = SplitTree(root: root)

        #expect(tree.allLeaves == [a, b, c])
        #expect(tree.leaf(atPaneID: 1) == a)
        #expect(tree.leaf(atPaneID: 2) == b)
        #expect(tree.leaf(atPaneID: 3) == c)
        #expect(tree.leaf(atPaneID: 4) == nil)
        #expect(tree.leaf(atPaneID: -1) == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter PaneIndexTests`
Expected: compile failure — `leaf(atPaneID:)` does not exist.

- [ ] **Step 3: Add the helper to SplitTree**

Edit `Sources/GrafttyKit/Model/SplitTree.swift`. Add inside the `SplitTree` struct, in the "Queries" section (below `allLeaves`):

```swift
    /// Resolve a user-facing 1-based pane ID (as printed by `graftty
    /// pane list`) to its underlying `TerminalID`, or nil if the ID is
    /// out of range. Uses `allLeaves` order — the same order `list`
    /// displays.
    public func leaf(atPaneID paneID: Int) -> TerminalID? {
        let leaves = allLeaves
        let idx = paneID - 1
        guard leaves.indices.contains(idx) else { return nil }
        return leaves[idx]
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter PaneIndexTests`
Expected: all three tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Model/SplitTree.swift Tests/GrafttyKitTests/Notification/PaneIndexTests.swift
git commit -m "feat(kit): add SplitTree.leaf(atPaneID:) 1-based resolver"
```

---

## Task 5: CLI `sendExpectingResponse` and the `Pane` subcommand tree

**Files:**
- Modify: `Sources/GrafttyCLI/SocketClient.swift`
- Modify: `Sources/GrafttyCLI/CLI.swift`

No tests — the CLI surface talks to a live socket (exercised in Task 7 manual verification). The types are unit-tested in earlier tasks.

- [ ] **Step 1: Add `sendExpectingResponse` to SocketClient**

Edit `Sources/GrafttyCLI/SocketClient.swift`. Replace the entire `SocketClient` enum with:

```swift
enum SocketClient {
    /// Fire-and-forget: write the message and close. Used by `notify`.
    static func send(_ message: NotificationMessage) throws {
        let fd = try openConnectedSocket()
        defer { close(fd) }
        try writeMessage(message, to: fd)
    }

    /// Request/response: write the message, half-close the write side so
    /// the server knows the request is complete, then read the reply.
    /// Used by `pane list`, `pane add`, `pane close`.
    static func sendExpectingResponse(_ message: NotificationMessage) throws -> ResponseMessage {
        let fd = try openConnectedSocket()
        defer { close(fd) }
        try writeMessage(message, to: fd)

        // Half-close so the server's read-until-EOF loop terminates and
        // it proceeds to compute + write the response. Without this the
        // server would block indefinitely waiting for more bytes.
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &chunk, 4096)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        guard let str = String(data: buffer, encoding: .utf8),
              let line = str.components(separatedBy: "\n").first(where: { !$0.isEmpty }),
              let data = line.data(using: .utf8) else {
            throw CLIError.socketError("Empty response from app")
        }
        return try JSONDecoder().decode(ResponseMessage.self, from: data)
    }

    // MARK: - Internals

    private static func openConnectedSocket() throws -> Int32 {
        let socketPath = resolveSocketPath()
        let pathBytes = socketPath.utf8.count
        guard pathBytes <= SocketServer.maxPathBytes else {
            throw CLIError.socketPathTooLong(bytes: pathBytes, maxBytes: SocketServer.maxPathBytes)
        }
        guard FileManager.default.fileExists(atPath: socketPath) else { throw CLIError.appNotRunning }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.socketError("Failed to create socket") }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            close(fd)
            if errno == ECONNREFUSED || errno == ENOENT { throw CLIError.appNotRunning }
            throw CLIError.socketTimeout
        }
        return fd
    }

    private static func writeMessage(_ message: NotificationMessage, to fd: Int32) throws {
        let data = try JSONEncoder().encode(message)
        let jsonLine = String(data: data, encoding: .utf8)! + "\n"
        jsonLine.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
    }

    private static func resolveSocketPath() -> String {
        if let envPath = ProcessInfo.processInfo.environment["GRAFTTY_SOCK"] { return envPath }
        return AppState.defaultDirectory.appendingPathComponent("graftty.sock").path
    }
}
```

Prepend Foundation + GrafttyKit imports if the file doesn't already have them. (It does — keep them.)

- [ ] **Step 2: Add the `Pane` subcommand tree to CLI.swift**

Edit `Sources/GrafttyCLI/CLI.swift`. Replace the entire `GrafttyCLI` configuration and the file contents with:

```swift
import ArgumentParser
import Foundation
import GrafttyKit

@main
struct GrafttyCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "graftty",
        abstract: "Graftty terminal multiplexer CLI",
        subcommands: [Notify.self, Pane.self]
    )
}

struct Notify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Send an attention notification to Graftty")

    @Argument(help: "Notification text to display in the sidebar")
    var text: String?

    @Flag(name: .long, help: "Clear the attention notification")
    var clear: Bool = false

    @Option(name: .long, help: "Auto-clear the notification after N seconds")
    var clearAfter: Int?

    func validate() throws {
        if !clear && text == nil {
            throw ValidationError("Provide notification text or use --clear")
        }
    }

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let message: NotificationMessage
        if clear {
            message = .clear(path: worktreePath)
        } else {
            message = .notify(path: worktreePath, text: text!, clearAfter: clearAfter.map { TimeInterval($0) })
        }
        try CLIEnv.sendFireAndForget(message)
    }
}

struct Pane: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add, remove, or list panes in the current worktree",
        subcommands: [PaneList.self, PaneAdd.self, PaneClose.self]
    )
}

struct PaneList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List panes in the current worktree"
    )

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(.listPanes(path: worktreePath))
        switch response {
        case .paneList(let panes):
            for pane in panes {
                let marker = pane.focused ? "*" : " "
                let idPadding = String(repeating: " ", count: max(0, 3 - String(pane.id).count))
                let title = pane.title ?? ""
                let line = title.isEmpty
                    ? "\(marker) \(pane.id)\(idPadding)"
                    : "\(marker) \(pane.id)\(idPadding)\(title)"
                print(line)
            }
        case .error(let msg):
            CLIEnv.printError(msg)
            throw ExitCode(1)
        case .ok:
            CLIEnv.printError("Unexpected ok response for list")
            throw ExitCode(1)
        }
    }
}

struct PaneAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a new pane by splitting the focused pane in the current worktree"
    )

    @Option(name: .long, help: "Split direction: right (default), left, up, or down")
    var direction: String = "right"

    @Option(name: .long, help: "Optional command to run in the new pane (typed into the shell followed by Enter)")
    var command: String?

    func validate() throws {
        guard PaneSplitWire(rawValue: direction) != nil else {
            throw ValidationError("--direction must be one of: right, left, up, down")
        }
    }

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let dir = PaneSplitWire(rawValue: direction)!
        let response = try CLIEnv.sendRequest(.addPane(path: worktreePath, direction: dir, command: command))
        try CLIEnv.expectOk(response)
    }
}

struct PaneClose: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a pane by its 1-based ID as shown by `pane list`"
    )

    @Argument(help: "Pane ID from `graftty pane list`")
    var id: Int

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(.closePane(path: worktreePath, index: id))
        try CLIEnv.expectOk(response)
    }
}

/// Small shared helpers used by every subcommand. Keeps each subcommand's
/// `run()` readable and avoids copy-pasting the error plumbing.
enum CLIEnv {
    static func resolveWorktree() throws -> String {
        do {
            return try WorktreeResolver.resolve()
        } catch {
            printError("Not inside a tracked worktree")
            throw ExitCode(1)
        }
    }

    static func sendFireAndForget(_ message: NotificationMessage) throws {
        do {
            try SocketClient.send(message)
        } catch let error as CLIError {
            printError(error.description)
            throw ExitCode(1)
        }
    }

    static func sendRequest(_ message: NotificationMessage) throws -> ResponseMessage {
        do {
            return try SocketClient.sendExpectingResponse(message)
        } catch let error as CLIError {
            printError(error.description)
            throw ExitCode(1)
        } catch {
            printError("Decode error: \(error)")
            throw ExitCode(1)
        }
    }

    static func expectOk(_ response: ResponseMessage) throws {
        switch response {
        case .ok:
            return
        case .error(let msg):
            printError(msg)
            throw ExitCode(1)
        case .paneList:
            printError("Unexpected pane_list response")
            throw ExitCode(1)
        }
    }

    static func printError(_ msg: String) {
        FileHandle.standardError.write(Data("graftty: \(msg)\n".utf8))
    }
}
```

- [ ] **Step 3: Build to verify CLI compiles**

Run: `swift build --target graftty-cli`
Expected: build succeeds with no errors.

- [ ] **Step 4: Run full test suite to verify no regressions**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyCLI/SocketClient.swift Sources/GrafttyCLI/CLI.swift
git commit -m "feat(cli): add graftty pane list/add/close subcommands"
```

---

## Task 6: Wire `onRequest` in `GrafttyApp` and dispatch to per-case handlers

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

This task changes `splitPane`'s signature to return `TerminalID?` (was `Void`), adds `handlePaneRequest`, and registers `services.socketServer.onRequest`.

- [ ] **Step 1: Change `splitPane` to return `TerminalID?`**

Edit `Sources/Graftty/GrafttyApp.swift` around `splitPane` (starts at line ~348).

Replace the declaration and body:

```swift
    @MainActor
    @discardableResult
    fileprivate static func splitPane(
        appState: Binding<AppState>,
        terminalManager: TerminalManager,
        targetID: TerminalID,
        split: PaneSplit
    ) -> TerminalID? {
        for repoIdx in appState.wrappedValue.repos.indices {
            for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                guard wt.state == .running, wt.splitTree.allLeaves.contains(targetID) else { continue }

                let direction: SplitDirection = (split == .right || split == .left) ? .horizontal : .vertical
                let newID = TerminalID()
                let newTree: SplitTree
                switch split {
                case .right, .down:
                    newTree = wt.splitTree.inserting(newID, at: targetID, direction: direction)
                case .left, .up:
                    newTree = wt.splitTree.insertingBefore(newID, at: targetID, direction: direction)
                }
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
                _ = terminalManager.createSurface(terminalID: newID, worktreePath: wt.path)
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = newID
                terminalManager.setFocus(newID)
                return newID
            }
        }
        return nil
    }
```

The existing call sites (Cmd+D handler at ~line 331 and the context-menu handler at ~line 122) already ignore the return value. `@discardableResult` keeps them warning-free.

- [ ] **Step 2: Add `handlePaneRequest` as a sibling of `handleNotification`**

In the same file, add (place it just after `handleNotification`'s closing brace):

```swift
    /// Dispatcher for request-style messages from the CLI. Returns a
    /// `ResponseMessage` the server writes back to the client. Must run
    /// on the main actor because it touches `appState` and `terminalManager`.
    @MainActor
    fileprivate static func handlePaneRequest(
        _ message: NotificationMessage,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage? {
        switch message {
        case .listPanes(let path):
            return listPanes(path: path, appState: appState, terminalManager: terminalManager)
        case .addPane(let path, let direction, let command):
            return addPane(path: path, direction: direction, command: command,
                           appState: appState, terminalManager: terminalManager)
        case .closePane(let path, let index):
            return closePaneByIndex(path: path, index: index,
                                    appState: appState, terminalManager: terminalManager)
        case .notify, .clear:
            // Fire-and-forget cases — no response. `onMessage` already handled them.
            return nil
        }
    }

    @MainActor
    private static func listPanes(
        path: String,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        let leaves = wt.splitTree.allLeaves
        let panes = leaves.enumerated().map { (i, terminalID) -> PaneInfo in
            PaneInfo(
                id: i + 1,
                title: terminalManager.titles[terminalID],
                focused: terminalID == wt.focusedTerminalID
            )
        }
        return .paneList(panes)
    }

    @MainActor
    private static func addPane(
        path: String,
        direction: PaneSplitWire,
        command: String?,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        guard wt.state == .running else {
            return .error("worktree not running")
        }
        guard let targetID = wt.focusedTerminalID ?? wt.splitTree.allLeaves.first else {
            return .error("no panes to split")
        }
        let split: PaneSplit
        switch direction {
        case .right: split = .right
        case .left:  split = .left
        case .up:    split = .up
        case .down:  split = .down
        }
        guard let newID = splitPane(
            appState: appState,
            terminalManager: terminalManager,
            targetID: targetID,
            split: split
        ) else {
            return .error("split failed")
        }
        if let command, !command.isEmpty {
            typeCommand(command, into: newID, terminalManager: terminalManager)
        }
        return .ok
    }

    @MainActor
    private static func closePaneByIndex(
        path: String,
        index: Int,
        appState: Binding<AppState>,
        terminalManager: TerminalManager
    ) -> ResponseMessage {
        guard let wt = appState.wrappedValue.worktree(forPath: path) else {
            return .error("not tracked")
        }
        guard let targetID = wt.splitTree.leaf(atPaneID: index) else {
            return .error("no pane with id \(index) in this worktree")
        }
        closePane(appState: appState, terminalManager: terminalManager, targetID: targetID)
        return .ok
    }

    /// Type `text` followed by a newline into the surface owned by
    /// `terminalID`. Used by `pane add --command`. Newline is appended so
    /// the user's shell executes the command immediately.
    ///
    /// The text is forwarded via `ghostty_surface_text`, the same API
    /// libghostty uses for its paste action. Timing: if the shell hasn't
    /// drawn its prompt yet, the first characters can get eaten — in
    /// practice on macOS with zsh this is reliable, but if you observe
    /// flake, consider wiring libghostty's `command` config field at
    /// surface creation instead.
    @MainActor
    private static func typeCommand(
        _ text: String,
        into terminalID: TerminalID,
        terminalManager: TerminalManager
    ) {
        guard let handle = terminalManager.handle(for: terminalID) else { return }
        let toSend = text + "\n"
        toSend.withCString { cstr in
            ghostty_surface_text(
                handle.surface,
                cstr,
                UInt(toSend.lengthOfBytes(using: .utf8))
            )
        }
    }
```

**Note:** `ghostty_surface_text` is declared in the `GhosttyKit` module header (`void ghostty_surface_text(ghostty_surface_t, const char*, uintptr_t);`). The file already imports `GhosttyKit`? Check: `Sources/Graftty/GrafttyApp.swift` imports `SwiftUI`, `AppKit`, `GrafttyKit`. **Add** at the top:

```swift
import GhosttyKit
```

If this breaks anything (it shouldn't — `TerminalManager.swift` already depends on GhosttyKit and the module is transitively linked), the alternative is to add a `terminalManager.typeText(_:into:)` wrapper to keep GhosttyKit isolation. Prefer the import unless it causes a build issue.

- [ ] **Step 3: Register `onRequest` in `startup()`**

In `Sources/Graftty/GrafttyApp.swift`, find the existing block (around line 197–203) that sets `services.socketServer.onMessage`. Just below it, add:

```swift
        services.socketServer.onRequest = { message in
            MainActor.assumeIsolated {
                Self.handlePaneRequest(message, appState: binding, terminalManager: tm)
            }
        }
```

(The `binding` and `tm` local variables are already defined in the surrounding scope — the `onMessage` block uses them.)

- [ ] **Step 4: Build to verify the app compiles**

Run: `swift build`
Expected: build succeeds with no errors (warnings about unused results are fine).

- [ ] **Step 5: Run tests**

Run: `swift test`
Expected: all pre-existing + newly-added tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "feat(app): handle pane list/add/close requests from the CLI"
```

---

## Task 7: Manual smoke test and bug-fix loop

This task has no code to write up front — it's the "run it, find issues, add failing test, fix, commit" loop. Budget it.

- [ ] **Step 1: Build and install the CLI**

Run the existing install path. From the app: **Graftty menu → Install CLI Tool...**, or via the app's `CLIInstaller.install()` (see `Sources/GrafttyKit/CLIInstaller.swift`). For a dev build without full installation, use the built CLI directly:

```bash
swift build
APP_PID=$(pgrep -x Graftty || echo "not running")
echo "App pid: $APP_PID"
# If the app isn't running, launch it from Xcode or: open -a Graftty
```

- [ ] **Step 2: Smoke test `pane list`**

From a shell inside a tracked worktree:

```bash
.build/debug/graftty-cli pane list
```

Expected: one or more lines like `* 1  zsh` with `*` on the focused pane. If it errors with "Not inside a tracked worktree", cd into a worktree the app knows about.

- [ ] **Step 3: Smoke test `pane add`**

```bash
.build/debug/graftty-cli pane add
# New pane appears to the right of the focused one.
.build/debug/graftty-cli pane add --direction down
.build/debug/graftty-cli pane add --direction up --command "echo hello world"
```

Expected: three new panes appear. The third runs `echo hello world` and shows the output.

- [ ] **Step 4: Smoke test `pane close`**

```bash
.build/debug/graftty-cli pane list   # note the IDs
.build/debug/graftty-cli pane close 2
.build/debug/graftty-cli pane close 99   # should error
```

Expected: pane 2 closes. The `99` invocation prints `graftty: no pane with id 99 in this worktree` to stderr and exits 1.

- [ ] **Step 5: Fix any bugs found, TDD-style**

For each bug:
1. Write a failing test that reproduces it (unit if possible, else extend the socket integration tests).
2. Run to confirm failure.
3. Fix.
4. Run to confirm pass.
5. Commit with `fix:` prefix.

If no bugs are found, commit nothing.

- [ ] **Step 6: Final full-suite run**

Run: `swift test`
Expected: all tests pass.

---

## Self-Review

Checking against the spec:

- ✅ CLI shape `graftty pane list|add|close [--direction ...] [--command ...]` — Task 5.
- ✅ 1-based per-worktree pane IDs in `allLeaves` order — Task 4 (`leaf(atPaneID:)`) + Task 6 (`listPanes` handler).
- ✅ `* 1  zsh — /repo` output format with focus marker — Task 5 (`PaneList.run`).
- ✅ Response channel (`ok`/`error`/`paneList`) over the existing socket — Tasks 1, 3, 5.
- ✅ `ghostty_surface_text` for `--command` injection — Task 6 (`typeCommand`).
- ✅ Reuse of existing `splitPane` / `closePane` static helpers — Task 6.
- ✅ Error response when invalid pane ID passed to `close` — Task 6 (`closePaneByIndex`).
- ✅ Error when worktree not running for `add` — Task 6 (`addPane`).
- ✅ All three cases exit non-zero with message on error — Task 5 (`CLIEnv.expectOk`, `PaneList.run` error branch).

No placeholders, no TBDs. Types align: `PaneSplitWire`, `PaneInfo`, `ResponseMessage`, `leaf(atPaneID:)`, `splitPane` return type, all consistent across tasks.

The output format in Task 5 differs slightly from the design spec example (`* 1  zsh — /repo`). The implementation prints the title column without the `— /repo` suffix because `TerminalManager.titles` already contains whatever the shell's OSC-0/OSC-2 sequence set (typically includes the directory for zsh's default prompt). Good enough for MVP; tightening is a follow-up.
