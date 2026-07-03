# W5 — Dead-Code Deletion + REMOTE-5.1 Rewrite + Reconnect Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the dead `ChannelRouter` family (M1.4 scaffolding the SSH channels superseded), rewrite REMOTE-5.1 for the kept-`/ws` reality with auth+shared-core parity, fix the `sshInstallStarted` reconnect latch (W4 follow-up), and land the highest-value dedupe (the hand-rolled `.stdErr` control-frame codec).

**Architecture:** Pure cleanup + one correctness fix. The `ChannelRouter`/`ChannelFrame`/`ChannelID`/`TerminalChannelEnvelope` types have zero production references (dead since PR #176) — delete them and their tests. REMOTE-5.1's disabled text ("retired `/ws` rejects") is obsolete since the program kept `/ws`; rewrite it to assert `/ws` routes through the shared ownership machinery under `WebAccessAuth`. `WebRTCHostAgent.close()` never resets `sshInstallStarted`, so a reconnect gets no SSH — a one-line fix with a headless test seam.

**Tech Stack:** SwiftNIO, `EmbeddedEventLoop`/`setStateForTesting` for WebRTC-free host tests, Swift Testing.

## Global Constraints

- **NEVER initialize native libwebrtc (RTCPeerConnection/RTCPeerConnectionFactory) in a mac-CI test** — hangs the headless runner (cost W3+W4 three CI fix rounds). The `sshInstallStarted` test MUST use `WebRTCHostAgent.setStateForTesting(_:)` + `EmbeddedEventLoop`, never a real peer.
- iOS CI green for any `GrafttyMobileKit` change; new iOS test FILES need pbxproj registration (prefer extending existing files or SPM targets).
- `scripts/generate-specs.py` + commit `SPECS.md` with spec changes; EARS phrasing; no literal escaped quotes in `@spec` titles.
- Exit criterion (from the program plan): `grep -rn "ChannelRouter\|ChannelFrame" Sources/` returns nothing.
- Strict concurrency, warnings-as-errors; RED/GREEN TDD for the fix; commit per green task; `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`; `/code-review xhigh --fix` after opening the PR.

## Key facts (survey-verified @ 6046dc7)

- **Dead family** (all from PR #176, never touched; ZERO production refs; NO `@spec` IDs): `Sources/GrafttyKit/Remote/ChannelRouter.swift`, `Sources/GrafttyKit/Remote/TerminalChannelHandler.swift`, `Sources/GrafttyProtocol/ChannelFrame.swift`, `ChannelFrameCoder.swift`, `ChannelID.swift`, `TerminalChannelEnvelope.swift` (this file declares `TerminalChannelOpenMeta` — verify unused too). Cross-refs are internal to the family. Test files to delete: `Tests/GrafttyKitTests/Remote/ChannelRouterTests.swift`, `ChannelRouterOpenCleanupTests.swift`, `ChannelRouterTestSupport.swift`, `TerminalChannelHandlerTests.swift`, `Tests/GrafttyProtocolTests/ChannelFrameCoderTests.swift`, `ChannelOpenMetadataTests.swift`, `TerminalChannelEnvelopeTests.swift`.
- **Live files with only STALE COMMENT refs** (scrub comments, do NOT delete): `Sources/GrafttyKit/Remote/TerminalByteStream.swift`, `Sources/GrafttyMobileKit/Remote/TerminalByteStream.swift`, `Sources/GrafttyKit/Remote/ZmxAttachEngine.swift` (:21,119,294,331), `Tests/GrafttyKitTests/Remote/ZmxAttachEngineTests.swift` (:87,127). Note two of the to-be-deleted ChannelRouter test files carry a `pollUntil` copy that dies with them — no separate action.
- **REMOTE-5.1**: disabled inventory `Tests/GrafttyTests/Specs/RemoteTodo.swift:21-24`, text "When a client attempts to use the retired /ws terminal endpoint, the host shall reject...". Rewrite direction (program plan lines 51/124/142): kept-`/ws`, shared-core + auth parity. Proposed EARS: *"While a session terminal is served over `/ws`, the application shall route it through the same display-ownership machinery as SSH-attached clients."* + companion pinning `/ws` stays behind `WebAccessAuth`.
- **`/ws` auth gate**: `Sources/GrafttyKit/Web/WebServer.swift:394-408` (`makeWSUpgrader.shouldUpgrade` → `await auth.isAllowed(peer)` at :403; the plan's `:758` ref is stale). `/ws` is upgrade-only (:560-562). Existing pins: `Tests/GrafttyKitTests/Web/WebSocketBridgeOwnershipTests.swift` (ownership), `WebServerAuthTests.swift` (auth). NOTE: there is NO literal `TerminalAttachCore` type — "terminal-attach core" is the plan's conceptual name for `WebSocketBridge` + `SessionDisplayOwnershipStore`; word the spec behaviorally, not by a non-existent type.
- **sshInstallStarted bug**: `Sources/GrafttyHostAgent/WebRTCHostAgent.swift:46` (decl), `:324-325` (latch in `installSSHHandler`), `close()` (:267-296) resets everything per-connection EXCEPT `sshInstallStarted`. Fix: add `sshInstallStarted = false` near :273. No comment justifies the omission (oversight). Seam: `setStateForTesting(_:)` (:143-151) + `EmbeddedEventLoop`.
- **stdErr control-frame codec (Family B, the dedupe target)**: hand-rolled `<u32 BE len><UTF-8 JSON>` in 3+ places — host `TerminalSessionHandler.swift` encodeStdErrFrame (:627-640)/drainControlFrames (:516-523); mobile `TerminalSessionClient.swift` (:275-285 / :444-447); tests (`SSHTerminalLoopbackTests.swift` :1472/:1443, `TerminalSessionHandlerTests.swift` :937/957/1003, `RemoteConnectionReconnectTests.swift` :831/874). All three targets import `GrafttyProtocol`. This is NOT the NIOExtras `LengthPrefixedFraming` (that's a separate dedupe; the `.stdErr` codec rides the raw PTY channel's sub-stream, per `TerminalSessionHandler.swift:28`).
- **LoopbackPeer (5 copies)**: all iOS-target `GrafttyMobileKitTests`, all native `RTCPeerConnection` — extraction needs a pbxproj-registered NEW file AND anything exercising it is device-gated. HIGHEST FRICTION — **defer to a follow-up ticket, not W5** (matches the existing "deferred to a W5 sweep" comment's intent but the native+pbxproj cost outweighs the win this pass; W5 does the mac-safe, high-value stdErr codec instead).

---

### Task 1: Delete the dead ChannelRouter family

**Files:**
- Delete: `Sources/GrafttyKit/Remote/ChannelRouter.swift`, `Sources/GrafttyKit/Remote/TerminalChannelHandler.swift`, `Sources/GrafttyProtocol/ChannelFrame.swift`, `ChannelFrameCoder.swift`, `ChannelID.swift`, `TerminalChannelEnvelope.swift`
- Delete: the 7 test files listed in Key facts
- Modify (comment scrub only): `Sources/GrafttyKit/Remote/TerminalByteStream.swift`, `Sources/GrafttyMobileKit/Remote/TerminalByteStream.swift`, `Sources/GrafttyKit/Remote/ZmxAttachEngine.swift`, `Tests/GrafttyKitTests/Remote/ZmxAttachEngineTests.swift`

Steps:
- [ ] Before deleting, re-verify ZERO production refs: `grep -rn "ChannelRouter\|ChannelFrame\|ChannelID\|TerminalChannelEnvelope\|TerminalChannelHandler\|TerminalChannelOpenMeta" Sources/ | grep -v "\.swift:.*//"` (exclude comment lines) — must return nothing but the files themselves. If ANY live code ref survives, STOP and report (the survey said zero; verify).
- [ ] Delete the 6 source + 7 test files.
- [ ] Scrub the stale comment mentions in the 4 live files (rewrite comments to not reference the deleted types; keep the surrounding accurate doc).
- [ ] `swift build` clean; full `swift test` (known flakes only wsEchoRoundTrip/WEB-5.6; confirm no other test now fails from a lost helper); `grep -rn "ChannelRouter\|ChannelFrame" Sources/` returns nothing.
- [ ] `python3 scripts/generate-specs.py --check` (no @spec on these — should be unaffected).
- [ ] Commit `refactor(remote): delete the dead ChannelRouter/ChannelFrame family (superseded by SSH channels)`.

### Task 2: Fix the `sshInstallStarted` reconnect latch

**Files:**
- Modify: `Sources/GrafttyHostAgent/WebRTCHostAgent.swift` `close()` (~:273) — add `sshInstallStarted = false`
- Test: extend a mac-target host test (e.g. a new `Tests/GrafttyTests/Remote/WebRTCHostAgentReconnectTests.swift` — SPM, no pbxproj) OR extend `WebRTCHostAgentRevocationTests.swift`

**Interfaces:** consumes `setStateForTesting(_:)` (:143-151). If `sshInstallStarted` is `private` and not observable, add a minimal internal test seam — a `var sshHandlerInstalledForTesting: Bool { sshInstallStarted }` getter, or reset-and-reassert via an internal method — keep it `internal`/`@testable`, doc-commented test-only.

Steps:
- [ ] RED: a headless test (no native WebRTC — construct the agent, its lazy factory stays cold) that after `close()` the install latch is re-armed (via the seam), so a second install path would proceed. Confirm it FAILS against current code (latch stays true).
- [ ] GREEN: add `sshInstallStarted = false` to `close()`.
- [ ] Verify no OTHER per-connection state is left latched (the survey confirms sshTransport/authenticatedRegistration/peerConnection/dataChannel/state all reset — re-confirm; if any other one-shot flag exists, reset it too, but ONLY if it actually gates reconnect — do not reset non-connection state).
- [ ] `swift test` (confirm no hang — this test must NOT touch native WebRTC); full suite green.
- [ ] This makes W4's REMOTE-2.1/3.2 reconnect paths non-latent. Note it in the report; consider whether an existing disabled/latent-noted test can now be un-caveated (do NOT force a native reconnect test into mac CI).
- [ ] Commit `fix(remote): reset sshInstallStarted on close so a reconnect re-installs SSH (W4 follow-up)`.

### Task 3: Rewrite + promote REMOTE-5.1

**Files:**
- Modify: `Tests/GrafttyTests/Specs/RemoteTodo.swift` — delete the disabled REMOTE-5.1 entry
- Test: add active behavioral test(s) carrying the rewritten `@spec REMOTE-5.1` — home in the GrafttyKitTests Web suite where `/ws`+ownership is already exercised (`WebSocketBridgeOwnershipTests` / `WebServerAuthTests` neighbors)
- Regenerate `SPECS.md`

**Rewrite:** REMOTE-5.1 becomes (final text TBD by the implementer, but behavioral, no non-existent type names): *"While a session terminal is served over `/ws`, the application shall subject the connection to `WebAccessAuth` and route its terminal + ownership traffic through the same display-ownership store as SSH-attached clients."* Split into two assertions if cleaner (auth gate + shared-ownership routing). Reuse the existing `/ws` auth + ownership test seams — this is promoting ALREADY-TRUE behavior (W2 made `/ws` share the ownership core; auth was always there), so the test asserts the current reality, not new code.

Steps:
- [ ] Decide the final EARS text (behavioral; cite `WebAccessAuth`/display-ownership by role, not by a non-existent `TerminalAttachCore` type). If it needs a companion ID (auth vs routing), use REMOTE-5.2 for the second — check it's free.
- [ ] Write the test(s) reusing existing `/ws` auth + ownership harnesses; they should pass on write (promoting existing behavior). Verify they'd fail if the behavior regressed (e.g. auth gate removed → unauth `/ws` upgrade succeeds).
- [ ] Delete the disabled entry; regen SPECS.md; `--check` green.
- [ ] Commit `test(web): rewrite + promote REMOTE-5.1 — /ws kept, auth + shared-ownership parity`.

### Task 4: Dedupe the `.stdErr` control-frame codec (mac-safe scope)

**Files:**
- Create: `Sources/GrafttyProtocol/StdErrControlFraming.swift` — one `encode(_ payload: String) -> [UInt8]` (or `Data`/`ByteBuffer` — match what host+mobile need) + a `decode`/`drain` that pulls complete `<u32 BE len><bytes>` frames from an accumulator, with the SAME frame cap the current code enforces (grep the cap constant). Pure, no NIO/UIKit deps so all three targets can use it.
- Modify: host `Sources/GrafttyHostAgent/SSH/Channels/TerminalSessionHandler.swift` (encodeStdErrFrame/drainControlFrames → call the shared helper)
- Modify: mobile `Sources/GrafttyMobileKit/Remote/SSH/Channels/TerminalSessionClient.swift` (same)
- Modify: the test hand-rolls that are in reach WITHOUT native WebRTC — `Tests/GrafttyTests/Remote/SSH/TerminalSessionHandlerTests.swift` (mac target, safe). LEAVE the iOS-target test hand-rolls (`SSHTerminalLoopbackTests`, `RemoteConnectionReconnectTests`) using the shared helper too IF the mechanical swap is safe, but do NOT restructure those suites.
- Test: `Tests/GrafttyProtocolTests/StdErrControlFramingTests.swift` (mac SPM target) — round-trip, partial-frame accumulation, oversized-frame cap, multi-frame-in-one-chunk.

Steps:
- [ ] Extract the helper; RED its unit tests (new type) then GREEN.
- [ ] Swap host + mobile prod call sites to the shared helper; byte-format MUST be identical (this is the whole point — the host and client currently agree by hand-mirroring; the shared helper enforces it). Run the SSH loopback suites (iOS) to confirm no wire-format drift — but that's iOS CI, device-safe? The loopback tests use native WebRTC → they run in iOS CI (which is fine — iOS CI isn't the headless-mac-hang problem; the hang is specifically the MAC target). Confirm.
- [ ] Full mac `swift test` + iOS `GrafttyMobileKitTests` green; `--check` green.
- [ ] Commit `refactor(remote): shared StdErrControlFraming for host + mobile + tests`.

### Task 5: Comment/doc sweep + final SPECS

**Files:** grep `triggerUserInitiatedClose` in docs/ (historical design docs still mention the non-existent method) — correct or annotate as superseded per judgment; grep any other now-false ChannelRouter/`/ws`-retired comments across Sources/; regenerate SPECS.md; full suite.

Commit `docs(remote): scrub stale ChannelRouter + triggerUserInitiatedClose references`.

---

## Self-review notes

- Task order: delete dead code FIRST (Task 1) so later tasks aren't editing doomed files; the fix (Task 2) and spec rewrite (Task 3) are independent; dedupe (Task 4) touches live prod paths so it comes after the fix is in.
- LoopbackPeer 5-copy dedup is DEFERRED (native + pbxproj cost > win this pass) — file a follow-up ticket; W5 does the mac-safe high-value stdErr codec instead. Say so in the PR body.
- REMOTE-5.1 is a REWRITE of a stale disabled spec, not a promote-as-written — the original "retired /ws" text is obsolete; do not ship it.
- Out of scope: LoopbackPeer dedup; the NIOExtras `LengthPrefixedFraming` host/mobile mirror dedup (separate, lower value); W6 device gate.

## Risks

1. **A stale-comment scrub accidentally removes a load-bearing comment** — only touch mentions of the DELETED types; preserve surrounding accurate docs.
2. **stdErr codec swap drifts the wire format** — the shared helper must produce byte-identical output to the current hand-rolls; the SSH loopback tests (iOS) are the cross-check. Diff a known frame before/after.
3. **sshInstallStarted reset test tempting to do end-to-end** — resist; the real reconnect E2E is native-WebRTC (iOS, device-gated). The mac test asserts only the latch reset via the seam.
4. **REMOTE-5.1 companion-ID collision** — grep REMOTE-5.2 free before minting.
