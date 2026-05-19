# WebRTC M1.2 — Direct/Tailscale HTTPS Signaling Endpoint

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the M1.1 in-process loopback SDP exchange with a real HTTPS signaling endpoint so the iPad client can establish a WebRTC peer connection to the Mac over LAN or Tailscale.

**Architecture:** The Mac's existing NIO web server (`Sources/GrafttyKit/Web/WebServer.swift`) gains a `POST /v1/rtc/offer` route. The client posts a JSON envelope carrying its SDP offer; the server invokes a `signalingHandler` closure (wired to a `WebRTCHostAgent` from `GrafttyApp` startup, same shape as the existing `worktreeCreator` plumbing) that drives `acceptOffer` and returns the SDP answer. ICE is **non-trickle** for v1: each side waits for `iceGatheringState == .complete` before responding, so all candidates land bundled in the SDP as `a=candidate:` lines. No new endpoint for ICE candidate exchange in this PR.

**Tech Stack:** Same as M1.1 — Swift Testing, SwiftPM `stasel/WebRTC`, swift-nio for the server. Adds JSON wire types in `GrafttyProtocol`.

**Scope this PR explicitly does NOT include:**
- Trickle ICE (deferred; non-trickle works for LAN/Tailscale where gathering completes in ~10-50ms).
- Noise_KK handshake (M1.3 — separate PR with crypto review). The signaling endpoint is **unauthenticated** in this PR; gating remains the existing Tailscale-whois policy on the web server. Real attach auth lands in M1.3 layered on top.
- Channel framing (M1.4).
- Wiring `WebRTCHostAgent` into `GrafttyApp.startup()` for production — the route exists, the config slot exists, but the production injection is left to the M2 PR where it's actually needed. Tests inject a fake `signalingHandler`.

---

## File Structure

**Files to create:**
- `Sources/GrafttyProtocol/SignalingEnvelope.swift` — `SignalingOffer` / `SignalingAnswer` / `SignalingError` wire types.
- `Sources/GrafttyMobileKit/Remote/SignalingClient.swift` — HTTP client that POSTs the offer JSON and decodes the answer.
- `Tests/GrafttyKitTests/Remote/SignalingRouteTests.swift` — exercises the route end-to-end against a real NIO server with a fake handler.
- `Tests/GrafttyMobileKitTests/Remote/SignalingClientTests.swift` — unit test for the HTTP client against a fake URL.

**Files to modify:**
- `Sources/GrafttyKit/Web/WebServer.swift` — add a `signalingHandler` slot on `Config`, add `POST /v1/rtc/offer` route dispatch.
- `Sources/GrafttyKit/Remote/WebRTCHostAgent.swift` — add `waitForIceGatheringComplete()` helper + adopt it in `acceptOffer`.
- `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift` — add `waitForIceGatheringComplete()` + `connect(baseURL:)` high-level method.

---

## Task 1: Signaling wire types in `GrafttyProtocol`

**Files:**
- Create: `Sources/GrafttyProtocol/SignalingEnvelope.swift`

- [ ] **Step 1: Create the file**

Write `Sources/GrafttyProtocol/SignalingEnvelope.swift`:

```swift
import Foundation

/// JSON body accepted by `POST /v1/rtc/offer`. Carries the client's SDP
/// offer plus identification fields the M1.3 attach handshake will
/// authenticate. In M1.2 the auth fields are forwarded to the handler
/// but not yet verified.
public struct SignalingOffer: Codable, Sendable, Equatable {
    public let clientDeviceID: String
    public let sdp: String
    public init(clientDeviceID: String, sdp: String) {
        self.clientDeviceID = clientDeviceID
        self.sdp = sdp
    }
}

/// JSON body returned by `POST /v1/rtc/offer` on success.
public struct SignalingAnswer: Codable, Sendable, Equatable {
    public let sdp: String
    public init(sdp: String) {
        self.sdp = sdp
    }
}

/// JSON body returned on signaling failure. Mirrors the existing
/// `{ "error": "<message>" }` shape used by other endpoints like
/// `POST /worktrees`.
public struct SignalingError: Codable, Sendable, Equatable {
    public let error: String
    public init(error: String) {
        self.error = error
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyProtocol/SignalingEnvelope.swift
git commit -m "feat(protocol): SignalingOffer/Answer/Error wire types for POST /v1/rtc/offer"
```

---

## Task 2: Add `waitForIceGatheringComplete` to `WebRTCHostAgent`

**Files:**
- Modify: `Sources/GrafttyKit/Remote/WebRTCHostAgent.swift`

- [ ] **Step 1: Capture the ICE gathering state transition on the delegate**

Find the `private final class PeerConnectionDelegate` block. The existing line for ICE gathering state is empty:

```swift
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
```

Replace with:

```swift
    nonisolated(unsafe) var onIceGatheringComplete: (@Sendable () -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            onIceGatheringComplete?()
        }
    }
```

- [ ] **Step 2: Add the wait helper on the actor**

In `WebRTCHostAgent`, after the existing `acceptOffer` method, insert this private helper:

```swift
    /// Block until the peer connection's ICE gathering reaches `.complete`.
    /// Required for non-trickle ICE: only after gathering completes does the
    /// local SDP include every `a=candidate:` line the remote peer needs.
    /// Returns immediately if gathering is already complete.
    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onIceGatheringComplete = {
                continuation.resume()
            }
            if pc.iceGatheringState == .complete {
                delegate.onIceGatheringComplete = nil
                continuation.resume()
            }
        }
        delegate.onIceGatheringComplete = nil
    }
```

- [ ] **Step 3: Adopt it inside `acceptOffer` before returning the answer**

In `WebRTCHostAgent.acceptOffer`, the current tail of the method reads:

```swift
        try await Self.setLocalDescription(pc, answer)
        return answer
    }
```

Replace with:

```swift
        try await Self.setLocalDescription(pc, answer)
        await waitForIceGatheringComplete(pc)
        // After gathering completes, `pc.localDescription` has the full
        // SDP with `a=candidate:` lines included.
        return pc.localDescription ?? answer
    }
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Remote/WebRTCHostAgent.swift
git commit -m "feat(remote): WebRTCHostAgent waits for ICE gathering before returning answer (non-trickle)"
```

---

## Task 3: Add `waitForIceGatheringComplete` + `connect(baseURL:)` to `RemoteHostConnection`

**Files:**
- Modify: `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift`

- [ ] **Step 1: Capture ICE gathering state on the mobile delegate**

Find `private final class PeerConnectionDelegate` in this file. The empty line:

```swift
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
```

Replace with:

```swift
    nonisolated(unsafe) var onIceGatheringComplete: (@Sendable () -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            onIceGatheringComplete?()
        }
    }
```

- [ ] **Step 2: Add the wait helper + apply it inside `createOffer`**

Find the current `createOffer` method. Its tail reads:

```swift
        try await Self.setLocalDescription(pc, offer)
        return offer
    }
```

Replace with:

```swift
        try await Self.setLocalDescription(pc, offer)
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? offer
    }

    /// See `WebRTCHostAgent.waitForIceGatheringComplete` for the rationale.
    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            delegate.onIceGatheringComplete = {
                continuation.resume()
            }
            if pc.iceGatheringState == .complete {
                delegate.onIceGatheringComplete = nil
                continuation.resume()
            }
        }
        delegate.onIceGatheringComplete = nil
    }
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift
git commit -m "feat(remote): RemoteHostConnection waits for ICE gathering before returning offer (non-trickle)"
```

---

## Task 4: Add `SignalingClient` on the mobile side

**Files:**
- Create: `Sources/GrafttyMobileKit/Remote/SignalingClient.swift`

- [ ] **Step 1: Write the file**

Write `Sources/GrafttyMobileKit/Remote/SignalingClient.swift`:

```swift
#if canImport(UIKit)
import Foundation
import GrafttyProtocol

/// Posts a `SignalingOffer` JSON to the host's `/v1/rtc/offer` endpoint
/// and decodes the `SignalingAnswer` reply. Pure HTTP transport — no
/// WebRTC types — so the type can be unit-tested by injecting a fake
/// `URLSession`-like callable.
public struct SignalingClient: Sendable {

    public typealias Transport = @Sendable (URLRequest, Data) async throws -> (Data, HTTPURLResponse)

    private let transport: Transport

    public init(transport: @escaping Transport = SignalingClient.defaultTransport) {
        self.transport = transport
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case http(status: Int, body: String)
        case decode(String)
        case transport(String)
    }

    public func exchange(baseURL: URL, offer: SignalingOffer) async throws -> SignalingAnswer {
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("rtc").appendingPathComponent("offer")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        let body: Data
        do {
            body = try JSONEncoder().encode(offer)
        } catch {
            throw Error.transport("encode offer: \(error)")
        }
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport(request, body)
        } catch {
            throw Error.transport(String(describing: error))
        }
        guard (200..<300).contains(response.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw Error.http(status: response.statusCode, body: bodyString)
        }
        do {
            return try JSONDecoder().decode(SignalingAnswer.self, from: data)
        } catch {
            throw Error.decode(String(describing: error))
        }
    }

    public static let defaultTransport: Transport = { request, body in
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
#endif
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyMobileKit/Remote/SignalingClient.swift
git commit -m "feat(remote): SignalingClient — POSTs SignalingOffer to /v1/rtc/offer"
```

---

## Task 5: Unit test for `SignalingClient`

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Remote/SignalingClientTests.swift`

- [ ] **Step 1: Write the failing tests**

Write `Tests/GrafttyMobileKitTests/Remote/SignalingClientTests.swift`:

```swift
#if canImport(UIKit)
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("SignalingClient — POSTs SignalingOffer to /v1/rtc/offer and decodes SignalingAnswer.")
struct SignalingClientTests {

    @Test
    func postsOfferAsJsonAndDecodesAnswer() async throws {
        var capturedURL: URL?
        var capturedBody: Data?
        var capturedMethod: String?
        let fake: SignalingClient.Transport = { request, body in
            capturedURL = request.url
            capturedBody = body
            capturedMethod = request.httpMethod
            let answer = SignalingAnswer(sdp: "v=0\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\n")
            let data = try JSONEncoder().encode(answer)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (data, response)
        }
        let client = SignalingClient(transport: fake)
        let baseURL = URL(string: "https://mac.example.local:54321")!
        let offer = SignalingOffer(clientDeviceID: "ios-device-123", sdp: "v=0\n")

        let answer = try await client.exchange(baseURL: baseURL, offer: offer)

        #expect(answer.sdp.hasPrefix("v=0"))
        #expect(capturedMethod == "POST")
        #expect(capturedURL == URL(string: "https://mac.example.local:54321/v1/rtc/offer"))
        let decoded = try JSONDecoder().decode(SignalingOffer.self, from: capturedBody!)
        #expect(decoded.clientDeviceID == "ios-device-123")
        #expect(decoded.sdp == "v=0\n")
    }

    @Test
    func reportsHttpErrorWithStatusAndBody() async throws {
        let fake: SignalingClient.Transport = { request, _ in
            let body = Data("{\"error\":\"not paired\"}".utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        }
        let client = SignalingClient(transport: fake)
        await #expect(throws: SignalingClient.Error.self) {
            _ = try await client.exchange(
                baseURL: URL(string: "https://example.local")!,
                offer: SignalingOffer(clientDeviceID: "x", sdp: "")
            )
        }
    }

    @Test
    func reportsDecodeFailureWhenAnswerIsMalformed() async throws {
        let fake: SignalingClient.Transport = { request, _ in
            let body = Data("not json".utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        }
        let client = SignalingClient(transport: fake)
        await #expect(throws: SignalingClient.Error.self) {
            _ = try await client.exchange(
                baseURL: URL(string: "https://example.local")!,
                offer: SignalingOffer(clientDeviceID: "x", sdp: "")
            )
        }
    }
}
#endif
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter SignalingClientTests 2>&1 | tail -10`
Expected: skipped on macOS (UIKit-guarded). On iOS CI: 3 tests pass.

Verify locally that they at least compile cleanly by running `swift build --build-tests 2>&1 | tail -10`.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyMobileKitTests/Remote/SignalingClientTests.swift
git commit -m "test(remote): SignalingClient unit tests — POST body, HTTP error, decode error"
```

---

## Task 6: Add a `signalingHandler` slot to `WebServer.Config`

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebServer.swift`

- [ ] **Step 1: Add the field to `Config`**

In `Sources/GrafttyKit/Web/WebServer.swift`, find the `Config` struct (around line 146). After the existing `worktreePanesProvider` line (around 182), and before the closing brace of the `let` declarations, append a new field:

```swift
        /// Drives `POST /v1/rtc/offer`. Receives the client's
        /// `SignalingOffer` and returns either a `SignalingAnswer` (success)
        /// or a `SignalingError` (failure). Nil disables the endpoint with
        /// a 503 response — matching the existing `worktreeCreator` shape
        /// so a client can distinguish "not supported yet" from "wrong URL".
        public let signalingHandler: (@Sendable (SignalingOffer) async -> SignalingHandlerOutcome)?
```

The `Config` field is declared mid-struct; placement is between `worktreePanesProvider` (line ~182) and the `init` declaration (line ~184). Make sure the placement is *inside* the `public struct Config { ... }` body, *before* `public init(...)`.

- [ ] **Step 2: Declare `SignalingHandlerOutcome`**

Just above the `public struct Config` declaration (so it's accessible inside `Config` and to callers), insert a sibling outcome enum. Locate the existing `public struct DeleteWorktreeResponse` definitions (around line 122–143), and insert after their associated `public enum DeleteWorktreeOutcome` block (around line 138–143):

```swift
    public enum SignalingHandlerOutcome: Sendable {
        case success(SignalingAnswer)
        case invalid(String)        // 400 — malformed offer
        case unavailable(String)    // 503 — handler not wired
        case internalFailure(String) // 500
    }
```

(If your local file's enum positions differ slightly, the rule is: place it inside `WebServer` but at the same nesting level as `DeleteWorktreeOutcome` — they're peer outcome types.)

- [ ] **Step 3: Extend `init` to accept the new field**

Find the `Config.init` signature (line ~184) and its parameter list. Add a default-nil parameter after `worktreePanesProvider`:

```swift
            worktreePanesProvider: @escaping @Sendable () async -> [WorktreePanes] = { [] },
            signalingHandler: (@Sendable (SignalingOffer) async -> SignalingHandlerOutcome)? = nil
```

And inside the init body (right after `self.worktreePanesProvider = worktreePanesProvider`), assign:

```swift
            self.signalingHandler = signalingHandler
```

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Web/WebServer.swift
git commit -m "feat(web): Config slot for signalingHandler driving POST /v1/rtc/offer"
```

---

## Task 7: Dispatch `POST /v1/rtc/offer` in `serveStatic`

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebServer.swift`

- [ ] **Step 1: Add the route block**

In `Sources/GrafttyKit/Web/WebServer.swift`, find the existing `/worktrees/delete` block (around line 586). Insert a new block immediately after it (before the `do { let asset = try ...` fallback):

```swift
            // POST /v1/rtc/offer — WebRTC signaling exchange (M1.2).
            // The handler runs the SDP offer through `WebRTCHostAgent`
            // (or any test fake) and returns either a SignalingAnswer or
            // a SignalingError. POST-only; other verbs get 405 so
            // caching proxies and curl probes don't surprise the client.
            if path == "/v1/rtc/offer" {
                guard head.method == .POST else {
                    Self.respondJSON(
                        context: context,
                        status: .methodNotAllowed,
                        error: "only POST is supported"
                    )
                    return
                }
                handleSignalingOffer(context: context, body: body)
                return
            }
```

- [ ] **Step 2: Implement `handleSignalingOffer`**

Find the existing `handleCreateWorktree(context:body:)` method (search for "func handleCreateWorktree"). Locate its closing brace and insert a sibling method right after it:

```swift
        /// Decode the JSON body as a `SignalingOffer`, invoke the
        /// injected `signalingHandler`, and map the outcome to an HTTP
        /// status + JSON envelope. Mirrors `handleCreateWorktree`.
        func handleSignalingOffer(context: ChannelHandlerContext, body: Data) {
            guard let handler = config.signalingHandler else {
                Self.respondJSON(
                    context: context,
                    status: .serviceUnavailable,
                    error: "signaling endpoint not available"
                )
                return
            }
            let offer: SignalingOffer
            do {
                offer = try JSONDecoder().decode(SignalingOffer.self, from: body)
            } catch {
                Self.respondJSON(
                    context: context,
                    status: .badRequest,
                    error: "malformed signaling offer: \(error.localizedDescription)"
                )
                return
            }
            Task {
                let outcome = await handler(offer)
                await MainActor.run {
                    switch outcome {
                    case .success(let answer):
                        Self.respondEncodable(context: context, items: answer)
                    case .invalid(let msg):
                        Self.respondJSON(context: context, status: .badRequest, error: msg)
                    case .unavailable(let msg):
                        Self.respondJSON(context: context, status: .serviceUnavailable, error: msg)
                    case .internalFailure(let msg):
                        Self.respondJSON(context: context, status: .internalServerError, error: msg)
                    }
                }
            }
        }
```

Note: this method's `await MainActor.run` is required because the NIO `ChannelHandlerContext` is not `Sendable` and can't be passed into the detached `Task` directly. If your existing `handleCreateWorktree` uses a different pattern (e.g., capturing a promise on the event loop), mirror that pattern instead — read its implementation to confirm.

If the `MainActor.run` pattern produces a Sendable-related compile error, fall back to: instead of a `Task`, use the `context.eventLoop.makePromise(of: SignalingHandlerOutcome.self)` pattern with `promise.futureResult.whenComplete { ... Self.respondEncodable(...) }`, matching how `handleSessions` / `handleRepos` already work. The signaling path is asynchronous but the response dispatch must remain on the event loop's thread.

If you get stuck here, **stop and report BLOCKED** — the response dispatch pattern is the trickiest part of touching this NIO server.

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | tail -10`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyKit/Web/WebServer.swift
git commit -m "feat(web): POST /v1/rtc/offer route — invokes signalingHandler, maps outcome to HTTP"
```

---

## Task 8: End-to-end test for the signaling route

**Files:**
- Create: `Tests/GrafttyKitTests/Remote/SignalingRouteTests.swift`

- [ ] **Step 1: Look at the existing WebServer integration test pattern**

Read `Tests/GrafttyKitTests/Web/WebServerTests.swift` (or whatever the existing NIO-based test file in `Tests/GrafttyKitTests/Web/` is — find it with `ls Tests/GrafttyKitTests/Web/`). Notice how it:

- Starts a `WebServer` on port 0 (kernel-assigned).
- Issues `URLSession` requests against `http://127.0.0.1:<actualPort>`.
- Injects fake providers via `Config`.

Mirror that pattern.

If no comparable test exists, **stop and report BLOCKED** — handcrafting a NIO server bootstrap from scratch is out of scope for this PR.

- [ ] **Step 2: Write the test**

Write `Tests/GrafttyKitTests/Remote/SignalingRouteTests.swift`:

```swift
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("POST /v1/rtc/offer — signaling route returns SignalingAnswer from injected handler.")
struct SignalingRouteTests {

    @Test
    func postOfferReturnsAnswerFromHandler() async throws {
        let server = try await TestWebServer.start { offer in
            #expect(offer.clientDeviceID == "ios-device-abc")
            return .success(SignalingAnswer(sdp: "v=0\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\n"))
        }
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/v1/rtc/offer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let offer = SignalingOffer(clientDeviceID: "ios-device-abc", sdp: "v=0\n")
        let body = try JSONEncoder().encode(offer)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        let answer = try JSONDecoder().decode(SignalingAnswer.self, from: data)
        #expect(answer.sdp.contains("webrtc-datachannel"))
    }

    @Test
    func malformedOfferReturns400() async throws {
        let server = try await TestWebServer.start { _ in
            .success(SignalingAnswer(sdp: ""))
        }
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/v1/rtc/offer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Data("not-json".utf8)

        let (_, response) = try await URLSession.shared.upload(for: request, from: body)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 400)
    }

    @Test
    func missingHandlerReturns503() async throws {
        let server = try await TestWebServer.start(signalingHandler: nil)
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/v1/rtc/offer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(SignalingOffer(clientDeviceID: "x", sdp: ""))

        let (_, response) = try await URLSession.shared.upload(for: request, from: body)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 503)
    }

    @Test
    func handlerReturningInvalidYields400() async throws {
        let server = try await TestWebServer.start { _ in
            .invalid("offer references unknown device")
        }
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/v1/rtc/offer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(SignalingOffer(clientDeviceID: "x", sdp: ""))

        let (_, response) = try await URLSession.shared.upload(for: request, from: body)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 400)
    }
}
```

- [ ] **Step 3: Decide on the `TestWebServer` helper**

If `Tests/GrafttyKitTests/Web/` already has a helper that boots a real `WebServer` on a kernel-assigned port with injectable config, reuse it — make `SignalingRouteTests` import it via `@testable import GrafttyKitTests` if it's marked `internal`, or copy the boot logic into the same test file as a private helper.

If no helper exists, **stop and report NEEDS_CONTEXT** — write the question "what's the established test pattern for booting `WebServer` in tests, and what's its accessor type?" The controller can answer or expand the plan.

If you can identify the pattern, write a thin `TestWebServer` helper at the top of `SignalingRouteTests.swift`:

```swift
private struct TestWebServer {
    let port: Int
    let stop: () -> Void

    static func start(
        signalingHandler: (@Sendable (SignalingOffer) async -> WebServer.SignalingHandlerOutcome)? = nil
    ) async throws -> TestWebServer {
        // ... copy the boot-on-port-0 pattern from the existing WebServerTests helper ...
    }
}
```

The placeholder above is **not** a license to leave it as TBD — fill it in from the existing helper or escalate.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter SignalingRouteTests 2>&1 | tail -15`
Expected: 4 tests pass.

If any timing-flake-prone behavior surfaces (port collision, slow boot, etc.), follow the existing `WebServerTests`' debounce / wait pattern.

- [ ] **Step 5: Commit**

```bash
git add Tests/GrafttyKitTests/Remote/SignalingRouteTests.swift
git commit -m "test(web): SignalingRouteTests — POST /v1/rtc/offer end-to-end via real NIO server"
```

---

## Task 9: Full test-suite verification

**Files:**
- Read: (no changes)

- [ ] **Step 1: Run `swift test` and confirm no regressions**

Run: `swift test 2>&1 | tail -10`
Expected: pass. Look for `Test run with NNNN tests in MMM suites passed`.

If a pre-existing flaky test (e.g., `PollingTickerTests`, `WebSessionTests` WEB-4.5) fails, note it for the PR description and do not attempt to fix.

- [ ] **Step 2: Clean working tree**

Run: `git status --short`
Expected: empty.

---

## Self-Review

After all tasks:

- **Spec coverage:** The PR delivers the M1.2 milestone foundation — HTTPS signaling endpoint on the Mac, mobile-side signaling client, end-to-end test. M1.3 (Noise) layers on top; M1.4 (channel framing) sits inside the established DataChannel.
- **Placeholders:** none — every step has full code or exact escalation criteria. Task 7's "fall back to event-loop promise pattern" and Task 8's "if no helper exists, BLOCKED" are concrete escalation paths, not placeholders.
- **Type consistency:** `SignalingOffer` / `SignalingAnswer` / `SignalingError` / `SignalingHandlerOutcome` names appear in Tasks 1, 4, 5, 6, 7, 8.
- **iOS-only guard:** `SignalingClient` is `#if canImport(UIKit)` because `URLSession.upload(for:from:)` is iOS 15+/macOS 12+; the GrafttyMobileKit module is UIKit-scoped anyway. `SignalingRouteTests` is in `GrafttyKitTests` (Mac-side) and doesn't need the guard.
