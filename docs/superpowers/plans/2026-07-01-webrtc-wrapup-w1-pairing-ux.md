# W1 — Pairing UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user can pair an iPhone/iPad with the Mac directly over the local network: Mac shows a QR + verification code, phone scans and confirms, the Mac persists a `TrustedPeer` and the phone pins the host identity.

**Architecture:** The already-landed pairing protocol (`HostPairingSession`/`HostPairingServer` on Mac, `ClientPairingSession`/`LocalPairingClient` on mobile, wire types in `GrafttyProtocol`) gets its missing transport + UI: an **ephemeral plaintext-HTTP pairing listener** on the Mac that exists only while a pairing session is active (the existing web server binds Tailscale IPs only, so it cannot serve plain-LAN pairing), a pairing section in the Mac's settings pane, and a scan-to-pair flow in the mobile `AddHostView`. Plaintext HTTP is cryptographically sound here: the exchange carries only public keys; the QR pins the host-key fingerprint, the nonce is single-use, and the REMOTE-1.2 verification code confirms both sides — TLS would add nothing (the client couldn't verify the cert anyway).

**Tech Stack:** SwiftNIO (NIOHTTP1) for the listener, SwiftUI on both sides, Swift Testing with `@spec` EARS titles.

## Global Constraints

- iOS CI green required before merge (Task 4 touches `GrafttyMobileKit`); macOS `swift test` alone is insufficient.
- Run `scripts/generate-specs.py` and commit `SPECS.md` with the spec changes; never edit `SPECS.md` manually.
- No literal escaped quotes (`\"`) inside `@spec` test titles.
- New spec IDs used in this plan: `REMOTE-1.3`, `REMOTE-1.4`, `REMOTE-1.5` (REMOTE-1.1/1.2 already active; do not renumber them).
- Follow RED/GREEN TDD: write the failing test first, run it, implement, re-run.
- JSON coding for pairing wire types must use the same coders `LocalPairingClient` uses: `JSONEncoder.iso8601()` / `JSONDecoder.iso8601()` (extensions already exist — grep for them).
- `GrafttyMobileKit` must not import `GrafttyKit` (mac-side module) and vice versa; shared types live in `GrafttyProtocol`.
- Commit after every green task; end commit messages with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: PairingHTTPServer — ephemeral pairing listener

**Files:**
- Create: `Sources/GrafttyKit/Remote/Pairing/PairingHTTPServer.swift`
- Test: `Tests/GrafttyTests/Remote/Pairing/PairingHTTPServerTests.swift`

**Interfaces:**
- Consumes: `HostPairingServer` (existing actor, `Sources/GrafttyKit/Remote/Pairing/HostPairingServer.swift`): `handleIntroduce(_:) -> Result<PairingIntroduceResponse, PairingErrorResponse>`, `handleAwaitOutcome(_:)` (async long-poll — read its exact signature in the file), plus UI-facing `start/confirm/deny/cancel/tick/currentState`.
- Consumes: wire types `PairingIntroduceRequest/Response`, `PairingAwaitOutcomeRequest`, `PairingOutcomeResponse`, `PairingErrorResponse` from `Sources/GrafttyProtocol/PairingExchange.swift`.
- Produces (later tasks depend on these exact signatures):

```swift
public actor PairingHTTPServer {
    public init(pairingServer: HostPairingServer)
    /// Binds a plaintext HTTP/1.1 listener. Returns the bound port
    /// (pass port 0 for ephemeral). Serves ONLY the two pairing routes.
    @discardableResult
    public func start(host: String = "0.0.0.0", port: Int = 0) async throws -> Int
    public func stop() async
}
```

**Routes:**
- `POST /v1/pairing/introduce` — decode `PairingIntroduceRequest`, call `handleIntroduce`, respond 200 + `PairingIntroduceResponse` JSON on success, 400 + `PairingErrorResponse` JSON on failure.
- `POST /v1/pairing/await-outcome` — decode `PairingAwaitOutcomeRequest`, call `handleAwaitOutcome`. This is a **long-poll**: the await may suspend for minutes. Do not block the event loop — accumulate the body in the NIO handler, then bridge to a `Task` that awaits the actor and writes the response back on the channel's event loop (same promise+`Task` shape as `WebServer.handleSignalingOffer`, `Sources/GrafttyKit/Web/WebServer.swift:1208`).
- Any other path → 404; non-POST on the two routes → 405. No static assets, no TLS, no auth (the pairing protocol is self-authenticating; the listener exists only while a session is active).
- Use `MultiThreadedEventLoopGroup(numberOfThreads: 1)` owned by the actor; `stop()` closes the channel and shuts down the group.

**Steps:**

- [ ] **Step 1: Write the failing tests** in `PairingHTTPServerTests.swift`. Build a real `HostPairingServer` over a `HostPairingSession` with temp-dir stores (mirror the setup in existing `Tests/GrafttyTests/Remote/Pairing/` tests — read one first). Drive HTTP with `URLSession` against `http://127.0.0.1:<port>`. Required test cases:
  1. `introduceRoundTrip` — `start(validFor:)` the pairing server, POST a valid `PairingIntroduceRequest` → 200, body decodes to `PairingIntroduceResponse` whose `hostPublicKey` matches the host identity store.
  2. `introduceWrongNonce` — POST with a fabricated nonce → non-2xx, body decodes to `PairingErrorResponse`.
  3. `awaitOutcomeResolvesOnConfirm` — POST await-outcome in a child task (after introduce), poll `pairingServer.pendingWaiterCount` until 1, then `confirm()`; the HTTP response arrives with `outcome == .confirmed`.
  4. `unknownPathIs404` / `getIs405`.
  5. `@spec REMOTE-1.4` (see EARS text below) — after `stop()`, a request to the same port fails at the connection level (assert `URLError`).
- [ ] **Step 2: Run tests, confirm they fail** (type doesn't exist): `swift test --filter PairingHTTPServerTests` → compile error / FAIL.
- [ ] **Step 3: Implement `PairingHTTPServer`** per the interface above.
- [ ] **Step 4: Run** `swift test --filter PairingHTTPServerTests` → PASS; then full `swift test` for regressions.
- [ ] **Step 5: Commit** `feat(remote): plaintext LAN pairing listener (REMOTE-1.4)`.

**Spec text (EARS), used verbatim as the test title:**
- `@spec REMOTE-1.4: While no pairing session is active, the host shall not accept connections on the pairing endpoint; the pairing listener runs only for the lifetime of an active pairing session.`

---

### Task 2: PairingPayload.webBaseURL + HostDeviceIDStore + HostPairingCoordinator

**Files:**
- Modify: `Sources/GrafttyProtocol/PairingPayload.swift` — add `public let webBaseURL: URL?`
- Create: `Sources/GrafttyKit/Remote/HostDeviceIDStore.swift`
- Create: `Sources/Graftty/Remote/HostPairingCoordinator.swift`
- Create: `Sources/Graftty/Remote/LANAddress.swift`
- Test: `Tests/GrafttyProtocolTests/PairingPayloadTests.swift` (extend existing if present), `Tests/GrafttyTests/Remote/HostDeviceIDStoreTests.swift`, `Tests/GrafttyTests/Remote/Pairing/HostPairingCoordinatorTests.swift` — note: `Sources/Graftty` is the app target; if app-target types aren't test-visible, place `HostPairingCoordinator` + `LANAddress` in `Sources/GrafttyKit/Remote/Pairing/` instead (check how existing app-level logic is tested first — e.g. where `WebServerController` tests live — and follow that precedent).

**Interfaces:**
- Produces: `PairingPayload.webBaseURL: URL?` — the host's durable web base URL (wss/https, Tailscale), carried in the QR so the mobile side can create a usable `Host` record after pairing. Optional + decoded with `decodeIfPresent` so older payload JSON still decodes; keep `version` at 1 (no shipped consumer exists). Update `qrEncoded()`/`decodeQR` round-trip accordingly.
- Produces: `HostDeviceIDStore` — mirrors the identity-store pattern (read `Sources/GrafttyKit/Remote/HostIdentityStore.swift` first and copy its persistence idiom):

```swift
public final class HostDeviceIDStore: @unchecked Sendable {
    public init(directory: URL)
    /// Loads the persisted RemoteDeviceID, or generates + persists one.
    public func loadOrGenerateAndPersist() throws -> RemoteDeviceID
}
```

- Produces: `HostPairingCoordinator` — the single object Task 3's UI talks to:

```swift
@MainActor
public final class HostPairingCoordinator: ObservableObject {
    @Published public private(set) var state: HostPairingSessionState
    @Published public private(set) var payload: PairingPayload?     // set while awaitingClient
    @Published public private(set) var lastError: String?

    public init(
        identityStore: HostIdentityStore,
        trustedPeerStore: TrustedPeerStore,
        deviceIDStore: HostDeviceIDStore,
        hostDisplayName: String,
        webBaseURLProvider: @escaping @Sendable () -> URL?
    )

    /// Start listener → build session (pairingURLProvider returns
    /// http://<primaryLANIPv4>:<boundPort>/v1/pairing) → startPairing()
    /// → publish payload. Starts a 1s tick task driving server.tick()
    /// + state refresh until a terminal state.
    public func beginPairing() async
    public func confirm() async
    public func deny() async
    /// Cancels the session AND stops the listener (also called on
    /// terminal states from the tick task) — REMOTE-1.4's guarantee.
    public func endPairing() async
}
```

- Produces: `LANAddress.primaryIPv4() -> String?` — `getifaddrs` walk; prefer `en*` interfaces, skip loopback/`utun*`/`awdl*`/link-local (169.254.*). Factor the selection into a pure function `LANAddress.select(from: [(name: String, address: String)]) -> String?` so tests cover the filtering without real interfaces.

**Steps:**

- [ ] **Step 1 (RED):** payload round-trip test — `qrEncoded()`→`decodeQR` preserves `webBaseURL`; legacy JSON without the field decodes with `webBaseURL == nil`. Run → FAIL.
- [ ] **Step 2 (GREEN):** add the field; run → PASS.
- [ ] **Step 3 (RED):** `HostDeviceIDStore` tests — generates once, second load returns the same ID; corrupt file regenerates. Run → FAIL.
- [ ] **Step 4 (GREEN):** implement; run → PASS.
- [ ] **Step 5 (RED):** coordinator tests with temp-dir stores: `beginPairing()` publishes a payload whose `pairingURL` contains the bound port and path `/v1/pairing`, and whose `webBaseURL` comes from the provider; a full introduce (via `URLSession` POST, reusing Task 1's shapes) transitions state to `pendingConfirmation` on tick; `confirm()` reaches `.confirmed` and the peer is in the store — title this test with `@spec REMOTE-1.3` (EARS below); `endPairing()` stops the listener (connection refused) and returns state to a terminal/idle shape. Include `LANAddress.select` filtering cases. Run → FAIL.
- [ ] **Step 6 (GREEN):** implement coordinator + LANAddress; run → PASS; full `swift test`.
- [ ] **Step 7: Commit** `feat(remote): host pairing coordinator + device id + payload webBaseURL (REMOTE-1.3)`.

**Spec text (EARS):**
- `@spec REMOTE-1.3: When the host user confirms an introduced pairing, the application shall persist the introduced peer in the trusted peer store.`

---

### Task 3: Mac settings UI — Device Pairing section

**Files:**
- Modify: `Sources/Graftty/Web/WebSettingsPane.swift` — new `Section("Device Pairing")` below Web Access
- Modify: `Sources/Graftty/GrafttyApp.swift` — construct `HostPairingCoordinator` (reuse the SAME `HostIdentityStore`/`TrustedPeerStore` instances built at `GrafttyApp.swift:356-357` for `WebRTCHostAgent` — do not construct parallel stores) and inject to the settings scene; `webBaseURLProvider` derives from `WebServerController.serverHostname` + listening port via `WebURLComposer.baseURL` (see `WebSettingsPane.swift:17-20` for the existing derivation)
- Create: `Sources/Graftty/Web/PairedDevicesSection.swift` (list + pairing flow UI, kept out of the already-long settings pane)
- Test: state→presentation mapping tests if any pure logic emerges; UI itself is exercised manually + by Task 5's end-to-end

**UI states (drive from `coordinator.state`):**
- idle/terminal: "Pair a Device…" button → `beginPairing()`; below it, the paired-devices list: `TrustedPeerStore.list()` rows (displayName, kind, `fingerprint.display`, pairedAt) each with a Remove button → `store.remove(id:)` + refresh (live-session teardown on revoke is W4 — not in scope here).
- `.awaitingClient(payload, expiry)`: `QRCodeView(text: try payload.qrEncoded(), size: 200)` + "Scan with Graftty on your phone" caption + expiry countdown + Cancel button → `endPairing()`.
- `.pendingConfirmation(..., verificationCode, ...)`: show `verificationCode.display` LARGE + requesting client's display name + kind, with Confirm / Deny buttons → `confirm()`/`deny()`. Caption: "Confirm this code matches the one shown on the device."
- `.confirmed(trustedPeer)`: success row with peer name, auto-return to idle after listener teardown.
- `.denied`/`.expired`/`.failed`: message + "Start Over" button.

**Steps:**

- [ ] **Step 1:** Read `WebSettingsPane.swift` fully; add the section + `PairedDevicesSection` view; wire coordinator injection in `GrafttyApp`.
- [ ] **Step 2:** `swift build` clean; `swift test` no regressions.
- [ ] **Step 3:** Manual smoke: launch app → Settings → Device Pairing → QR renders, Cancel tears down (verify port closed with `nc`).
- [ ] **Step 4: Commit** `feat(settings): device pairing section — QR, verification code, paired-device list`.

---

### Task 4: Mobile pairing flow — scan QR, verify code, pin host

**Files:**
- Modify: `Sources/GrafttyMobileKit/Hosts/AddHostView.swift` — in `handle(rawURL:)`, FIRST try `PairingPayload.decodeQR(value)`; on success switch to the pairing flow; on `DecodeError` fall through to the existing URL path unchanged
- Create: `Sources/GrafttyMobileKit/Hosts/PairDeviceFlowView.swift` — the pairing UI
- Create: `Sources/GrafttyMobileKit/Remote/ClientDeviceIDStore.swift` — same shape as Task 2's `HostDeviceIDStore` (separate module; intentional mirror like the identity stores)
- Modify: `Sources/GrafttyMobileKit/Hosts/Host.swift` — add `public var remoteDeviceID: RemoteDeviceID?` (optional ⇒ existing persisted hosts decode; thread through `init`)
- Modify: `Apps/GrafttyMobile/GrafttyMobile/Info.plist` — add `NSLocalNetworkUsageDescription` ("Graftty connects to your Mac on the local network to pair and attach to terminal sessions.") and `NSAppTransportSecurity` → `NSAllowsLocalNetworking = true` (the pairing listener is plaintext HTTP on the LAN; ATS blocks it otherwise)
- Test: `Tests/GrafttyMobileKitTests/Hosts/PairingFlowTests.swift`

**Flow (PairDeviceFlowView):**
1. Construct once on appear: `ClientIdentityStore` + `PinnedHostStore` (existing default directories — find how other mobile code constructs them), `ClientPairingSession(identityStore:pinnedHostStore:clientDeviceID:clientKind:clientDisplayName:)` with `clientDeviceID` from `ClientDeviceIDStore`, `clientKind` `.iPad`/`.iPhone` by `UIDevice.current.userInterfaceIdiom` (read `RemoteDeviceKind` for exact case names), `clientDisplayName = UIDevice.current.name`; `LocalPairingClient(session:identityStore:transport:)` with the URLSession-backed production transport (see how `LocalPairingClient`'s `Transport` is satisfied in its tests, then build the URLSession equivalent).
2. Kick `runPairing(payload:)` in a `.task`. UI states: *connecting* (spinner) → *awaiting confirmation*: show the verification code — read it from the session's state after `markAwaitingConfirmation` (grep `ClientPairingSession` for the state exposing the transcript; the code is `transcript.verificationCode().display`) + "Confirm on your Mac" caption → *success*: host display name + Done → *denied/expired/error*: message + retry.
3. On success (`runPairing` returns `PinnedHost` — verify whether `session.confirm` already persisted it to `PinnedHostStore`; if not, `pinnedHostStore.add` here): call `onSave(Host(label: payload.hostDisplayName, baseURL: payload.webBaseURL ?? derived-from-pairingURL-fallback, remoteDeviceID: payload.hostDeviceID))` and dismiss. If `webBaseURL` is nil AND there's no sensible fallback, save the host with the pairing URL's host + default port and surface a "verify address in host settings" hint — do not fail the pairing.

**Steps:**

- [ ] **Step 1 (RED):** tests — (a) QR discrimination: a `qrEncoded()` payload string routes to pairing, a plain `https://…` routes to the URL path, garbage yields the existing error; (b) `ClientDeviceIDStore` persistence round-trip; (c) flow state machine against a stubbed `Transport` (happy path → success + `PinnedHost` persisted + `Host.remoteDeviceID` set; denied path → denied state, nothing pinned) — title (c)'s happy-path test `@spec REMOTE-1.5` (EARS below). Run on macOS destination if UIKit-gated — these are `#if canImport(UIKit)` types, so run via the iOS test bundle: `xcodebuild test -project Apps/GrafttyMobile/GrafttyMobile.xcodeproj -scheme GrafttyMobile -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:GrafttyMobileKitTests/PairingFlowTests` → FAIL.
- [ ] **Step 2 (GREEN):** implement view + store + Host field + Info.plist keys; re-run → PASS.
- [ ] **Step 3:** Run the broader mobile suite locally if feasible; otherwise rely on iOS CI (canonical gate).
- [ ] **Step 4: Commit** `feat(mobile): scan-to-pair flow — verification code, pinned host, host record identity (REMOTE-1.5)`.

**Spec text (EARS):**
- `@spec REMOTE-1.5: When a pairing completes with host confirmation, the client shall pin the host identity and record the host device identifier on the saved host entry.`

---

### Task 5: Host-side end-to-end test + SPECS.md regeneration

**Files:**
- Create: `Tests/GrafttyTests/Remote/Pairing/PairingEndToEndTests.swift`
- Regenerate: `SPECS.md` via `scripts/generate-specs.py`

**Test:** single-process ceremony over real HTTP on 127.0.0.1 (no mobile module — drive the client side with raw `URLSession` POSTs of the `GrafttyProtocol` wire types): `beginPairing`-equivalent setup (or the coordinator directly, if test-visible) → introduce → assert `pendingConfirmation` state and that the verification code equals `RemotePairingTranscript(hostPublicKey:clientPublicKey:nonce:expiry:).verificationCode()` computed independently from the wire traffic (both sides derive the same code — REMOTE-1.2's property, already specced; do NOT add a new spec ID for it) → `confirm()` → await-outcome long-poll returns `.confirmed` → `TrustedPeerStore.get(id:)` returns the client's ID with the client's public key.

**Steps:**

- [ ] **Step 1:** Write the test; run `swift test --filter PairingEndToEnd` → PASS (all pieces exist; if it fails, that's a real integration bug — fix forward).
- [ ] **Step 2:** `scripts/generate-specs.py`; verify REMOTE-1.3/1.4/1.5 appear in `SPECS.md`; `scripts/generate-specs.py --check` passes.
- [ ] **Step 3:** Full `swift test`.
- [ ] **Step 4: Commit** `test(remote): pairing end-to-end over loopback HTTP + SPECS.md regen`.

---

## Self-review notes

- REMOTE-1.2 (verification code) already has active coverage — Task 5 exercises it end-to-end but introduces no duplicate spec ID.
- The `HostPairingServer.start` doc mentions a TODO about self-expiry without `tick()`; the coordinator's 1s tick task (Task 2) is the designed answer — do not add a parallel expiry mechanism in the listener.
- Type-consistency check: `PairingHTTPServer(pairingServer:)` consumed by `HostPairingCoordinator` (Task 2); `HostPairingCoordinator` consumed by `PairedDevicesSection` (Task 3); `PairingPayload.webBaseURL` + `Host.remoteDeviceID` consumed by Task 4. All signatures declared above.
- Out of scope, deliberately: live-session teardown on Remove (W4), Bonjour discovery, TLS on the pairing listener, any change to the Tailscale-bound web server binding.

## Risks

1. `Sources/Graftty` app-target testability — Task 2 has an explicit fallback (move coordinator into `GrafttyKit`). Decide by precedent, not preference.
2. `ClientPairingSession.confirm` may or may not persist the `PinnedHost` itself — Task 4 must verify and act accordingly (double-add would throw on the duplicate).
3. iOS local-network permission prompt appears on first pairing — expected; the usage description makes it comprehensible.
4. `URLSession` long-poll default timeout (60s) is shorter than the 300s pairing window — the mobile transport must set `timeoutIntervalForRequest` ≥ 320s for await-outcome (Task 4; check what `LocalPairingClient`'s production transport does about timeouts).
