# WebRTC M1.4 — SSH-Style Channel Framing

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the SSH-style channel multiplexing layer over WebRTC DataChannel: a wire-frame format (open/close/payload/error) and a per-side `ChannelRouter` actor that dispatches frames to per-channel handlers. This is the substrate every later channel type plugs into (M2 `terminal`, M3 `panes_state`, M4 `pane_control`).

**Architecture:** A `Channel` is a unidirectional or bidirectional logical stream identified by a `ChannelID` (UInt32) and tagged with a `ChannelType` (string). Frames are encoded as a single-byte type tag + JSON metadata + opaque binary payload. The same `DataChannel` carries N concurrent channels by interleaving frames. `ChannelRouter` lives on both sides; it owns the DataChannel send/receive loop, dispatches inbound frames to registered `ChannelHandler`s by type, and exposes a `send(frame:)` API the handlers use to write outbound frames.

**Tech Stack:** Pure Swift + `Foundation.Data` + JSON. No new SwiftPM dependencies. Uses `RTCDataBuffer` from `stasel/WebRTC` (already pulled in by M1.1).

**Scope this PR explicitly does NOT include:**
- Noise authentication wrapping the channel layer (M1.3 — needs human crypto review).
- Concrete channel handlers for `terminal`, `panes_state`, `pane_control` (M2/M3/M4).
- Backpressure / window updates (deferred per design doc §8 — "Custom flow-control/window updates are reserved for the port-tunnel milestone").
- Server-side wiring into `GrafttyApp.startup()` — `ChannelRouter` is a library type; production injection happens when the first concrete handler ships (M3 likely).

---

## Wire format

Each frame is one `RTCDataBuffer` carrying:

```
+--------+-----------------+----------------+
| 1 byte | 4 bytes (LE)    | variable       |
| type   | metadata length | metadata JSON  |
+--------+-----------------+----------------+
                                            |
+----------------+--------------------------+
| 4 bytes (LE)   | variable                 |
| payload length | payload bytes (opaque)   |
+----------------+--------------------------+
```

- `type` is a `FrameType` byte: `0x01 open`, `0x02 close`, `0x03 payload`, `0x04 error`.
- `metadata` is UTF-8 JSON whose decoded shape depends on `type`. Each `FrameType` has its own Codable struct.
- `payload` is opaque bytes carried only by `payload` frames; the other frame types use `payload length == 0`.

LE u32 lengths cap each section at 4 GiB — far above any practical SCTP message size (WebRTC DataChannels cap individual messages at ~256 KiB anyway).

## File Structure

**Files to create (in `GrafttyProtocol` — shared by mobile + Mac):**
- `Sources/GrafttyProtocol/ChannelID.swift` — opaque `UInt32`-wrapper struct with `Sendable`, `Hashable`, `Codable` conformances.
- `Sources/GrafttyProtocol/ChannelFrame.swift` — `FrameType` enum, the 4 metadata structs (`ChannelOpen`, `ChannelClose`, `ChannelPayload`, `ChannelError`), and `ChannelFrame` enum aggregating them.
- `Sources/GrafttyProtocol/ChannelFrameCoder.swift` — `encode(_:)` and `decode(_:)` static methods over `Data`.

**Files to create (in `GrafttyProtocol` shared test target):**
- `Tests/GrafttyProtocolTests/ChannelFrameCoderTests.swift` — round-trip + malformed-input tests.

**Files to create (in `GrafttyMobileKit`):**
- `Sources/GrafttyMobileKit/Remote/ChannelRouter.swift` — mobile-side actor that owns one DataChannel's frame dispatch + handler registry.
- `Tests/GrafttyMobileKitTests/Remote/ChannelRouterTests.swift` — unit tests against a fake `ChannelTransport`.

**Files to create (in `GrafttyKit`):**
- `Sources/GrafttyKit/Remote/ChannelRouter.swift` — Mac-side mirror. Identical shape; cross-target duplication forced by SwiftPM target boundary (same as `WebRTCHostAgent` / `RemoteHostConnection`).
- `Tests/GrafttyKitTests/Remote/ChannelRouterTests.swift` — same tests, Mac-side.

**Files modified:**
- None in this PR. `RemoteHostConnection` / `WebRTCHostAgent` are NOT wired to `ChannelRouter` yet — the wiring lands in M2 when the first concrete `terminal` handler ships, alongside retiring `/ws`.

---

## Task 1: `ChannelID` newtype in `GrafttyProtocol`

**Files:**
- Create: `Sources/GrafttyProtocol/ChannelID.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Unique-per-connection identifier for a logical channel multiplexed over
/// the WebRTC DataChannel. Wraps `UInt32` to make routing-by-id a typed
/// operation rather than a raw-integer footgun.
///
/// `ChannelID(0)` is reserved for the channel layer itself (heartbeats,
/// future control messages); concrete channel handlers must use values
/// `>= 1`. The allocator (`ChannelRouter.nextOutboundID`) starts at 1.
public struct ChannelID: Sendable, Hashable, Codable {
    public let raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(UInt32.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public static let reserved = ChannelID(0)
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyProtocol/ChannelID.swift
git commit -m "feat(protocol): ChannelID newtype — UInt32 wrapper for channel-mux routing"
```

---

## Task 2: `ChannelFrame` types

**Files:**
- Create: `Sources/GrafttyProtocol/ChannelFrame.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Wire-level frame type tag. Each value's metadata shape is the
/// corresponding `Channel*` struct below.
public enum FrameType: UInt8, Sendable, CaseIterable {
    case open    = 0x01
    case close   = 0x02
    case payload = 0x03
    case error   = 0x04
}

/// `open` frame metadata. Opens a new channel of the given type. The
/// receiver's `ChannelRouter` looks up a handler factory by `type`; if
/// found, the handler accepts the open and begins receiving subsequent
/// `payload` frames on this `id`. If no handler factory matches, the
/// router responds with an `error` frame and the channel is dropped.
public struct ChannelOpen: Codable, Sendable, Equatable {
    public let id: ChannelID
    public let type: String
    public init(id: ChannelID, type: String) {
        self.id = id
        self.type = type
    }
}

/// `close` frame metadata. Either side can close. The receiver removes
/// its routing entry and notifies the handler.
public struct ChannelClose: Codable, Sendable, Equatable {
    public let id: ChannelID
    public init(id: ChannelID) { self.id = id }
}

/// `payload` frame metadata. The opaque bytes ride alongside in the
/// frame's payload section (not encoded in this struct).
public struct ChannelPayload: Codable, Sendable, Equatable {
    public let id: ChannelID
    public init(id: ChannelID) { self.id = id }
}

/// `error` frame metadata. Sent by either side to signal a non-recoverable
/// failure on a specific channel. The recipient should drop the channel.
public struct ChannelError: Codable, Sendable, Equatable {
    public let id: ChannelID
    public let code: String
    public let message: String
    public init(id: ChannelID, code: String, message: String) {
        self.id = id
        self.code = code
        self.message = message
    }
}

/// Tagged-union aggregate; `ChannelFrameCoder` encodes/decodes this.
public enum ChannelFrame: Sendable, Equatable {
    case open(ChannelOpen)
    case close(ChannelClose)
    case payload(ChannelPayload, Data)
    case error(ChannelError)
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyProtocol/ChannelFrame.swift
git commit -m "feat(protocol): ChannelFrame — open/close/payload/error frame types"
```

---

## Task 3: `ChannelFrameCoder` encode/decode

**Files:**
- Create: `Sources/GrafttyProtocol/ChannelFrameCoder.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Encodes a `ChannelFrame` into the wire layout documented in the
/// M1.4 plan, and decodes it back. The encoder produces a single
/// `Data` blob sized to fit in one `RTCDataBuffer`.
public enum ChannelFrameCoder {

    public enum DecodeError: Error, Equatable, Sendable {
        case truncated
        case unknownType(UInt8)
        case malformedJSON(String)
        case payloadLengthMismatch
    }

    public static func encode(_ frame: ChannelFrame) throws -> Data {
        let typeByte: UInt8
        let metadataJSON: Data
        let payload: Data
        let encoder = JSONEncoder()
        switch frame {
        case .open(let m):
            typeByte = FrameType.open.rawValue
            metadataJSON = try encoder.encode(m)
            payload = Data()
        case .close(let m):
            typeByte = FrameType.close.rawValue
            metadataJSON = try encoder.encode(m)
            payload = Data()
        case .payload(let m, let bytes):
            typeByte = FrameType.payload.rawValue
            metadataJSON = try encoder.encode(m)
            payload = bytes
        case .error(let m):
            typeByte = FrameType.error.rawValue
            metadataJSON = try encoder.encode(m)
            payload = Data()
        }
        var out = Data()
        out.reserveCapacity(1 + 4 + metadataJSON.count + 4 + payload.count)
        out.append(typeByte)
        appendLittleEndianUInt32(UInt32(metadataJSON.count), to: &out)
        out.append(metadataJSON)
        appendLittleEndianUInt32(UInt32(payload.count), to: &out)
        out.append(payload)
        return out
    }

    public static func decode(_ data: Data) throws -> ChannelFrame {
        guard data.count >= 9 else { throw DecodeError.truncated }
        var cursor = data.startIndex
        let typeByte = data[cursor]
        cursor = data.index(after: cursor)
        guard let frameType = FrameType(rawValue: typeByte) else {
            throw DecodeError.unknownType(typeByte)
        }
        let metadataLength = try readLittleEndianUInt32(from: data, at: &cursor)
        guard cursor + Int(metadataLength) <= data.endIndex else {
            throw DecodeError.truncated
        }
        let metadataJSON = data[cursor..<(cursor + Int(metadataLength))]
        cursor = cursor + Int(metadataLength)
        let payloadLength = try readLittleEndianUInt32(from: data, at: &cursor)
        guard cursor + Int(payloadLength) <= data.endIndex else {
            throw DecodeError.payloadLengthMismatch
        }
        let payload = data[cursor..<(cursor + Int(payloadLength))]
        let decoder = JSONDecoder()
        switch frameType {
        case .open:
            let m = try decoder.decode(ChannelOpen.self, from: Data(metadataJSON))
            return .open(m)
        case .close:
            let m = try decoder.decode(ChannelClose.self, from: Data(metadataJSON))
            return .close(m)
        case .payload:
            let m = try decoder.decode(ChannelPayload.self, from: Data(metadataJSON))
            return .payload(m, Data(payload))
        case .error:
            let m = try decoder.decode(ChannelError.self, from: Data(metadataJSON))
            return .error(m)
        }
    }

    private static func appendLittleEndianUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func readLittleEndianUInt32(
        from data: Data,
        at cursor: inout Data.Index
    ) throws -> UInt32 {
        guard cursor + 4 <= data.endIndex else { throw DecodeError.truncated }
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { buf in
            for i in 0..<4 {
                buf[i] = data[cursor + i]
            }
        }
        cursor = cursor + 4
        return UInt32(littleEndian: value)
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyProtocol/ChannelFrameCoder.swift
git commit -m "feat(protocol): ChannelFrameCoder — encode/decode round-trip"
```

---

## Task 4: Coder round-trip tests

**Files:**
- Create: `Tests/GrafttyProtocolTests/ChannelFrameCoderTests.swift`

- [ ] **Step 1: Write the tests**

```swift
import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("ChannelFrameCoder — encode/decode round-trip across all four FrameType variants.")
struct ChannelFrameCoderTests {

    @Test
    func openFrameRoundTrips() throws {
        let frame: ChannelFrame = .open(ChannelOpen(id: ChannelID(7), type: "terminal"))
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func closeFrameRoundTrips() throws {
        let frame: ChannelFrame = .close(ChannelClose(id: ChannelID(42)))
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func payloadFrameRoundTrips() throws {
        let payload = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0xFF])
        let frame: ChannelFrame = .payload(ChannelPayload(id: ChannelID(13)), payload)
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func emptyPayloadFrameRoundTrips() throws {
        let frame: ChannelFrame = .payload(ChannelPayload(id: ChannelID(1)), Data())
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func errorFrameRoundTrips() throws {
        let frame: ChannelFrame = .error(ChannelError(
            id: ChannelID(99),
            code: "channel-type-unknown",
            message: "no handler factory for type 'panes_state'"
        ))
        let bytes = try ChannelFrameCoder.encode(frame)
        let decoded = try ChannelFrameCoder.decode(bytes)
        #expect(decoded == frame)
    }

    @Test
    func decodeTruncatedHeaderThrows() throws {
        let bytes = Data([0x01, 0x00, 0x00])
        #expect(throws: ChannelFrameCoder.DecodeError.truncated) {
            try ChannelFrameCoder.decode(bytes)
        }
    }

    @Test
    func decodeUnknownTypeThrows() throws {
        // type byte 0x99 is not a valid FrameType; the 8 zero bytes after
        // satisfy the minimum header-length check.
        let bytes = Data([0x99, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: ChannelFrameCoder.DecodeError.unknownType(0x99)) {
            try ChannelFrameCoder.decode(bytes)
        }
    }

    @Test
    func decodeShortMetadataThrows() throws {
        // type=open, metadata length=100, but only 3 bytes of metadata follow
        // before the payload-length field. Should be flagged as truncated
        // when reading metadata.
        var bytes = Data([0x01])
        bytes.append(contentsOf: [0x64, 0x00, 0x00, 0x00]) // metadataLength = 100
        bytes.append(contentsOf: [0x00, 0x00, 0x00])       // 3 bytes only
        #expect(throws: ChannelFrameCoder.DecodeError.truncated) {
            try ChannelFrameCoder.decode(bytes)
        }
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter ChannelFrameCoderTests 2>&1 | tail -15`
Expected: 8 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyProtocolTests/ChannelFrameCoderTests.swift
git commit -m "test(protocol): ChannelFrameCoder round-trip + malformed-input coverage"
```

---

## Task 5: Define `ChannelHandler` protocol + `ChannelTransport` injection seam (mobile)

**Files:**
- Create: `Sources/GrafttyMobileKit/Remote/ChannelRouter.swift`

This is the mobile-side router. The Mac-side mirror in Task 6 reuses the same shape (cross-target duplication, same forced constraint as M1.1's `RemoteHostConnection` / `WebRTCHostAgent`).

- [ ] **Step 1: Write the file**

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Abstract send/receive surface for the `ChannelRouter`. Production wires
/// this to an `RTCDataChannel`; tests inject an in-memory transport.
public protocol ChannelTransport: Sendable {
    func send(_ data: Data) async throws
    /// Hand the next inbound `Data` blob (one DataChannel message) to the
    /// router. The router decodes and dispatches.
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async
}

/// Receives frames addressed to a single channel and writes outbound frames
/// via the supplied `ChannelOutbox`. Concrete handlers (e.g. for
/// `terminal`, `panes_state`, `pane_control`) implement this.
public protocol ChannelHandler: Sendable {
    var channelType: String { get }
    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async
    func onPayload(_ data: Data) async
    func onClose() async
    func onError(_ code: String, message: String) async
}

/// Limited-surface object handed to a `ChannelHandler` so it can write
/// outbound frames without holding a reference to the whole router.
public struct ChannelOutbox: Sendable {
    private let _send: @Sendable (ChannelFrame) async throws -> Void
    public init(send: @escaping @Sendable (ChannelFrame) async throws -> Void) {
        self._send = send
    }
    public func send(_ frame: ChannelFrame) async throws {
        try await _send(frame)
    }
}

/// Multiplexes N logical channels over a single `ChannelTransport`.
/// Owns the inbound dispatch loop, the per-`ChannelID` handler map, and
/// the allocator for outbound `ChannelID`s.
public actor ChannelRouter {

    public enum RouterError: Error, Equatable, Sendable {
        case noHandlerForType(String)
        case unknownChannelID(ChannelID)
        case encodeFailed(String)
        case decodeFailed(String)
    }

    private let transport: ChannelTransport
    private var handlersByID: [ChannelID: ChannelHandler] = [:]
    private var handlerFactoriesByType: [String: @Sendable () -> ChannelHandler] = [:]
    private var nextOutboundID: UInt32 = 1

    public init(transport: ChannelTransport) {
        self.transport = transport
    }

    /// Register a factory that produces a fresh handler for inbound `open`
    /// frames of `type`. The router calls the factory each time an inbound
    /// `open` arrives; the handler's `onOpen` is then awaited before the
    /// next frame for the same channel-id is dispatched.
    public func register(
        type: String,
        factory: @escaping @Sendable () -> ChannelHandler
    ) {
        handlerFactoriesByType[type] = factory
    }

    /// Open an outbound channel of `type`. Returns the allocated `ChannelID`
    /// and the handler the caller registered via this opening.
    @discardableResult
    public func open(
        type: String,
        handler: ChannelHandler
    ) async throws -> ChannelID {
        let id = ChannelID(nextOutboundID)
        nextOutboundID &+= 1
        handlersByID[id] = handler
        let frame: ChannelFrame = .open(ChannelOpen(id: id, type: type))
        try await sendFrame(frame)
        let outbox = ChannelOutbox { [weak self] frame in
            try await self?.sendFrame(frame)
        }
        await handler.onOpen(id, outbox: outbox)
        return id
    }

    /// Begin the inbound dispatch loop. Call once after construction.
    public func start() async {
        await transport.onReceive { [weak self] data in
            await self?.dispatch(data)
        }
    }

    public func close(_ id: ChannelID) async throws {
        guard let handler = handlersByID.removeValue(forKey: id) else { return }
        await handler.onClose()
        try await sendFrame(.close(ChannelClose(id: id)))
    }

    private func sendFrame(_ frame: ChannelFrame) async throws {
        let data: Data
        do {
            data = try ChannelFrameCoder.encode(frame)
        } catch {
            throw RouterError.encodeFailed(String(describing: error))
        }
        try await transport.send(data)
    }

    private func dispatch(_ data: Data) async {
        let frame: ChannelFrame
        do {
            frame = try ChannelFrameCoder.decode(data)
        } catch {
            // Decoder failure on an unknown peer's frame is logged-and-dropped
            // rather than fatal — a future peer with a newer wire format
            // shouldn't crash this side.
            return
        }
        switch frame {
        case .open(let m):
            guard let factory = handlerFactoriesByType[m.type] else {
                try? await sendFrame(.error(ChannelError(
                    id: m.id,
                    code: "channel-type-unknown",
                    message: "no handler factory for type '\(m.type)'"
                )))
                return
            }
            let handler = factory()
            handlersByID[m.id] = handler
            let outbox = ChannelOutbox { [weak self] frame in
                try await self?.sendFrame(frame)
            }
            await handler.onOpen(m.id, outbox: outbox)
        case .close(let m):
            guard let handler = handlersByID.removeValue(forKey: m.id) else { return }
            await handler.onClose()
        case .payload(let m, let bytes):
            guard let handler = handlersByID[m.id] else { return }
            await handler.onPayload(bytes)
        case .error(let m):
            guard let handler = handlersByID.removeValue(forKey: m.id) else { return }
            await handler.onError(m.code, message: m.message)
        }
    }
}
#endif
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/ChannelRouter.swift
git commit -m "feat(remote): ChannelRouter (mobile) — multiplex N channels over one DataChannel"
```

---

## Task 6: Mac-side mirror of `ChannelRouter`

**Files:**
- Create: `Sources/GrafttyKit/Remote/ChannelRouter.swift`

- [ ] **Step 1: Write the file**

Write `Sources/GrafttyKit/Remote/ChannelRouter.swift` — same content as Task 5, with the `#if canImport(UIKit)` guard REMOVED (Mac side has no UIKit guard). The cross-target duplication is forced by SwiftPM target boundaries (same reason as the M1.1 `RemoteHostConnection` / `WebRTCHostAgent` split).

```swift
import Foundation
import GrafttyProtocol

public protocol ChannelTransport: Sendable {
    func send(_ data: Data) async throws
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async
}

public protocol ChannelHandler: Sendable {
    var channelType: String { get }
    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async
    func onPayload(_ data: Data) async
    func onClose() async
    func onError(_ code: String, message: String) async
}

public struct ChannelOutbox: Sendable {
    private let _send: @Sendable (ChannelFrame) async throws -> Void
    public init(send: @escaping @Sendable (ChannelFrame) async throws -> Void) {
        self._send = send
    }
    public func send(_ frame: ChannelFrame) async throws {
        try await _send(frame)
    }
}

public actor ChannelRouter {

    public enum RouterError: Error, Equatable, Sendable {
        case noHandlerForType(String)
        case unknownChannelID(ChannelID)
        case encodeFailed(String)
        case decodeFailed(String)
    }

    private let transport: ChannelTransport
    private var handlersByID: [ChannelID: ChannelHandler] = [:]
    private var handlerFactoriesByType: [String: @Sendable () -> ChannelHandler] = [:]
    private var nextOutboundID: UInt32 = 1

    public init(transport: ChannelTransport) {
        self.transport = transport
    }

    public func register(
        type: String,
        factory: @escaping @Sendable () -> ChannelHandler
    ) {
        handlerFactoriesByType[type] = factory
    }

    @discardableResult
    public func open(
        type: String,
        handler: ChannelHandler
    ) async throws -> ChannelID {
        let id = ChannelID(nextOutboundID)
        nextOutboundID &+= 1
        handlersByID[id] = handler
        let frame: ChannelFrame = .open(ChannelOpen(id: id, type: type))
        try await sendFrame(frame)
        let outbox = ChannelOutbox { [weak self] frame in
            try await self?.sendFrame(frame)
        }
        await handler.onOpen(id, outbox: outbox)
        return id
    }

    public func start() async {
        await transport.onReceive { [weak self] data in
            await self?.dispatch(data)
        }
    }

    public func close(_ id: ChannelID) async throws {
        guard let handler = handlersByID.removeValue(forKey: id) else { return }
        await handler.onClose()
        try await sendFrame(.close(ChannelClose(id: id)))
    }

    private func sendFrame(_ frame: ChannelFrame) async throws {
        let data: Data
        do {
            data = try ChannelFrameCoder.encode(frame)
        } catch {
            throw RouterError.encodeFailed(String(describing: error))
        }
        try await transport.send(data)
    }

    private func dispatch(_ data: Data) async {
        let frame: ChannelFrame
        do {
            frame = try ChannelFrameCoder.decode(data)
        } catch {
            return
        }
        switch frame {
        case .open(let m):
            guard let factory = handlerFactoriesByType[m.type] else {
                try? await sendFrame(.error(ChannelError(
                    id: m.id,
                    code: "channel-type-unknown",
                    message: "no handler factory for type '\(m.type)'"
                )))
                return
            }
            let handler = factory()
            handlersByID[m.id] = handler
            let outbox = ChannelOutbox { [weak self] frame in
                try await self?.sendFrame(frame)
            }
            await handler.onOpen(m.id, outbox: outbox)
        case .close(let m):
            guard let handler = handlersByID.removeValue(forKey: m.id) else { return }
            await handler.onClose()
        case .payload(let m, let bytes):
            guard let handler = handlersByID[m.id] else { return }
            await handler.onPayload(bytes)
        case .error(let m):
            guard let handler = handlersByID.removeValue(forKey: m.id) else { return }
            await handler.onError(m.code, message: m.message)
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Remote/ChannelRouter.swift
git commit -m "feat(remote): ChannelRouter (Mac) — mirror of mobile-side router"
```

---

## Task 7: `ChannelRouter` tests on the mobile side

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Remote/ChannelRouterTests.swift`

- [ ] **Step 1: Write the tests**

```swift
#if canImport(UIKit)
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("ChannelRouter — multiplexes channel frames + dispatches to handlers by type.")
struct ChannelRouterTests {

    @Test
    func openRegistersHandlerAndDispatchesPayload() async throws {
        let pair = FakePair()
        let alice = ChannelRouter(transport: pair.aliceSide)
        let bob = ChannelRouter(transport: pair.bobSide)
        await alice.start()
        await bob.start()

        let recorder = RecordingHandler(channelType: "terminal")
        await bob.register(type: "terminal") { recorder }

        let aliceHandler = RecordingHandler(channelType: "terminal")
        let id = try await alice.open(type: "terminal", handler: aliceHandler)
        #expect(id == ChannelID(1))

        // Allow the open frame to ride across the fake transport
        try await pollUntil(timeout: .seconds(2)) {
            await recorder.opened
        }
    }

    @Test
    func payloadFrameReachesRegisteredHandler() async throws {
        let pair = FakePair()
        let alice = ChannelRouter(transport: pair.aliceSide)
        let bob = ChannelRouter(transport: pair.bobSide)
        await alice.start()
        await bob.start()

        let bobRecorder = RecordingHandler(channelType: "panes_state")
        await bob.register(type: "panes_state") { bobRecorder }

        let aliceHandler = RecordingHandler(channelType: "panes_state")
        let id = try await alice.open(type: "panes_state", handler: aliceHandler)
        try await pollUntil(timeout: .seconds(2)) { await bobRecorder.opened }

        // Use Alice's outbox to send a payload frame on the channel she opened.
        let outbox = try #require(await aliceHandler.outbox)
        try await outbox.send(.payload(ChannelPayload(id: id), Data([0x42, 0x43])))
        try await pollUntil(timeout: .seconds(2)) { await bobRecorder.lastPayload == Data([0x42, 0x43]) }
    }

    @Test
    func openForUnregisteredTypeReturnsErrorFrame() async throws {
        let pair = FakePair()
        let alice = ChannelRouter(transport: pair.aliceSide)
        let bob = ChannelRouter(transport: pair.bobSide)
        await alice.start()
        await bob.start()

        let aliceHandler = RecordingHandler(channelType: "unknown_type")
        _ = try await alice.open(type: "unknown_type", handler: aliceHandler)

        try await pollUntil(timeout: .seconds(2)) {
            await aliceHandler.lastErrorCode == "channel-type-unknown"
        }
    }

    @Test
    func closeFrameNotifiesHandlerAndRemovesEntry() async throws {
        let pair = FakePair()
        let alice = ChannelRouter(transport: pair.aliceSide)
        let bob = ChannelRouter(transport: pair.bobSide)
        await alice.start()
        await bob.start()

        let bobRecorder = RecordingHandler(channelType: "terminal")
        await bob.register(type: "terminal") { bobRecorder }

        let aliceHandler = RecordingHandler(channelType: "terminal")
        let id = try await alice.open(type: "terminal", handler: aliceHandler)
        try await pollUntil(timeout: .seconds(2)) { await bobRecorder.opened }

        try await alice.close(id)
        try await pollUntil(timeout: .seconds(2)) { await bobRecorder.closed }
        try await pollUntil(timeout: .seconds(2)) { await aliceHandler.closed }
    }
}

/// In-process bidirectional fake `ChannelTransport`. Each side's `send`
/// puts the bytes on the other side's `onReceive`.
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

private actor RecordingHandler: ChannelHandler {
    nonisolated let channelType: String
    var opened = false
    var closed = false
    var lastPayload: Data?
    var lastErrorCode: String?
    var outbox: ChannelOutbox?

    init(channelType: String) {
        self.channelType = channelType
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.opened = true
        self.outbox = outbox
    }

    func onPayload(_ data: Data) async {
        self.lastPayload = data
    }

    func onClose() async {
        self.closed = true
    }

    func onError(_ code: String, message: String) async {
        self.lastErrorCode = code
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

Run: `swift test --filter ChannelRouterTests 2>&1 | tail -10`
Expected: on macOS, 0 tests run (UIKit-guarded). Compile must be clean. On iOS CI: 4 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyMobileKitTests/Remote/ChannelRouterTests.swift
git commit -m "test(remote): ChannelRouter (mobile) — open/payload/close/unknown-type coverage"
```

---

## Task 8: Mirror tests on the Mac side

**Files:**
- Create: `Tests/GrafttyKitTests/Remote/ChannelRouterTests.swift`

- [ ] **Step 1: Write the tests**

Same content as Task 7, with:
- Remove the `#if canImport(UIKit)` / `#endif` wrapping.
- Change `@testable import GrafttyMobileKit` → `@testable import GrafttyKit`.

Otherwise byte-identical. Forced cross-target duplication.

- [ ] **Step 2: Run the tests**

Run: `swift test --filter ChannelRouterTests 2>&1 | tail -15`
Expected: 4 tests pass (on macOS, this is the Mac-side suite).

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyKitTests/Remote/ChannelRouterTests.swift
git commit -m "test(remote): ChannelRouter (Mac) — mirror of mobile-side coverage"
```

---

## Task 9: Full test-suite verification

**Files:** none.

- [ ] **Step 1: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: pass. The new tests join the existing 1910 — expect ~1918 total (8 new framing tests + 4 new router tests on Mac side; the mobile-side router tests are UIKit-guarded and skip on macOS).

- [ ] **Step 2: Clean working tree**

Run: `git status --short`
Expected: empty.

- [ ] **Step 3: Verify spec drift**

Run: `python3 scripts/generate-specs.py --check`
Expected: exit 0 (no new `@spec` markers, no drift).

---

## Self-Review

- **Spec coverage:** This PR implements the substrate for REMOTE-6.x (`panes_state` channel — M3) and REMOTE-7.x (`pane_control` — M4) without committing to either's protocol yet. The framing layer is the open/close/payload/error wire format the design doc §6 specifies.
- **Placeholders:** none — every code block is complete, every command has an expected output.
- **Type consistency:** `ChannelID`, `ChannelFrame`, `ChannelOpen`/`Close`/`Payload`/`Error`, `ChannelFrameCoder`, `ChannelTransport`, `ChannelHandler`, `ChannelOutbox`, `ChannelRouter` — all names appear consistently across Tasks 1-8.
- **Cross-target duplication:** `ChannelRouter` is identical in both `GrafttyKit` and `GrafttyMobileKit`. Same forced-by-SwiftPM constraint as `RemoteHostConnection` / `WebRTCHostAgent`. Lifting to a shared module would require a new SwiftPM target; deferred.
- **iOS-only guard:** the mobile router file + its tests carry `#if canImport(UIKit)` to match the rest of `GrafttyMobileKit`.
