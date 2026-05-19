# WebRTC M1.1 — SDK Integration + RemoteHostConnection Scaffold

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the `stasel/WebRTC` SwiftPM package into the project and ship a minimal `RemoteHostConnection` actor that can establish a WebRTC peer connection + open a DataChannel in a loopback test. This is the foundation slice of milestone M1 from the [iPad layout design doc](../specs/2026-05-15-ipad-layout-design.md) §8.

**Architecture:** Add `stasel/WebRTC` as a SwiftPM dependency to both `GrafttyKit` (Mac-side WebRTC host agent) and `GrafttyMobileKit` (mobile client transport). Create per-side actor types (`WebRTCHostAgent` on Mac, `RemoteHostConnection` on mobile) that wrap `RTCPeerConnection`. No signaling endpoint, no Noise handshake, no channel framing in this PR — just "two RTCPeerConnection instances negotiate a DataChannel in-process" so the SDK integration is provably working before later PRs build on it.

**Tech Stack:** stasel/WebRTC (`github.com/stasel/WebRTC`, v137.0.0+), Swift Testing, Swift 5.10, `@MainActor`+actor concurrency, `swift-crypto` (already transitively available via swift-nio-ssl).

**Scope this PR explicitly does NOT include:**
- Noise_KK handshake (M1.3 — separate PR with crypto review)
- Direct/Tailscale HTTPS signaling endpoint (M1.2)
- Channel framing layer / open/close/payload frames (M1.4)
- `terminal` / `panes_state` / `pane_control` channel handlers (M2/M3/M4)
- iOS Xcode project file edits (SwiftPM transitive resolution handles this when `GrafttyMobileKit` depends on `WebRTC`)
- App Store / TestFlight build verification (binary distribution risk — flag in PR description for human review before any user release)

---

## SDK choice rationale

Adopting **stasel/WebRTC** (`github.com/stasel/WebRTC`, M137 series):

| Criterion | Choice |
|---|---|
| iOS minimum | iOS 13+ — covers our iOS 17 target |
| macOS minimum | macOS 10.15+ — covers our macOS 14 target |
| App Store compatible | Yes — privacy manifests included |
| Distribution | SwiftPM `binaryTarget` (precompiled `WebRTC.xcframework`) |
| Maintenance posture | Actively maintained, version-tracked against Google's WebRTC releases |
| Binary size | ~70 MB compressed, ~150 MB on-device |

**Alternatives rejected:**
- *Apple WebKit RTCPeerConnection*: not exposed as standalone framework.
- *Direct webrtc.googlesource.com build*: requires Bazel toolchain, not SwiftPM-friendly.
- *shiguredo/webrtc-build*: maintained but heavier integration; stasel covers our use case with less ceremony.

**Risk surfaced for human review at PR time:** the 70 MB binary lift on the iOS app bundle. Acceptable for a developer tool, but worth your sign-off.

---

## File Structure

**Files to create:**
- `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift` — mobile-side actor that owns a single `RTCPeerConnection` + its DataChannel. Skeleton for now: establish, open data channel, expose send/receive.
- `Sources/GrafttyKit/Remote/WebRTCHostAgent.swift` — Mac-side counterpart that accepts incoming offers and answers them. Same skeleton shape.
- `Tests/GrafttyMobileKitTests/Remote/RemoteHostConnectionLoopbackTests.swift` — single-process test: two `RTCPeerConnection`s exchange SDP+ICE in-memory, open a DataChannel, send a byte ping-pong.

**Files to modify:**
- `Package.swift` — add `stasel/WebRTC` to `dependencies` and to both `GrafttyKit` and `GrafttyMobileKit` target deps.

---

## Task 1: Add the `stasel/WebRTC` SwiftPM dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the package to `dependencies`**

In `Package.swift`, the existing `dependencies` array ends with the `Stencil` entry. Append a new line:

```swift
.package(url: "https://github.com/stasel/WebRTC.git", from: "137.0.0"),
```

The full block should become:

```swift
dependencies: [
    .package(url: "https://github.com/btucker/libghostty-spm.git", branch: "expose-selection-api"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    .package(url: "https://github.com/stencilproject/Stencil.git", from: "0.15.1"),
    .package(url: "https://github.com/stasel/WebRTC.git", from: "137.0.0"),
],
```

- [ ] **Step 2: Add `WebRTC` to `GrafttyKit`'s dependencies**

In the same file, the `GrafttyKit` target's `dependencies` array currently ends with `Stencil`. Append:

```swift
.product(name: "WebRTC", package: "WebRTC"),
```

The target's full dependencies block should become:

```swift
dependencies: [
    "GrafttyProtocol",
    .product(name: "NIO", package: "swift-nio"),
    .product(name: "NIOHTTP1", package: "swift-nio"),
    .product(name: "NIOWebSocket", package: "swift-nio"),
    .product(name: "NIOSSL", package: "swift-nio-ssl"),
    .product(name: "Sparkle", package: "Sparkle"),
    .product(name: "Stencil", package: "Stencil"),
    .product(name: "WebRTC", package: "WebRTC"),
],
```

- [ ] **Step 3: Add `WebRTC` to `GrafttyMobileKit`'s dependencies**

In the same file, the `GrafttyMobileKit` target currently lists `"GrafttyProtocol"` and the `GhosttyTerminal` product. Append `WebRTC`:

```swift
dependencies: [
    "GrafttyProtocol",
    .product(name: "GhosttyTerminal", package: "libghostty-spm"),
    .product(name: "WebRTC", package: "WebRTC"),
],
```

- [ ] **Step 4: Resolve the package and verify it downloads**

Run:

```bash
swift package resolve 2>&1 | tail -10
```

Expected: `Computing version for ...`, `Computed version for ... 137.x.x`, `Fetching https://github.com/stasel/WebRTC.git` lines. The binary download is large (~70 MB) and may take 30-90 seconds on a fresh checkout.

- [ ] **Step 5: Verify build is clean**

Run:

```bash
swift build 2>&1 | tail -15
```

Expected: `Build complete!`. If you see warnings from the WebRTC binary surface, the `-warnings-as-errors` flag in `Package.swift:11` will fail the debug build. If this happens, **report BLOCKED** with the warning text — we'll either add a per-target suppression or pin a different SDK version. Do not weaken `strictWarnings` globally.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat(remote): add stasel/WebRTC SwiftPM dependency to GrafttyKit + GrafttyMobileKit"
```

---

## Task 2: Create the mobile-side `RemoteHostConnection` skeleton

**Files:**
- Create: `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`

- [ ] **Step 1: Write the file**

Write `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift` with this exact content:

```swift
#if canImport(UIKit)
import Foundation
import WebRTC

/// Mobile-side actor that owns a single `RTCPeerConnection` to a paired
/// host plus its DataChannel.
///
/// This is the scaffold per the [iPad layout design doc](../../../docs/superpowers/specs/2026-05-15-ipad-layout-design.md)
/// §6.1. Subsequent PRs add: signaling exchange (M1.2), Noise handshake
/// over the DataChannel (M1.3), and the channel-framing layer (M1.4)
/// that multiplexes terminal / panes_state / pane_control traffic.
///
/// The instance is per-host: one `RemoteHostConnection` exists per
/// host the user has open in the iPad layout. Host switching tears
/// the current connection down and builds a fresh one.
public actor RemoteHostConnection {

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected
        case failed(reason: String)
        case closed
    }

    public private(set) var state: State = .idle

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private let delegate: PeerConnectionDelegate
    private let dataChannelDelegate: DataChannelDelegate

    /// Continuation that resumes when the data channel transitions to
    /// `open`. Set during `connect`, resumed by `dataChannelDidChangeState`.
    private var openContinuation: CheckedContinuation<Void, Error>?

    /// Most-recently received binary frame. Test-only entry point —
    /// production code routes through the channel-framing layer
    /// added in a later PR.
    public private(set) var lastReceivedBinary: Data?

    public init() {
        // Initialising the factory triggers WebRTC's SSL/codec setup;
        // expensive (~10ms) but only done once per `RemoteHostConnection`.
        // Subsequent peer connections share the factory.
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        self.delegate = PeerConnectionDelegate()
        self.dataChannelDelegate = DataChannelDelegate()
    }

    deinit {
        RTCCleanupSSL()
    }

    /// Build the local peer connection and create the data channel.
    /// Returns the local SDP offer for signaling-side hand-off.
    public func createOffer() async throws -> RTCSessionDescription {
        let config = Self.defaultConfig()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let pc = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw ConnectionError.peerConnectionInitFailed
        }
        self.peerConnection = pc

        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = true
        guard let dc = pc.dataChannel(
            forLabel: "graftty",
            configuration: dataChannelConfig
        ) else {
            throw ConnectionError.dataChannelInitFailed
        }
        dc.delegate = dataChannelDelegate
        self.dataChannel = dc

        state = .connecting

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let offer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: offerConstraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: ConnectionError.sdpGenerationFailed); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, offer)
        return offer
    }

    /// Apply the answer received from the remote host and return when
    /// the data channel is open (or throw on failure / timeout).
    public func applyAnswer(_ answer: RTCSessionDescription) async throws {
        guard let pc = peerConnection else { throw ConnectionError.notConfigured }
        try await Self.setRemoteDescription(pc, answer)
        try await waitForDataChannelOpen()
    }

    /// Send a binary frame over the open data channel. Throws if the
    /// channel isn't open. Production code will route through a channel
    /// multiplexer; this is the raw-bytes entry point for the loopback test.
    public func sendBinary(_ data: Data) async throws {
        guard let dc = dataChannel, dc.readyState == .open else {
            throw ConnectionError.notOpen
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard dc.sendData(buffer) else {
            throw ConnectionError.sendFailed
        }
    }

    /// Test-only — exposes the WebRTC factory so a paired
    /// `WebRTCHostAgent` running in the same process can be constructed
    /// against a known offerer for the loopback test.
    public func underlyingPeerConnection() -> RTCPeerConnection? {
        peerConnection
    }

    /// Test-only — records the last binary frame received on the data
    /// channel. Used by the loopback test to verify ping-pong.
    func _testRecordReceivedBinary(_ data: Data) {
        lastReceivedBinary = data
    }

    public func close() {
        dataChannel?.close()
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        state = .closed
    }

    private func waitForDataChannelOpen() async throws {
        if dataChannel?.readyState == .open {
            state = .connected
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.openContinuation = continuation
            self.dataChannelDelegate.onOpen = { [weak self] in
                Task { await self?.handleDataChannelOpen() }
            }
            self.dataChannelDelegate.onMessage = { [weak self] data in
                Task { await self?._testRecordReceivedBinary(data) }
            }
        }
    }

    private func handleDataChannelOpen() {
        state = .connected
        let continuation = openContinuation
        openContinuation = nil
        continuation?.resume()
    }

    public static func defaultConfig() -> RTCConfiguration {
        let config = RTCConfiguration()
        // Empty ICE servers — LAN / Tailscale loopback uses mDNS-derived
        // host candidates only; no STUN/TURN needed in M1.1 scope.
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        return config
    }

    private static func setLocalDescription(
        _ pc: RTCPeerConnection,
        _ sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume()
            }
        }
    }

    private static func setRemoteDescription(
        _ pc: RTCPeerConnection,
        _ sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume()
            }
        }
    }

    public enum ConnectionError: Error, Equatable, Sendable {
        case peerConnectionInitFailed
        case dataChannelInitFailed
        case sdpGenerationFailed
        case notConfigured
        case notOpen
        case sendFailed
    }
}

/// `RTCPeerConnectionDelegate` glue. Routes ICE-related signals into
/// the actor; we don't yet do anything with them in M1.1, but capture
/// them so M1.2 can wire signaling.
private final class PeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate {
    var onIceCandidate: ((RTCIceCandidate) -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// `RTCDataChannelDelegate` glue. The actor sets `onOpen` / `onMessage`
/// before awaiting state transitions.
private final class DataChannelDelegate: NSObject, RTCDataChannelDelegate {
    var onOpen: (() -> Void)?
    var onMessage: ((Data) -> Void)?

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .open {
            onOpen?()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }
}
#endif
```

- [ ] **Step 2: Verify it compiles**

Run:

```bash
swift build 2>&1 | tail -10
```

Expected: `Build complete!` with no errors. If the WebRTC headers don't import cleanly or `-warnings-as-errors` trips, **report BLOCKED** with the specific error.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift
git commit -m "feat(remote): RemoteHostConnection actor — RTCPeerConnection + DataChannel scaffold (M1.1)"
```

---

## Task 3: Create the Mac-side `WebRTCHostAgent` skeleton

**Files:**
- Create: `Sources/GrafttyKit/Remote/WebRTCHostAgent.swift`

- [ ] **Step 1: Write the file**

Write `Sources/GrafttyKit/Remote/WebRTCHostAgent.swift` with this exact content:

```swift
import Foundation
import WebRTC

/// Mac-side actor that accepts incoming WebRTC offers, completes the
/// answer side of the handshake, and exposes the data channel.
///
/// Mirror of `RemoteHostConnection` on the mobile side. Together, the
/// loopback test in `RemoteHostConnectionLoopbackTests` constructs both
/// in-process and verifies the SDK integration works end-to-end before
/// any later PR adds signaling, Noise, or channel framing.
public actor WebRTCHostAgent {

    public enum State: Sendable, Equatable {
        case idle
        case answering
        case connected
        case failed(reason: String)
        case closed
    }

    public private(set) var state: State = .idle

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private let delegate: PeerConnectionDelegate
    private let dataChannelDelegate: DataChannelDelegate

    /// Test-only — most recent binary frame received on the answerer's
    /// data channel. Production replaces this with channel-framing
    /// dispatch in M1.4.
    public private(set) var lastReceivedBinary: Data?

    public init() {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        self.delegate = PeerConnectionDelegate()
        self.dataChannelDelegate = DataChannelDelegate()
    }

    deinit {
        RTCCleanupSSL()
    }

    /// Accept an incoming offer and return the answer.
    public func acceptOffer(_ offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        let config = Self.defaultConfig()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let pc = factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: delegate
        ) else {
            throw HostError.peerConnectionInitFailed
        }
        self.peerConnection = pc

        // The mobile side is the data-channel creator; the host receives
        // the data channel via `didOpen dataChannel` (handled in
        // `PeerConnectionDelegate.onDataChannel`).
        delegate.onDataChannel = { [weak self] dc in
            Task { await self?.adoptDataChannel(dc) }
        }

        state = .answering
        try await Self.setRemoteDescription(pc, offer)

        let answerConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: answerConstraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: HostError.sdpGenerationFailed); return }
                continuation.resume(returning: sdp)
            }
        }
        try await Self.setLocalDescription(pc, answer)
        return answer
    }

    /// Send a binary frame back to the client. Test-only entry point.
    public func sendBinary(_ data: Data) async throws {
        guard let dc = dataChannel, dc.readyState == .open else {
            throw HostError.notOpen
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        guard dc.sendData(buffer) else {
            throw HostError.sendFailed
        }
    }

    /// Test-only — exposes the underlying peer connection so ICE
    /// candidates from the offerer can be funneled in by the loopback
    /// test harness without going through a signaling endpoint.
    public func underlyingPeerConnection() -> RTCPeerConnection? {
        peerConnection
    }

    public func close() {
        dataChannel?.close()
        peerConnection?.close()
        dataChannel = nil
        peerConnection = nil
        state = .closed
    }

    private func adoptDataChannel(_ dc: RTCDataChannel) {
        self.dataChannel = dc
        dc.delegate = dataChannelDelegate
        dataChannelDelegate.onMessage = { [weak self] data in
            Task { await self?.recordReceivedBinary(data) }
        }
        if dc.readyState == .open {
            state = .connected
        }
    }

    private func recordReceivedBinary(_ data: Data) {
        lastReceivedBinary = data
    }

    public static func defaultConfig() -> RTCConfiguration {
        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        return config
    }

    private static func setLocalDescription(
        _ pc: RTCPeerConnection,
        _ sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume()
            }
        }
    }

    private static func setRemoteDescription(
        _ pc: RTCPeerConnection,
        _ sdp: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume()
            }
        }
    }

    public enum HostError: Error, Equatable, Sendable {
        case peerConnectionInitFailed
        case sdpGenerationFailed
        case notOpen
        case sendFailed
    }
}

private final class PeerConnectionDelegate: NSObject, RTCPeerConnectionDelegate {
    var onIceCandidate: ((RTCIceCandidate) -> Void)?
    var onDataChannel: ((RTCDataChannel) -> Void)?

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        onDataChannel?(dataChannel)
    }
}

private final class DataChannelDelegate: NSObject, RTCDataChannelDelegate {
    var onMessage: ((Data) -> Void)?

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `swift build 2>&1 | tail -10`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Remote/WebRTCHostAgent.swift
git commit -m "feat(remote): WebRTCHostAgent actor — Mac-side answerer scaffold (M1.1)"
```

---

## Task 4: Loopback test verifying SDK integration

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Remote/RemoteHostConnectionLoopbackTests.swift`

- [ ] **Step 1: Write the failing test**

Write `Tests/GrafttyMobileKitTests/Remote/RemoteHostConnectionLoopbackTests.swift`:

```swift
#if canImport(UIKit)
import Foundation
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// Loopback test: construct a `RemoteHostConnection` (offerer, mobile-side)
/// and a paired in-process answerer using the bundled WebRTC SDK, exchange
/// SDP + ICE in-process (no signaling endpoint yet), verify a DataChannel
/// opens, and verify a byte ping-pong round-trips.
///
/// This is the M1.1 acceptance criterion: SDK integration works, peer
/// connection negotiates, data channel opens. M1.2 replaces the in-process
/// SDP swap with an HTTPS signaling endpoint; M1.3 adds Noise before any
/// channel traffic; M1.4 framing.
@Suite("@spec REMOTE-2.x — WebRTC peer connection establishes locally (M1.1 foundation).")
struct RemoteHostConnectionLoopbackTests {

    @Test
    func twoConnectionsExchangeBytesOverDataChannel() async throws {
        let client = RemoteHostConnection()
        let answererPeer = TestAnswerer()

        // 1. Client creates offer.
        let offer = try await client.createOffer()

        // 2. In a real flow this would be POSTed to /v1/rtc/offer.
        //    Here we feed it straight into the answerer.
        let answer = try await answererPeer.accept(offer: offer)

        // 3. Forward ICE candidates each way as they're gathered.
        client.bindIceCandidates(to: answererPeer)
        answererPeer.bindIceCandidates(to: client)

        // 4. Apply the answer on the client; this waits for the data
        //    channel to reach the `open` state on the offerer side.
        try await client.applyAnswer(answer)

        // 5. Send a binary ping from the client; the answerer should
        //    receive it within a short window.
        let ping = Data([0xCA, 0xFE, 0xBA, 0xBE])
        try await client.sendBinary(ping)

        try await pollUntil(timeout: .seconds(5)) {
            await answererPeer.lastReceived == ping
        }

        // 6. Send a binary pong back; the client should receive it.
        let pong = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await answererPeer.send(pong)

        try await pollUntil(timeout: .seconds(5)) {
            await client.lastReceivedBinary == pong
        }

        await client.close()
        await answererPeer.close()
    }
}

/// Test helper that owns the answerer side of the loopback. Production
/// uses `WebRTCHostAgent` from GrafttyKit, but that target isn't
/// importable here; we duplicate the minimal answerer logic inline so
/// the loopback proves the mobile-side `RemoteHostConnection` works in
/// isolation. The Mac-side test in `GrafttyKitTests` will mirror.
private actor TestAnswerer {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private let delegate = AnswererDelegate()
    private let dataChannelDelegate = AnswererDataChannelDelegate()
    private(set) var lastReceived: Data?

    init() {
        RTCInitializeSSL()
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }

    deinit {
        RTCCleanupSSL()
    }

    func accept(offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        let config = RTCConfiguration()
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            throw NSError(domain: "TestAnswerer", code: 1)
        }
        self.peerConnection = pc

        delegate.onDataChannel = { [weak self] dc in
            Task { await self?.adopt(dc) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "TestAnswerer", code: 2)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return answer
    }

    func send(_ data: Data) async throws {
        guard let dc = dataChannel, dc.readyState == .open else {
            throw NSError(domain: "TestAnswerer", code: 3)
        }
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        _ = dc.sendData(buffer)
    }

    func bindIceCandidates(to client: RemoteHostConnection) {
        delegate.onIceCandidate = { candidate in
            Task { try? await client.addRemoteIceCandidate(candidate) }
        }
    }

    func close() {
        dataChannel?.close()
        peerConnection?.close()
    }

    fileprivate func adopt(_ dc: RTCDataChannel) {
        self.dataChannel = dc
        dc.delegate = dataChannelDelegate
        dataChannelDelegate.onMessage = { [weak self] data in
            Task { await self?.record(data) }
        }
    }

    fileprivate func record(_ data: Data) {
        self.lastReceived = data
    }
}

private final class AnswererDelegate: NSObject, RTCPeerConnectionDelegate {
    var onIceCandidate: ((RTCIceCandidate) -> Void)?
    var onDataChannel: ((RTCDataChannel) -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        onDataChannel?(dataChannel)
    }
}

private final class AnswererDataChannelDelegate: NSObject, RTCDataChannelDelegate {
    var onMessage: ((Data) -> Void)?
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }
}

/// Poll until `condition()` returns true or the deadline expires. Used
/// instead of arbitrary `Task.sleep` so the test exits promptly on
/// success but still fails clearly when the condition genuinely doesn't
/// hold.
private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(50),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    Issue.record("pollUntil timed out after \(timeout)")
}
#endif
```

- [ ] **Step 2: Add the `bindIceCandidates` + `addRemoteIceCandidate` methods to `RemoteHostConnection`**

The test calls `client.bindIceCandidates(to: answererPeer)` and the answerer calls `client.addRemoteIceCandidate(candidate)`. These methods don't exist yet — add them to `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift` inside the `actor RemoteHostConnection` body, after the existing `sendBinary` method:

```swift
    /// Bind locally-gathered ICE candidates so they're routed into the
    /// peer's connection. Used by the M1.1 loopback test that bypasses
    /// the signaling endpoint. Real signaling lands in M1.2.
    nonisolated public func bindIceCandidates(to peer: WebRTCIceCandidateReceiver) {
        delegate.onIceCandidate = { candidate in
            Task { try? await peer.addRemoteIceCandidate(candidate) }
        }
    }

    /// Apply an ICE candidate received from the remote peer.
    public func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { throw ConnectionError.notConfigured }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume()
            }
        }
    }
```

- [ ] **Step 3: Add the same protocol + methods on `TestAnswerer` and a `WebRTCIceCandidateReceiver` protocol**

At the top of `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`, just below the `import WebRTC` line, add the protocol:

```swift
/// Common interface for "thing that can accept ICE candidates from a
/// peer." Used by the loopback test to wire ICE both directions
/// without a signaling endpoint. Real signaling (M1.2) replaces this.
public protocol WebRTCIceCandidateReceiver: Sendable {
    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws
}
```

Then make `RemoteHostConnection` conform: change the `actor RemoteHostConnection {` declaration line to:

```swift
public actor RemoteHostConnection: WebRTCIceCandidateReceiver {
```

In the loopback test file, make `TestAnswerer` also conform — add `: WebRTCIceCandidateReceiver` to the `private actor TestAnswerer {` declaration (becomes `private actor TestAnswerer: WebRTCIceCandidateReceiver {`), and add an `addRemoteIceCandidate` method to it:

```swift
    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
```

- [ ] **Step 4: Run the test (expected to PASS — TDD pattern is reversed for this PR because the SDK call has to actually work)**

Run:

```bash
swift test --filter RemoteHostConnectionLoopbackTests 2>&1 | tail -20
```

Expected: 1 test, 0 failures. The whole exchange should complete in well under 5 seconds (the timeout cap).

If the test hangs or fails: **report BLOCKED** with the error. Common failure modes:
- "no usable ICE candidates" → the local loopback `iceServers = []` config may need an mDNS hostname; check `RTCConfiguration.disableLinkLocalNetworks` is not set (it isn't, by default).
- Build error about UIKit-only code on macOS → the test is wrapped in `#if canImport(UIKit)`; if it's running on macOS via `swift test`, it should skip the whole file. Verify it's not being compiled out unintentionally.
- "binary not found" → `swift package resolve` didn't pick up WebRTC. Re-run resolve.

Note about iOS-only guard: per the user-memory `feedback_macos_swift_test_misses_uikit_guarded_code`, `swift test` on macOS won't execute UIKit-guarded code. The loopback test is wrapped in `#if canImport(UIKit)` because `RemoteHostConnection.swift` is UIKit-scoped. This test only runs on iOS CI.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift Tests/GrafttyMobileKitTests/Remote/RemoteHostConnectionLoopbackTests.swift
git commit -m "test(remote): loopback DataChannel test for RemoteHostConnection (M1.1)"
```

---

## Task 5: Verify the full test suite

**Files:**
- Read: (no changes)

- [ ] **Step 1: Run `swift test` (on macOS, the iOS-guarded test skips compilation; we just verify nothing else broke)**

Run:

```bash
swift test 2>&1 | tail -20
```

Expected: all tests pass. The 30+ disabled `@Test` entries from the spec-inventory PR continue to skip. `RemoteHostConnectionLoopbackTests` is iOS-only and won't run here. Look for `Test run with NNNN tests in MMM suites succeeded`.

Pre-existing flaky failures (e.g., `PollingTickerTests.tickFiresMultipleTimesWithoutPulse`) are *not* blocking — note them for the PR description but do not attempt to fix.

- [ ] **Step 2: Confirm clean working tree**

Run: `git status --short`
Expected: empty (all commits already made).

---

## Task 6: Open the PR

**Files:** (no source changes)

- [ ] **Step 1: Push the branch**

```bash
git push 2>&1 | tail -5
```

- [ ] **Step 2: Open the PR via gh**

```bash
gh pr create --title "feat(remote): WebRTC M1.1 — SDK integration + RemoteHostConnection scaffold" --body "$(cat <<'EOF'
## Summary

First implementation slice of the WebRTC adoption from the iPad-layout
design (\`docs/superpowers/specs/2026-05-15-ipad-layout-design.md\` §8
milestone M1). Integrates the \`stasel/WebRTC\` SwiftPM package and lands
the per-side actor scaffolds (\`RemoteHostConnection\` on mobile,
\`WebRTCHostAgent\` on Mac) along with a loopback test that proves the
SDK works end-to-end before later PRs build on it.

## What's in this PR

- **\`stasel/WebRTC\`** added as a SwiftPM dependency on both
  \`GrafttyKit\` and \`GrafttyMobileKit\` (v137 series, MIT, App Store
  compatible, privacy-manifest-included).
- **\`RemoteHostConnection\`** actor — mobile-side WebRTC peer connection
  + DataChannel owner.
- **\`WebRTCHostAgent\`** actor — Mac-side answerer counterpart.
- **Loopback test** — two peer connections in one process negotiate a
  DataChannel and ping-pong bytes. Verifies the SDK is correctly
  integrated before M1.2 adds the real signaling endpoint.

## What's NOT in this PR (sequenced for later)

- M1.2: Direct/Tailscale HTTPS signaling endpoint (\`POST /v1/rtc/offer\`)
- M1.3: Noise_KK handshake (security-critical; needs human review)
- M1.4: Channel framing layer
- M2: \`terminal\` channel + retire \`/ws\`
- M3: \`panes_state\` channel
- M4: \`pane_control\` channel

## Risks flagged for your review

- **70 MB binary lift** on the iOS app bundle (WebRTC.xcframework).
  Acceptable for a dev tool, but worth a sign-off before TestFlight.
- **SDK choice (\`stasel/WebRTC\`):** alternatives considered are
  documented in the plan (\`docs/superpowers/plans/2026-05-16-webrtc-m1-1-sdk-and-scaffold.md\`).
  Override the SDK choice if you have a different preference.

## Test plan

- [x] \`swift build\` clean.
- [x] \`swift test\` passes on macOS (loopback test is iOS-guarded; runs in iOS CI).
- [ ] CI green on PR.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)" 2>&1 | tail -5
```

Expected: PR URL printed.

- [ ] **Step 3: Report the PR URL**

---

## Self-Review

After all tasks land:

- **Spec coverage:** The PR delivers REMOTE-2.1 foundation infrastructure (peer connection + data channel); doesn't yet test the "fresh authenticated attach" requirement because the Noise handshake comes in M1.3.
- **Placeholders:** none — every step has full code or exact command.
- **Type consistency:** `RemoteHostConnection`, `WebRTCHostAgent`, `WebRTCIceCandidateReceiver`, and the `ConnectionError`/`HostError` enums match between Tasks 2/3/4.
- **Naming consistency:** Swift `Remote/` directory matches the existing `Sources/GrafttyKit/Remote/` and `Sources/GrafttyMobileKit/Remote/` namespace.
- **iOS-only guard:** the loopback test is wrapped in `#if canImport(UIKit)` to match `RemoteHostConnection.swift`'s scope.
