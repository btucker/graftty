# zmx Integration Phase 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose every running Espalier pane over a local WebSocket server bound only to Tailscale IPs (+ 127.0.0.1), gated by Tailscale `WhoIs` identity. Ship a single-page xterm.js web client that attaches to a pane via `?session=<name>`, renders the VT stream, and handles keystrokes + resize.

**Architecture:** A new `EspalierKit/Web/` module houses a `swift-nio`-based HTTP + WebSocket server (`WebServer`), a Tailscale LocalAPI client (`TailscaleLocalAPI`), and a per-connection bridge (`WebSession`) that allocates a PTY pair (`PtyProcess`), forks `zmx attach <session>` into it, and pipes PTY bytes to/from WS binary frames. Text frames carry JSON control events (only `resize` in Phase 2). AppKit glue (`WebServerController` + `WebSettingsPane`) exposes an off-by-default toggle and a port field in macOS Settings. The sidebar pane-row context menu gains a "Copy web URL" item when listening.

**Tech Stack:** Swift 5.10, Swift Testing (`@Suite`/`@Test`/`#expect`), SwiftUI/AppKit (macOS 14+), `swift-nio` 2.x (+ `swift-nio-http1`, `swift-nio-websocket`), POSIX PTY APIs via Darwin (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname`, `forkpty` alternative via manual `fork` + `setsid` + `TIOCSCTTY`), `Network.framework` for the Unix-socket client to Tailscale LocalAPI. Vendored `xterm.js` 5.x (minified JS + CSS).

**Spec:** `docs/superpowers/specs/2026-04-17-zmx-integration-phase-2-design.md`

---

## File Structure

**Create (EspalierKit — pure Swift, testable without AppKit):**
- `Sources/EspalierKit/Web/WebServer.swift` — NIO HTTP + WS server, auth gate, channel config.
- `Sources/EspalierKit/Web/WebSession.swift` — per-WS bridge: PTY ↔ WS.
- `Sources/EspalierKit/Web/WebControlEnvelope.swift` — JSON envelope types + parser (`resize`).
- `Sources/EspalierKit/Web/WebURLComposer.swift` — `(session, ip, port) → URL` + IP selection.
- `Sources/EspalierKit/Web/WebStaticResources.swift` — accessors for the bundled HTML/JS.
- `Sources/EspalierKit/Web/TailscaleLocalAPI.swift` — Unix-socket client for `status` + `whois`.
- `Sources/EspalierKit/Web/PtyProcess.swift` — open PTY, fork, exec with slave as controlling terminal.

**Create (Espalier app — AppKit/SwiftUI glue):**
- `Sources/Espalier/Web/WebServerController.swift` — owns `WebServer` lifetime, reacts to Settings.
- `Sources/Espalier/Web/WebSettingsPane.swift` — SwiftUI view in the Settings window.
- `Sources/Espalier/Web/WebAccessSettings.swift` — `@AppStorage`-backed settings model.

**Create (Resources):**
- `Resources/web/index.html` — the minimal client shell.
- `Resources/web/xterm.min.js` — vendored from unpkg, version 5.3.0.
- `Resources/web/xterm.min.css` — vendored from unpkg, version 5.3.0.
- `Resources/web/xterm-addon-fit.min.js` — vendored, used for auto-sizing.
- `Resources/web/VERSION` — plain text "xterm.js 5.3.0 — vendored YYYY-MM-DD".

**Create (tests):**
- `Tests/EspalierKitTests/Web/TailscaleLocalAPITests.swift`
- `Tests/EspalierKitTests/Web/PtyProcessTests.swift`
- `Tests/EspalierKitTests/Web/WebControlEnvelopeTests.swift`
- `Tests/EspalierKitTests/Web/WebURLComposerTests.swift`
- `Tests/EspalierKitTests/Web/WebServerAuthTests.swift`
- `Tests/EspalierKitTests/Web/WebServerIntegrationTests.swift` — requires `zmx`.
- `Tests/EspalierKitTests/Web/Fixtures/tailscale-status.json`
- `Tests/EspalierKitTests/Web/Fixtures/tailscale-whois-owner.json`
- `Tests/EspalierKitTests/Web/Fixtures/tailscale-whois-peer.json`

**Modify:**
- `Package.swift` — add swift-nio deps; register `Resources/web/` as a resource of `EspalierKit`.
- `Sources/Espalier/EspalierApp.swift` — instantiate `WebServerController`; tear down on quit.
- `Sources/Espalier/Views/` (sidebar pane-row context menu — specific file TBD by grep) — add "Copy web URL" item gated on `.listening`.
- `SPECS.md` — append §14 "Web Access" (EARS requirements).

---

## Test Infrastructure Notes

Tests follow the same pattern as Phase 1 (`Tests/EspalierKitTests/Zmx/ZmxSurvivalIntegrationTests.swift`):

- Pure logic tests use `@Suite`/`@Test`/`#expect`, no sockets.
- Integration tests that need `zmx` installed gate with `try #require(ZmxLauncher(executable: …).isAvailable, "zmx binary not vendored")`.
- Integration tests that need a socket bind to `127.0.0.1:0` (ephemeral port), stub `TailscaleLocalAPI` to always allow.
- Fixtures live alongside tests under `Fixtures/` and are read via `Bundle.module.url(forResource:...)`. `Package.swift` will include these as test resources (already set up; just drop files in).

---

## Execution Strategy for Parallel Subagents

Tasks are grouped into waves. Within a wave, tasks are independent and can be dispatched to parallel subagents. Between waves, integration is sequential.

- **Wave A (parallel):** Tasks 1, 2, 3 — Package.swift scaffolding + isolated utility modules.
- **Wave B (parallel):** Tasks 4, 5 — utilities built on Wave A.
- **Wave C (sequential in main):** Tasks 6, 7 — WebSession and WebServer (tightly coupled NIO code).
- **Wave D (parallel):** Tasks 8, 9, 10 — AppKit glue + SPECS.md.
- **Wave E (sequential):** Task 11 — final `swift build` + manual smoke + PR.

---

## Task 1: Add swift-nio dependencies + vendor xterm.js

**Files:**
- Modify: `Package.swift`
- Create: `Resources/web/xterm.min.js`, `xterm.min.css`, `xterm-addon-fit.min.js`, `VERSION`, `index.html`

- [ ] **Step 1.1: Add NIO dependencies to `Package.swift`**

Open `Package.swift`. After the existing dependencies block, extend to:

```swift
dependencies: [
    .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
],
```

Then modify the `EspalierKit` target:

```swift
.target(
    name: "EspalierKit",
    dependencies: [
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
    ],
    resources: [
        .copy("../../Resources/web"),
    ]
),
```

Note: `resources: [.copy(...)]` copies the directory tree as a flat resource; Swift Package Manager expects resource paths *relative to the target's Source directory* (hence `../../`). Confirm at build time with `swift build`.

- [ ] **Step 1.2: Vendor xterm.js assets**

Run from the repo root:

```bash
mkdir -p Resources/web
curl -fsSLo Resources/web/xterm.min.js https://unpkg.com/xterm@5.3.0/lib/xterm.js
curl -fsSLo Resources/web/xterm.min.css https://unpkg.com/xterm@5.3.0/css/xterm.css
curl -fsSLo Resources/web/xterm-addon-fit.min.js https://unpkg.com/@xterm/addon-fit@0.10.0/lib/addon-fit.js
printf "xterm.js 5.3.0 — vendored %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > Resources/web/VERSION
```

Verify file sizes are non-trivial:

```bash
wc -c Resources/web/*.js Resources/web/*.css
```

Expected: each JS file > 40 KB, CSS > 1 KB. If 0 bytes, the curl failed — re-run.

- [ ] **Step 1.3: Author `Resources/web/index.html`**

Create `Resources/web/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Espalier</title>
    <link rel="stylesheet" href="./xterm.min.css">
    <style>
        html, body { margin: 0; height: 100%; background: #0d0d0d; }
        #term { height: 100vh; padding: 8px; box-sizing: border-box; }
        #status { position: fixed; top: 4px; right: 8px; color: #888; font: 12px monospace; }
    </style>
</head>
<body>
    <div id="status">connecting…</div>
    <div id="term"></div>
    <script src="./xterm.min.js"></script>
    <script src="./xterm-addon-fit.min.js"></script>
    <script>
        (function() {
            const params = new URLSearchParams(location.search);
            const session = params.get("session");
            const statusEl = document.getElementById("status");
            if (!session) {
                statusEl.textContent = "missing ?session=";
                return;
            }

            const term = new Terminal({ convertEol: false, fontFamily: "Menlo, monospace", fontSize: 13 });
            const fit = new FitAddon.FitAddon();
            term.loadAddon(fit);
            term.open(document.getElementById("term"));
            fit.fit();

            const wsURL = (location.protocol === "https:" ? "wss:" : "ws:") +
                "//" + location.host + "/ws?session=" + encodeURIComponent(session);
            const ws = new WebSocket(wsURL);
            ws.binaryType = "arraybuffer";

            function sendResize() {
                if (ws.readyState !== 1) return;
                ws.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows }));
            }

            ws.onopen = () => {
                statusEl.textContent = session;
                sendResize();
            };
            ws.onmessage = (ev) => {
                if (ev.data instanceof ArrayBuffer) {
                    term.write(new Uint8Array(ev.data));
                } else {
                    // Text frame — control event from server.
                    try {
                        const msg = JSON.parse(ev.data);
                        if (msg.type === "error" || msg.type === "sessionEnded") {
                            statusEl.textContent = msg.message || msg.type;
                        }
                    } catch (_) { /* ignore */ }
                }
            };
            ws.onclose = () => { statusEl.textContent = "disconnected"; };
            ws.onerror = () => { statusEl.textContent = "error"; };

            term.onData((data) => {
                if (ws.readyState !== 1) return;
                ws.send(new TextEncoder().encode(data));
            });
            window.addEventListener("resize", () => { fit.fit(); sendResize(); });
        })();
    </script>
</body>
</html>
```

- [ ] **Step 1.4: Run `swift build` to verify Package.swift + resource path**

Run: `swift build 2>&1 | tail -20`

Expected: build succeeds (may emit deprecation warnings from NIO; ignore). If "unknown package" error, the path in `resources: [.copy(...)]` is wrong — try `.copy("Resources/web")` relative to target Source dir.

- [ ] **Step 1.5: Commit**

```bash
git add Package.swift Resources/web/
git commit -m "$(cat <<'EOF'
build(web): swift-nio deps + vendored xterm.js 5.3.0

- Adds swift-nio (NIO + HTTP1 + WebSocket) to EspalierKit target
- Vendors xterm.js 5.3.0 + fit addon + CSS under Resources/web/
- Authors minimal index.html client that reads ?session= and opens /ws
- Registers Resources/web/ as a copy resource of EspalierKit

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: TailscaleLocalAPI — Unix-socket client for WhoIs

**Files:**
- Create: `Sources/EspalierKit/Web/TailscaleLocalAPI.swift`
- Create: `Tests/EspalierKitTests/Web/Fixtures/tailscale-status.json`
- Create: `Tests/EspalierKitTests/Web/Fixtures/tailscale-whois-owner.json`
- Create: `Tests/EspalierKitTests/Web/Fixtures/tailscale-whois-peer.json`
- Create: `Tests/EspalierKitTests/Web/TailscaleLocalAPITests.swift`

- [ ] **Step 2.1: Capture fixtures**

If Tailscale is installed locally, you can capture real fixtures:

```bash
curl --unix-socket /var/run/tailscaled.socket "http://local-tailscaled.sock/localapi/v0/status" | jq > /tmp/status.json
curl --unix-socket /var/run/tailscaled.socket "http://local-tailscaled.sock/localapi/v0/whois?addr=100.64.0.1:0" | jq > /tmp/whois.json
```

If not, use these synthesized fixtures — they match the documented schema.

Create `Tests/EspalierKitTests/Web/Fixtures/tailscale-status.json`:

```json
{
    "Self": {
        "UserID": 123456,
        "TailscaleIPs": ["100.64.0.5", "fd7a:115c:a1e0::5"]
    },
    "User": {
        "123456": {
            "LoginName": "ben@example.com"
        }
    }
}
```

Create `Tests/EspalierKitTests/Web/Fixtures/tailscale-whois-owner.json`:

```json
{
    "Node": {
        "ID": 7001,
        "Addresses": ["100.64.0.5/32"]
    },
    "UserProfile": {
        "LoginName": "ben@example.com",
        "DisplayName": "Ben"
    }
}
```

Create `Tests/EspalierKitTests/Web/Fixtures/tailscale-whois-peer.json`:

```json
{
    "Node": {
        "ID": 7042,
        "Addresses": ["100.64.0.42/32"]
    },
    "UserProfile": {
        "LoginName": "someone-else@example.com",
        "DisplayName": "Someone Else"
    }
}
```

- [ ] **Step 2.2: Write failing tests for `TailscaleLocalAPI` parsers**

Create `Tests/EspalierKitTests/Web/TailscaleLocalAPITests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("TailscaleLocalAPI — parsing")
struct TailscaleLocalAPIParsingTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "fixture \(name).json missing"
        )
        return try Data(contentsOf: url)
    }

    @Test func parseStatus_extractsOwnerAndIPs() throws {
        let data = try fixture("tailscale-status")
        let status = try TailscaleLocalAPI.parseStatus(data)
        #expect(status.loginName == "ben@example.com")
        #expect(status.tailscaleIPs.count == 2)
        #expect(status.tailscaleIPs.contains("100.64.0.5"))
        #expect(status.tailscaleIPs.contains("fd7a:115c:a1e0::5"))
    }

    @Test func parseWhois_ownerLoginName() throws {
        let data = try fixture("tailscale-whois-owner")
        let whois = try TailscaleLocalAPI.parseWhois(data)
        #expect(whois.loginName == "ben@example.com")
    }

    @Test func parseWhois_peerLoginName() throws {
        let data = try fixture("tailscale-whois-peer")
        let whois = try TailscaleLocalAPI.parseWhois(data)
        #expect(whois.loginName == "someone-else@example.com")
    }

    @Test func parseStatus_malformedReturnsNil() throws {
        let data = Data("{ not valid json".utf8)
        #expect(throws: DecodingError.self) {
            _ = try TailscaleLocalAPI.parseStatus(data)
        }
    }
}
```

- [ ] **Step 2.3: Run test — expect failure (`TailscaleLocalAPI` undefined)**

Run: `swift test --filter TailscaleLocalAPIParsingTests 2>&1 | tail -20`

Expected: compilation error — `TailscaleLocalAPI` unknown.

- [ ] **Step 2.4: Implement `TailscaleLocalAPI.swift`**

Create `Sources/EspalierKit/Web/TailscaleLocalAPI.swift`:

```swift
import Foundation

/// Client for the Tailscale LocalAPI served on a Unix domain socket by
/// the Tailscale daemon. We call two endpoints only:
///
/// - `GET /localapi/v0/status` — returns the local tailnet identity
///   (our LoginName) and the TailscaleIPs assigned to this host.
/// - `GET /localapi/v0/whois?addr=<ip>:<port>` — returns the
///   UserProfile of the tailnet peer at that address.
///
/// # Lifetime
/// Stateless. Each call opens + closes the Unix socket.
///
/// # Failure policy
/// All failure modes throw. Callers are expected to treat any thrown
/// error as "deny" (fail-closed). The top-level `WebServer` never
/// binds without a successful `status()` call.
public struct TailscaleLocalAPI {

    /// Candidate Unix-socket paths, tried in order. The first path
    /// reachable is used; later calls do not re-probe — the caller
    /// is expected to stop/restart the server if Tailscale moves.
    public static let defaultSocketPaths: [String] = [
        "/var/run/tailscaled.socket",
        NSString(string: "~/Library/Containers/io.tailscale.ipn.macsys/Data/IPN/tailscaled.sock").expandingTildeInPath,
    ]

    public struct Status: Equatable {
        public let loginName: String
        public let tailscaleIPs: [String]
    }

    public struct Whois: Equatable {
        public let loginName: String
    }

    public enum Error: Swift.Error, Equatable {
        case socketUnreachable
        case httpError(Int)
        case malformedResponse
    }

    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Construct using the first reachable default path. Throws
    /// `.socketUnreachable` if none are reachable.
    public static func autoDetected() throws -> TailscaleLocalAPI {
        for path in defaultSocketPaths where FileManager.default.fileExists(atPath: path) {
            return TailscaleLocalAPI(socketPath: path)
        }
        throw Error.socketUnreachable
    }

    // MARK: - Public API

    public func status() async throws -> Status {
        let body = try await request(path: "/localapi/v0/status")
        return try Self.parseStatus(body)
    }

    public func whois(peerIP: String) async throws -> Whois {
        // LocalAPI expects host:port; we don't know the peer port and
        // the API accepts port=0 for "any".
        let escaped = peerIP.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? peerIP
        let body = try await request(path: "/localapi/v0/whois?addr=\(escaped):0")
        return try Self.parseWhois(body)
    }

    // MARK: - Parsing (testable)

    static func parseStatus(_ data: Data) throws -> Status {
        struct RawStatus: Decodable {
            struct Me: Decodable {
                let UserID: Int?
                let TailscaleIPs: [String]?
            }
            struct UserProfile: Decodable {
                let LoginName: String
            }
            let `Self`: Me?
            let User: [String: UserProfile]?
        }
        let decoder = JSONDecoder()
        let raw = try decoder.decode(RawStatus.self, from: data)
        guard
            let me = raw.Self,
            let userID = me.UserID,
            let profile = raw.User?["\(userID)"]
        else {
            throw Error.malformedResponse
        }
        return Status(
            loginName: profile.LoginName,
            tailscaleIPs: me.TailscaleIPs ?? []
        )
    }

    static func parseWhois(_ data: Data) throws -> Whois {
        struct Raw: Decodable {
            struct UP: Decodable { let LoginName: String }
            let UserProfile: UP
        }
        let decoder = JSONDecoder()
        let raw = try decoder.decode(Raw.self, from: data)
        return Whois(loginName: raw.UserProfile.LoginName)
    }

    // MARK: - HTTP over Unix socket

    private func request(path: String) async throws -> Data {
        // We implement the minimum HTTP/1.1 framing needed: a single GET,
        // read headers until CRLFCRLF, then body by Content-Length.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw Error.socketUnreachable }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Error.socketUnreachable
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, src.count)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, size)
            }
        }
        if rc != 0 { throw Error.socketUnreachable }

        // Tailscale LocalAPI expects Basic auth with no password — the
        // user is implicit because the socket is local. An empty auth
        // header works for the documented endpoints.
        let req = """
        GET \(path) HTTP/1.1\r
        Host: local-tailscaled.sock\r
        Authorization: Basic Og==\r
        Connection: close\r
        \r\n
        """
        let reqBytes = Array(req.utf8)
        let sent = reqBytes.withUnsafeBufferPointer { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
        if sent != reqBytes.count { throw Error.socketUnreachable }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                Darwin.recv(fd, buf.baseAddress, buf.count, 0)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }

        // Split headers + body.
        guard let split = Self.findDoubleCRLF(in: buffer) else {
            throw Error.malformedResponse
        }
        let headerText = String(data: buffer.prefix(split), encoding: .utf8) ?? ""
        let body = buffer.suffix(from: split + 4)

        // Parse status line.
        let firstLine = headerText.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        if parts.count >= 2, let code = Int(parts[1]), code != 200 {
            throw Error.httpError(code)
        }

        return Data(body)
    }

    private static func findDoubleCRLF(in data: Data) -> Int? {
        let marker: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let bytes = Array(data)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where Array(bytes[i..<(i+4)]) == marker {
            return i
        }
        return nil
    }
}
```

- [ ] **Step 2.5: Run tests — expect pass**

Run: `swift test --filter TailscaleLocalAPIParsingTests 2>&1 | tail -15`

Expected: 4/4 pass.

- [ ] **Step 2.6: Commit**

```bash
git add Sources/EspalierKit/Web/TailscaleLocalAPI.swift \
        Tests/EspalierKitTests/Web/TailscaleLocalAPITests.swift \
        Tests/EspalierKitTests/Web/Fixtures/
git commit -m "$(cat <<'EOF'
feat(web): TailscaleLocalAPI — Unix-socket client for status + whois

Minimal async client that speaks HTTP/1.1 over the Tailscale daemon's
local socket. Exposes status() (our LoginName + tailnet IPs) and
whois(peerIP:) (peer's LoginName) — the two calls the WebServer's
owner-only auth gate needs. Parsers extracted as static for unit-
testing via JSON fixtures.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: PtyProcess — POSIX PTY open/fork/exec helper

**Files:**
- Create: `Sources/EspalierKit/Web/PtyProcess.swift`
- Create: `Tests/EspalierKitTests/Web/PtyProcessTests.swift`

- [ ] **Step 3.1: Write failing tests for `PtyProcess`**

Create `Tests/EspalierKitTests/Web/PtyProcessTests.swift`:

```swift
import Testing
import Foundation
import Darwin
@testable import EspalierKit

@Suite("PtyProcess — PTY allocation + fork/exec")
struct PtyProcessTests {

    @Test func spawns_childEchoAndExit() throws {
        let spawn = try PtyProcess.spawn(
            argv: ["/bin/sh", "-c", "printf hello; exit 0"],
            env: [:]
        )
        defer { close(spawn.masterFD) }

        // Read until EOF or "hello".
        var collected = Data()
        var buf = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(spawn.masterFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            collected.append(contentsOf: buf[0..<n])
            if String(data: collected, encoding: .utf8)?.contains("hello") == true { break }
        }
        #expect(String(data: collected, encoding: .utf8)?.contains("hello") == true)

        // Reap.
        var status: Int32 = 0
        _ = waitpid(spawn.pid, &status, 0)
    }

    @Test func childHasControllingTerminal() throws {
        // `tty -s` exits 0 iff stdin is a terminal. If our PTY setup is
        // correct, the child should report success.
        let spawn = try PtyProcess.spawn(
            argv: ["/usr/bin/tty", "-s"],
            env: [:]
        )
        defer { close(spawn.masterFD) }
        var status: Int32 = 0
        _ = waitpid(spawn.pid, &status, 0)
        let exitCode = (status >> 8) & 0xFF
        #expect(exitCode == 0)
    }

    @Test func resize_ioctlAppliesDimensions() throws {
        let spawn = try PtyProcess.spawn(
            argv: ["/bin/sh", "-c", "stty size; exit 0"],
            env: [:]
        )
        defer { close(spawn.masterFD) }
        try PtyProcess.resize(masterFD: spawn.masterFD, cols: 42, rows: 13)

        var collected = Data()
        var buf = [UInt8](repeating: 0, count: 256)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(spawn.masterFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            collected.append(contentsOf: buf[0..<n])
            if String(data: collected, encoding: .utf8)?.contains("13 42") == true { break }
        }
        var status: Int32 = 0
        _ = waitpid(spawn.pid, &status, 0)
        #expect(String(data: collected, encoding: .utf8)?.contains("13 42") == true)
    }
}
```

- [ ] **Step 3.2: Run test — expect fail**

Run: `swift test --filter PtyProcessTests 2>&1 | tail -15`

Expected: compilation error — `PtyProcess` unknown.

- [ ] **Step 3.3: Implement `PtyProcess.swift`**

Create `Sources/EspalierKit/Web/PtyProcess.swift`:

```swift
import Foundation
import Darwin

/// Open a PTY pair, fork, and exec a program with the PTY slave as
/// its controlling terminal and as fd 0/1/2. The parent retains the
/// master fd; the caller reads/writes it directly.
///
/// This is the narrow complement to Phase 1's `ZmxRunner`. `ZmxRunner`
/// is for short-lived subprocesses that communicate over pipes
/// (`kill`, `list`). `PtyProcess` is for long-lived subprocesses that
/// need a real TTY (`zmx attach`).
///
/// Not a class — the result struct carries everything needed to
/// interact with the child. The caller is responsible for closing
/// the master fd and reaping the child (`waitpid`).
public enum PtyProcess {

    public struct Spawned {
        public let masterFD: Int32
        public let pid: pid_t
    }

    public enum Error: Swift.Error {
        case openptFailed(errno: Int32)
        case grantptFailed(errno: Int32)
        case unlockptFailed(errno: Int32)
        case ptsnameFailed
        case forkFailed(errno: Int32)
        case execFailed(errno: Int32)
    }

    /// Spawn `argv[0]` with `argv[1...]` as arguments and `env` as
    /// the environment. The child's stdin/stdout/stderr are the PTY
    /// slave; the master fd is returned for the parent to use.
    public static func spawn(argv: [String], env: [String: String]) throws -> Spawned {
        precondition(!argv.isEmpty, "argv must not be empty")

        // 1. Open the master.
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        if master < 0 { throw Error.openptFailed(errno: errno) }

        // 2. Grant + unlock the slave.
        if grantpt(master) != 0 {
            let err = errno
            close(master)
            throw Error.grantptFailed(errno: err)
        }
        if unlockpt(master) != 0 {
            let err = errno
            close(master)
            throw Error.unlockptFailed(errno: err)
        }

        // 3. Resolve the slave path.
        guard let slaveNameCStr = ptsname(master) else {
            close(master)
            throw Error.ptsnameFailed
        }
        let slavePath = String(cString: slaveNameCStr)

        // 4. Prepare argv + envp for execve. We copy into C arrays the
        //    child will inherit; after fork, the child execs, which
        //    replaces its address space, so leaks don't matter.
        let argvCStrings = argv.map { strdup($0) }
        var argvPointers: [UnsafeMutablePointer<CChar>?] = argvCStrings + [nil]

        let mergedEnv = env.isEmpty ? ProcessInfo.processInfo.environment : env
        let envStrings = mergedEnv.map { "\($0)=\($1)" }
        let envCStrings = envStrings.map { strdup($0) }
        var envPointers: [UnsafeMutablePointer<CChar>?] = envCStrings + [nil]

        // 5. Fork.
        let pid = fork()
        if pid < 0 {
            close(master)
            throw Error.forkFailed(errno: errno)
        }
        if pid == 0 {
            // Child process.
            _ = setsid()
            let slave = Darwin.open(slavePath, O_RDWR)
            if slave < 0 { _exit(127) }
            if ioctl(slave, UInt(TIOCSCTTY), 0) != 0 {
                // Non-fatal on some kernels; continue.
            }
            _ = dup2(slave, 0)
            _ = dup2(slave, 1)
            _ = dup2(slave, 2)
            if slave > 2 { close(slave) }
            close(master)
            _ = argvPointers.withUnsafeMutableBufferPointer { argvBuf in
                envPointers.withUnsafeMutableBufferPointer { envBuf in
                    execve(argvBuf.baseAddress![0], argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
            _exit(127)
        }

        // Parent.
        // Free the C strings we allocated for argv/env; execve in the
        // child has its own copy.
        for ptr in argvCStrings { free(ptr) }
        for ptr in envCStrings { free(ptr) }
        return Spawned(masterFD: master, pid: pid)
    }

    /// Apply a terminal size change to the PTY. The shell on the slave
    /// side will receive SIGWINCH.
    public static func resize(masterFD: Int32, cols: UInt16, rows: UInt16) throws {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let rc = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
        if rc != 0 {
            throw Error.execFailed(errno: errno)  // repurposing; cleaner to add a dedicated case if this becomes common
        }
    }
}
```

- [ ] **Step 3.4: Run tests**

Run: `swift test --filter PtyProcessTests 2>&1 | tail -15`

Expected: 3/3 pass. If `childHasControllingTerminal` fails, the `TIOCSCTTY` path matters — double-check the `_ = setsid()` → `open(slavePath, O_RDWR)` → `dup2` order.

- [ ] **Step 3.5: Commit**

```bash
git add Sources/EspalierKit/Web/PtyProcess.swift Tests/EspalierKitTests/Web/PtyProcessTests.swift
git commit -m "$(cat <<'EOF'
feat(web): PtyProcess — open PTY + fork + exec helper

Narrow POSIX helper: open a master/slave pair, fork, install the
slave as the child's controlling terminal, exec an argv with a
supplied env. Returns (masterFD, pid) for the parent to drive.

Needed because Phase 1's ZmxRunner is a pipe-based subprocess
wrapper and zmx attach requires a real TTY (which in Phase 1 was
supplied by libghostty; the WebSession has no libghostty available).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: WebControlEnvelope — JSON parser for WS text frames

**Files:**
- Create: `Sources/EspalierKit/Web/WebControlEnvelope.swift`
- Create: `Tests/EspalierKitTests/Web/WebControlEnvelopeTests.swift`

- [ ] **Step 4.1: Write failing tests**

Create `Tests/EspalierKitTests/Web/WebControlEnvelopeTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("WebControlEnvelope — parse")
struct WebControlEnvelopeTests {

    @Test func validResize() throws {
        let json = #"{"type":"resize","cols":120,"rows":40}"#
        let env = try WebControlEnvelope.parse(Data(json.utf8))
        guard case let .resize(cols, rows) = env else {
            Issue.record("expected .resize, got \(env)"); return
        }
        #expect(cols == 120 && rows == 40)
    }

    @Test func resizeIgnoresExtraFields() throws {
        let json = #"{"type":"resize","cols":80,"rows":24,"extraneous":"ok"}"#
        let env = try WebControlEnvelope.parse(Data(json.utf8))
        guard case let .resize(cols, rows) = env else {
            Issue.record("expected .resize"); return
        }
        #expect(cols == 80 && rows == 24)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data("not json".utf8))
        }
    }

    @Test func missingFieldsThrow() {
        let json = #"{"type":"resize","cols":80}"#
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data(json.utf8))
        }
    }

    @Test func negativeDimensionsThrow() {
        let json = #"{"type":"resize","cols":-1,"rows":24}"#
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data(json.utf8))
        }
    }

    @Test func zeroDimensionsThrow() {
        let json = #"{"type":"resize","cols":0,"rows":24}"#
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data(json.utf8))
        }
    }

    @Test func unknownTypeThrows() {
        let json = #"{"type":"unknown"}"#
        #expect(throws: Error.self) {
            _ = try WebControlEnvelope.parse(Data(json.utf8))
        }
    }
}
```

- [ ] **Step 4.2: Run test — expect failure**

Run: `swift test --filter WebControlEnvelopeTests 2>&1 | tail -15`

Expected: compilation error.

- [ ] **Step 4.3: Implement `WebControlEnvelope.swift`**

Create `Sources/EspalierKit/Web/WebControlEnvelope.swift`:

```swift
import Foundation

/// A control event sent from the web client as a WebSocket *text*
/// frame. Binary frames carry raw PTY bytes; this shape is for
/// everything else.
///
/// Phase 2 has exactly one variant (`.resize`). Keeping it as a
/// Swift enum rather than a looser dictionary lets us enforce
/// exhaustive handling when new variants arrive in Phase 3
/// (sessionList, ping, etc.).
public enum WebControlEnvelope: Equatable {
    case resize(cols: UInt16, rows: UInt16)

    public enum ParseError: Error, Equatable {
        case notJSON
        case unknownType(String)
        case missingField(String)
        case invalidDimension
    }

    public static func parse(_ data: Data) throws -> WebControlEnvelope {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let dict = json as? [String: Any] else { throw ParseError.notJSON }
        guard let type = dict["type"] as? String else { throw ParseError.missingField("type") }
        switch type {
        case "resize":
            guard let cols = dict["cols"] as? Int else { throw ParseError.missingField("cols") }
            guard let rows = dict["rows"] as? Int else { throw ParseError.missingField("rows") }
            guard cols > 0 && rows > 0 && cols <= 10_000 && rows <= 10_000 else {
                throw ParseError.invalidDimension
            }
            return .resize(cols: UInt16(cols), rows: UInt16(rows))
        default:
            throw ParseError.unknownType(type)
        }
    }
}
```

- [ ] **Step 4.4: Run tests — expect all pass**

Run: `swift test --filter WebControlEnvelopeTests 2>&1 | tail -15`

Expected: 7/7 pass.

- [ ] **Step 4.5: Commit**

```bash
git add Sources/EspalierKit/Web/WebControlEnvelope.swift Tests/EspalierKitTests/Web/WebControlEnvelopeTests.swift
git commit -m "$(cat <<'EOF'
feat(web): WebControlEnvelope — JSON parser for WS text control frames

Single Phase 2 variant (.resize). Guarded by dimension bounds and
unknown-type rejection to keep the channel strict while leaving
room for Phase 3 variants.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: WebURLComposer — `(session, ip, port) → URL`

**Files:**
- Create: `Sources/EspalierKit/Web/WebURLComposer.swift`
- Create: `Tests/EspalierKitTests/Web/WebURLComposerTests.swift`

- [ ] **Step 5.1: Write failing tests**

Create `Tests/EspalierKitTests/Web/WebURLComposerTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("WebURLComposer")
struct WebURLComposerTests {

    @Test func ipv4Url() {
        let url = WebURLComposer.url(session: "espalier-abcd1234", host: "100.64.0.5", port: 8799)
        #expect(url == "http://100.64.0.5:8799/?session=espalier-abcd1234")
    }

    @Test func ipv6UrlBrackets() {
        let url = WebURLComposer.url(session: "espalier-abcd1234", host: "fd7a:115c::5", port: 8799)
        #expect(url == "http://[fd7a:115c::5]:8799/?session=espalier-abcd1234")
    }

    @Test func chooseHostPrefersIPv4() {
        let ips = ["fd7a:115c::5", "100.64.0.5"]
        #expect(WebURLComposer.chooseHost(from: ips) == "100.64.0.5")
    }

    @Test func chooseHostFallsBackToIPv6() {
        let ips = ["fd7a:115c::5"]
        #expect(WebURLComposer.chooseHost(from: ips) == "fd7a:115c::5")
    }

    @Test func chooseHostReturnsNilForEmpty() {
        #expect(WebURLComposer.chooseHost(from: []) == nil)
    }

    @Test func sessionNameIsPercentEscaped() {
        // Session names with unusual chars shouldn't happen today, but
        // we encode defensively.
        let url = WebURLComposer.url(session: "name with space", host: "100.64.0.5", port: 8799)
        #expect(url.contains("session=name%20with%20space"))
    }
}
```

- [ ] **Step 5.2: Run test — expect failure**

Run: `swift test --filter WebURLComposerTests 2>&1 | tail -10`

Expected: compilation error.

- [ ] **Step 5.3: Implement**

Create `Sources/EspalierKit/Web/WebURLComposer.swift`:

```swift
import Foundation

/// Composes the shareable URL used in the "Copy web URL" action.
/// No statefulness; pure transformation from (host, port, session).
public enum WebURLComposer {

    /// Compose the URL. Bracket-notation for IPv6 hosts; percent-encode
    /// the session name.
    public static func url(session: String, host: String, port: Int) -> String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let encodedSession = session.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(
                CharacterSet(charactersIn: " ")
            )
        ) ?? session
        return "http://\(hostPart):\(port)/?session=\(encodedSession)"
    }

    /// Prefer the first IPv4 address; fall back to the first IPv6 only
    /// if no IPv4 is present. `nil` when the input is empty.
    public static func chooseHost(from ips: [String]) -> String? {
        if let v4 = ips.first(where: { !$0.contains(":") }) { return v4 }
        return ips.first
    }
}
```

- [ ] **Step 5.4: Run tests**

Run: `swift test --filter WebURLComposerTests 2>&1 | tail -10`

Expected: 6/6 pass.

- [ ] **Step 5.5: Commit**

```bash
git add Sources/EspalierKit/Web/WebURLComposer.swift Tests/EspalierKitTests/Web/WebURLComposerTests.swift
git commit -m "$(cat <<'EOF'
feat(web): WebURLComposer — URL + IP selection

Prefer IPv4; bracket-notation for IPv6; percent-encoded session param.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: WebStaticResources — access bundled HTML/JS/CSS

**Files:**
- Create: `Sources/EspalierKit/Web/WebStaticResources.swift`

- [ ] **Step 6.1: Write + implement together (tiny file)**

Create `Sources/EspalierKit/Web/WebStaticResources.swift`:

```swift
import Foundation

/// Accessors for the Phase 2 web client bundled via
/// `resources: [.copy("Resources/web")]`.
public enum WebStaticResources {

    public enum Error: Swift.Error {
        case missingResource(String)
    }

    /// Maps a URL path (e.g., "/", "/xterm.min.js") to its bundled data
    /// and content type.
    public struct Asset {
        public let contentType: String
        public let data: Data
    }

    public static func asset(for urlPath: String) throws -> Asset {
        let name: String
        let contentType: String
        switch urlPath {
        case "/", "/index.html":
            name = "index.html"
            contentType = "text/html; charset=utf-8"
        case "/xterm.min.js":
            name = "xterm.min.js"
            contentType = "application/javascript; charset=utf-8"
        case "/xterm.min.css":
            name = "xterm.min.css"
            contentType = "text/css; charset=utf-8"
        case "/xterm-addon-fit.min.js":
            name = "xterm-addon-fit.min.js"
            contentType = "application/javascript; charset=utf-8"
        default:
            throw Error.missingResource(urlPath)
        }

        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        guard let url = Bundle.module.url(
            forResource: base,
            withExtension: ext,
            subdirectory: "web"
        ) ?? Bundle.module.url(forResource: base, withExtension: ext) else {
            throw Error.missingResource(name)
        }
        let data = try Data(contentsOf: url)
        return Asset(contentType: contentType, data: data)
    }
}
```

- [ ] **Step 6.2: Verify `swift build`**

Run: `swift build 2>&1 | tail -10`

Expected: success.

- [ ] **Step 6.3: Commit**

```bash
git add Sources/EspalierKit/Web/WebStaticResources.swift
git commit -m "feat(web): WebStaticResources — accessors for bundled index.html + xterm.js

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: WebSession — per-WS PTY bridge

**Files:**
- Create: `Sources/EspalierKit/Web/WebSession.swift`

`WebSession` is NOT tested in isolation — its behavior is integration-tested in Task 9 via a real WS. It's a composition of PtyProcess + control envelope + a callback surface.

- [ ] **Step 7.1: Implement `WebSession.swift`**

Create `Sources/EspalierKit/Web/WebSession.swift`:

```swift
import Foundation
import Darwin

/// Per-WebSocket bridge between the client and a single `zmx attach`
/// child. Decoupled from NIO so `WebServer` owns the NIO plumbing
/// and `WebSession` stays testable over any byte-pipe.
///
/// The session spawns the child on init (`start()`), spawns a reader
/// thread that blocks on `read(masterFD)`, and exposes `write(_:)`
/// (for binary frames from the client) and `resize(cols:rows:)`
/// (for control frames). On `close()`, sends SIGTERM to the child
/// and closes the master fd.
public final class WebSession {

    public struct Config {
        public let zmxExecutable: URL
        public let zmxDir: URL
        public let sessionName: String
        public let baseEnv: [String: String]
        public init(zmxExecutable: URL, zmxDir: URL, sessionName: String, baseEnv: [String: String] = ProcessInfo.processInfo.environment) {
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
            self.sessionName = sessionName
            self.baseEnv = baseEnv
        }
    }

    public enum Error: Swift.Error {
        case notStarted
        case alreadyStarted
        case spawnFailed(Swift.Error)
    }

    /// Called on each chunk read from the PTY. Invoked off the caller's
    /// thread (from the reader thread). Caller is responsible for thread
    /// safety in the callback (e.g., dispatching onto NIO's event loop).
    public var onPTYData: ((Data) -> Void)?

    /// Called when the PTY reader observes EOF or an error, signaling
    /// that the zmx attach child exited (shell exit, session ended,
    /// or error). The caller should initiate WS close.
    public var onExit: (() -> Void)?

    private let config: Config
    private var spawned: PtyProcess.Spawned?
    private var readerThread: Thread?
    private let stateLock = NSLock()
    private var isClosed = false

    public init(config: Config) {
        self.config = config
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard spawned == nil else { throw Error.alreadyStarted }

        var env = config.baseEnv
        env["ZMX_DIR"] = config.zmxDir.path

        let argv = [config.zmxExecutable.path, "attach", config.sessionName, "$SHELL"]
        do {
            spawned = try PtyProcess.spawn(argv: argv, env: env)
        } catch {
            throw Error.spawnFailed(error)
        }
        startReaderThread()
    }

    public func write(_ data: Data) {
        guard let fd = spawned?.masterFD, !data.isEmpty else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, base.advanced(by: offset), buf.count - offset)
                if n < 0 { break }
                offset += n
            }
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        guard let fd = spawned?.masterFD else { return }
        try? PtyProcess.resize(masterFD: fd, cols: cols, rows: rows)
    }

    public func close() {
        stateLock.lock()
        if isClosed { stateLock.unlock(); return }
        isClosed = true
        let spawned = self.spawned
        stateLock.unlock()

        if let spawned {
            _ = kill(spawned.pid, SIGTERM)
            // Brief wait, then force.
            var status: Int32 = 0
            for _ in 0..<10 {
                let rc = waitpid(spawned.pid, &status, WNOHANG)
                if rc != 0 { break }
                usleep(50_000)
            }
            _ = kill(spawned.pid, SIGKILL)
            _ = waitpid(spawned.pid, &status, 0)
            Darwin.close(spawned.masterFD)
        }
    }

    private func startReaderThread() {
        guard let fd = spawned?.masterFD else { return }
        let thread = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                let chunk = Data(buf[0..<n])
                self?.onPTYData?(chunk)
            }
            self?.onExit?()
        }
        thread.name = "WebSession.reader(\(config.sessionName))"
        thread.start()
        readerThread = thread
    }
}
```

- [ ] **Step 7.2: Verify `swift build`**

Run: `swift build 2>&1 | tail -10`

Expected: success.

- [ ] **Step 7.3: Commit**

```bash
git add Sources/EspalierKit/Web/WebSession.swift
git commit -m "$(cat <<'EOF'
feat(web): WebSession — PTY bridge for one WebSocket connection

Composes PtyProcess + onPTYData/onExit callbacks. The WS handler in
WebServer plugs in by setting onPTYData to "send binary frame" and
onExit to "initiate WS close." Does not know about NIO.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: WebServer — NIO HTTP + WS server with auth gate

**Files:**
- Create: `Sources/EspalierKit/Web/WebServer.swift`

`WebServer` is the NIO glue: HTTP/1.1 pipeline, WS upgrade, per-connection auth. Integration-tested separately (Task 9).

- [ ] **Step 8.1: Implement `WebServer.swift`**

Create `Sources/EspalierKit/Web/WebServer.swift`:

```swift
import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

/// HTTP + WebSocket server for Phase 2 web access. Binds to each
/// Tailscale IP (plus 127.0.0.1), serves static assets at `/`,
/// upgrades `/ws?session=<name>` to WebSocket, and gates both
/// paths via `AuthPolicy.isAllowed(peerIP:)`.
public final class WebServer {

    public enum Status: Equatable {
        case stopped
        case listening(addresses: [String], port: Int)
        case disabledNoTailscale
        case portUnavailable
        case error(String)
    }

    public struct Config {
        public let port: Int
        public let allowedPaths: [String: WebStaticResources.Asset]
        public let zmxExecutable: URL
        public let zmxDir: URL
        public init(port: Int, allowedPaths: [String: WebStaticResources.Asset], zmxExecutable: URL, zmxDir: URL) {
            self.port = port
            self.allowedPaths = allowedPaths
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
        }
    }

    /// Decides whether a given peer IP is allowed. Pluggable so tests
    /// can inject a permissive stub without real Tailscale.
    public struct AuthPolicy {
        public let isAllowed: (String) async -> Bool
        public init(isAllowed: @escaping (String) async -> Bool) { self.isAllowed = isAllowed }
    }

    public private(set) var status: Status = .stopped
    public let config: Config
    public let auth: AuthPolicy
    public let bindAddresses: [String]

    private var group: EventLoopGroup?
    private var channels: [Channel] = []

    public init(config: Config, auth: AuthPolicy, bindAddresses: [String]) {
        self.config = config
        self.auth = auth
        self.bindAddresses = bindAddresses
    }

    public func start() throws {
        precondition(group == nil, "WebServer already started")
        guard !bindAddresses.isEmpty else {
            status = .disabledNoTailscale
            throw Status.disabledNoTailscale.asError
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 16)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [config, auth] channel in
                let handler = HTTPHandler(config: config, auth: auth)
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (
                    upgraders: [handler.wsUpgrader()],
                    completionHandler: { _ in }
                )).flatMap {
                    channel.pipeline.addHandler(handler)
                }
            }

        do {
            channels = try bindAddresses.map { try bootstrap.bind(host: $0, port: config.port).wait() }
        } catch {
            try? group.syncShutdownGracefully()
            self.group = nil
            let ns = (error as NSError)
            if ns.domain.contains("posix") || "\(error)".contains("EADDRINUSE") {
                status = .portUnavailable
            } else {
                status = .error("\(error)")
            }
            throw error
        }
        status = .listening(addresses: bindAddresses, port: config.port)
    }

    public func stop() {
        for c in channels { try? c.close().wait() }
        channels.removeAll()
        try? group?.syncShutdownGracefully()
        group = nil
        status = .stopped
    }

    // MARK: - HTTP handler

    private final class HTTPHandler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        let config: Config
        let auth: AuthPolicy
        var currentRequestHead: HTTPRequestHead?

        init(config: Config, auth: AuthPolicy) {
            self.config = config
            self.auth = auth
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = unwrapInboundIn(data)
            switch part {
            case .head(let head): currentRequestHead = head
            case .body: break
            case .end:
                guard let head = currentRequestHead else { return }
                currentRequestHead = nil
                let peer = Self.peerIP(channel: context.channel)
                let loop = context.eventLoop
                let promise = loop.makePromise(of: Bool.self)
                loop.execute {
                    Task {
                        let allowed = await self.auth.isAllowed(peer)
                        promise.succeed(allowed)
                    }
                }
                promise.futureResult.whenComplete { result in
                    let allowed = (try? result.get()) ?? false
                    if !allowed {
                        Self.respond(context: context, status: .forbidden, body: Data("forbidden\n".utf8), contentType: "text/plain; charset=utf-8")
                        return
                    }
                    self.serveStatic(context: context, head: head)
                }
            }
        }

        func serveStatic(context: ChannelHandlerContext, head: HTTPRequestHead) {
            let path = head.uri.split(separator: "?").first.map(String.init) ?? "/"
            do {
                let asset = try WebStaticResources.asset(for: path)
                Self.respond(context: context, status: .ok, body: asset.data, contentType: asset.contentType)
            } catch {
                Self.respond(context: context, status: .notFound, body: Data("not found\n".utf8), contentType: "text/plain; charset=utf-8")
            }
        }

        func wsUpgrader() -> NIOWebSocketServerUpgrader {
            return NIOWebSocketServerUpgrader(
                shouldUpgrade: { [auth] channel, head in
                    guard head.uri.hasPrefix("/ws") else {
                        return channel.eventLoop.makeSucceededFuture(nil)
                    }
                    let peer = Self.peerIP(channel: channel)
                    let promise = channel.eventLoop.makePromise(of: HTTPHeaders?.self)
                    channel.eventLoop.execute {
                        Task {
                            let allowed = await auth.isAllowed(peer)
                            promise.succeed(allowed ? HTTPHeaders() : nil)
                        }
                    }
                    return promise.futureResult
                },
                upgradePipelineHandler: { [config] channel, head in
                    let session = Self.parseSession(from: head.uri)
                    let wsHandler = WebSocketBridgeHandler(
                        sessionName: session,
                        zmxExecutable: config.zmxExecutable,
                        zmxDir: config.zmxDir
                    )
                    return channel.pipeline.addHandler(wsHandler)
                }
            )
        }

        static func peerIP(channel: Channel) -> String {
            channel.remoteAddress?.ipAddress ?? "unknown"
        }

        static func parseSession(from uri: String) -> String {
            guard let q = uri.split(separator: "?").dropFirst().first else { return "" }
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if kv.count == 2, kv[0] == "session" { return String(kv[1]).removingPercentEncoding ?? String(kv[1]) }
            }
            return ""
        }

        static func respond(context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data, contentType: String) {
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: contentType)
            headers.add(name: "Content-Length", value: "\(body.count)")
            headers.add(name: "Connection", value: "close")
            let head = HTTPResponseHead(version: .init(major: 1, minor: 1), status: status, headers: headers)
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            var buf = context.channel.allocator.buffer(capacity: body.count)
            buf.writeBytes(body)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf))), promise: nil)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            context.close(promise: nil)
        }
    }

    // MARK: - WebSocket bridge handler

    private final class WebSocketBridgeHandler: ChannelInboundHandler {
        typealias InboundIn = WebSocketFrame
        typealias OutboundOut = WebSocketFrame

        let sessionName: String
        let zmxExecutable: URL
        let zmxDir: URL
        private var session: WebSession?
        private weak var channel: Channel?

        init(sessionName: String, zmxExecutable: URL, zmxDir: URL) {
            self.sessionName = sessionName
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
        }

        func handlerAdded(context: ChannelHandlerContext) {
            channel = context.channel
            let sess = WebSession(config: WebSession.Config(
                zmxExecutable: zmxExecutable,
                zmxDir: zmxDir,
                sessionName: sessionName
            ))
            sess.onPTYData = { [weak self] data in
                guard let self, let channel = self.channel else { return }
                channel.eventLoop.execute {
                    var buffer = channel.allocator.buffer(capacity: data.count)
                    buffer.writeBytes(data)
                    let frame = WebSocketFrame(fin: true, opcode: .binary, data: buffer)
                    channel.writeAndFlush(NIOAny(frame), promise: nil)
                }
            }
            sess.onExit = { [weak self] in
                guard let self, let channel = self.channel else { return }
                channel.eventLoop.execute {
                    let close = WebSocketFrame(fin: true, opcode: .connectionClose,
                        data: channel.allocator.buffer(capacity: 0))
                    channel.writeAndFlush(NIOAny(close), promise: nil)
                    channel.close(promise: nil)
                }
            }
            do {
                try sess.start()
                session = sess
            } catch {
                let errMsg = #"{"type":"error","message":"session unavailable"}"#
                var buf = context.channel.allocator.buffer(capacity: errMsg.utf8.count)
                buf.writeString(errMsg)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buf)
                context.writeAndFlush(NIOAny(frame), promise: nil)
                context.close(promise: nil)
            }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let frame = unwrapInboundIn(data)
            switch frame.opcode {
            case .binary:
                var buf = frame.unmaskedData
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    session?.write(Data(bytes))
                }
            case .text:
                var buf = frame.unmaskedData
                if let bytes = buf.readBytes(length: buf.readableBytes) {
                    let payload = Data(bytes)
                    if let env = try? WebControlEnvelope.parse(payload) {
                        if case let .resize(cols, rows) = env {
                            session?.resize(cols: cols, rows: rows)
                        }
                    }
                }
            case .connectionClose:
                session?.close()
                context.close(promise: nil)
            case .ping:
                let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
                context.writeAndFlush(NIOAny(pong), promise: nil)
            default:
                break
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            session?.close()
        }
    }
}

private extension WebServer.Status {
    var asError: Swift.Error {
        NSError(domain: "WebServer", code: 0, userInfo: [NSLocalizedDescriptionKey: "\(self)"])
    }
}
```

- [ ] **Step 8.2: Verify `swift build`**

Run: `swift build 2>&1 | tail -10`

Expected: success. If NIO API mismatch errors, the plan's NIO 2.65 assumption may be off by a minor version; adjust imports (e.g., `NIOHTTP1` module name) based on the actual error.

- [ ] **Step 8.3: Commit**

```bash
git add Sources/EspalierKit/Web/WebServer.swift
git commit -m "$(cat <<'EOF'
feat(web): WebServer — NIO HTTP/1.1 + WebSocket server with auth gate

Binds to a supplied list of hosts on a single port, serves static
resources from WebStaticResources, upgrades /ws to WebSocket, and
gates every connection via a pluggable AuthPolicy. The WS handler
bridges frames to a per-connection WebSession (PTY ↔ WS).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: WebServerAuthTests + integration tests

**Files:**
- Create: `Tests/EspalierKitTests/Web/WebServerAuthTests.swift`
- Create: `Tests/EspalierKitTests/Web/WebServerIntegrationTests.swift`

- [ ] **Step 9.1: Write auth tests (HTTP-level; no zmx needed)**

Create `Tests/EspalierKitTests/Web/WebServerAuthTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("WebServer — auth gate")
struct WebServerAuthTests {

    private func resources() throws -> [String: WebStaticResources.Asset] {
        var out: [String: WebStaticResources.Asset] = [:]
        for path in ["/", "/xterm.min.js", "/xterm.min.css", "/xterm-addon-fit.min.js"] {
            out[path] = try WebStaticResources.asset(for: path)
        }
        return out
    }

    @Test func deniedRequestReturns403() async throws {
        let config = WebServer.Config(
            port: 0,  // ephemeral
            allowedPaths: try resources(),
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp")
        )
        let server = WebServer(
            config: config,
            auth: WebServer.AuthPolicy(isAllowed: { _ in false }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 403)
    }

    @Test func allowedRequestServesHTML() async throws {
        let config = WebServer.Config(
            port: 0,
            allowedPaths: try resources(),
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp")
        )
        let server = WebServer(
            config: config,
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
        let html = String(data: data, encoding: .utf8) ?? ""
        #expect(html.contains("xterm.min.js"))
    }
}
```

Note: when `port: 0`, NIO returns the actual ephemeral port. The `WebServer.start()` stores this in `status.listening.port`. (If this requires tweaking in `start()`, update both the server and the test accordingly.)

- [ ] **Step 9.2: Write integration test (zmx-gated)**

Create `Tests/EspalierKitTests/Web/WebServerIntegrationTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("WebServer — integration (requires zmx on PATH)")
struct WebServerIntegrationTests {

    /// Resolve a zmx binary from PATH, or skip.
    private static func requireZmx() throws -> URL {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["zmx"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try #require(!path.isEmpty, "zmx binary not on PATH; skipping integration")
        return URL(fileURLWithPath: path)
    }

    private static func scopedZmxDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("espalier-web-it-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func wsEchoRoundTrip() async throws {
        let zmx = try Self.requireZmx()
        let zmxDir = try Self.scopedZmxDir()
        defer { try? FileManager.default.removeItem(at: zmxDir) }

        var assets: [String: WebStaticResources.Asset] = [:]
        for p in ["/", "/xterm.min.js", "/xterm.min.css", "/xterm-addon-fit.min.js"] {
            assets[p] = try WebStaticResources.asset(for: p)
        }
        let server = WebServer(
            config: WebServer.Config(port: 0, allowedPaths: assets, zmxExecutable: zmx, zmxDir: zmxDir),
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"]
        )
        try server.start()
        defer { server.stop() }
        guard case let .listening(_, port) = server.status else {
            Issue.record("server not listening"); return
        }

        // Use URLSession's WebSocket support for a simple client.
        let sessionName = "espalier-it\(UUID().uuidString.prefix(6).lowercased())"
        let url = URL(string: "ws://127.0.0.1:\(port)/ws?session=\(sessionName)")!
        let wsTask = URLSession.shared.webSocketTask(with: url)
        wsTask.resume()

        // Send resize then echo command.
        try await wsTask.send(.string(#"{"type":"resize","cols":80,"rows":24}"#))
        try await wsTask.send(.data(Data("echo HELLO_INTEG\n".utf8)))

        // Read until we see HELLO_INTEG.
        var collected = Data()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let msg = try await wsTask.receive()
            switch msg {
            case .data(let d): collected.append(d)
            case .string(let s): collected.append(Data(s.utf8))
            @unknown default: break
            }
            if let s = String(data: collected, encoding: .utf8), s.contains("HELLO_INTEG") { break }
        }
        let text = String(data: collected, encoding: .utf8) ?? ""
        #expect(text.contains("HELLO_INTEG"))

        wsTask.cancel(with: .goingAway, reason: nil)

        // Best-effort clean up daemons.
        let kill = Process()
        kill.executableURL = zmx
        kill.arguments = ["kill", "--force", sessionName]
        kill.environment = ["ZMX_DIR": zmxDir.path]
        try? kill.run()
        kill.waitUntilExit()
    }
}
```

- [ ] **Step 9.3: Run tests**

Run: `swift test --filter WebServerAuthTests 2>&1 | tail -20`

Expected: 2/2 pass.

Run: `swift test --filter WebServerIntegrationTests 2>&1 | tail -20`

Expected: 1/1 pass (skip if `zmx` not installed — add a fallback `XCTSkip` if `#require` is too strict; the current code uses `try #require(...)` which throws-skip).

- [ ] **Step 9.4: Commit**

```bash
git add Tests/EspalierKitTests/Web/WebServerAuthTests.swift \
        Tests/EspalierKitTests/Web/WebServerIntegrationTests.swift
git commit -m "$(cat <<'EOF'
test(web): WebServer auth gate + integration round-trip

Auth tests: 403 for denied, 200 HTML for allowed. Integration test:
stands up a WebServer with a stubbed always-allow policy, spawns
a real zmx attach via WebSession, round-trips "echo HELLO_INTEG"
over the WS. Integration test skips when zmx is not on PATH.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: WebAccessSettings + WebSettingsPane + WebServerController

**Files:**
- Create: `Sources/Espalier/Web/WebAccessSettings.swift`
- Create: `Sources/Espalier/Web/WebServerController.swift`
- Create: `Sources/Espalier/Web/WebSettingsPane.swift`

- [ ] **Step 10.1: Implement `WebAccessSettings.swift`**

Create `Sources/Espalier/Web/WebAccessSettings.swift`:

```swift
import SwiftUI

/// Minimal @AppStorage-backed settings model. Off by default; port
/// defaults to 8799.
@MainActor
final class WebAccessSettings: ObservableObject {
    @AppStorage("WebAccessEnabled") var isEnabled: Bool = false
    @AppStorage("WebAccessPort") var port: Int = 8799

    static let shared = WebAccessSettings()
}
```

- [ ] **Step 10.2: Implement `WebServerController.swift`**

Create `Sources/Espalier/Web/WebServerController.swift`:

```swift
import Foundation
import EspalierKit
import Combine

/// Owns the `WebServer` lifetime at app scope. Subscribes to
/// `WebAccessSettings` and starts/stops the server accordingly.
@MainActor
final class WebServerController: ObservableObject {

    @Published var status: WebServer.Status = .stopped
    @Published var currentURL: String? = nil

    private var server: WebServer?
    private let settings: WebAccessSettings
    private let zmxExecutable: URL
    private let zmxDir: URL
    private var cancellables = Set<AnyCancellable>()

    init(settings: WebAccessSettings, zmxExecutable: URL, zmxDir: URL) {
        self.settings = settings
        self.zmxExecutable = zmxExecutable
        self.zmxDir = zmxDir
        reconcile()
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async { self?.reconcile() }
            }
            .store(in: &cancellables)
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped
    }

    private func reconcile() {
        server?.stop()
        server = nil
        status = .stopped
        guard settings.isEnabled else { return }
        do {
            let api = try TailscaleLocalAPI.autoDetected()
            let tailscaleStatus = try runBlocking { try await api.status() }
            var bind = tailscaleStatus.tailscaleIPs
            bind.append("127.0.0.1")
            var assets: [String: WebStaticResources.Asset] = [:]
            for p in ["/", "/xterm.min.js", "/xterm.min.css", "/xterm-addon-fit.min.js"] {
                assets[p] = try WebStaticResources.asset(for: p)
            }
            let ownerLogin = tailscaleStatus.loginName
            let auth = WebServer.AuthPolicy { peerIP in
                guard let api = try? TailscaleLocalAPI.autoDetected() else { return false }
                guard let whois = try? await api.whois(peerIP: peerIP) else { return false }
                return whois.loginName == ownerLogin
            }
            let s = WebServer(
                config: .init(port: settings.port, allowedPaths: assets,
                              zmxExecutable: zmxExecutable, zmxDir: zmxDir),
                auth: auth,
                bindAddresses: bind
            )
            try s.start()
            server = s
            status = s.status
            if let host = WebURLComposer.chooseHost(from: tailscaleStatus.tailscaleIPs) {
                currentURL = "http://\(host):\(settings.port)/"
            } else {
                currentURL = nil
            }
        } catch TailscaleLocalAPI.Error.socketUnreachable {
            status = .disabledNoTailscale
        } catch {
            status = .error("\(error)")
        }
    }

    /// Bridge async to sync for the one-shot status() at reconcile time.
    private func runBlocking<T>(_ op: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error> = .failure(CancellationError())
        Task {
            do { result = .success(try await op()) }
            catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }
}
```

- [ ] **Step 10.3: Implement `WebSettingsPane.swift`**

Create `Sources/Espalier/Web/WebSettingsPane.swift`:

```swift
import SwiftUI
import EspalierKit

struct WebSettingsPane: View {
    @StateObject private var settings = WebAccessSettings.shared
    @EnvironmentObject private var controller: WebServerController

    var body: some View {
        Form {
            Section {
                Toggle("Enable web access", isOn: $settings.isEnabled)
                TextField("Port", value: $settings.port, format: .number)
                    .frame(width: 80)
                statusRow
                if case .listening = controller.status, let url = controller.currentURL {
                    Text("Base URL: \(url)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Web Access")
            } footer: {
                Text("Binds only to Tailscale IPs. Allows only your Tailscale identity.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 240)
    }

    @ViewBuilder private var statusRow: some View {
        HStack {
            Text("Status:")
            switch controller.status {
            case .stopped:
                Text("Stopped").foregroundStyle(.secondary)
            case .listening(let addrs, let port):
                Text("Listening on \(addrs.joined(separator: ", ")):\(port)")
                    .foregroundStyle(.green)
            case .disabledNoTailscale:
                Text("Tailscale unavailable").foregroundStyle(.orange)
            case .portUnavailable:
                Text("Port in use").foregroundStyle(.red)
            case .error(let msg):
                Text("Error: \(msg)").foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}
```

- [ ] **Step 10.4: Verify `swift build`**

Run: `swift build 2>&1 | tail -10`

Expected: success. (If SwiftUI imports warn about macOS targets, no action needed.)

- [ ] **Step 10.5: Commit**

```bash
git add Sources/Espalier/Web/
git commit -m "$(cat <<'EOF'
feat(web): WebServerController + Settings pane

Controller subscribes to WebAccessSettings and reconciles the
EspalierKit WebServer's lifetime. Reads Tailscale status via the
LocalAPI, binds to each tailnet IP + 127.0.0.1, installs an
owner-only WhoIs AuthPolicy. Settings pane exposes toggle + port
+ live status line.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Wire into EspalierApp + sidebar context menu + SPECS.md + smoke + PR

**Files:**
- Modify: `Sources/Espalier/EspalierApp.swift`
- Modify: sidebar pane-row context menu (find via grep)
- Modify: `SPECS.md`

- [ ] **Step 11.1: Find the pane-row context menu**

Run:

```bash
grep -rn "LAYOUT-2.7\|contextMenu\|Copy" Sources/Espalier/Views/ | head
```

Expect a SwiftUI file containing `.contextMenu { ... }` on a pane row. Open it; add a "Copy web URL" item gated on `controller.status == .listening`.

- [ ] **Step 11.2: Add "Copy web URL" menu item**

Template — adapt to the actual file:

```swift
if case .listening = controller.status,
   let host = WebURLComposer.chooseHost(from: <computed from controller.status or Tailscale IPs>) {
    Button("Copy web URL") {
        let url = WebURLComposer.url(
            session: launcher.sessionName(for: pane.id),
            host: host,
            port: WebAccessSettings.shared.port
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
```

Verify `controller` + `launcher` are in scope for the menu view; if not, pass them as properties from the owning view.

- [ ] **Step 11.3: Instantiate `WebServerController` in `EspalierApp`**

In `Sources/Espalier/EspalierApp.swift`, next to the existing subsystem setup (look for `ZmxLauncher` instantiation), add:

```swift
@StateObject private var webController: WebServerController = {
    // Match the launcher path used elsewhere:
    let zmxExe = /* existing zmx URL */
    let zmxDir = /* existing ZMX_DIR */
    return WebServerController(
        settings: WebAccessSettings.shared,
        zmxExecutable: zmxExe,
        zmxDir: zmxDir
    )
}()
```

Pass `webController` as an `.environmentObject` onto the relevant views (Settings window and the sidebar view tree).

Add the settings pane to the app's Settings scene:

```swift
Settings {
    TabView {
        // existing tabs (if any)
        WebSettingsPane()
            .environmentObject(webController)
            .tabItem { Label("Web Access", systemImage: "network") }
    }
}
```

On `applicationWillTerminate` (or the equivalent SwiftUI lifecycle hook), call `webController.stop()`.

- [ ] **Step 11.4: Append §14 to `SPECS.md`**

Append to `SPECS.md`:

```markdown
## 14. Web Access

### 14.1 Binding

**WEB-1.1** When web access is enabled, the application shall bind a local HTTP server to each Tailscale IPv4 and IPv6 address reported by the Tailscale LocalAPI, and to `127.0.0.1`, on the user-configured port (default 8799).

**WEB-1.2** The application shall not bind to `0.0.0.0`.

**WEB-1.3** If no Tailscale addresses are available, the application shall not bind the server and shall surface a "Tailscale unavailable" status in the Settings pane.

**WEB-1.4** The feature shall be off by default.

### 14.2 Authorization

**WEB-2.1** The application shall resolve each incoming peer IP via Tailscale LocalAPI `whois` before serving any content at any path.

**WEB-2.2** The application shall accept a connection only when the resolved `UserProfile.LoginName` equals the current Mac's Tailscale `LoginName`.

**WEB-2.3** When `whois` fails or the resolved LoginName differs, the application shall respond with HTTP `403 Forbidden`.

**WEB-2.4** When Tailscale is not running, the application shall refuse all incoming connections (the server is not bound; connections are refused at TCP).

### 14.3 Protocol

**WEB-3.1** The application shall serve a single static page at `/` (and `/index.html`) bundled with vendored xterm.js.

**WEB-3.2** The application shall upgrade `/ws?session=<name>` to WebSocket after the authorization check passes.

**WEB-3.3** WebSocket binary frames shall carry raw PTY bytes in both directions.

**WEB-3.4** WebSocket text frames shall carry JSON control envelopes. The only Phase 2 envelope shape shall be `{"type":"resize","cols":<uint16>,"rows":<uint16>}`.

### 14.4 Lifecycle

**WEB-4.1** When the user enables web access in Settings, the application shall probe Tailscale, bind, and transition status to `.listening(...)` or an error status.

**WEB-4.2** When the user disables web access, the application shall close all listening sockets and terminate all in-flight `zmx attach` children spawned for the web.

**WEB-4.3** When the application quits, the application shall stop the server (same tear-down as 14.4.2) as part of normal shutdown.

**WEB-4.4** For each incoming WebSocket, the application shall spawn one child `zmx attach <session>` whose PTY it owns (per §13 naming and ZMX_DIR rules from Phase 1).

**WEB-4.5** When a WebSocket closes, the application shall send SIGTERM to the associated `zmx attach` child, leaving the zmx daemon alive.

### 14.5 Client

**WEB-5.1** The bundled client shall render a single terminal (xterm.js) that attaches to the session indicated by the `?session=` query parameter.

**WEB-5.2** The client shall send xterm.js data events as binary WebSocket frames.

**WEB-5.3** The client shall send resize events as JSON control envelopes in text frames.

### 14.6 Non-goals

**WEB-6.1** Phase 2 shall not implement TLS at the application level; the application shall rely on Tailscale transport encryption.

**WEB-6.2** Phase 2 shall not implement a session picker UI, multi-pane layout, mouse events, OSC 52 clipboard sync, or reboot survival.

**WEB-6.3** Phase 2 shall not implement rate limiting, URL tokens, or cookies; authorization shall be via Tailscale WhoIs only.

### 14.7 Cross-references to §13

The web access path uses Phase 1's session-naming and sandbox requirements unchanged. See §13.2 (session naming), §13.3 (`ZMX_DIR` sandbox), §13.4 (lifecycle mapping), and §13.6 (pass-through guarantees).
```

- [ ] **Step 11.5: Full build + full test**

Run: `swift build 2>&1 | tail -15`
Run: `swift test 2>&1 | tail -25`

Expected: build succeeds; tests pass (integration tests skip without zmx but should not fail).

- [ ] **Step 11.6: Commit**

```bash
git add Sources/Espalier/EspalierApp.swift Sources/Espalier/Views SPECS.md
git commit -m "$(cat <<'EOF'
feat(web): wire WebServerController into the app + Sidebar URL menu + SPECS §14

- EspalierApp instantiates WebServerController and adds a Web Access
  tab to the Settings scene.
- Pane-row context menu (LAYOUT-2.7 surface) gains a "Copy web URL"
  item, enabled only when the server is listening.
- SPECS.md §14 codifies binding, authorization, protocol, lifecycle,
  and explicit non-goals; cross-references §13.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 11.7: Manual smoke (maintainer, on hardware with Tailscale)**

Document completion of smoke checklist from spec §Testing → "End-to-end — manual smoke checklist". Six items; mark each OK / NA in the PR description.

- [ ] **Step 11.8: Push + open PR**

```bash
git push -u origin zmx-phase-2
gh pr create --base main --title "zmx integration phase 2 — web access over tailscale" --body "$(cat <<'EOF'
## Summary
- WebSocket server (swift-nio) on Tailscale IPs + 127.0.0.1, off by default
- Tailscale WhoIs owner-only auth gate, fail-closed
- Per-WS child `zmx attach` with a dedicated PTY (new `PtyProcess`)
- JSON control envelope for resize; binary frames for PTY I/O
- Vendored xterm.js 5.3.0 + minimal single-page client
- Settings pane (toggle + port + status); sidebar "Copy web URL" on listening
- SPECS.md §14

## Test plan
- [ ] `swift build`
- [ ] `swift test` (integration test skips without zmx)
- [ ] Enable web access, Copy URL, open in browser on same tailnet, type — both clients see echo
- [ ] Another tailnet user → 403
- [ ] Kill Tailscale → Settings shows "Tailscale unavailable", no port bound
- [ ] Disable in Settings → connection refused

Spec: `docs/superpowers/specs/2026-04-17-zmx-integration-phase-2-design.md`
Plan: `docs/superpowers/plans/2026-04-17-zmx-integration-phase-2.md`
EOF
)"
```

---

## Self-Review Notes

**Spec coverage:**
- Binding posture (§Architecture → Binding posture) → Task 8 (WebServer.bindAddresses), Task 10 (Controller builds the list), SPECS-14.1/2/3.
- Authorization (§Architecture → Authorization) → Task 2 (TailscaleLocalAPI.parseWhois), Task 8 (AuthPolicy + `shouldUpgrade`), SPECS-14.2.
- Protocol (§Architecture → Protocol) → Task 4 (control envelope), Task 8 (WS handler dispatch), SPECS-14.3.
- Components list — all 9 new files have tasks; modifications (Package.swift, EspalierApp.swift, sidebar, SPECS.md) covered in 1, 11.
- Data flows 1–6 → integration test covers Flow 1–4; WebServerController covers Flow 5; app quit (Flow 6) covered by `webController.stop()` in EspalierApp teardown.
- Error modes → auth tests cover denied path; Controller status enum enumerates the error modes; documented in comments. No silent failures.
- Tests: unit tests for TailscaleLocalAPI, PtyProcess, ControlEnvelope, URLComposer; integration for WebServer (both HTTP-only auth test and zmx-gated WS echo).
- Acceptance criteria 1 (all tests pass) → Task 11 step 11.5.
- Acceptance criteria 2 (manual smoke) → Task 11 step 11.7.
- Acceptance criteria 3 (SPECS §14) → Task 11 step 11.4.
- Acceptance criteria 4 (feature off → no sockets, no LocalAPI call) → Controller only probes when `settings.isEnabled == true`; verified by default settings = off.
- Acceptance criteria 5–7 → manual smoke tests in 11.7 + auth tests in 9.1.

**Placeholder scan:** None.

**Type consistency:** `WebServer.AuthPolicy.isAllowed` takes `String` (peerIP) throughout. `WebSession.Config.sessionName: String` matches `HTTPHandler.parseSession` output. `WebServer.Status.listening(addresses: [String], port: Int)` consistent in Task 8, Task 9's tests, and Task 10 (Controller reads it).

**Known fragilities (call out to implementer):**
- NIO API surface varies by version. If `configureHTTPServerPipeline(withServerUpgrade:)` signature differs in installed 2.x, adapt: the tuple `(upgraders:, completionHandler:)` may be named params or a struct.
- The `URLSession.webSocketTask` in Task 9 integration test sometimes requires macOS 11+; the package platform is macOS 14, so fine.
- If `swift build` chokes on `Bundle.module` access from `Sources/EspalierKit/Web/WebStaticResources.swift` because the resources didn't actually get wired, verify the `Package.swift` `.copy("../../Resources/web")` path — alternative: relocate `Resources/web/` under `Sources/EspalierKit/Web/Resources/` and use `.copy("Resources")` or `.process("Resources")`.
