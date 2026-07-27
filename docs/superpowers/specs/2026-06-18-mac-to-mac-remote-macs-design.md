# Mac-to-Mac Remote Macs

**Status:** Approved, 2026-06-18
**Depends on:** [`2026-05-21-ssh-over-webrtc-design.md`](2026-05-21-ssh-over-webrtc-design.md), [`2026-05-27-ssh-over-webrtc-phase-4-design.md`](2026-05-27-ssh-over-webrtc-phase-4-design.md)

## 1. Purpose and scope

Add Mac-to-Mac Graftty connectivity so one Mac can discover, pair with, and connect to another Mac's existing Graftty sessions over the current WebRTC + SSH transport.

The user-facing model is explicit saved connections, not ambient sidebar noise. Nearby Macs may appear in an "Add Remote Mac..." flow, but the main macOS sidebar only shows remote Macs after the user pairs/adds them.

This design covers:

- Local-network discovery.
- Pairing and trust establishment.
- Persisted remote Mac identity.
- A separate `Remote Macs` sidebar section.
- Mac-side client reuse of the existing SSH-over-WebRTC channel model.

## 2. Non-goals

- Replacing WebRTC or SSH. Terminal, panes-state, and pane-control traffic continue to use the existing `WebRTC DataChannel -> SSH -> channel` stack.
- Using AirDrop as a discovery substrate. Public AirDrop API is a sharing service, not a peer enumeration and connection-address API.
- Making remote worktrees indistinguishable from local repositories. Remote worktrees do not have local paths, local git watchers, local PR polling, or local delete semantics.
- Cloud-routed discovery. This design is local-network first.
- A new remote desktop or screen-sharing capability.

## 3. Decisions summary

| Decision | Choice | Rationale |
|---|---|---|
| Discovery substrate | Bonjour via Network/Foundation APIs | Apple-supported service advertisement and browsing for local networks; simpler than adding Multipeer Connectivity beside WebRTC |
| Service type | `_graftty._tcp` | App-specific service type, declared in `NSBonjourServices` where required |
| AirDrop | Do not use | Public API supports sending items through the share UI, not listing nearby Macs for app-controlled connections |
| LAN endpoint | Add a dedicated local remote-access listener | Do not broaden the existing Tailscale-authenticated web server for unauthenticated LAN discovery/pairing |
| Sidebar visibility | Saved/paired Macs only | Prevents mDNS churn from making the sidebar noisy or unstable |
| Sidebar placement | Separate `Remote Macs` section | Avoids coupling remote entries to local repo/path/git assumptions |
| Pairing | Client selects discovered Mac; host accepts/denies; both sides verify a short code | Discovery is unauthenticated; trust is explicit and human-confirmed |
| Key material | Exchange public identity keys, never reusable shared secrets | Aligns with existing SSH host/user public-key authentication |
| Durable identity key | `RemoteDeviceID` plus host public-key fingerprint | URLs, Bonjour names, and IPs can change |
| Client stack | Promote/share existing mobile client primitives where practical | The client transport is not inherently UIKit-specific |

## 4. Discovery

### 4.1 Host advertisement

Every Mac running Graftty and allowing local remote access advertises a Bonjour service. Advertisement is conditional on the host-side remote access service being enabled, a LAN remote-access listener being available, and host identity loading successfully.

- Type: `_graftty._tcp`
- Domain: `local.`
- Port: the dedicated LAN remote-access listener port
- Name: user-visible device label, disambiguated by Bonjour when needed

TXT records carry non-secret routing and compatibility metadata:

| Key | Meaning |
|---|---|
| `version` | Discovery schema version |
| `deviceID` | Stable `RemoteDeviceID` for self-filtering and dedupe |
| `fingerprint` | Host public-key fingerprint in full canonical string form |
| `name` | Display name hint |
| `proto` | Minimum/maximum supported remote protocol version |
| `pairing` | `required` or `paired-only` |

No repository names, worktree paths, shell state, user names, or session names are advertised.

### 4.2 LAN remote-access listener

Bonjour advertises a dedicated LAN listener, not the existing web access server.

The current `WebServerController` is Tailscale-oriented: it binds to Tailscale addresses, provisions HTTPS certificates from Tailscale, and authorizes requests with Tailscale `whois`. Mac-to-Mac local discovery needs a different surface:

- LAN-reachable from peers on the same local network.
- Small route set: pairing bootstrap, pairing introduce/await-outcome, and WebRTC offer exchange.
- No repository/worktree management routes.
- No static web app or `/ws` terminal fallback.
- Security based on explicit pairing, public-key transcript verification, pinned host keys, SSH userauth, and channel authorization.
- Basic rate limiting or busy backoff on pairing and RTC offer routes, so an unpaired LAN peer cannot cheaply keep the host unavailable.

The LAN listener may be implemented as a separate server type or a narrowly configured `WebServer` variant, but the implementation must not accidentally expose the broader Tailscale web UI/API to the local network.

### 4.3 Client browsing

The macOS app adds an "Add Remote Mac..." flow. Opening it starts browsing for `_graftty._tcp` services and renders a transient list of candidates.

The browser filters out:

- The current device's own `deviceID`.
- Duplicate results for the same `deviceID` or fingerprint, preferring the newest resolved endpoint.
- Protocol-incompatible candidates.

The discovery sheet also provides manual entry for networks where mDNS is blocked or disabled.

### 4.4 Local network permissions

Where the target platform requires local-network privacy declarations, the app declares:

- `NSLocalNetworkUsageDescription`
- `NSBonjourServices` including `_graftty._tcp`

The UX should explain discovery before starting the browser so any OS permission prompt has clear context.

## 5. Pairing and trust

Discovery is not trust. A discovered Mac is only a network candidate until pairing succeeds.

### 5.1 Pairing sequence

```
Client Mac                                      Host Mac
    |                                              |
    | browse _graftty._tcp                         |
    | resolve service -> base URL                  |
    |                                              |
    | POST /v1/pairing/begin --------------------->| start HostPairingServer session
    |<------------- PairingPayload ----------------| includes nonce + pairingURL
    |                                              |
    | POST pairing introduce with client pubkey -->|
    |                                              | show "MacBook wants to connect"
    |                                              | show verification code
    | show same verification code                  |
    |                                              |
    | user confirms client side                    |
    |                                              | user accepts host side
    |<------------- pairing confirmed -------------|
    |                                              |
    | store PinnedHost                             | store TrustedPeer
```

The new bootstrap route is `POST /v1/pairing/begin`. It runs on the LAN remote-access listener and calls `HostPairingServer.start(validFor:)` to mint the nonce-backed `PairingPayload`. The response gives the client the same inputs a QR scan would have provided: host identity, expiry, nonce, and `pairingURL`.

The QR-code decoder's existing HTTPS-only guard remains correct for QR/manual pairing payloads. The Bonjour-discovered Mac path does not need to route through QR decoding; it may accept the LAN listener's URL scheme from the trusted in-process `begin` response, because the path stores no trust until the verification code matches and the host accepts. If the implementation chooses HTTPS for the LAN listener, it must define certificate handling explicitly rather than relying on the Tailscale certificate path.

After `begin`, the client uses the existing pairing request shapes:

- `POST <pairingURL>/introduce` with `PairingIntroduceRequest`
- `POST <pairingURL>/await-outcome` with `PairingAwaitOutcomeRequest`

This preserves the current `HostPairingServer` invariant that `introduce` must carry the nonce from an active host-side pairing session. It also avoids putting long-lived or reusable pairing tokens in Bonjour TXT records.

If an existing QR/manual pairing session is active, the Mac-to-Mac `begin` route must not silently cancel it. The implementation must perform a busy check before calling `HostPairingServer.start(validFor:)`, because that method cancels active waiters today. It should either reject `begin` with a structured busy response or route all pairing starts through one host-visible coordinator that makes replacement explicit.

The LAN pairing bootstrap may be unauthenticated because it exchanges only public identity material and no trust is stored until both sides verify the transcript and the host accepts. The user-visible verification code is mandatory for this path.

### 5.2 Stored trust

On the host:

- Store the client public key in `TrustedPeerStore`.
- Associate default capabilities with the trusted peer.
- Revocation removes the peer and closes active SSH connections for that peer.

On the client:

- Store the host public key in `PinnedHostStore`.
- Persist the saved remote Mac entry in a remote-host store.
- Future SSH KEX must match the pinned host key or fail closed.

The pairing process exchanges public identity keys. It must not create or store a reusable shared secret.

## 6. Persistence model

Mac-to-Mac needs a saved remote-host model analogous to mobile `Host`, but not UIKit-gated and not keyed by URL alone.

Suggested shape:

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
```

Important invariants:

- `RemoteDeviceID` and fingerprint identify the Mac.
- URL and Bonjour service name are mutable endpoint hints.
- Rediscovery refreshes `lastKnownBaseURL` and `lastDiscoveredAt`.
- Adding a Mac with an already-pinned identity updates the existing record rather than inserting a duplicate.

The existing mobile `Host` / `HostStore` can either be promoted into shared code with a more general name or left as an iOS adapter over a shared store. The shared model should remain file-backed for non-secret metadata. Private keys and pinned/trusted public-key trust stores stay in their existing identity stores.

## 7. Sidebar and navigation

The macOS sidebar gains a top-level `Remote Macs` section below or near the local repository section.

Rules:

- Only saved remote Macs appear.
- The section is hidden or collapsed when there are no saved remote Macs.
- A row-level `Add Remote Mac...` action opens the discovery sheet.
- Remote Mac rows show connection state: offline, discovered, connecting, connected, failed, or needs pairing.
- Expanding a connected remote Mac shows remote worktrees and pane leaves from `panes-state@graftty.dev`.
- Selecting a remote pane opens a terminal backed by `RemoteHostConnection.openTerminalSession(sessionName:)`.
- Pane actions that map to `pane-control@graftty.dev` are enabled according to the peer's capabilities.

Remote worktrees should be visually related to local worktrees but not reuse local path semantics. They should not participate in:

- Local repository add/remove.
- Local worktree deletion.
- Local git watchers.
- Local PR polling keyed by path.
- Local `TerminalManager` surface ownership.

This separation is the main reason `Remote Macs` is a distinct sidebar section rather than an extension of `AppState.repos`.

## 8. Connection lifecycle and cardinality

The sidebar may persist many remote Macs, but it should not eagerly connect to all of them at launch. Connections are on demand:

- Browsing/pairing creates or updates saved `RemoteMac` records.
- Expanding a remote Mac or selecting one of its cached rows starts connection if needed.
- A connected remote Mac owns one `RemoteHostConnection` client instance.
- Collapsing a remote Mac may keep the connection warm briefly; app quit, explicit disconnect, trust failure, or sustained idle closes it.
- Reconnect rebuilds the WebRTC peer connection, DataChannel, SSH transport, and SSH channels from pinned identity.

Client-side cardinality is one active `RemoteHostConnection` per connected saved remote Mac. This lets a user keep two remote Macs expanded without overloading a single connection object with unrelated peer state.

Host-side cardinality needs an implementation decision because the current `WebRTCHostAgent` is singleton-shaped and rejects concurrent offers while busy. Mac-to-Mac support should not bake that singleton into the product model. The implementation plan should either:

1. Introduce a host connection manager that creates one WebRTC/SSH server session per accepted peer, sharing `TrustedPeerStore`, stream factories, panes-state subscription, and pane-control mutation closures; or
2. Declare an explicit phase-1 limit of one active inbound remote peer per host, surface "busy" clearly to additional clients, and keep the code shaped so a manager can replace the singleton later.

The preferred direction is option 1 if it stays tractable. Option 2 is acceptable only as a deliberately scoped first increment, not as a protocol limitation.

## 9. Transport and module shape

The host side already exists on macOS:

- `WebRTCHostAgent`
- `HostIdentityStore`
- `TrustedPeerStore`
- `ZmxAttachStream`
- SSH channel handlers for terminal, panes-state, and pane-control

The missing Mac-to-Mac piece is a macOS client role. The existing client implementation currently lives in UIKit-gated mobile code:

- `ClientIdentityStore`
- `PinnedHostStore`
- `RemoteHostConnection`
- `SignalingClient`
- `SSHNIOTransport`
- `SSHClientSetup`
- SSH channel clients
- `Host` / `HostStore`

The implementation should promote or split these into shared targets where practical. The goal is one client transport model used by both iPad and Mac, with platform-specific UI layered on top.

Possible target shape:

| Target | Responsibility |
|---|---|
| `GrafttyProtocol` | Shared wire/data types |
| `GrafttyKit` or new shared remote target | Remote host persistence, client identity, pinned hosts, signaling client abstractions that do not require UIKit |
| `GrafttyMobileKit` | iOS/iPad UI and adapters |
| `Graftty` | macOS UI, sidebar, discovery sheet, remote Mac connection orchestration |
| `GrafttyHostAgent` | Mac host-side WebRTC/SSH server |

If WebRTC package availability makes a fully shared client target awkward, the implementation may duplicate a thin macOS client wrapper initially, but the protocol and persistence types should still be shared to avoid divergent trust models.

## 10. Error handling

| Failure | Behavior |
|---|---|
| Bonjour browse denied or unavailable | Discovery sheet shows a local-network access/manual-entry recovery path |
| Candidate fails resolve | Keep it transient; do not save |
| Host rejects pairing | Client reports denial; no remote Mac row is created |
| Host pairing already active | Client reports host busy; no active nonce is replaced silently |
| Verification code mismatch | Abort pairing; store no trust material |
| Host key mismatch after pairing | Fail closed and mark saved Mac as trust error until user repairs/removes it |
| WebRTC/ICE failure | Mark remote Mac failed/offline; allow retry |
| SSH userauth failure | Mark needs pairing or revoked depending on response/context |
| Remote panes-state channel closes | Keep saved Mac; collapse or stale-mark remote worktree rows |
| Host reports busy | Surface as "host already has an active remote connection" for phase-1 singleton hosts; retry remains available |

## 11. Testing strategy

Unit tests:

- Bonjour TXT record encode/decode rejects missing identity fields and ignores unknown keys.
- Discovery browser dedupes by device ID/fingerprint and filters self.
- Remote host store persists, dedupes by identity, and updates mutable endpoint fields.
- Pairing transcript verification code is stable across Mac-to-Mac flow and matches existing pairing semantics.
- `POST /v1/pairing/begin` starts a host pairing session and returns a payload whose nonce is accepted by `introduce`.
- `POST /v1/pairing/begin` rejects or explicitly coordinates replacement when another pairing session is active.
- Sidebar model keeps remote Macs separate from `AppState.repos`.
- Remote connection registry creates at most one active client connection per saved remote Mac.

Integration tests:

- LAN remote-access listener exposes only pairing and RTC offer routes, not local repo/worktree management or static web UI routes.
- Loopback Mac client -> `WebRTCHostAgent` over `POST /v1/rtc/offer` opens SSH terminal and panes-state/control channels.
- Revoked peer cannot reconnect and active connection closes.
- Host key mismatch fails before channel opens.
- If the host remains singleton in phase 1, a second concurrent offer receives a structured busy response and does not corrupt the active connection.

Manual gate:

- Two physical Macs on the same LAN.
- Host advertises.
- Client discovers host.
- Pairing requires host accept and matching verification code.
- Saved remote Mac appears in `Remote Macs`.
- Selecting a remote pane opens an interactive terminal.
- Quitting/relaunching preserves the saved remote Mac and reconnects using pinned trust.

## 12. Risks and holes to watch

1. **Bonjour availability is not universal.** Corporate networks may block mDNS. Manual URL entry remains required.
2. **Local-network permission UX can be inconsistent.** Start discovery from an explicit user action and provide recovery text.
3. **Both Macs are both hosts and clients.** Self-filter by stable `RemoteDeviceID`; dedupe by identity, not URL.
4. **Remote rows can accidentally inherit local behavior.** Keep the remote sidebar model separate from `AppState.repos`.
5. **Target split can get messy.** Treat the UIKit gates as accidental placement, not proof that the client stack is mobile-only.
6. **Discovery metadata can become tempting.** Keep Bonjour TXT records non-sensitive and small.
7. **Host concurrency can leak through abstraction boundaries.** Do not let a singleton `WebRTCHostAgent` force the sidebar or protocol to assume only one remote peer forever.

## 13. References

- Apple Bonjour documentation: https://developer.apple.com/documentation/foundation/bonjour
- Apple Multipeer Connectivity documentation: https://developer.apple.com/documentation/multipeerconnectivity
- Apple AirDrop sharing service documentation: https://developer.apple.com/documentation/appkit/nssharingservice/name/sendviaairdrop
- Apple `NSBonjourServices` documentation: https://developer.apple.com/documentation/bundleresources/information-property-list/nsbonjourservices
