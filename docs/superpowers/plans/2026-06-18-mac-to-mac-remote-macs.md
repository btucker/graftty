# Mac-to-Mac Remote Macs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Mac-to-Mac Graftty connectivity end to end: saved remote Macs, Bonjour discovery, LAN pairing/signaling, host accept/deny pairing UI, a separate macOS `Remote Macs` sidebar section, and SSH-over-WebRTC terminal/panes access.

**Architecture:** Keep local repositories and remote Macs as separate models. Put non-UI remote identity/discovery/persistence and LAN HTTP route handling in `GrafttyKit`, add a new `GrafttyRemoteClient` target for client-side pairing/signaling/WebRTC/SSH code shared by iPad and Mac, keep Mac host WebRTC in `GrafttyHostAgent`, and layer macOS sidebar/add-remote UI in the `Graftty` executable target. Phase 1 explicitly keeps the current one-active-inbound-peer host limit and returns structured busy responses; the protocol and UI are shaped so a later host connection manager can remove that limit.

**Tech Stack:** Swift 5.10, Swift Testing, SwiftUI/AppKit, Foundation Bonjour (`NetService`/`NetServiceBrowser` or Network framework), SwiftNIO HTTP, existing `GrafttyProtocol`, `GrafttyKit`, and `GrafttyHostAgent`.

---

## File Structure

### Shared Remote Model and Discovery

- Create `Sources/GrafttyKit/Remote/MacToMac/RemoteMac.swift`
  - `RemoteMac` persisted saved-host model keyed by `RemoteDeviceID`.
  - `RemoteMacConnectionState` enum for sidebar state.
- Create `Sources/GrafttyKit/Remote/MacToMac/RemoteMacStore.swift`
  - File-backed store analogous to mobile `HostStore`, but not UIKit-gated.
  - Synchronous mutation safety matching `HostStore.ensureLoaded()`.
- Create `Sources/GrafttyKit/Remote/MacToMac/GrafttyBonjourService.swift`
  - Constants and TXT encode/decode for `_graftty._tcp`.
  - `GrafttyBonjourCandidate` resolved discovery record.
- Test `Tests/GrafttyKitTests/Remote/MacToMac/RemoteMacStoreTests.swift`
- Test `Tests/GrafttyKitTests/Remote/MacToMac/GrafttyBonjourServiceTests.swift`

### LAN Pairing and Signaling Listener

- Create `Sources/GrafttyKit/Remote/MacToMac/LANRemoteAccessServer.swift`
  - Narrow SwiftNIO HTTP server for LAN routes only.
  - Routes: `POST /v1/pairing/begin`, `POST /v1/pairing/introduce`, `POST /v1/pairing/await-outcome`, `POST /v1/rtc/offer`.
  - No `/repos`, `/worktrees`, `/sessions`, `/ws`, or static assets.
- Create `Sources/GrafttyKit/Remote/MacToMac/LANRemoteAccessRouteHandler.swift`
  - Testable pure route dispatcher so most behavior can be verified without socket timing.
- Create `Sources/GrafttyKit/Remote/MacToMac/PairingBeginCoordinator.swift`
  - Provides an atomic `startIfIdle(validFor:lanBaseURL:)` primitive so concurrent begin requests cannot both observe idle.
  - Rewrites the returned `PairingPayload.pairingURL` to the client-reachable LAN base URL for this request.
- Test `Tests/GrafttyKitTests/Remote/MacToMac/LANRemoteAccessRouteHandlerTests.swift`
- Test `Tests/GrafttyKitTests/Remote/MacToMac/PairingBeginCoordinatorTests.swift`

### Bonjour Runtime

- Create `Sources/Graftty/Remote/MacToMac/GrafttyBonjourAdvertiser.swift`
  - macOS runtime advertiser wrapping `NetService`.
- Create `Sources/Graftty/Remote/MacToMac/GrafttyBonjourBrowser.swift`
  - macOS browser wrapping `NetServiceBrowser`, publishing transient candidates.
- Testable transforms stay in `GrafttyKit`; runtime wrappers get light integration tests only if practical.

### macOS App Wiring and Sidebar

- Create `Sources/Graftty/Remote/MacToMac/RemoteMacsModel.swift`
  - `@MainActor ObservableObject` owning `RemoteMacStore`, transient discovery, connection states, and on-demand connect/disconnect commands.
- Create `Sources/Graftty/Views/RemoteMacsSection.swift`
  - Sidebar section that renders saved remote Macs only.
- Create `Sources/Graftty/Views/AddRemoteMacSheet.swift`
  - Discovery/manual-entry sheet. Starts browsing only while visible.
  - Shows the client-side verification code and requires user confirmation before storing trust.
- Modify `Sources/Graftty/Views/SidebarView.swift`
  - Add `Remote Macs` section below local repos and above `Add Repository`.
- Modify `Sources/Graftty/Views/MainWindow.swift`
  - Pass `RemoteMacsModel` and remote selection callbacks into `SidebarView`.
- Modify `Sources/Graftty/GrafttyApp.swift`
  - Own and start LAN listener/Bonjour advertiser when local remote access is enabled.
  - Own `RemoteMacsModel`.
- Test `Tests/GrafttyTests/RemoteMacsSidebarTests.swift` or focused pure view-model tests if SwiftUI inspection is not available.

### Shared Client Pairing and SSH-over-WebRTC

- Modify `Package.swift`
  - Add library product `GrafttyRemoteClient`.
  - Add target `GrafttyRemoteClient` depending on `GrafttyProtocol`, `NIO`, `NIOExtras`, `NIOSSH`, and `WebRTC`.
  - Make `GrafttyMobileKit` and `Graftty` depend on `GrafttyRemoteClient`.
- Move from `Sources/GrafttyMobileKit/Remote` to `Sources/GrafttyRemoteClient/Remote`:
  - `ClientIdentityStore.swift`
  - `PinnedHostStore.swift`
  - `PaneControlClient.swift`
  - `WorktreePanesStore.swift`
  - `SignalingClient.swift`
  - `RemoteHostConnection.swift`
  - `../Session/WebSocketClient.swift` or an equivalent minimal `WebSocketClient`/`WebSocketFrame` abstraction required by `TerminalSessionClient`
  - `../Session/URL+APIPath.swift` or an equivalent URL path-join helper required by `LocalPairingClient` and `SignalingClient`
  - `SSH/**`
  - `Pairing/ClientPairingSession.swift`
  - `Pairing/LocalPairingClient.swift`
- Create `Sources/GrafttyMobileKit/Remote/GrafttyRemoteClientExports.swift` if existing mobile imports need compatibility.
- Move or duplicate non-UIKit tests into `Tests/GrafttyRemoteClientTests`.

### Host Pairing Prompt

- Create `Sources/Graftty/Remote/MacToMac/HostPairingCoordinator.swift`
  - Owns `HostPairingServer`, pending prompt state, and confirm/deny/cancel actions.
- Create `Sources/Graftty/Views/RemotePairingRequestSheet.swift`
  - Host-side sheet/alert that shows requesting device label and verification code.
- Modify `Sources/Graftty/GrafttyApp.swift` or `Sources/Graftty/Views/MainWindow.swift`
  - Present the prompt when `HostPairingSessionState.pendingConfirmation` appears.

### Mac Client Connection Registry

- Create `Sources/Graftty/Remote/MacToMac/RemoteMacConnectionRegistry.swift`
  - One active `RemoteHostConnection` per saved `RemoteMac`.
  - Opens panes-state and pane-control channels through `GrafttyRemoteClient`.
  - Opens terminal session channels through `RemoteHostConnection.openTerminalSession(sessionName:)`.
  - Tracks active peer identity so revocation closes live sessions for that peer.
- Create `Sources/Graftty/Remote/MacToMac/RemoteMacPaneEnvironment.swift`
  - Mac-side wrapper equivalent to mobile `buildPaneEnvironment(remoteHost:)`, adapted for macOS sidebar/detail selection.

---

## Task 1: Shared RemoteMac Store and Bonjour TXT Records

**Files:**
- Create: `Sources/GrafttyKit/Remote/MacToMac/RemoteMac.swift`
- Create: `Sources/GrafttyKit/Remote/MacToMac/RemoteMacStore.swift`
- Create: `Sources/GrafttyKit/Remote/MacToMac/GrafttyBonjourService.swift`
- Test: `Tests/GrafttyKitTests/Remote/MacToMac/RemoteMacStoreTests.swift`
- Test: `Tests/GrafttyKitTests/Remote/MacToMac/GrafttyBonjourServiceTests.swift`

- [ ] **Step 1: Write failing RemoteMacStore tests**

Add Swift Testing coverage:

```swift
@Suite("RemoteMacStore")
struct RemoteMacStoreTests {
    @Test("add inserts and reloads a saved remote Mac")
    func addPersistsRemoteMac() throws { /* temp JSON file, add, reload, expect same id/fingerprint */ }

    @Test("add updates existing identity instead of duplicating")
    func addDedupesByIdentity() throws { /* same id+fingerprint, new URL/name, expect one row */ }

    @Test("mutation before async load preserves existing file")
    func mutationBeforeLoadDoesNotClobberPersistedRows() throws { /* mirrors HostStore race test */ }
}
```

- [ ] **Step 2: Write failing Bonjour TXT tests**

```swift
@Suite("GrafttyBonjourService TXT records")
struct GrafttyBonjourServiceTests {
    @Test("encodes canonical discovery metadata")
    func encodesTXT() throws { /* expect _graftty._tcp, version, deviceID, full fingerprint, proto, pairing */ }

    @Test("rejects missing identity fields")
    func rejectsMissingIdentityFields() throws { /* no deviceID/fingerprint -> nil or typed error */ }

    @Test("filters self and dedupes by identity")
    func filtersSelfAndDedupes() throws { /* candidates -> unique non-self candidates */ }

    @Test("filters protocol-incompatible candidates")
    func filtersProtocolIncompatibleCandidates() throws { /* candidate proto range excludes current version -> filtered out */ }

    @Test("round-trips pairing status")
    func pairingStatusRoundTrips() throws { /* required / paired-only encode and decode */ }
}
```

- [ ] **Step 3: Run tests and verify RED**

Run:

```bash
swift test --filter RemoteMacStoreTests
swift test --filter GrafttyBonjourServiceTests
```

Expected: compile failures because the new types do not exist.

- [ ] **Step 4: Implement minimal shared types**

Implement:

```swift
public struct RemoteMac: Codable, Sendable, Hashable, Identifiable {
    public let id: RemoteDeviceID
    public var label: String
    public var fingerprint: RemoteIdentityFingerprint
    public var lastKnownBaseURL: URL?
    public var addedAt: Date
    public var lastUsedAt: Date?
    public var lastDiscoveredAt: Date?
}

public enum RemoteMacConnectionState: String, Codable, Sendable, Equatable {
    case offline, discovered, connecting, connected, failed, needsPairing
}
```

`RemoteMacStore` should mirror `HostStore` semantics but be platform-neutral and keyed by `(id, fingerprint)`.

`GrafttyBonjourService` should expose:

```swift
public enum GrafttyBonjourService {
    public static let serviceType = "_graftty._tcp."
    public static let domain = "local."
    public static let discoveryVersion = "1"
}
```

and typed TXT encode/decode helpers.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
swift test --filter RemoteMacStoreTests
swift test --filter GrafttyBonjourServiceTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Remote/MacToMac Tests/GrafttyKitTests/Remote/MacToMac
git commit -m "feat(remote): add remote Mac store and Bonjour metadata"
```

---

## Task 2: LAN Pairing Bootstrap and Route Handler

**Files:**
- Create: `Sources/GrafttyKit/Remote/MacToMac/PairingBeginCoordinator.swift`
- Create: `Sources/GrafttyKit/Remote/MacToMac/LANRemoteAccessRouteHandler.swift`
- Modify if needed: `Sources/GrafttyProtocol/PairingExchange.swift`
- Test: `Tests/GrafttyKitTests/Remote/MacToMac/PairingBeginCoordinatorTests.swift`
- Test: `Tests/GrafttyKitTests/Remote/MacToMac/LANRemoteAccessRouteHandlerTests.swift`

- [ ] **Step 1: Write failing coordinator tests**

Cover:

```swift
@Suite("PairingBeginCoordinator")
struct PairingBeginCoordinatorTests {
    @Test("begin starts host pairing session and returns payload")
    func beginReturnsPayload() async throws { }

    @Test("begin rejects while a pairing session is active")
    func beginRejectsActiveSession() async throws { }

    @Test("concurrent begin requests cannot both start sessions")
    func concurrentBeginIsAtomic() async throws { }
}
```

The busy tests are critical: `HostPairingServer.start(validFor:)` cancels active waiters today. A separate `currentState()` actor call followed by `start(validFor:)` is not sufficient because concurrent begin requests can race. The coordinator must expose one serialized `startIfIdle(validFor:lanBaseURL:)` operation and tests must prove only one concurrent caller receives a payload.

- [ ] **Step 2: Write failing route tests**

Use a pure route API, not sockets:

```swift
let response = await handler.handle(
    method: .POST,
    path: "/v1/pairing/begin",
    body: Data()
)
#expect(response.status == 200)
#expect(try JSONDecoder.iso8601().decode(PairingPayload.self, from: response.body).nonce.bytes.isEmpty == false)
```

Also assert:

- `GET /v1/pairing/begin` returns 405.
- `/repos`, `/worktrees`, `/sessions`, `/ws`, `/` return 404.
- `/v1/rtc/offer` forwards to the injected signaling handler.
- Busy pairing returns a structured JSON error.
- `POST /v1/pairing/begin` returns a `PairingPayload.pairingURL` equal to a client-reachable LAN pairing route base like `http://host.local:port/v1/pairing`, not the Tailscale web URL, not `0.0.0.0`, and not the root base URL.
- Repeated pairing/RTC requests beyond the configured limit return structured backoff/rate-limit responses.

- [ ] **Step 3: Run tests and verify RED**

Run:

```bash
swift test --filter PairingBeginCoordinatorTests
swift test --filter LANRemoteAccessRouteHandlerTests
```

Expected: compile failures because coordinator/handler do not exist.

- [ ] **Step 4: Implement route primitives**

Implement a small route result type:

```swift
public struct LANRemoteAccessResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public var contentType: String
}
```

Implement `PairingBeginCoordinator` as the only code path allowed to call `HostPairingServer.start(validFor:)` for LAN pairing. It must serialize the idle check and start in one actor-isolated method:

```swift
public actor PairingBeginCoordinator {
    public func startIfIdle(validFor: TimeInterval, lanBaseURL: URL) async -> Result<PairingPayload, PairingErrorResponse>
}
```

Do not implement this as `await server.currentState(); await server.start(...)` from outside the coordinator.

The LAN begin path must rewrite or construct `PairingPayload.pairingURL` from a client-reachable base URL. Acceptable inputs:

- The HTTP request `Host` header when it names the address the client used.
- The Bonjour-resolved candidate base URL passed by the client flow.
- A route-handler-injected `lanBaseURLProvider`.

Do not return `0.0.0.0`, `::`, `localhost`, the existing Tailscale web URL, or a bare root such as `http://host:port` in the `PairingPayload` served to a Bonjour client. `LocalPairingClient` appends `introduce` and `await-outcome` to `pairingURL`, so the value must be the pairing route base, e.g. `http://host:port/v1/pairing`, and it must be reachable from the client Mac.

Implement `LANRemoteAccessRouteHandler` with injected closures:

- `beginPairing`
- `handleIntroduce`
- `handleAwaitOutcome`
- `handleSignalingOffer`

Keep it independent from NIO.

Use structured response codes for UI mapping:

- Pairing active: HTTP `409`, `PairingErrorResponse.Code.wrongSessionState` or a new explicit `pairingBusy` code if added.
- Rate limited/backoff: HTTP `429` with a machine-readable JSON code such as `rateLimited`.
- Host WebRTC busy: HTTP `503` with a machine-readable JSON code such as `hostBusy`.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
swift test --filter PairingBeginCoordinatorTests
swift test --filter LANRemoteAccessRouteHandlerTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Remote/MacToMac Tests/GrafttyKitTests/Remote/MacToMac
git commit -m "feat(remote): add LAN pairing route handler"
```

---

## Task 3: LAN Remote Access HTTP Server

**Files:**
- Create: `Sources/GrafttyKit/Remote/MacToMac/LANRemoteAccessServer.swift`
- Test: `Tests/GrafttyKitTests/Remote/MacToMac/LANRemoteAccessServerTests.swift`

- [ ] **Step 1: Write failing server tests**

Use an ephemeral port (`0`) and localhost bind for socket tests. Test:

- Server starts and reports actual port.
- `POST /v1/pairing/begin` returns JSON payload through the real socket.
- `GET /repos` returns 404.
- Production config binds to a LAN-reachable host (`0.0.0.0` or `::`) while tests can override to `127.0.0.1`.
- Pairing and RTC offer routes enforce simple rate limiting or busy backoff.
- `stop()` closes the listener.

Follow existing web integration test patterns in `Tests/GrafttyKitTests/Web/WebServerIntegrationTests.swift`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter LANRemoteAccessServerTests
```

Expected: compile failures because server does not exist.

- [ ] **Step 3: Implement SwiftNIO server wrapper**

Use `ServerBootstrap` and a small HTTP handler that accumulates request body up to a safe cap, then delegates to `LANRemoteAccessRouteHandler`.

Do not add TLS in this task. The spec allows the Bonjour path to store no trust until transcript verification and host acceptance. Keep certificate handling out unless a later task explicitly chooses HTTPS.

Expose:

```swift
public final class LANRemoteAccessServer: Sendable {
    public struct Config: Sendable { public var port: Int; public var bindHost: String }
    public var listeningPort: Int? { get }
    public func start() throws
    public func stop()
}
```

Production app wiring must use a LAN-reachable bind host, not localhost. Tests may use `127.0.0.1` for determinism, but `GrafttyApp` should pass `0.0.0.0` or the Network-framework equivalent and Bonjour should advertise the actual listener port returned after bind.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter LANRemoteAccessServerTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Remote/MacToMac/LANRemoteAccessServer.swift Tests/GrafttyKitTests/Remote/MacToMac/LANRemoteAccessServerTests.swift
git commit -m "feat(remote): add LAN remote access server"
```

---

## Task 4: Bonjour Advertiser and Browser Runtime

**Files:**
- Create: `Sources/Graftty/Remote/MacToMac/GrafttyBonjourAdvertiser.swift`
- Create: `Sources/Graftty/Remote/MacToMac/GrafttyBonjourBrowser.swift`
- Test: `Tests/GrafttyTests/RemoteMacBonjourTests.swift`

- [ ] **Step 1: Write failing tests for runtime mapping**

Avoid timing-heavy network tests. Test pure delegate mapping helpers:

- TXT data from `NetService` maps to `GrafttyBonjourCandidate`.
- Self candidates are ignored.
- Protocol-incompatible candidates are rejected and never published to the sheet.
- TXT `pairing` status is carried into the candidate model.
- Resolved candidates refresh `RemoteMac.lastKnownBaseURL`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter RemoteMacBonjourTests
```

Expected: compile failures because wrappers do not exist.

- [ ] **Step 3: Implement advertiser/browser wrappers**

`GrafttyBonjourAdvertiser`:

- Takes port, label, deviceID, fingerprint, protocol range.
- Publishes `_graftty._tcp.` in `local.`.
- Sets TXT data from `GrafttyBonjourService`.
- Has `start()` and `stop()`.

`GrafttyBonjourBrowser`:

- Starts from explicit user action only.
- Publishes candidates through an injected callback or `@Published` state.
- Resolves services and converts TXT + host/port into `GrafttyBonjourCandidate`.
- Filters out candidates whose advertised `proto` range does not include the current client protocol version.
- Carries advertised `pairing` status into the candidate so UI can distinguish pairable and paired-only hosts.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter RemoteMacBonjourTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Remote/MacToMac/GrafttyBonjourAdvertiser.swift Sources/Graftty/Remote/MacToMac/GrafttyBonjourBrowser.swift Tests/GrafttyTests/RemoteMacBonjourTests.swift
git commit -m "feat(mac): add Bonjour remote Mac discovery"
```

---

## Task 5: Shared Remote Client Target and macOS Pairing Primitives

**Files:**
- Modify: `Package.swift`
- Create: `Sources/GrafttyRemoteClient/Remote/...`
- Create if needed: `Sources/GrafttyMobileKit/Remote/GrafttyRemoteClientExports.swift`
- Test: `Tests/GrafttyRemoteClientTests/Remote/GrafttyRemoteClientExportsTests.swift`
- Move/adapt tests from `Tests/GrafttyMobileKitTests/Remote`

- [ ] **Step 1: Write failing package/visibility tests**

Add:

```swift
import Testing
import GrafttyRemoteClient

@Suite("GrafttyRemoteClient exports")
struct GrafttyRemoteClientExportsTests {
    @Test("client pairing and remote connection types are available")
    func exportsClientTypes() {
        _ = ClientIdentityStore.self
        _ = PinnedHostStore.self
        _ = ClientPairingSession.self
        _ = LocalPairingClient.self
        _ = SignalingClient.self
        _ = RemoteHostConnection.self
    }
}
```

- [ ] **Step 2: Run test and verify RED**

Run:

```bash
swift test --filter GrafttyRemoteClientExportsTests
```

Expected: package target/import failure.

- [ ] **Step 3: Add package target and move client files**

Update `Package.swift`:

- Add `.library(name: "GrafttyRemoteClient", targets: ["GrafttyRemoteClient"])`.
- Add target `GrafttyRemoteClient` with dependencies: `GrafttyProtocol`, `NIO`, `NIOExtras`, `NIOSSH`, `WebRTC`.
- Add `GrafttyRemoteClient` dependency to `GrafttyMobileKit`.
- Add `GrafttyRemoteClient` dependency to `Graftty`.
- Add test target `GrafttyRemoteClientTests`.

Move these files out of `GrafttyMobileKit` and remove accidental `#if canImport(UIKit)` guards:

- `Remote/ClientIdentityStore.swift`
- `Remote/PinnedHostStore.swift`
- `Remote/PaneControlClient.swift`
- `Remote/WorktreePanesStore.swift`
- `Remote/SignalingClient.swift`
- `Remote/RemoteHostConnection.swift`
- `Session/WebSocketClient.swift` or an equivalent minimal terminal stream abstraction containing `WebSocketClient` and `WebSocketFrame`
- `Session/URL+APIPath.swift` or an equivalent URL path-join helper
- `Remote/SSH/**`
- `Remote/Pairing/ClientPairingSession.swift`
- `Remote/Pairing/LocalPairingClient.swift`

If existing mobile code/tests need compatibility, add a shim:

```swift
@_exported import GrafttyRemoteClient
```

Also update any `GrafttyMobileKit` files that directly reference moved symbols to add `import GrafttyRemoteClient` where the export shim is not sufficient or would obscure ownership.

- [ ] **Step 4: Move focused tests**

Move tests for moved types to `Tests/GrafttyRemoteClientTests` when they do not depend on UIKit:

- `ClientPairingSessionTests`
- `LocalPairingClientTests`
- `PinnedHostStoreTests`
- `PaneControlClientTests`
- `WorktreePanesStoreTests`
- tests for `TerminalSessionClient`'s stream protocol/conformance after moving `WebSocketClient`
- macOS-compilable SSH transport/channel tests

Leave UIKit/simulator-only tests in `GrafttyMobileKitTests`.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
swift test --filter GrafttyRemoteClientExportsTests
swift test --filter ClientPairingSessionTests
swift test --filter LocalPairingClientTests
swift test --filter PinnedHostStoreTests
swift test --filter PaneControlClientTests
swift test --filter WorktreePanesStoreTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/GrafttyRemoteClient Sources/GrafttyMobileKit Tests/GrafttyRemoteClientTests Tests/GrafttyMobileKitTests
git commit -m "refactor(remote): share client pairing and WebRTC stack"
```

---

## Task 6: Host Pairing Coordinator and Accept/Deny UI

**Files:**
- Create: `Sources/Graftty/Remote/MacToMac/HostPairingCoordinator.swift`
- Create: `Sources/Graftty/Views/RemotePairingRequestSheet.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Test: `Tests/GrafttyTests/HostPairingCoordinatorTests.swift`

- [ ] **Step 1: Write failing coordinator tests**

Cover:

- `begin` starts a host pairing session and exposes no prompt until client identity arrives.
- `introduce` transitions to a pending prompt with client display name and verification code.
- `confirm` stores a trusted peer and clears prompt.
- `deny` returns denied outcome and clears prompt.
- A second `begin` while active returns busy and does not call `HostPairingServer.start(validFor:)`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter HostPairingCoordinatorTests
```

Expected: compile failures.

- [ ] **Step 3: Implement coordinator**

`HostPairingCoordinator` wraps `PairingBeginCoordinator` and `HostPairingServer`. It provides route closures for `LANRemoteAccessRouteHandler` and exposes pending prompt state:

```swift
struct PendingRemotePairingRequest: Identifiable, Equatable {
    let id: RemotePairingNonce
    let clientDisplayName: String
    let verificationCode: RemoteVerificationCode
}
```

- [ ] **Step 4: Implement host prompt UI**

`RemotePairingRequestSheet` shows client display name, verification code, Accept, and Deny. Wire it from `MainWindow` or app-level state so the host has a clear consent moment.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
swift test --filter HostPairingCoordinatorTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty/Remote/MacToMac/HostPairingCoordinator.swift Sources/Graftty/Views/RemotePairingRequestSheet.swift Sources/Graftty/GrafttyApp.swift Sources/Graftty/Views/MainWindow.swift Tests/GrafttyTests/HostPairingCoordinatorTests.swift
git commit -m "feat(mac): add remote pairing consent prompt"
```

---

## Task 7: Mac App Remote Access Services Wiring

**Files:**
- Create: `Sources/Graftty/Remote/MacToMac/RemoteMacsModel.swift`
- Create: `Sources/Graftty/Remote/MacToMac/RemoteMacConnectionRegistry.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Test: `Tests/GrafttyTests/RemoteMacsModelTests.swift`

- [ ] **Step 1: Write failing model tests**

Cover:

- Saved remotes load from `RemoteMacStore`.
- Discovery candidate matching an existing remote updates state to `.discovered`.
- Connecting twice to the same `RemoteMac.id` returns/reuses one registry entry.
- Pairing success inserts a saved remote using `PinnedHost` from `GrafttyRemoteClient`; pairing denial does not.
- Phase-1 singleton host behavior maps a second concurrent inbound offer to structured busy.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter RemoteMacsModelTests
```

Expected: compile failures.

- [ ] **Step 3: Implement model and service wiring**

`RemoteMacsModel` owns `RemoteMacStore`, saved remotes, transient discovery candidates, connection state dictionary keyed by `RemoteDeviceID`, and actions for pairing/connect/disconnect.

`RemoteMacConnectionRegistry` owns one active `RemoteHostConnection` per `RemoteDeviceID`; repeated connect calls reuse an existing in-flight or connected entry.

Wire `LANRemoteAccessRouteHandler` to:

- `HostPairingCoordinator` for pairing routes.
- `WebRTCHostAgent.acceptOffer` for `/v1/rtc/offer`.
- Existing singleton host behavior for phase 1: second concurrent inbound offer returns structured busy instead of corrupting state.

Modify `GrafttyApp` to construct the model and start/stop the LAN listener/advertiser behind a local remote-access enabled condition. If no setting exists yet, add an internal default-on-for-dev flag in the model, not a full Settings UI.

Production listener binding must use a LAN-reachable bind host (`0.0.0.0` or Network-framework equivalent). Do not bind the app's real listener to `127.0.0.1`; localhost is only for tests. Bonjour must advertise the actual listener port after successful bind.

- [ ] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter RemoteMacsModelTests
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/Remote/MacToMac Sources/Graftty/GrafttyApp.swift Tests/GrafttyTests/RemoteMacsModelTests.swift
git commit -m "feat(mac): wire remote Mac service model"
```

---

## Task 8: Remote Macs Sidebar and Add Sheet

**Files:**
- Create: `Sources/Graftty/Views/RemoteMacsSection.swift`
- Create: `Sources/Graftty/Views/AddRemoteMacSheet.swift`
- Modify: `Sources/Graftty/Views/SidebarView.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Test: `Tests/GrafttyTests/RemoteMacsSidebarTests.swift`

- [x] **Step 1: Write failing sidebar/view-model tests**

Prefer pure helpers if SwiftUI inspection is unavailable:

- No saved remotes hides or collapses the section.
- Saved remotes produce rows separate from `AppState.repos`.
- Selecting `Add Remote Mac...` toggles sheet state.
- Discovered candidates do not appear in sidebar until saved.
- Selecting a discovered candidate starts pairing through `LocalPairingClient`.
- After introduce succeeds, the sheet shows the verification code and requires a client-side Confirm action before awaiting/storing trust.
- Cancelling at the client-side verification step stores no `PinnedHost` and creates no `RemoteMac`.
- Local-network permission denied/unavailable state explains recovery and keeps manual URL entry available.

- [x] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter RemoteMacsSidebarTests
```

Expected: compile failure or assertion failure.

- [x] **Step 3: Implement UI**

`RemoteMacsSection` renders saved remote rows only, connection state, and an `Add Remote Mac...` button.

`AddRemoteMacSheet` renders transient discovered candidates, manual URL field, Pair action for selected candidate, client-side verification-code confirmation, local-network permission recovery, and empty/loading/error states.

Do not call the full `LocalPairingClient.runPairing(payload:)` as a black box if that would skip client confirmation. Split the client flow so the sheet can:

1. Begin pairing and post introduce.
2. Build/display the `RemotePairingTranscript.verificationCode()`.
3. Wait for the user to press Confirm on the client.
4. Then await host outcome and persist the `PinnedHost` only if both sides confirmed.

Pairing success saves a `RemoteMac`; denial, cancellation, mismatch, or client-side cancel does not.

Keep visual style consistent with the existing sidebar: dense, quiet, native controls, no landing-page treatment.

- [x] **Step 4: Run tests and verify GREEN**

Run:

```bash
swift test --filter RemoteMacsSidebarTests
```

Expected: pass.

- [x] **Step 5: Commit**

```bash
git add Sources/Graftty/Views/RemoteMacsSection.swift Sources/Graftty/Views/AddRemoteMacSheet.swift Sources/Graftty/Views/SidebarView.swift Sources/Graftty/Views/MainWindow.swift Tests/GrafttyTests/RemoteMacsSidebarTests.swift
git commit -m "feat(mac): show saved remote Macs in sidebar"
```

---

## Task 9: Mac Client Panes, Control, and Terminal Attach

**Files:**
- Modify: `Sources/Graftty/Remote/MacToMac/RemoteMacConnectionRegistry.swift`
- Modify: `Sources/GrafttyHostAgent/WebRTCHostAgent.swift`
- Create if needed: `Sources/GrafttyHostAgent/Remote/ActiveRemotePeerRegistry.swift`
- Create: `Sources/Graftty/Remote/MacToMac/RemoteMacPaneEnvironment.swift`
- Modify: `Sources/Graftty/Views/RemoteMacsSection.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Test: `Tests/GrafttyTests/RemoteMacConnectionRegistryTests.swift`
- Test: `Tests/GrafttyTests/RemoteMacPaneEnvironmentTests.swift`
- Integration test: `Tests/GrafttyTests/RemoteMacConnectionLoopbackTests.swift`

- [ ] **Step 1: Write failing registry and pane environment tests**

Cover:

- Registry posts `SignalingOffer` to saved remote `lastKnownBaseURL`.
- Host busy maps to `.failed` with a user-visible reason.
- Repeated connect for same `RemoteDeviceID` reuses one in-flight connection task.
- Host key mismatch fails closed.
- Revoking a trusted peer on the host closes active inbound SSH/WebRTC sessions for that peer.
- A revoked peer cannot reconnect.
- Connected remote opens `panes-state@graftty.dev`.
- Connected remote opens `pane-control@graftty.dev`.
- Selecting a remote pane opens an SSH terminal session via `openTerminalSession(sessionName:)`.

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter RemoteMacConnectionRegistryTests
swift test --filter RemoteMacPaneEnvironmentTests
```

Expected: fail/compile fail.

- [ ] **Step 3: Implement Mac client connection**

Use `GrafttyRemoteClient.RemoteHostConnection`:

- Create offer.
- Exchange `/v1/rtc/offer` with `SignalingClient`.
- Apply answer and wait for DataChannel/SSH readiness.
- Open panes-state and pane-control channels.
- Open terminal session channels for selected remote pane leaves.
- On the host, register active inbound SSH/WebRTC sessions by authenticated remote peer identity so revocation can close them.

Pinned host validation must remain the gate before any terminal channel is treated as connected.

- [ ] **Step 4: Wire sidebar remote rows to live panes**

Remote Mac rows expand into `WorktreePanes` snapshots from the remote panes-state channel. Selecting a remote pane displays an interactive terminal backed by `TerminalSessionClient`.

Keep local `TerminalManager` ownership out of this path; remote terminal rendering should use existing remote terminal client abstractions or a thin Mac wrapper around the SSH terminal session stream.

- [ ] **Step 5: Run tests and verify GREEN**

Run:

```bash
swift test --filter RemoteMacConnectionRegistryTests
swift test --filter RemoteMacPaneEnvironmentTests
```

Expected: pass.

- [ ] **Step 6: Run loopback/end-to-end test**

Add or adapt a loopback test that exercises pairing/trust persistence, signaling, SSH authentication, panes-state channel, and terminal session open with echo/fake stream.

The loopback suite must also exercise revocation: after the host revokes the peer, the active SSH/WebRTC connection closes and a reconnect attempt fails authentication.

Run:

```bash
swift test --filter RemoteMacConnectionLoopbackTests
```

Expected: pass.

- [ ] **Step 7: Run broader focused tests**

Run:

```bash
swift test --filter HostPairingServerTests
swift test --filter GrafttyRemoteClientTests
swift test --filter GrafttyTests
```

If filter names do not match SwiftPM's generated names, run the specific test suites added in Tasks 1-9 plus `swift test --filter HostPairingServerTests`.

- [ ] **Step 8: Commit**

```bash
git add Sources/Graftty Sources/GrafttyKit Sources/GrafttyRemoteClient Tests/GrafttyTests Tests/GrafttyKitTests Tests/GrafttyRemoteClientTests
git commit -m "feat(mac): connect to saved remote Macs"
```

---

## Task 10: Specs, Info.plist, and Final Verification

**Files:**
- Modify: `scripts/bundle.sh`
- Modify: `Apps/GrafttyMobile/GrafttyMobile/Info.plist` only if mobile local-network declarations are touched.
- Modify: `SPECS.md`
- Add/modify spec inventory/tests under `Tests/GrafttyTests/Specs` if new `@spec` IDs are introduced.

- [ ] **Step 1: Add or update `@spec` tests/inventory**

Add EARS requirements for:

- Bonjour metadata contains no repo/worktree/session data.
- `Remote Macs` sidebar shows saved remotes only.
- Pairing begin refuses to silently replace an active session.
- LAN listener exposes only pairing/signaling routes.
- Host singleton phase-1 returns structured busy for concurrent inbound offers.
- Selecting a remote pane opens an SSH-over-WebRTC terminal session.
- Revoking a trusted remote Mac closes active sessions and blocks reconnect.

- [ ] **Step 2: Add macOS local-network plist keys to bundle script**

Modify `scripts/bundle.sh` Info.plist heredoc to include:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Graftty uses the local network to discover and connect to your other Macs.</string>
<key>NSBonjourServices</key>
<array>
  <string>_graftty._tcp</string>
</array>
```

- [ ] **Step 3: Run spec generation**

Run:

```bash
scripts/generate-specs.py
```

Expected: `SPECS.md` updates or remains unchanged if no `@spec` annotations were added.

- [ ] **Step 4: Run full verification**

Run:

```bash
swift test
scripts/generate-specs.py --check
git status --short
```

Expected: tests pass, specs check passes, only intentional files are modified.

- [ ] **Step 5: Run manual two-Mac verification**

On two physical Macs on the same LAN:

1. Launch Graftty on both Macs with local remote access enabled.
2. Confirm host advertises and client discovers it in `Add Remote Mac...`.
3. Pair with matching verification codes shown on both Macs.
4. Confirm host accept stores trust and client confirmation stores the saved `RemoteMac`.
5. Expand the saved remote Mac in the sidebar.
6. Select a remote pane and verify an interactive terminal opens.
7. Quit/relaunch the client Mac app and reconnect using pinned trust without re-pairing.
8. Revoke the peer on the host and verify the active connection closes and reconnect fails.

- [ ] **Step 6: Commit**

```bash
git add SPECS.md Tests Sources Apps Package.swift scripts/bundle.sh
git commit -m "test(remote): cover Mac-to-Mac remote Macs"
```

Skip the commit if Task 10 only verifies and produces no file changes.

---

## Subagent Execution Notes

- Dispatch tasks sequentially. Do not run implementation subagents in parallel because many tasks share package targets and macOS app wiring.
- Each implementer must follow TDD: write failing tests, run them, implement, rerun.
- Each implementer must commit its task.
- After each implementation task:
  - Run a spec-compliance reviewer against the task and design spec.
  - Run a code-quality reviewer after spec compliance passes.
- This plan implements the full approved spec. Do not stop at signaling-only scaffolding unless you report BLOCKED and return control to the coordinator.
