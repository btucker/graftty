# zmx Integration — Phase 2 Design Specification

Phase 2 of bringing [zmx](https://zmx.sh) into Graftty. Phase 1 made every pane's PTY child a `zmx attach <session>` process, so terminal sessions survive app quits. Phase 2 exposes those same sessions over a local WebSocket server bound to the Tailscale interface, so a browser on the same tailnet can attach to a pane and mirror it live. No protocol invention — the server is a thin bridge, shelling out to `zmx attach` just like a native pane does.

## Multi-Phase Context

- **Phase 1 (shipped):** zmx as the PTY backing for every Graftty pane.
- **Phase 2 (this spec):** WebSocket server on the Tailscale interface, gated by Tailscale `WhoIs` identity, with a minimal xterm.js-based single-pane web client.
- **Phase 3 (future spec):** Full TanStack-based web client (Router + DB + xterm.js) mirroring the native sidebar and split layout, with a mobile collapse.

Phase 3 is out of scope for this spec but is referenced where Phase 2 decisions create or close doors for it.

## Goal

After Phase 2 ships, this user story works:

> From my phone on the couch, on the same tailnet as my Mac, I open Graftty's web URL in Safari. One of my running Graftty panes renders in the browser — live. Keystrokes I type in the browser show up on the Mac pane; output from the Mac pane shows up in the browser. Resizing the browser resizes the shell. Closing the tab leaves the Mac pane running; quitting Graftty still kills the pane (Phase 1's `zmx kill` path is unchanged).

This is a **single-pane** experience per page load. No sidebar, no splits, no session picker in the UI — the pane is chosen via a `?session=<name>` query parameter in the URL. Phase 3 layers the richer client on top.

## Architecture

```
[Browser]             [Graftty (Mac)]                  [zmx daemon]        [shell]
  │                       │                                  │                 │
  │── GET / ──────────────►│                                  │                 │
  │◄── HTML + xterm.js ────│                                  │                 │
  │── WS /ws upgrade ─────►│  (Tailscale WhoIs gate —         │                 │
  │                        │   owner-only, fail-closed)       │                 │
  │                        │  [spawn zmx attach <session>] ──►│                 │
  │                        │                                  │◄──────PTY───────┤
  │◄── PTY bytes (WS bin) ─│◄──stdout─────────────────────────│                 │
  │── keys (WS bin) ──────►│──stdin──────────────────────────►│                 │
  │── resize (WS text) ───►│  [ioctl TIOCSWINSZ on child PTY] │                 │
```

The server is stateless with respect to sessions: each WebSocket spawns a fresh `zmx attach` child, and zmx — not Graftty — is responsible for multi-client muxing. Two clients (the native Mac pane and a browser, or two browsers) attached to the same daemon simultaneously is the mechanism by which "couch terminal" works. We do not re-implement that mux; we rely on zmx's.

### Why Tailscale

Tailscale gives three properties Phase 2 needs without any crypto work in Graftty:

1. **Transport encryption end-to-end** via WireGuard. We can run plain HTTP/WS over the tailnet interface without TLS in our process.
2. **Per-connection identity** via the LocalAPI's `WhoIs` endpoint — lets us reject connections from the wrong user without inventing our own auth.
3. **Network reachability from the user's phone** without port-forwarding, DDNS, or anything else tricky.

No `tsnet`, no Go cgo bridge. Graftty talks to the already-installed Tailscale app's LocalAPI socket. The cost: "user must have Tailscale running" — which is implicit in the feature anyway.

### Binding posture

The server binds to **each Tailscale IP enumerated from LocalAPI** (both v4 and v6, if present) **and** to `127.0.0.1` for same-machine diagnostics. It never binds to `0.0.0.0`. If Tailscale is not running or assigns no IPs, the server refuses to start and reports `.disabledNoTailscale` in Settings. This is a deliberately narrow binding surface: no accidental exposure on Wi-Fi / Ethernet / hotel networks.

### Authorization

A single rule: the connecting peer's `WhoIs.UserProfile.LoginName` must equal the Mac's current Tailscale `LoginName`. No tokens, no cookies, no per-URL secrets. The check runs on every incoming connection, at both `/` and `/ws`. If `WhoIs` fails (Tailscale dropped, socket unreachable, malformed response), the connection is denied. Fail closed.

An allowlist extension is anticipated but not in Phase 2 — the data model is flexible enough that adding a "also allow these LoginNames" field later won't reshape the architecture.

### Protocol

One HTTP endpoint serves one static asset (`/` → HTML shell with vendored xterm.js). One WS endpoint (`/ws?session=<name>`) carries the live stream.

- **Binary WS frames** carry raw PTY bytes both directions. This is the hot path; no framing overhead.
- **Text WS frames** carry a small JSON envelope for control events. In Phase 2, there is exactly one envelope shape: `{"type":"resize","cols":N,"rows":M}`. The split between binary-is-data and text-is-control keeps the parser trivial and future-extensible.

This layering stays coherent if Phase 3 adds control events (e.g., `{"type":"ping"}`, `{"type":"sessionClosed"}`).

## Components

### New — `Sources/GrafttyKit/Web/`

Everything here is pure Swift, no AppKit deps. Lives in GrafttyKit to be testable without launching the app.

- **`WebServer.swift`** — HTTP + WebSocket server built on `swift-nio` (+ `swift-nio-http1` + `swift-nio-websocket`). Serves `/` (static HTML) and upgrades `/ws` to WebSocket. Enumerates Tailscale IPs via `TailscaleLocalAPI.status()` at start, creates one bound channel per IP plus `127.0.0.1`. Runs the owner-only `WhoIs` check on every incoming connection before accepting. Exposes `status: WebServer.Status` (`.stopped`, `.listening(on: [IPAddress])`, `.disabledNoTailscale`, `.portUnavailable`, `.error(String)`) for the Settings pane to render.
- **`TailscaleLocalAPI.swift`** — async Swift client for the Tailscale LocalAPI. Connects to `/var/run/tailscaled.socket` (macOS App Store build path may differ; see Error Handling). Two calls in Phase 2:
  - `status() async throws -> Status` — returns the Mac's own tailnet IPs and its `LoginName`.
  - `whois(_ peerIP: IPAddress) async throws -> Whois?` — returns the peer's `LoginName` or `nil` if the peer isn't known.
  Both return `nil` / throw on socket-missing or parse failure; callers fail closed.
- **`WebSession.swift`** — per-WS connection state. **Allocates a PTY pair** (`posix_openpt` + `grantpt` + `unlockpt` + `ptsname`). Forks a child running `zmx attach <session>` with `ZMX_DIR` matching the Graftty app's; the child's stdin/stdout/stderr are the PTY slave, and `setsid` + `ioctl(TIOCSCTTY)` in the child make the slave the controlling terminal. The parent retains the PTY master fd. Reader task: `read(masterFD)` → WS binary frames. Writer task: incoming WS binary frames → `write(masterFD)`. Control task: incoming WS text frames → JSON envelope parse; the only Phase 2 envelope is `resize`, which calls `ioctl(TIOCSWINSZ, &winsize)` on the master fd. On WS close, sends SIGTERM to the child, waits briefly for exit, closes the master fd. Daemon persists.

  Phase 1's `ZmxRunner` is **not** used here — it's a plain pipe-based subprocess wrapper for `kill`/`list`, and `zmx attach` requires a real TTY. A new `PtyProcess.swift` helper co-located in `Sources/GrafttyKit/Web/` encapsulates the PTY + fork + exec dance and is the component `WebSession` composes with. `PtyProcess` is intentionally narrow: open PTY, fork, exec an argv with a PTY slave as fd 0/1/2, return the master fd + child pid. No framing, no buffering, no WS awareness.
- **`PtyProcess.swift`** — a narrow POSIX PTY helper. Opens a master/slave pair, forks, installs the slave as the child's controlling terminal + fd 0/1/2, execs an argv with a supplied env. Returns `(masterFD: Int32, pid: pid_t)`. No knowledge of WebSocket, zmx, or framing. Used by `WebSession`; reusable later (e.g., a Phase 3 server-side `zmx run` path).
- **`WebStaticResources.swift`** — accessors for the compiled-in HTML and JS. Phase 2 vendors `xterm.js` 5.x (minified) into `Resources/web/` under the GrafttyKit target. One HTML file (`index.html`) with one `<script>` pointing at the vendored bundle, one `<div id="term">`, one `new Terminal()` call, one `WebSocket` opened to `/ws?session=...` read from `location.search`. The HTML is short enough to fit in this spec; that's deliberate.

### New — `Sources/Graftty/Web/`

AppKit glue that owns `WebServer`'s lifetime and surfaces it to the user.

- **`WebServerController.swift`** — starts/stops `WebServer` based on Settings. Owns the server instance. Publishes `WebServer.Status` to SwiftUI via an `@Published` property. On Settings change, stops the running server (if any) and starts a fresh one with new config. On app terminate, drains cleanly.
- **`WebSettingsPane.swift`** — SwiftUI view in the Settings window. Four elements:
  - `Enable web access` toggle, default **off**.
  - Port field, default **8799**, clamped to [1024, 65535].
  - Read-only status line fed from `WebServer.Status` (e.g., "Listening on 100.64.1.7:8799", "Tailscale unavailable", "Port 8799 in use").
  - When listening: "Copy URL for focused pane" button that composes `http://<tailscale-ip>:<port>/?session=<focused-pane-session>` and puts it on the clipboard. IP selection: prefer the first IPv4 from `TailscaleLocalAPI.status()` (most clients handle IPv4 URLs cleanest); fall back to an IPv6 with bracket notation (`http://[IPv6]:port/...`) only if no IPv4 is present.

### Modified

- **`Package.swift`** — add `swift-nio`, `swift-nio-http1`, `swift-nio-websocket` to dependencies, wired to the `GrafttyKit` target. Add the `Resources/web/` directory as a resource of `GrafttyKit`. No `swift-nio-ssl`: Tailscale provides transport encryption. No `swift-nio-http2`: HTTP/1.1 + WS upgrade is sufficient for xterm.js.
- **`GrafttyApp.swift`** — instantiate `WebServerController` next to the other subsystem collaborators; pass settings into it. Tear down in the app-quit path.
- **`Sources/Graftty/Sidebar/`** — extend the pane row's context menu (existing `LAYOUT-2.7` surface) with a `Copy web URL` item, enabled only when `WebServer.Status == .listening(...)`. Clicking it produces the same URL as the Settings-pane button for that pane.
- **`SPECS.md`** — new `§14 Web Access` in EARS form, immediately after `§13 zmx Session Backing`. Requirements cover: binding posture, authorization, lifecycle, protocol endpoints, control-event shape, error modes, and explicit out-of-scope pointers.

### Not changed

Phase 1's components (`ZmxLauncher`, `ZmxRunner`, `TerminalManager`, `SurfaceHandle`, `GhosttyBridge`) are untouched. The web server is a parallel consumer of zmx, not a participant in pane lifecycle. That separation is what makes Phase 2 safe to add without risking Phase 1 survival guarantees.

## Data Flow

### Flow 1 — Browser attaches to a pane

1. User right-clicks a pane row in the Graftty sidebar, chooses "Copy web URL" (only present when `WebServer` is listening). Clipboard receives `http://<first-tailscale-ip>:8799/?session=graftty-abcd1234`.
2. User pastes into Safari on their phone (same tailnet). Safari GETs `/`.
3. NIO handler receives the TCP connection, looks up peer IP via `TailscaleLocalAPI.whois(peerIP)`. If `LoginName != ownerLoginName` or lookup fails, respond `403` with a plain-text body. Otherwise serve `index.html`.
4. Browser loads `index.html`, xterm.js initializes, reads `?session=graftty-abcd1234` from `location.search`, opens WS to `/ws?session=graftty-abcd1234`.
5. WS upgrade handshake passes through the same `WhoIs` gate. On pass, `WebSession` is constructed.
6. `WebSession` spawns `zmx attach graftty-abcd1234` with `ZMX_DIR=~/Library/Application Support/Graftty/zmx/`. zmx's attach handshake completes; daemon replays scrollback to the new client.
7. PTY bytes now flow both ways. Native Mac pane and browser are attached to the same daemon; zmx muxes input from both and replicates output to both.

### Flow 2 — Keystroke from browser

1. User types in xterm.js. xterm fires `onData(bytes)` with the encoded bytes (arrow keys, ctrl sequences, plain text).
2. Client sends a **binary** WS frame with those bytes. No wrapping.
3. NIO reads the frame, writes payload to the attach child's stdin.
4. zmx daemon forwards to `$SHELL`. Output eventually returns through both clients.

### Flow 3 — Resize from browser

1. xterm.js fires `onResize(cols, rows)` when the terminal component is sized.
2. Client sends a **text** WS frame: `{"type":"resize","cols":120,"rows":40}`.
3. Server's control handler parses the JSON envelope. Calls `ioctl(TIOCSWINSZ)` on the attach child's master fd with `struct winsize{ws_col=120, ws_row=40}`.
4. Kernel delivers `SIGWINCH` to zmx attach, which propagates down to the daemon and then to `$SHELL`. Output reflows.

Resize is browser-driven only in Phase 2. The native Mac pane's own resize path is unchanged. The two clients may disagree on terminal dimensions; zmx's last-writer-wins behavior applies. Documented, accepted, addressable in Phase 3 if the UX warrants.

### Flow 4 — Browser disconnects

1. User closes tab, or network drops.
2. NIO's WS handler sees close. `WebSession` sends SIGTERM to the attach child.
3. Attach child exits, closes its side of the socket to the daemon. Daemon logs the client-gone event and keeps running.
4. Native Mac pane is unaffected.

### Flow 5 — User disables web access in Settings

1. Toggle flips off.
2. `WebServerController` calls `WebServer.stop()`. NIO group drains: in-flight requests finish, WS connections send close frames, attach children receive SIGTERM.
3. Status transitions to `.stopped`. Copy-URL surfaces (sidebar context menu item, Settings button) become disabled.

### Flow 6 — App quit

1. AppKit termination begins. `GrafttyApp` calls `WebServerController.stop()` as part of the normal shutdown sequence.
2. `WebServer.stop()` drains NIO group, sends WS closes, SIGTERMs attach children.
3. Phase 1's native-pane teardown proceeds unchanged.

No special ordering is required: the web server and the native pane system are independent consumers of the zmx daemons.

## Error Handling

The principle: **Graftty remains fully usable with the web feature disabled, misconfigured, or broken**. Every error below produces either a clear Settings-pane banner or a connection refusal, never a crash or a silent degradation.

### At server start

- **Tailscale not running or LocalAPI socket missing** → log, status `.disabledNoTailscale`, banner in Settings, **server does NOT bind**. Without Tailscale, there is no gate; without a gate, we cannot expose ports.
- **LocalAPI returns no tailnet IPs** (edge case, e.g., not logged in) → same treatment as above. Status `.disabledNoTailscale` with a more specific message.
- **Port already bound** → log, status `.portUnavailable`, banner. User changes port or resolves the conflict.
- **`xterm.js` vendored bundle missing** (bad release build) → log, status `.error("static resources missing")`, server does not start.

### At HTTP request

- **Unknown path** → `404 Not Found`, plain text.
- **Unknown `?session=` value** (not matching any daemon in `zmx list`) → serve HTML anyway; the WS will eventually fail when `zmx attach` errors, and xterm.js shows a clear "session unavailable" message. This is intentional: `/` shouldn't leak which sessions exist based on whether the HTML loads.
- **WhoIs failure or non-owner LoginName** → `403 Forbidden`, plain text. Log at warning level.
- **Tailscale drops between `/` and `/ws`** → the WS upgrade fails the gate, close with `1008` (policy violation). Browser page renders, WS never opens.

### At WebSession

- **`zmx attach` fails to exec** (binary missing, arch mismatch) → WS closes with code `1011` + a short text frame `{"type":"error","message":"session unavailable"}`. Browser displays the message.
- **Attach child exits on its own** (the shell exited, daemon also gone) → forward as WS close `1000` with `{"type":"sessionEnded"}`. Matches native pane auto-close behavior from Phase 1.
- **WS writer backpressure** → NIO's channel backpressure handles PTY → WS. For WS → PTY, if the attach child's stdin buffer is full, reads from the WS pause (standard NIO channel backpressure). No packet loss.

### At Tailscale LocalAPI

The LocalAPI socket path differs between Tailscale-installed-from-DMG and Tailscale-from-App-Store (sandboxed; socket in a different location). Phase 2 probes both:
1. `/var/run/tailscaled.socket` (DMG / homebrew install)
2. `~/Library/Containers/io.tailscale.ipn.macsys/Data/IPN/tailscaled.sock` (App Store install, path subject to verification during implementation)

If neither is reachable, status is `.disabledNoTailscale`. The probe runs at server start; if it fails, the Settings banner tells the user to install / launch Tailscale. No periodic re-probe in Phase 2 — user toggles off and back on after installing.

### Explicitly out of scope

- **TLS / HTTPS** — Tailscale encrypts the transport end-to-end.
- **Multiple simultaneous browsers per session** — zmx's mux handles it; we don't specifically test for it, and we don't add an Graftty-side UI for "who's connected."
- **Auth beyond WhoIs** — no tokens, cookies, per-URL secrets, or rate limiting. Owner-only is the entire story.
- **OSC 52 / clipboard sync** — browser clipboard integration is a Phase 3 concern.
- **Mouse events, file drops, image paste** — keystrokes + resize only.
- **Mobile-responsive layout** — xterm.js defaults; no media queries.
- **Reattach across reboots** — Phase 2 inherits Phase 1's out-of-scope here.

## Testing

### Unit tests — `Tests/GrafttyKitTests/Web/`

Pure logic, no sockets. Fixtures under `Tests/GrafttyKitTests/Web/Fixtures/`.

- **`TailscaleLocalAPITests`** — parse the LocalAPI's `status` response (several real-world shapes captured as fixtures: owner-only tailnet, tailnet with peers, no IPv6, IPv6-only edge case). Parse `whois` response. Returns `nil` when socket path doesn't exist. Returns `nil` on malformed JSON.
- **`WebServerAuthTests`** — `isConnectionAllowed(peerIP:)` returns `true` iff WhoIs resolves to owner's LoginName. Tests stub `TailscaleLocalAPI`. Cover: owner IPv4, owner IPv6, peer-different-user, peer-unknown, WhoIs-throws.
- **`WebSessionControlParserTests`** — resize envelope: valid, malformed (non-JSON, wrong type, missing fields, extra fields-ignored), `cols`/`rows` bounds (negative → reject, zero → reject, absurdly large → clamped or rejected).
- **`WebURLComposerTests`** — `(sessionName, tailscaleIP, port) → String` equals the expected URL. IPv4 and IPv6 (brackets for v6). `chooseURLHost(ips:)` prefers the first IPv4; falls back to first IPv6 only if no IPv4.
- **`PtyProcessTests`** — spawn `/bin/sh -c 'echo hello && sleep 0.1'`, read from the master fd until `hello\n`, assert child exited with status 0 and master fd is closeable without error. Separate test: spawn a child that calls `tty -s`, assert exit status 0 (proves the slave is a real controlling terminal). Does not require zmx.

### Integration tests — `Tests/GrafttyKitTests/Web/WebServerIntegrationTests.swift`

Require zmx installed (`XCTSkipUnless`). Bind the server to `127.0.0.1:0` with `TailscaleLocalAPI` stubbed to always allow. Use `withScopedZmxDir` from Phase 1 to isolate session state.

- **`startsAndServesIndex`** — GET `/` returns HTML containing the expected xterm.js `<script>` and `<div>`.
- **`attachesAndEchoes`** — open WS to `/ws?session=<fresh>`, write `echo HELLO\n` as a binary frame, read until `HELLO` appears in a returned binary frame, close WS. Verify `zmx list` shows the session cleaned up (no daemon leaked because the user didn't explicitly `zmx kill`; daemon persists, but this is the "clean detach" case).
- **`deniesNonOwner`** — stub WhoIs to return a different LoginName. GET `/` returns `403`. WS upgrade returns `403` before the WS handshake completes.
- **`resizesPty`** — attach WS, send a `resize` text frame `{"cols":42,"rows":13}`, run `stty size` in the shell by writing to stdin, read back the output, assert `13 42`.
- **`closesChildOnWsDisconnect`** — attach WS, close it from the client side, assert (via `zmx list` + a status probe) that the attach child exited but the daemon is still alive.

### End-to-end — `ZmxWebAccessSmokeChecklist.md`

Manual; maintainer runs before each release.

1. Enable web access in Settings. Open a pane in Graftty. Right-click its row → "Copy web URL". Open in Safari on phone (same tailnet). Pane renders. Type on phone → echo on Mac. Type on Mac → echo on phone. Resize phone's browser width → shell `stty size` reflects the new cols.
2. From a Mac outside the tailnet, paste the same URL → connection timeout (tailnet routing prevents reachability).
3. From a second tailnet peer logged in as a different user, paste the URL → Safari shows `403 Forbidden`.
4. In Settings, disable web access. Safari on phone → connection refused.
5. Quit Tailscale from the menu bar. Relaunch Graftty (web access still enabled). Settings pane shows "Tailscale unavailable"; no port is bound (verify with `lsof -i :8799`).
6. Close the browser tab while a long-running command is in progress (`sleep 30`). Verify on Mac: command continues to run; native pane is unaffected. Reopen browser: output is still streaming.

### What we deliberately don't test

- **Tailscale's LocalAPI correctness** — not our code.
- **xterm.js rendering fidelity** — well-exercised by its own test suite; we test that bytes arrive.
- **NIO WS framing** — same reasoning; stable library.
- **Multiple simultaneous browser clients** — zmx handles mux; Graftty is a passthrough.

## Acceptance Criteria

Phase 2 ships when all of the following hold:

1. All unit and integration tests pass under `swift test` with a stubbed `TailscaleLocalAPI`. The one skipped-without-zmx path is the same as Phase 1's.
2. The six manual smoke tests above pass on a build with Tailscale installed and running.
3. `SPECS.md §14 Web Access` is added in EARS form and cross-references `§13 zmx Session Backing` where relevant.
4. With the feature disabled (default), `lsof -i` shows no Graftty-owned listening sockets beyond what Phase 1 already uses (the CLI notification socket), and no LocalAPI call is made at startup.
5. With the feature enabled and Tailscale running, the end-to-end "couch terminal" story works: owner opens the URL on a tailnet device, pane renders, bidirectional I/O, resize, disconnect leaves the native pane intact.
6. A non-owner on the tailnet receives `403` at both `/` and `/ws`.
7. With Tailscale not running, the Settings pane's banner is clear and the server has bound zero sockets.

## Architectural Notes

### Why `zmx attach` per connection instead of daemon socket reads

zmx's per-session socket protocol is internal (per the Phase 1 design doc, `docs/superpowers/specs/2026-04-17-zmx-integration-design.md §229`). Speaking it directly would couple Graftty to zmx internals across major versions. Shelling out to `zmx attach` uses the public CLI seam and gets the mux-and-replay behavior for free. The overhead is one subprocess per concurrent browser client — acceptable for a Phase 2 where concurrency is expected to be ≤ 2 or 3.

### Why no TLS

The web server listens only on Tailscale IPs (and 127.0.0.1 for debugging). Traffic on the Tailscale interface is already WireGuard-encrypted. Adding TLS inside Graftty would mean self-signed certs, a cert store, browser warnings — all for traffic that's already encrypted. The simplicity is worth the small cost of being unusable off-tailnet (which is exactly the point of the Tailscale binding anyway).

### Why no `tsnet` / Go cgo

`tsnet` is the obvious Go-idiomatic way to embed Tailscale, but pulling it into a Swift macOS app needs a cgo bridge, a Go toolchain in CI, a second build-artifact pipeline. For a feature whose whole point is "if the user has Tailscale running, expose to tailnet," the LocalAPI is enough and is the lightest-weight path. A future rewrite could swap LocalAPI for `tsnet` without changing the data flow; the `TailscaleLocalAPI` protocol boundary is where that swap would land.

### What Phase 2 enables for Phase 3

Phase 3 reuses:
- **The WS protocol**, extending text-frame envelopes with new `type`s (`sessionList`, `sidebarUpdate`, `attentionChange`, …).
- **The owner-only WhoIs gate** as its auth baseline.
- **`WebSession`'s PTY-bridging plumbing** per tab in the TanStack client.
- **The port-binding model** (Tailscale + loopback).

Phase 3 adds on top:
- A richer HTTP surface (session-list JSON, worktree-model snapshots, attention events).
- A real client (TanStack Router + DB + xterm.js) instead of the single HTML page.
- Optional allowlist extension to `WhoIs` gating.
- Possibly a second URL scheme (`/term/<session>`) with path-based session selection.
