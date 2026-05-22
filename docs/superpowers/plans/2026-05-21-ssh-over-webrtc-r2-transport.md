# SSH-over-WebRTC R2 — `swift-nio-ssh` Integration + `SSHNIOTransport` Adapter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `apple/swift-nio-ssh` as a dependency, implement the `SSHNIOTransport` adapter that bridges a WebRTC `RTCDataChannel` (message-stream API) into a swift-nio `Channel` (byte-stream API), and prove end-to-end that `NIOSSHClient` and `NIOSSHServer` can run an SSH session over a paired `RTCDataChannel` via a single loopback test.

**Architecture:** R2 is the **architecture decision gate** of the 6-PR SSH-over-WebRTC rollout. Per `docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md` §11.1, if `SSHNIOTransport` does not adapt cleanly to message-stream `RTCDataChannel`, the entire architectural approach is in question. R2 must demonstrate a clean `exec ls` round-trip over loopback before R3 commits to wiring SSH into production code paths. R2 does NOT modify any production wiring; `RemoteHostConnection`, `WebRTCHostAgent`, and `ChannelRouter` are untouched. The new code sits in the tree, validated only by the loopback test, until R3+ rewires `RemoteHostConnection`.

**Tech Stack:** Swift, `apple/swift-nio-ssh` (Apache 2.0, ~0.13.0), `apple/swift-nio` (already a dep), `stasel/WebRTC` (already a dep), Swift Testing.

---

## File Structure

**Modify:**
- `Package.swift` — add `apple/swift-nio-ssh` as a SwiftPM dependency; add product deps to `GrafttyHostAgent` and `GrafttyMobileKit` targets

**Create:**
- `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift` — Mac-side adapter
- `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift` — mobile-side mirror (same shape, `#if canImport(UIKit)`-guarded)
- `Tests/GrafttyMobileKitTests/Remote/SSH/SSHOverWebRTCLoopbackTests.swift` — the gate test, mirrors the existing `RemoteHostConnectionLoopbackTests.swift` pattern but with NIOSSHClient on one side and NIOSSHServer on the other

**Test files unchanged but worth noting:** `Tests/GrafttyMobileKitTests/Remote/RemoteHostConnectionLoopbackTests.swift` exists and demonstrates the in-process paired-`RTCPeerConnection` pattern. The new loopback test reuses this pattern (paired connections, in-process SDP+ICE swap) and adds SSH on top of the established DataChannel.

**Files NOT modified in this PR:**
- `Sources/GrafttyMobileKit/Remote/RemoteHostConnection.swift` — stays as-is; not rewired to SSH until R4
- `Sources/GrafttyHostAgent/WebRTCHostAgent.swift` — stays as-is; not rewired until R4
- Any `ChannelRouter*` files — deleted in R6, kept alive until then
- Any production app code

---

## Important Context for the Implementer

### Why this PR is unusual

R1 was a straightforward TDD migration. **R2 is a spike-shaped PR**: the adapter design depends on choices about `swift-nio-ssh`'s API surface that nobody on this codebase has verified yet. The implementer is expected to:
- Read swift-nio-ssh's documentation and source examples
- Choose a viable NIO Channel pattern (options below)
- Iterate until the loopback test passes

**Acceptance criterion:** the loopback test in Task 3 demonstrates a clean `exec ls` SSH session round-trip over paired `RTCDataChannel`s. If the test passes, the adapter design is validated. If it doesn't pass after reasonable effort, escalate as BLOCKED — that triggers a design revisit per the design doc §11.1.

### NIO Channel patterns to consider (pick one)

`swift-nio-ssh`'s `NIOSSHHandler` is a `ChannelHandler` added to a NIO `ChannelPipeline`. The pipeline's underlying transport is a `Channel`. Options for backing that Channel with an `RTCDataChannel`:

**Option A — `NIOAsyncChannel` wrapping a `Channel`:**
The high-level async wrapper introduced in swift-nio 2.x. Cleanest async API, but still needs an underlying `Channel` that NIO can drive. Likely combines with one of the patterns below.

**Option B — `EmbeddedChannel` + manual pump (recommended starting point):**
- Use `EmbeddedChannel` (or `NIOAsyncTestingChannel`) as the underlying `Channel` that hosts the SSH pipeline
- Build a small pump task that ferries bytes both directions:
  - **NIO → DataChannel:** poll `embeddedChannel.readOutbound(as: ByteBuffer.self)` on each tick (or after each NIO event), serialize each `ByteBuffer` to `Data`, send via `RTCDataChannel.sendData(buffer: RTCDataBuffer(data: data, isBinary: true))`. If a single `ByteBuffer` exceeds the SCTP message size cap (~16KB safe), split into multiple `sendData` calls in order.
  - **DataChannel → NIO:** in the `dataChannel(_: didReceiveMessageWith:)` callback, call `embeddedChannel.writeInbound(ByteBuffer(data: buffer.data))`.
- The `EmbeddedChannel`'s `EventLoop` is a `EmbeddedEventLoop` you control; ensure all NIO interactions happen on it.

**Option C — Custom `Channel` implementation:**
Implement the full `Channel` protocol wrapping `RTCDataChannel` directly. Complex (Channel has many requirements) but avoids the pump indirection. Not recommended for the first cut.

**Default to Option B** unless you have a specific reason to deviate. It's the pragmatic "transport adapter" pattern and is well-supported by NIO's documentation.

### Concurrency concerns

`RTCDataChannel`'s delegate callbacks fire on WebRTC's own serial queue. `EmbeddedChannel` operations must happen on its `EmbeddedEventLoop`. Bridging these two requires:
- All `embeddedChannel.writeInbound(_:)` / `writeOutbound(_:)` / `pipeline.fireChannelRead(_:)` calls must hop to the embedded event loop (e.g. `eventLoop.execute { ... }` or `eventLoop.submit { ... }.wait()`).
- The buffering between WebRTC's queue and NIO's event loop must be ordered (FIFO).

### swift-nio-ssh server-side `exec` handler

The loopback test needs a server-side delegate that responds to client `exec` requests. swift-nio-ssh exposes `NIOSSHServerUserAuthenticationDelegate` for userauth and channel-type handlers for sessions. For the test:
- Configure the server to accept any publickey userauth (this is a transport test, not an auth test — auth comes in R3).
- Install a session channel handler that, on receiving an `exec` channel request, writes a fixed string (e.g., `"loopback-exec-ok\n"`) to the channel and closes it.

The client side opens a session channel, sends `exec ls`, reads the response, and asserts the response matches.

---

## Task 1: Add `swift-nio-ssh` dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the dependency**

Edit `Package.swift`. In the `dependencies:` array (currently at lines 32-40), add a line for swift-nio-ssh **after** the existing swift-nio entry to keep dependencies grouped:

```swift
.package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.13.0"),
```

The full `dependencies:` block should become:

```swift
dependencies: [
    .package(url: "https://github.com/btucker/libghostty-spm.git", branch: "expose-selection-api"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.13.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    .package(url: "https://github.com/stencilproject/Stencil.git", from: "0.15.1"),
    .package(url: "https://github.com/stasel/WebRTC.git", from: "137.0.0"),
],
```

- [ ] **Step 2: Add the product dep to `GrafttyHostAgent` target**

In the `GrafttyHostAgent` target block (currently at lines 66-73), add the NIOSSH product. The block should become:

```swift
.target(
    name: "GrafttyHostAgent",
    dependencies: [
        "GrafttyProtocol",
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "WebRTC", package: "WebRTC"),
    ],
    swiftSettings: strictWarnings
),
```

- [ ] **Step 3: Add the product dep to `GrafttyMobileKit` target**

In the `GrafttyMobileKit` target block (currently at lines 121-129), add `NIO` and `NIOSSH`. The block should become:

```swift
.target(
    name: "GrafttyMobileKit",
    dependencies: [
        "GrafttyProtocol",
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "GhosttyTerminal", package: "libghostty-spm"),
        .product(name: "WebRTC", package: "WebRTC"),
    ],
    swiftSettings: strictWarnings
),
```

- [ ] **Step 4: Resolve and build to confirm the dependency resolves cleanly**

Run: `swift package resolve`
Expected: zero exit, `Package.resolved` updated to include `swift-nio-ssh`.

Run: `swift build`
Expected: clean build, no warnings. (If the build fails, diagnose — most likely a version conflict between swift-nio versions. The dep on `swift-nio` from `2.65.0` should be compatible with swift-nio-ssh `0.13.0`.)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "$(cat <<'EOF'
build(remote): add swift-nio-ssh dependency for R2

R2 of the SSH-over-WebRTC rollout. swift-nio-ssh provides the SSH
session implementation that will run inside the existing WebRTC
DataChannel transport. Pinned to from: "0.13.0" — Apple-maintained,
Apache-2.0, used in Apple's own infrastructure.

Added to GrafttyHostAgent (server side) and GrafttyMobileKit (client
side); deliberately NOT added to GrafttyKit to keep graftty-cli out of
the SSH dependency tree, matching how PR #176 placed WebRTC.

No production wiring yet — that lands in R3-R6.

See docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md §5.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Implement `SSHNIOTransport` on both sides

**Files:**
- Create: `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift`
- Create: `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift`

This task creates the adapter between `RTCDataChannel` (message-stream API with delegate callbacks) and a swift-nio `Channel` (byte-stream API with `EventLoop`-driven I/O). The two files are intentionally mirrored — same shape, same API, just different module placement (the Mac-side lives in `GrafttyHostAgent` so `graftty-cli` doesn't transitively link it; the mobile-side lives in `GrafttyMobileKit` with the existing `#if canImport(UIKit)` guard convention).

**Default approach: Option B from the Important Context section above** (EmbeddedChannel + manual pump). Deviate only if you discover during implementation that this doesn't compose cleanly with swift-nio-ssh.

- [ ] **Step 1: Create the directories**

Run:
```bash
mkdir -p Sources/GrafttyHostAgent/SSH
mkdir -p Sources/GrafttyMobileKit/Remote/SSH
```

- [ ] **Step 2: Implement the Mac-side adapter**

Create `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift`. The minimum API you must provide:

```swift
import Foundation
import NIO
import NIOEmbedded
import WebRTC

/// Adapter that lets `swift-nio-ssh` run an SSH session over a WebRTC
/// `RTCDataChannel`. NIO speaks byte-stream `Channel` semantics; an
/// `RTCDataChannel` delivers discrete messages. This adapter ferries
/// `ByteBuffer`s outbound (NIO → DataChannel.send) and inbound
/// (DataChannel.onMessage → ByteBuffer → NIO pipeline) such that the
/// SSH state machine sees a continuous byte stream.
///
/// Both sides of an SSH session (server and client) instantiate one of
/// these against their respective `RTCDataChannel`. The instance owns
/// the embedded `Channel` that the SSH pipeline is installed into.
public final class SSHNIOTransport: @unchecked Sendable {
    // Implementation here. At minimum, expose:
    //   - init(dataChannel: RTCDataChannel) — captures the data channel,
    //     installs the WebRTC delegate that feeds DataChannel.onMessage
    //     into the embedded channel's inbound stream
    //   - var channel: Channel — the NIO Channel that the SSH pipeline
    //     gets installed into (likely an EmbeddedChannel or
    //     NIOAsyncTestingChannel)
    //   - var eventLoop: EventLoop — convenience accessor
    //   - func start() async throws — fires `channel.connect` /
    //     `pipeline.fireChannelActive()` after the DataChannel is open
    //   - func close() async — flushes pending outbound, fires
    //     channelInactive, and tears down
}
```

**Implementation hints (not prescribed code — pick the version that compiles and tests cleanly):**

- Use `EmbeddedChannel` (or `NIOAsyncTestingChannel` from `NIOEmbedded`) as the underlying channel. Both are designed for "non-network" Channels and let you drive I/O manually.
- Hold a reference to the `RTCDataChannel`. Install a `RTCDataChannelDelegate` that calls `channel.writeInbound(_:)` whenever a binary message arrives. Hop to the embedded event loop for the call.
- For outbound: after each `pipeline.fireChannelRead(_:)` or `writeOutbound(_:)`, poll `channel.readOutbound(as: ByteBuffer.self)` until it returns nil; for each `ByteBuffer`, convert to `Data` and send via `dataChannel.sendData(_:)` wrapping in `RTCDataBuffer(data: data, isBinary: true)`. If a single buffer exceeds 16 KB, split it into multiple sends.
- Wire the `EmbeddedEventLoop` so swift-nio-ssh's `NIOSSHHandler` can be installed via `channel.pipeline.addHandler(_:)`.
- Keep the inbound and outbound paths serialized via the event loop to preserve ordering.

**The exact implementation will require some swift-nio-ssh experimentation.** Read the swift-nio-ssh README at <https://github.com/apple/swift-nio-ssh> and look at its `Examples/` directory for the canonical client and server setup patterns.

- [ ] **Step 3: Implement the mobile-side mirror**

Create `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift`. Same public API and shape as the Mac-side file. Wrap the entire file in `#if canImport(UIKit) ... #endif` to match the existing iOS-only convention used by sibling files like `RemoteHostConnection.swift` and `ClientIdentityStore.swift`.

The two files will be near-duplicates. That's deliberate (the existing `ChannelRouter` mirroring is the precedent); a shared abstraction is post-R2 work. If the two files diverge in non-cosmetic ways, that's a smell — flag it as a concern.

- [ ] **Step 4: `swift build` to confirm both modules compile**

Run: `swift build`
Expected: clean build with no warnings. If swift-nio-ssh API surface differences cause compile errors, adjust based on the error messages. Read the swift-nio-ssh source if needed (it's pure Swift).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyHostAgent/SSH Sources/GrafttyMobileKit/Remote/SSH
git commit -m "$(cat <<'EOF'
feat(remote): SSHNIOTransport adapter — RTCDataChannel <-> NIO Channel

Mirrored on both sides (GrafttyHostAgent + GrafttyMobileKit). The
adapter ferries bytes between WebRTC's message-stream API and NIO's
byte-stream Channel API so swift-nio-ssh's NIOSSHHandler can run on
top of an RTCDataChannel.

No production code references the adapter yet; it's validated only by
the R2 loopback test (next commit). The R2 gate per the design doc
§11.1 is the loopback exec round-trip — if that fails, this adapter
design is wrong and the rollout needs to revisit.

See docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md §10.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Loopback test — SSH `exec` round-trip over paired `RTCDataChannel`s

**Files:**
- Create: `Tests/GrafttyMobileKitTests/Remote/SSH/SSHOverWebRTCLoopbackTests.swift`

This is the R2 acceptance gate. The test pairs two `RTCPeerConnection`s in-process (using the same SDP+ICE swap pattern as the existing `RemoteHostConnectionLoopbackTests.swift`), wraps each side's `RTCDataChannel` in an `SSHNIOTransport`, and runs an SSH session over the result.

**Reference for the existing pattern:** `Tests/GrafttyMobileKitTests/Remote/RemoteHostConnectionLoopbackTests.swift` (lines 1-120 contain the offerer/answerer setup and the ICE candidate plumbing). Reuse that scaffolding directly — the new test just adds an SSH layer on top.

- [ ] **Step 1: Write the loopback test skeleton**

Create `Tests/GrafttyMobileKitTests/Remote/SSH/SSHOverWebRTCLoopbackTests.swift`. Start with this scaffold:

```swift
#if canImport(UIKit)
import Foundation
import NIO
import NIOSSH
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// R2 architecture decision gate. Pairs two `RTCPeerConnection`s in-process,
/// wraps each side's `RTCDataChannel` in an `SSHNIOTransport`, installs
/// `NIOSSHHandler` on each end (client + server), and verifies that an
/// `exec` SSH session round-trips a fixed response.
///
/// Per the SSH-over-WebRTC design doc §11.1, R2 must pass this test before
/// R3 commits to wiring SSH into production code paths.
@Suite("SSH-over-WebRTC loopback — exec round-trip (R2 gate)")
struct SSHOverWebRTCLoopbackTests {

    @Test
    func execRoundTripOverPairedDataChannels() async throws {
        // 1. Pair two RTCPeerConnections, exchange SDP + ICE in-process.
        //    Reuse the offerer/answerer pattern from
        //    RemoteHostConnectionLoopbackTests.swift.
        //
        // 2. Once both RTCDataChannels report .open, wrap each one in an
        //    SSHNIOTransport.
        //
        // 3. On the answerer side: install NIOSSHHandler in server mode
        //    with a delegate that:
        //      - accepts any publickey userauth
        //      - on receiving a session channel + "exec" request,
        //        writes "loopback-exec-ok\n" to the channel and closes it
        //
        // 4. On the offerer side: install NIOSSHHandler in client mode
        //    with a server-host-key verification delegate that accepts
        //    any host key (auth specifics are R3, not R2)
        //
        // 5. Client opens an SSH session channel, sends an "exec ls"
        //    channel request, reads back from the channel.
        //
        // 6. Assert that the response equals "loopback-exec-ok\n" within
        //    a 10-second window. If it does, the R2 gate passes.

        // ... fill in implementation
    }
}
#endif
```

The skeleton intentionally describes the test in comments rather than fleshing out the body — the implementation is the substance of this task and requires figuring out swift-nio-ssh's API surface during implementation. You may also factor helpers into private types within the file (e.g., `LoopbackSSHServer`, `LoopbackSSHClient` actors that wrap each side's setup) following the `TestAnswerer` pattern from the existing M1.1 loopback test.

- [ ] **Step 2: Implement the test body**

Fill in the test. Specifically:

**2a. Reuse the SDP/ICE pairing pattern:**

The existing `RemoteHostConnectionLoopbackTests.swift` shows the pattern: `RemoteHostConnection` is the offerer (mobile), and a private `TestAnswerer` actor implements the answerer in-test. For R2, the same pattern works — but you may want to factor the answerer into a more generic helper since you'll also use it for `SSHOverWebRTCLoopbackTests`. Either:

- Copy the `TestAnswerer` implementation into the new test file (~50 lines, easy duplication), OR
- Extract a shared `RTCLoopbackPair` helper that produces an opened (offerer DataChannel, answerer DataChannel) pair. If you extract, put it under `Tests/GrafttyMobileKitTests/Remote/` and not in production code.

The simpler path is to copy. Don't over-engineer the helper.

**2b. SSH server-side setup:**

Once you have both DataChannels open, wrap the answerer's in an `SSHNIOTransport` and install a `NIOSSHHandler` in server mode. swift-nio-ssh's server setup typically looks like:

```swift
let serverConfig = SSHServerConfiguration(
    hostKeys: [/* an Ed25519 host key, generated in-test */],
    userAuthDelegate: AcceptAnyUserAuthDelegate(),
    globalRequestDelegate: nil
)
let sshHandler = NIOSSHHandler(role: .server(serverConfig), allocator: transport.channel.allocator, inboundChildChannelInitializer: { childChannel, channelType in
    // Install a session channel handler that responds to exec
    return childChannel.pipeline.addHandler(LoopbackExecResponder())
})
try await transport.channel.pipeline.addHandler(sshHandler).get()
```

The exact API may differ slightly across swift-nio-ssh versions; consult the swift-nio-ssh README for the canonical incantation. Generate the Ed25519 host key on-test with `Curve25519.Signing.PrivateKey()` (no need to persist anywhere).

`AcceptAnyUserAuthDelegate` and `LoopbackExecResponder` are private helpers you write in this test file. The userauth delegate should accept any publickey request without validation (this is a transport test, not an auth test — R3 implements real userauth). The exec responder should:

- On receiving an `exec` channel request, write `"loopback-exec-ok\n"` to the channel as `ByteBuffer`
- Send EOF, then close the channel

**2c. SSH client-side setup:**

Wrap the offerer's `RTCDataChannel` in an `SSHNIOTransport`, install `NIOSSHHandler` in client mode with a host-key verification delegate that accepts any host key:

```swift
let clientConfig = SSHClientConfiguration(
    userAuthDelegate: SingleKeyAuthDelegate(/* a generated Ed25519 client key */),
    serverAuthDelegate: AcceptAnyHostKeyDelegate()
)
let sshHandler = NIOSSHHandler(role: .client(clientConfig), allocator: transport.channel.allocator, inboundChildChannelInitializer: nil)
try await transport.channel.pipeline.addHandler(sshHandler).get()
```

After the SSH handshake completes (`channelActive` fires on the client pipeline, then KEX runs to completion), open a session channel:

```swift
let sessionChannel = try await sshHandler.createChannel(channelType: .session)
// Send an exec request
let execRequest = SSHChannelRequestEvent.ExecRequest(command: "ls", wantReply: true)
try await sessionChannel.triggerUserOutboundEvent(execRequest).get()
```

Read the inbound bytes (the server's response) into a buffer until EOF.

**2d. Assertion:**

```swift
// After the client receives EOF on the session channel:
let response = String(buffer: receivedBuffer)
#expect(response == "loopback-exec-ok\n", "Expected exec response from loopback SSH server")
```

Wrap the entire test body in a `withTimeout(.seconds(10))` block or equivalent — if the SSH session takes longer than 10 seconds on a loopback, something has hung.

- [ ] **Step 3: Run the test**

Run: `swift test --filter "SSHOverWebRTCLoopbackTests/execRoundTripOverPairedDataChannels"`
Expected: PASS.

If the test fails or hangs:
- **First diagnosis attempt:** add prints around the SSH handshake — is `channelActive` firing? Is `NIOSSHHandshakeComplete` ever invoked? Is the server receiving any inbound bytes at all? The first failure is most likely in the `SSHNIOTransport` byte-ferrying.
- **Second diagnosis attempt:** verify the EmbeddedChannel approach pumps bytes correctly without WebRTC. Write a smaller in-test variant that uses two `EmbeddedChannel`s back-to-back with no `RTCDataChannel` to confirm the SSH pipeline works in isolation.
- **If still stuck:** report BLOCKED with what you tried. R2 is the architecture decision gate and a BLOCKED status here is a legitimate signal that the design needs revisit, not a failure of effort.

- [ ] **Step 4: Commit**

```bash
git add Tests/GrafttyMobileKitTests/Remote/SSH
git commit -m "$(cat <<'EOF'
test(remote): R2 gate — SSH exec round-trip over WebRTC loopback

The architecture decision gate for SSH-over-WebRTC. Pairs two
RTCPeerConnections in-process (reusing the M1.1 loopback pattern),
wraps each side's RTCDataChannel in an SSHNIOTransport, installs
NIOSSHHandler in server + client mode, and verifies an "exec"
session channel round-trips a fixed response over the SSH-over-WebRTC
stack.

Passing this test proves swift-nio-ssh's NIOSSHHandler composes cleanly
with the message-stream RTCDataChannel via the SSHNIOTransport adapter.
R3-R6 build on top of this established foundation.

See docs/superpowers/specs/2026-05-21-ssh-over-webrtc-design.md §11.1.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Verification + `/simplify` + PR

**Files:** None (verification only).

- [ ] **Step 1: Full test suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests pass, including the new `SSHOverWebRTCLoopbackTests` and the existing M1.1 `RemoteHostConnectionLoopbackTests` (no regression). If a known-flaky test fails (e.g., `PollingTickerTests/tickFiresMultipleTimesWithoutPulse` — see commit history for the suite of prior flake fixes), re-run once before concluding it's a real failure.

- [ ] **Step 2: Verify `verify-specs` is clean**

Run: `python3 scripts/generate-specs.py --check`
Expected: zero exit code. This PR doesn't promote any spec IDs (the REMOTE-8.x family stays in `RemoteTodo.swift` disabled inventory; R3 promotes them), so SPECS.md should be unchanged.

- [ ] **Step 3: Audit for unintended scope creep**

Run:
```bash
git diff main..HEAD --stat
```

Expected: a small set of changes confined to:
- `Package.swift` + `Package.resolved`
- `Sources/GrafttyHostAgent/SSH/SSHNIOTransport.swift` (new)
- `Sources/GrafttyMobileKit/Remote/SSH/SSHNIOTransport.swift` (new)
- `Tests/GrafttyMobileKitTests/Remote/SSH/SSHOverWebRTCLoopbackTests.swift` (new)
- The R2 plan document itself

No changes to `RemoteHostConnection.swift`, `WebRTCHostAgent.swift`, any `ChannelRouter*` files, or any production code paths. If the diff includes anything else, audit whether the change was strictly necessary.

- [ ] **Step 4: Run the project's `code-simplifier` agent on the R2 diff**

This step is performed by the orchestrating session, not the subagent. The orchestrator dispatches the `code-simplifier:code-simplifier` agent against the cumulative R2 diff (range `main..HEAD`) to surface any unintended duplication or over-complication introduced. Apply whatever the simplifier suggests as a final commit.

- [ ] **Step 5: Push and open PR**

```bash
git push -u origin ssh-transport
gh pr create --title "feat(remote): R2 — swift-nio-ssh transport + SSHNIOTransport adapter" --body "..."
```

The PR body should:
- Cite the design doc and R2 plan
- Summarize the architecture decision gate framing
- Note that no production wiring lands in this PR
- Include the test plan: build clean, loopback exec round-trip passes locally, full `swift test` passes, /simplify run

---

## Self-Review Notes (for the orchestrator)

**Spec coverage:** R2 implements the following from the design doc:
- §5 module placement of `swift-nio-ssh` (Task 1)
- §10 `SSHNIOTransport` adapter (Task 2)
- §11.1 architecture decision gate via loopback test (Task 3)

R2 does NOT implement (deferred to R3+):
- Any production wiring of SSH into `RemoteHostConnection` or `WebRTCHostAgent` (R4)
- Userauth delegates that actually validate against `TrustedPeerStore` (R3)
- Host-key pinning via `PinnedHostStore` (R3)
- Channel handlers for terminal / panes_state / pane_control (R4 / R5)
- Promotion of any REMOTE-8.x spec from disabled inventory to active (R3 promotes them as their behaviors land)

**Honest acknowledgement:** This plan has more uncertainty than R1's plan because the right swift-nio-ssh API surface to use isn't validated yet. Tasks 2 and 3 ask the implementer to make NIO Channel pattern choices during implementation. The acceptance criterion (loopback test passes) is concrete; the path to get there has some latitude. If the chosen pattern doesn't work, the implementer should escalate as BLOCKED — that signals the architecture-decision gate needs human attention.

**No placeholders:** every step has either complete code or concrete acceptance criteria + a verification command. The only place "implementation TBD" exists in spirit is the body of `SSHNIOTransport` itself, which is genuinely the spike. The plan describes the API contract, the default approach (Option B from the Important Context), and the failure-escalation path; the implementer fills in the actual implementation.

**Type consistency:** the `SSHNIOTransport` API contract (init, channel, eventLoop, start, close) is described once in Task 2 and referenced in Task 3. The loopback test references the same methods. No type-name drift.

**Risk profile:** R2 is the lowest-stakes PR by production impact (no production code wired) and the highest-stakes by architectural commitment (passing the test validates the entire SSH-over-WebRTC rollout direction). A BLOCKED status is a legitimate outcome, not a failure.
