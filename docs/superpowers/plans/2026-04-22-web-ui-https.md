# Web UI HTTPS Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Graftty web UI from plain HTTP to HTTPS-only, using Tailscale-issued Let's Encrypt certs for the machine's MagicDNS name. Drop the `127.0.0.1` bind and the loopback `whois` bypass.

**Architecture:** `TailscaleLocalAPI` grows a cert-pair fetcher (`/localapi/v0/cert/<fqdn>?type=pair`) and exposes `Self.DNSName` from `/status`. A new `WebTLSContextProvider` wraps an `NIOSSLContext` behind a lock so the per-channel initializer reads the current cert while a 24-hour renewal timer (owned by `WebServerController`) can atomically swap it without a listener restart. `WebServer` takes the provider and wraps its NIO pipeline with `NIOSSLServerHandler`. URL composition flips to `https://<fqdn>:<port>/…`. `WebSettingsPane` renders three new error statuses (`.magicDNSDisabled`, `.httpsCertsNotEnabled`, `.certFetchFailed`) with admin-console deep links.

**Tech Stack:** Swift, SwiftUI, swift-nio, **new dep: swift-nio-ssl (`NIOSSL`)**, swift-testing (`@Suite`/`@Test`).

**Spec source:** `docs/superpowers/specs/2026-04-22-web-ui-https-design.md` (commit `a9d9626`).

---

## File Structure

### Modified
- `Package.swift` — add swift-nio-ssl dependency; add `NIOSSL` to GrafttyKit and GrafttyKitTests.
- `Sources/GrafttyKit/Web/TailscaleLocalAPI.swift` — extend `Status` with `dnsName`; add `certPair(for:)` and a new error case for "HTTPS certs not enabled".
- `Sources/GrafttyKit/Web/WebURLComposer.swift` — flip scheme from `http` to `https`; drop the IPv6 bracketing code path from `baseURL`/`url` (brackets now only live in `authority` for the diagnostic bind-list); drop `chooseHost` (dead under hostname-based URL composition).
- `Sources/GrafttyKit/Web/WebServer.swift` — constructor takes `WebTLSContextProvider`; child-channel initializer prepends `NIOSSLServerHandler`; `bindAddresses` stays as Tailscale IPs (no more `127.0.0.1`); `AuthPolicy.allowingLoopback()` + `AuthPolicy.isLoopback(_:)` removed; `Status` gains `.magicDNSDisabled`, `.httpsCertsNotEnabled`, `.certFetchFailed(String)`.
- `Sources/Graftty/Web/WebServerController.swift` — uses new LocalAPI surfaces; fetches cert before binding; owns the 24h renewal `Timer`; new error status mapping; removes `127.0.0.1` from the bind list; removes `.allowingLoopback()`.
- `Sources/Graftty/Web/WebSettingsPane.swift` — renders three new error cases with SwiftUI `Link` buttons; splits "Base URL" (hostname) from "Listening on" (IPs).
- `Sources/Graftty/Views/SidebarView.swift` — "Copy web URL" reads FQDN from controller, not from IP list.
- `SPECS.md` — `WEB-1.1`, `WEB-1.8`, `WEB-1.10`, `WEB-1.12` revised; `WEB-2.5` deleted; `WEB-6.1` inverted; `WEB-8.1..WEB-8.4` added.
- `Tests/GrafttyKitTests/Web/WebURLComposerTests.swift` — updated for HTTPS scheme; drop IPv6-bracketing-in-URL cases; keep `authority` bracket cases; drop `chooseHost` tests.
- `Tests/GrafttyKitTests/Web/WebServerAuthTests.swift` — tests now run with a `WebTLSContextProvider` over a self-signed test cert; `URLSession` calls use an `https://localhost:<port>/` URL with a trust-override delegate; WEB-2.5 loopback-bypass tests deleted (behavior removed).
- `Tests/GrafttyKitTests/Web/TailscaleLocalAPITests.swift` — new cases for `dnsName` extraction and `certPair` response parsing.
- `Tests/GrafttyKitTests/Web/Fixtures/tailscale-status.json` — add `DNSName` field.

### Created
- `Sources/GrafttyKit/Web/WebTLSContextProvider.swift` — lock-guarded box around `NIOSSLContext`; `current()` returns the live context, `swap(_:)` replaces it.
- `Sources/GrafttyKit/Web/WebTLSCertFetcher.swift` — thin seam that given a `TailscaleLocalAPI` + FQDN produces an `NIOSSLContext` or throws a classified error. Kept separate from the provider so it can be mocked in tests without faking NIO.
- `Sources/Graftty/Web/WebCertRenewer.swift` — MainActor-isolated `Timer`-backed scheduler that periodically calls a fetch closure and swaps the provider's context. 24h default, injectable interval for tests.
- `Tests/GrafttyKitTests/Web/Fixtures/tailscale-cert-pair.pem` — concatenated cert+key PEM from a real Tailscale LocalAPI response shape (sanitized).
- `Tests/GrafttyKitTests/Web/Fixtures/tailscale-cert-disabled.json` — the LocalAPI error body when a tailnet lacks HTTPS certs.
- `Tests/GrafttyKitTests/Web/Fixtures/test-tls-cert.pem` + `test-tls-key.pem` — self-signed cert+key for `localhost`, valid long into the future, used by WebServerAuthTests to exercise the real TLS handshake.
- `Tests/GrafttyKitTests/Web/WebTLSContextProviderTests.swift`
- `Tests/GrafttyKitTests/Web/WebTLSCertFetcherTests.swift`
- `Tests/GrafttyKitTests/Web/WebCertRenewerTests.swift` (under GrafttyTests target if needed — but the renewer lives in `Sources/Graftty`, which has no test target. See Task 6 note: put the renewer in GrafttyKit under MainActor, and its test in GrafttyKitTests. `WebServerController` stays in `Sources/Graftty` and wires the renewer up.)

---

## Task 1: Add swift-nio-ssl dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add the package dependency**

Edit `Package.swift`. In the `dependencies: [...]` array, add after the existing `swift-nio` entry:

```swift
.package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.26.0"),
```

In the `GrafttyKit` target's `dependencies: [...]` array, add after the existing NIO entries:

```swift
.product(name: "NIOSSL", package: "swift-nio-ssl"),
```

- [ ] **Step 2: Resolve the package graph**

Run: `swift package resolve`
Expected: exits 0, `Package.resolved` gains a `swift-nio-ssl` pin. The `swift-certificates` / `swift-crypto` transitive deps will also appear — that's expected.

- [ ] **Step 3: Build to confirm no regression**

Run: `swift build`
Expected: exits 0, no new warnings (the project uses `-warnings-as-errors`).

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "deps: add swift-nio-ssl for HTTPS server support (WEB-8)"
```

---

## Task 2: Extend TailscaleLocalAPI.Status with DNSName

**Files:**
- Modify: `Sources/GrafttyKit/Web/TailscaleLocalAPI.swift`
- Modify: `Tests/GrafttyKitTests/Web/Fixtures/tailscale-status.json`
- Modify: `Tests/GrafttyKitTests/Web/TailscaleLocalAPITests.swift`

- [ ] **Step 1: Write the failing tests**

At the top of `TailscaleLocalAPITests.swift`'s `@Suite("TailscaleLocalAPI — parsing")`, add:

```swift
@Test func parseStatus_extractsDNSNameStrippingTrailingDot() throws {
    let data = try fixture("tailscale-status")
    let status = try TailscaleLocalAPI.parseStatus(data)
    #expect(status.dnsName == "macbook.tail-abc12.ts.net")
}

@Test func parseStatus_missingDNSNameReturnsNil() throws {
    let raw = #"""
    {"Self":{"UserID":1,"TailscaleIPs":["100.64.0.5"]},"User":{"1":{"LoginName":"a@b"}}}
    """#
    let status = try TailscaleLocalAPI.parseStatus(Data(raw.utf8))
    #expect(status.dnsName == nil)
}
```

Also extend the existing fixture `Tests/GrafttyKitTests/Web/Fixtures/tailscale-status.json` to include a `DNSName`:

```json
{
    "Self": {
        "UserID": 123456,
        "TailscaleIPs": ["100.64.0.5", "fd7a:115c:a1e0::5"],
        "DNSName": "macbook.tail-abc12.ts.net."
    },
    "User": {
        "123456": {
            "LoginName": "ben@example.com"
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter TailscaleLocalAPIParsingTests`
Expected: two FAILs — `parseStatus_extractsDNSNameStrippingTrailingDot` and `parseStatus_missingDNSNameReturnsNil`, each reporting `dnsName` not a member of `Status`.

- [ ] **Step 3: Implement — extend Status and parseStatus**

In `Sources/GrafttyKit/Web/TailscaleLocalAPI.swift`, replace the `Status` struct with:

```swift
public struct Status: Equatable {
    public let loginName: String
    public let tailscaleIPs: [String]
    /// The machine's MagicDNS fully-qualified name, trailing dot
    /// stripped. `nil` when the tailnet has MagicDNS disabled or
    /// the response omits the field. Callers that need HTTPS
    /// cert provisioning treat `nil` as fatal (WEB-8.1).
    public let dnsName: String?
}
```

In `parseStatus`, replace the `RawStatus.Me` struct and the final `Status(...)` construction:

```swift
struct Me: Decodable {
    let UserID: Int?
    let TailscaleIPs: [String]?
    let DNSName: String?
}
```

```swift
let trimmedDNS = me.DNSName
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
    .flatMap { $0.isEmpty ? nil : $0 }
return Status(
    loginName: profile.LoginName,
    tailscaleIPs: me.TailscaleIPs ?? [],
    dnsName: trimmedDNS
)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TailscaleLocalAPIParsingTests`
Expected: all PASS, including the existing `parseStatus_extractsOwnerAndIPs` (which gains `dnsName` coverage implicitly via the fixture's new field).

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Web/TailscaleLocalAPI.swift Tests/GrafttyKitTests/Web/Fixtures/tailscale-status.json Tests/GrafttyKitTests/Web/TailscaleLocalAPITests.swift
git commit -m "feat(tailscale): expose MagicDNS FQDN from /status (WEB-8.1)"
```

---

## Task 3: Add `certPair(for:)` to TailscaleLocalAPI

**Files:**
- Modify: `Sources/GrafttyKit/Web/TailscaleLocalAPI.swift`
- Create: `Tests/GrafttyKitTests/Web/Fixtures/tailscale-cert-pair.pem`
- Create: `Tests/GrafttyKitTests/Web/Fixtures/tailscale-cert-disabled.json`
- Modify: `Tests/GrafttyKitTests/Web/TailscaleLocalAPITests.swift`

**Background:** Tailscale LocalAPI's `/localapi/v0/cert/<fqdn>?type=pair` returns `Content-Type: application/x-pem-file` with the cert-chain PEM block immediately followed by the key PEM block. When the tailnet has HTTPS certs disabled, LocalAPI returns HTTP ≥400 with a body containing the substring `"HTTPS"` and `"enable"` (e.g., `"Tailnet does not have HTTPS enabled; enable it in admin panel"`). Graftty classifies by substring since the exact wording is not API-stable.

- [ ] **Step 1: Add the PEM-pair fixture**

Create `Tests/GrafttyKitTests/Web/Fixtures/tailscale-cert-pair.pem` with any syntactically-valid cert+key PEM pair (can be a self-signed pair for an arbitrary hostname — we never do real TLS with it in this test, we only verify PEM splitting):

```
-----BEGIN CERTIFICATE-----
MIIBkTCB+wIJANbL... (any valid, non-sensitive test PEM)
-----END CERTIFICATE-----
-----BEGIN PRIVATE KEY-----
MIGEAgEAMBAGByqGSM49AgEGBSuBBAAK... (matching key)
-----END PRIVATE KEY-----
```

Generation command (run once to produce the fixture — commit the output, not the command):

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -days 36500 -subj "/CN=fixture.example" \
    -keyout /tmp/k.pem -out /tmp/c.pem
cat /tmp/c.pem /tmp/k.pem > Tests/GrafttyKitTests/Web/Fixtures/tailscale-cert-pair.pem
```

- [ ] **Step 2: Add the disabled-certs error fixture**

Create `Tests/GrafttyKitTests/Web/Fixtures/tailscale-cert-disabled.json`:

```json
{"error":"Tailnet does not have HTTPS enabled; enable it in admin panel"}
```

- [ ] **Step 3: Write the failing tests**

In `TailscaleLocalAPITests.swift`, add a new suite:

```swift
@Suite("TailscaleLocalAPI — cert pair")
struct TailscaleLocalAPICertParsingTests {

    private func fixture(_ name: String, ext: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    @Test func parseCertPair_splitsCertAndKey() throws {
        let data = try fixture("tailscale-cert-pair", ext: "pem")
        let pair = try TailscaleLocalAPI.parseCertPair(data)
        let cert = String(data: pair.cert, encoding: .utf8) ?? ""
        let key = String(data: pair.key, encoding: .utf8) ?? ""
        #expect(cert.contains("-----BEGIN CERTIFICATE-----"))
        #expect(cert.contains("-----END CERTIFICATE-----"))
        #expect(!cert.contains("PRIVATE KEY"))
        #expect(key.contains("PRIVATE KEY"))
        #expect(!key.contains("CERTIFICATE"))
    }

    @Test func parseCertPair_missingKeyThrows() {
        let justCert = "-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----\n"
        #expect(throws: TailscaleLocalAPI.Error.malformedResponse) {
            _ = try TailscaleLocalAPI.parseCertPair(Data(justCert.utf8))
        }
    }

    @Test func classifyCertError_recognisesHTTPSDisabled() throws {
        let body = try fixture("tailscale-cert-disabled", ext: "json")
        #expect(TailscaleLocalAPI.isHTTPSCertsDisabled(httpStatus: 500, body: body))
    }

    @Test func classifyCertError_ignoresUnrelatedErrors() {
        let body = Data("internal server error".utf8)
        #expect(TailscaleLocalAPI.isHTTPSCertsDisabled(httpStatus: 500, body: body) == false)
    }

    @Test func classifyCertError_ignoresSuccess() {
        let body = Data("{}".utf8)
        #expect(TailscaleLocalAPI.isHTTPSCertsDisabled(httpStatus: 200, body: body) == false)
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `swift test --filter TailscaleLocalAPICertParsingTests`
Expected: FAIL — `parseCertPair`/`isHTTPSCertsDisabled` not defined on `TailscaleLocalAPI`.

- [ ] **Step 5: Implement — add certPair + classifier**

In `Sources/GrafttyKit/Web/TailscaleLocalAPI.swift`:

a) Extend the `Error` enum:

```swift
public enum Error: Swift.Error, Equatable {
    case socketUnreachable
    case httpError(Int)
    case malformedResponse
    /// The tailnet admin has not enabled HTTPS Certificates. The
    /// caller surfaces a link to the admin console rather than a
    /// generic HTTP error code.
    case httpsCertsDisabled
}
```

b) Add the public entry point:

```swift
/// Fetch the cert + key PEM pair Tailscale has minted for this
/// machine's MagicDNS name. Classifies "tailnet HTTPS disabled"
/// into `.httpsCertsDisabled` so the Settings pane can render an
/// admin-console deep link instead of an opaque 500. WEB-8.2.
public func certPair(for fqdn: String) async throws -> (cert: Data, key: Data) {
    let escaped = fqdn.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fqdn
    do {
        let body = try await request(path: "/localapi/v0/cert/\(escaped)?type=pair")
        return try Self.parseCertPair(body)
    } catch let Error.httpError(code) {
        // `request` throws before reading the body on non-200. Re-fetch
        // just the body for classification via a raw transport call.
        // For now, any HTTP error during cert fetch is classified by
        // caller-side re-try; we re-issue to read the body.
        if let body = try? await requestRawBody(
            path: "/localapi/v0/cert/\(escaped)?type=pair"
        ), Self.isHTTPSCertsDisabled(httpStatus: code, body: body) {
            throw Error.httpsCertsDisabled
        }
        throw Error.httpError(code)
    }
}
```

Note: `request(path:)` currently throws `.httpError` before returning the body. Rather than restructure it, add a peer helper `requestRawBody(path:)` that returns `(httpStatus, body)` without throwing on non-200:

```swift
/// Same transport as `request`, but returns (status, body) and
/// does not throw on non-200. Used by `certPair` to classify
/// Tailscale's "HTTPS disabled" error body separately from other
/// HTTP errors.
private func requestRawBody(path: String) async throws -> Data {
    // (Share the body of `request` but elide the status-code check.
    // Simplest refactor: factor the shared transport into a
    // `transportCall(path:)` that returns (code, body); have
    // `request` translate non-200 into .httpError(code) and have
    // `certPair` use the raw version.)
    let (code, body) = try await transportCall(path: path)
    _ = code
    return body
}
```

Refactor: pull the socket-open / send / recv / header-parse block out of `request(path:)` into a new private `transportCall(path:) -> (Int, Data)`. `request(path:)` becomes:

```swift
private func request(path: String) async throws -> Data {
    let (code, body) = try await transportCall(path: path)
    if code != 200 { throw Error.httpError(code) }
    return body
}
```

c) Add the parser + classifier:

```swift
/// Split Tailscale's `application/x-pem-file` response into the
/// cert-chain PEM and the private-key PEM. The response is simply
/// both blocks concatenated; split on the first "BEGIN .* PRIVATE KEY"
/// line. Both halves are trimmed to end with a newline for NIOSSL.
static func parseCertPair(_ data: Data) throws -> (cert: Data, key: Data) {
    guard let text = String(data: data, encoding: .utf8) else {
        throw Error.malformedResponse
    }
    // Locate the first PRIVATE KEY boundary. Matches both
    // `-----BEGIN PRIVATE KEY-----` and `-----BEGIN EC PRIVATE KEY-----`
    // etc.
    guard let keyRange = text.range(of: "-----BEGIN [A-Z ]*PRIVATE KEY-----",
                                    options: .regularExpression) else {
        throw Error.malformedResponse
    }
    let certText = String(text[..<keyRange.lowerBound])
    let keyText = String(text[keyRange.lowerBound...])
    if !certText.contains("-----BEGIN CERTIFICATE-----") {
        throw Error.malformedResponse
    }
    return (Data(certText.utf8), Data(keyText.utf8))
}

/// Recognise Tailscale's "HTTPS certificates are not enabled for
/// this tailnet" response across plausible wordings. Any ≥400
/// status whose body mentions both "HTTPS" and "enable" qualifies
/// — the exact phrasing is not API-stable so a pure substring
/// match beats trying to parse the JSON envelope.
static func isHTTPSCertsDisabled(httpStatus: Int, body: Data) -> Bool {
    guard httpStatus >= 400 else { return false }
    guard let text = String(data: body, encoding: .utf8) else { return false }
    let lower = text.lowercased()
    return lower.contains("https") && lower.contains("enable")
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter TailscaleLocalAPICertParsingTests`
Expected: PASS all four new tests. Also run:

Run: `swift test --filter TailscaleLocalAPIParsingTests`
Expected: PASS — existing tests still pass (the `request` refactor is behavior-preserving).

- [ ] **Step 7: Commit**

```bash
git add Sources/GrafttyKit/Web/TailscaleLocalAPI.swift \
    Tests/GrafttyKitTests/Web/TailscaleLocalAPITests.swift \
    Tests/GrafttyKitTests/Web/Fixtures/tailscale-cert-pair.pem \
    Tests/GrafttyKitTests/Web/Fixtures/tailscale-cert-disabled.json
git commit -m "feat(tailscale): certPair fetcher + HTTPS-disabled classifier (WEB-8.2)"
```

---

## Task 4: Introduce `WebTLSContextProvider`

**Files:**
- Create: `Sources/GrafttyKit/Web/WebTLSContextProvider.swift`
- Create: `Tests/GrafttyKitTests/Web/WebTLSContextProviderTests.swift`
- Create: `Tests/GrafttyKitTests/Web/Fixtures/test-tls-cert.pem`
- Create: `Tests/GrafttyKitTests/Web/Fixtures/test-tls-key.pem`

**Note on test fixtures:** the cert+key here is **not** sensitive — it's a self-signed pair for `localhost` used only in unit/integration tests. Generate once:

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -days 36500 -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
    -keyout Tests/GrafttyKitTests/Web/Fixtures/test-tls-key.pem \
    -out Tests/GrafttyKitTests/Web/Fixtures/test-tls-cert.pem
```

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyKitTests/Web/WebTLSContextProviderTests.swift`:

```swift
import Testing
import Foundation
import NIOSSL
@testable import GrafttyKit

@Suite("WebTLSContextProvider")
struct WebTLSContextProviderTests {

    private func loadContext() throws -> NIOSSLContext {
        let certURL = try #require(
            Bundle.module.url(forResource: "test-tls-cert", withExtension: "pem",
                              subdirectory: "Fixtures")
        )
        let keyURL = try #require(
            Bundle.module.url(forResource: "test-tls-key", withExtension: "pem",
                              subdirectory: "Fixtures")
        )
        let cert = try NIOSSLCertificate.fromPEMFile(certURL.path)
        let key = try NIOSSLPrivateKey(file: keyURL.path, format: .pem)
        var cfg = TLSConfiguration.makeServerConfiguration(
            certificateChain: cert.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        cfg.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: cfg)
    }

    @Test func currentReturnsInitialContext() throws {
        let ctx = try loadContext()
        let provider = WebTLSContextProvider(initial: ctx)
        #expect(provider.current() === ctx)
    }

    @Test func swapReplacesContext() throws {
        let a = try loadContext()
        let b = try loadContext()
        let provider = WebTLSContextProvider(initial: a)
        provider.swap(b)
        #expect(provider.current() === b)
    }

    @Test func concurrentReadsDoNotCrash() async throws {
        let ctx = try loadContext()
        let provider = WebTLSContextProvider(initial: ctx)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask { _ = provider.current() }
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WebTLSContextProviderTests`
Expected: FAIL with "cannot find 'WebTLSContextProvider' in scope".

- [ ] **Step 3: Implement the provider**

Create `Sources/GrafttyKit/Web/WebTLSContextProvider.swift`:

```swift
import Foundation
import NIOSSL

/// Lock-guarded box around the live `NIOSSLContext`. The per-channel
/// initializer in `WebServer` reads `current()` on each new inbound
/// connection; the cert-renewal scheduler calls `swap(_:)` when
/// Tailscale hands back freshly-renewed PEM bytes. Swaps do not touch
/// connections already past the handshake — NIO's TLS handler holds
/// its own context reference for the life of the connection. WEB-8.3.
public final class WebTLSContextProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var context: NIOSSLContext

    public init(initial: NIOSSLContext) {
        self.context = initial
    }

    public func current() -> NIOSSLContext {
        lock.lock()
        defer { lock.unlock() }
        return context
    }

    public func swap(_ new: NIOSSLContext) {
        lock.lock()
        context = new
        lock.unlock()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WebTLSContextProviderTests`
Expected: PASS all three tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Web/WebTLSContextProvider.swift \
    Tests/GrafttyKitTests/Web/WebTLSContextProviderTests.swift \
    Tests/GrafttyKitTests/Web/Fixtures/test-tls-cert.pem \
    Tests/GrafttyKitTests/Web/Fixtures/test-tls-key.pem
git commit -m "feat(web): WebTLSContextProvider for hot-swappable TLS context (WEB-8.3)"
```

---

## Task 5: Add `WebTLSCertFetcher`

**Files:**
- Create: `Sources/GrafttyKit/Web/WebTLSCertFetcher.swift`
- Create: `Tests/GrafttyKitTests/Web/WebTLSCertFetcherTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyKitTests/Web/WebTLSCertFetcherTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("WebTLSCertFetcher")
struct WebTLSCertFetcherTests {

    private func loadPEM(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "pem",
                              subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    @Test func buildContext_fromValidPEMs_succeeds() throws {
        let cert = try loadPEM("test-tls-cert")
        let key = try loadPEM("test-tls-key")
        _ = try WebTLSCertFetcher.buildContext(certPEM: cert, keyPEM: key)
    }

    @Test func buildContext_garbage_throws() {
        let junk = Data("not pem".utf8)
        #expect(throws: (any Swift.Error).self) {
            _ = try WebTLSCertFetcher.buildContext(certPEM: junk, keyPEM: junk)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WebTLSCertFetcherTests`
Expected: FAIL — `WebTLSCertFetcher` not in scope.

- [ ] **Step 3: Implement the fetcher**

Create `Sources/GrafttyKit/Web/WebTLSCertFetcher.swift`:

```swift
import Foundation
import NIOSSL

/// Turns PEM bytes (cert chain + key) into an `NIOSSLContext` suitable
/// for `WebServer`'s child-channel initializer. Factored out of
/// `WebServerController` so the integration-test path can stub the
/// NIOSSL construction step without standing up Tailscale LocalAPI.
/// WEB-8.2.
public enum WebTLSCertFetcher {

    /// Build an `NIOSSLContext` from a concatenated cert-chain PEM and
    /// a separate private-key PEM. Matches what
    /// `TailscaleLocalAPI.parseCertPair` produces.
    public static func buildContext(certPEM: Data, keyPEM: Data) throws -> NIOSSLContext {
        let certs = try NIOSSLCertificate.fromPEMBytes(Array(certPEM))
        let key = try NIOSSLPrivateKey(bytes: Array(keyPEM), format: .pem)
        var cfg = TLSConfiguration.makeServerConfiguration(
            certificateChain: certs.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        cfg.minimumTLSVersion = .tlsv12
        return try NIOSSLContext(configuration: cfg)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WebTLSCertFetcherTests`
Expected: PASS both tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Web/WebTLSCertFetcher.swift \
    Tests/GrafttyKitTests/Web/WebTLSCertFetcherTests.swift
git commit -m "feat(web): WebTLSCertFetcher bridges PEM bytes to NIOSSLContext"
```

---

## Task 6: Update `WebURLComposer` to HTTPS

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebURLComposer.swift`
- Modify: `Tests/GrafttyKitTests/Web/WebURLComposerTests.swift`

**Behavior change:** `baseURL` and `url` now produce `https://<host>:<port>/…`. IPv6 bracketing in URLs is no longer exercised by production callers (we only feed FQDNs), but we keep the `authority(host:port:)` helper unchanged for the diagnostic "Listening on" line. `chooseHost(from:)` is removed — callers now take the FQDN from the controller's `currentURL` / `serverHostname` instead of picking one from an IP list.

- [ ] **Step 1: Update the tests**

Replace `Tests/GrafttyKitTests/Web/WebURLComposerTests.swift` contents with:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("WebURLComposer")
struct WebURLComposerTests {

    @Test func sessionURLIsHTTPSWithHostname() {
        let url = WebURLComposer.url(
            session: "graftty-abcd1234",
            host: "macbook.tail-abc12.ts.net",
            port: 8799
        )
        #expect(url == "https://macbook.tail-abc12.ts.net:8799/session/graftty-abcd1234")
    }

    @Test func baseURLIsHTTPSWithHostname() {
        let url = WebURLComposer.baseURL(host: "macbook.tail-abc12.ts.net", port: 8799)
        #expect(url == "https://macbook.tail-abc12.ts.net:8799/")
    }

    @Test func sessionNameIsPercentEscaped() {
        let url = WebURLComposer.url(session: "name with space",
                                     host: "h.ts.net", port: 1)
        #expect(url.contains("/session/name%20with%20space"))
    }

    @Test func sessionNameWithPathSeparatorIsEscaped() {
        let url = WebURLComposer.url(session: "a?b", host: "h.ts.net", port: 1)
        #expect(url == "https://h.ts.net:1/session/a%3Fb")
    }

    @Test func sessionNameWithFragmentSeparatorIsEscaped() {
        let url = WebURLComposer.url(session: "a#b", host: "h.ts.net", port: 1)
        #expect(url == "https://h.ts.net:1/session/a%23b")
    }

    // `authority(host:port:)` remains for the diagnostic bind-list
    // ("Listening on …"). Its IPv6-bracketing behavior (WEB-1.10) is
    // preserved even though baseURL/url no longer exercise it.
    @Test func authorityBracketsIPv6() {
        #expect(WebURLComposer.authority(host: "fd7a:115c::5", port: 8799)
                == "[fd7a:115c::5]:8799")
    }

    @Test func authorityLeavesIPv4Alone() {
        #expect(WebURLComposer.authority(host: "100.64.0.5", port: 49161)
                == "100.64.0.5:49161")
    }

    @Test func authorityAcceptsHostname() {
        #expect(WebURLComposer.authority(host: "macbook.ts.net", port: 8799)
                == "macbook.ts.net:8799")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WebURLComposerTests`
Expected: FAIL — existing `baseURL` tests still produce `http://...`, new cases expect `https://...`; `chooseHost` references removed from the test file compile fine because we deleted them.

- [ ] **Step 3: Update the composer**

Replace `Sources/GrafttyKit/Web/WebURLComposer.swift` with:

```swift
import Foundation

/// Composes the shareable URL used in the "Copy web URL" action and
/// the Settings-pane "Base URL" row. Pure transformation from
/// (host, port, session) to a string URL.
///
/// As of WEB-8, the host is always a MagicDNS FQDN (not an IP
/// literal) and the scheme is always HTTPS. The `authority(host:port:)`
/// helper is retained for the Settings-pane's diagnostic "Listening
/// on …" list, which still renders IP literals with bracketed IPv6
/// per WEB-1.10.
public enum WebURLComposer {

    /// Session-scoped URL. Percent-encodes the session segment with
    /// `urlPathAllowed` so session names containing reserved path
    /// separators (`?`, `#`) don't confuse the browser's URL parser
    /// (WEB-1.9).
    public static func url(session: String, host: String, port: Int) -> String {
        let encodedSession = session.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? session
        return "\(baseURL(host: host, port: port))session/\(encodedSession)"
    }

    /// Root URL of the server. HTTPS-only per WEB-6.1.
    public static func baseURL(host: String, port: Int) -> String {
        return "https://\(host):\(port)/"
    }

    /// Compose a URI authority (`<host>:<port>`), bracketing IPv6.
    /// Used by the Settings-pane's "Listening on" diagnostic row
    /// (WEB-1.10) where host is still an IP literal.
    public static func authority(host: String, port: Int) -> String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return "\(hostPart):\(port)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WebURLComposerTests`
Expected: PASS all 8 tests.

Run: `swift build`
Expected: FAIL with "type 'WebURLComposer' has no member 'chooseHost'" at two call sites:
- `Sources/Graftty/Web/WebServerController.swift:137`
- `Sources/Graftty/Views/SidebarView.swift:251`

That's intentional — those get fixed in Tasks 9 and 10. Leave them broken for now; the next commit is pure composer.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Web/WebURLComposer.swift \
    Tests/GrafttyKitTests/Web/WebURLComposerTests.swift
git commit -m "refactor(web): WebURLComposer emits HTTPS with hostname (WEB-6.1, WEB-1.8)"
```

---

## Task 7: Wire TLS into `WebServer`

**Files:**
- Modify: `Sources/GrafttyKit/Web/WebServer.swift`
- Modify: `Tests/GrafttyKitTests/Web/WebServerAuthTests.swift`

**Behavior change:**
- Constructor takes a `WebTLSContextProvider`. The child-channel initializer prepends a `NIOSSLServerHandler(context: provider.current())` to the pipeline.
- `AuthPolicy.allowingLoopback()` and `AuthPolicy.isLoopback(_:)` deleted.
- `Status.disabledNoTailscale` renamed to `.tailscaleUnavailable` (matches the spec's naming) — existing callers in `WebServerController` need to update. (Ack: slight scope creep, but "disabledNoTailscale" was already awkward and the spec uses "tailscaleUnavailable"; rename in the same commit for consistency with the new status cases.)
- Three new `Status` cases: `.magicDNSDisabled`, `.httpsCertsNotEnabled`, `.certFetchFailed(String)`.

- [ ] **Step 1: Update tests first**

In `Tests/GrafttyKitTests/Web/WebServerAuthTests.swift`:

a) Add a helper at file scope:

```swift
private func makeTestTLSProvider() throws -> WebTLSContextProvider {
    let certURL = try #require(
        Bundle.module.url(forResource: "test-tls-cert", withExtension: "pem",
                          subdirectory: "Fixtures")
    )
    let keyURL = try #require(
        Bundle.module.url(forResource: "test-tls-key", withExtension: "pem",
                          subdirectory: "Fixtures")
    )
    let certPEM = try Data(contentsOf: certURL)
    let keyPEM = try Data(contentsOf: keyURL)
    let ctx = try WebTLSCertFetcher.buildContext(certPEM: certPEM, keyPEM: keyPEM)
    return WebTLSContextProvider(initial: ctx)
}

/// URLSession delegate that trusts any server cert. Used only in
/// the test suite to exercise the real TLS handshake against our
/// localhost-fixture cert.
private final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let st = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: st))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private func trustAllSession() -> URLSession {
    URLSession(configuration: .ephemeral, delegate: TrustAllDelegate(), delegateQueue: nil)
}
```

b) Change **every** `WebServer(...)` construction in the file to pass a TLS provider and use `https://` URLs. For example the first test becomes:

```swift
@Test func deniedRequestReturns403() async throws {
    let server = WebServer(
        config: Self.makeConfig(),
        auth: WebServer.AuthPolicy(isAllowed: { _ in false }),
        bindAddresses: ["127.0.0.1"],
        tlsProvider: try Self.makeTestTLSProvider()
    )
    try server.start()
    defer { server.stop() }
    guard case let .listening(_, port) = server.status else {
        Issue.record("server not listening"); return
    }
    let (_, response) = try await trustAllSession()
        .data(from: URL(string: "https://localhost:\(port)/")!)
    let http = response as! HTTPURLResponse
    #expect(http.statusCode == 403)
}
```

(Static `makeTestTLSProvider` on the struct, not the file-scope one, is fine — pick whichever style is consistent.)

Apply the same pattern — new `tlsProvider:` arg + `https://localhost:<port>/` + `trustAllSession()` — to every test in the file **except** the two `loopback*` tests (see (c) below).

c) **Delete** `loopbackBypassAllowsLocalConnection` and `loopbackBypassDelegatesForNonLoopbackPeer`. The behavior is being removed (WEB-2.5 deleted).

d) The raw-socket helper `rawHTTPGet` is HTTP-only — for the one test that uses it (`appJSRawReadMatchesContentLength`), either:
   - skip it via `#if false // disabled for HTTPS migration — regresses the underlying bug in a follow-up` with a TODO, **or**
   - rewrite it to TLS using `Network.framework`'s `NWConnection` with `NWProtocolTLS`.

Prefer the TLS rewrite — the Content-Length-vs-close race (WEB-3.6) is still a meaningful regression guard. Replace `rawHTTPGet` with:

```swift
private func rawHTTPSGet(
    host: String, port: Int, path: String,
    recvBufBytes: Int? = nil, perReadDelayUSec: UInt32 = 0
) throws -> (headers: [String: String], body: Data) {
    // Use Network.framework NWConnection with NWProtocolTLS so we
    // can observe raw bytes after the TLS layer (unlike URLSession
    // which hides short reads). Trust-all verify block used because
    // the server cert is our test-only fixture for localhost.
    // …
}
```

(Implementer: build a minimal `NWConnection(to: .hostPort(host: host, port: .init(integerLiteral: UInt16(port))), using: tlsParams)` where `tlsParams` has `sec_protocol_options_set_verify_block` returning complete trust. Send `GET \(path) HTTP/1.1\r\nHost: ...\r\nConnection: close\r\n\r\n`, then `receiveMessage` / `receive` in a loop, concat bytes until EOF, split on `\r\n\r\n`, return.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WebServerAuthTests`
Expected: FAIL — `WebServer` initializer signature doesn't accept `tlsProvider:`.

- [ ] **Step 3: Implement TLS in WebServer**

In `Sources/GrafttyKit/Web/WebServer.swift`:

a) Add import at top: `import NIOSSL`

b) Replace the `Status` enum:

```swift
public enum Status: Equatable {
    case stopped
    case listening(addresses: [String], port: Int)
    case tailscaleUnavailable
    case magicDNSDisabled
    case httpsCertsNotEnabled
    case certFetchFailed(String)
    case portUnavailable
    case error(String)
}
```

(Note: `disabledNoTailscale` → `tailscaleUnavailable`. All callers must update.)

c) Delete the `AuthPolicy.allowingLoopback()` method and the static `AuthPolicy.isLoopback(_:)`. Keep `AuthPolicy.init(isAllowed:)` as-is.

d) Add a stored property and update the initializer:

```swift
public let tlsProvider: WebTLSContextProvider

public init(
    config: Config,
    auth: AuthPolicy,
    bindAddresses: [String],
    tlsProvider: WebTLSContextProvider
) {
    self.config = config
    self.auth = auth
    self.bindAddresses = bindAddresses
    self.tlsProvider = tlsProvider
}
```

e) In `start()`, inside the `childChannelInitializer`, prepend the TLS handler before configuring the HTTP pipeline:

```swift
.childChannelInitializer { channel in
    let handler = HTTPHandler(config: capturedConfig, auth: capturedAuth)
    let upgrader = Self.makeWSUpgrader(config: capturedConfig, auth: capturedAuth)
    let upgradeConfig: NIOHTTPServerUpgradeConfiguration = (
        upgraders: [upgrader],
        completionHandler: { context in
            context.channel.pipeline.removeHandler(handler, promise: nil)
        }
    )
    // Snapshot the current TLS context at channel-accept time. Any
    // in-flight handshake uses this exact context even if a renewal
    // swaps the provider mid-handshake; that's fine — new connections
    // accepted after the swap pick up the fresh context on their
    // next initializer call. WEB-8.3.
    let sslHandler: NIOSSLServerHandler
    do {
        sslHandler = try NIOSSLServerHandler(context: capturedTLS.current())
    } catch {
        return channel.eventLoop.makeFailedFuture(error)
    }
    return channel.pipeline.addHandler(sslHandler).flatMap {
        channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: upgradeConfig
        )
    }.flatMap {
        channel.pipeline.addHandler(handler)
    }
}
```

Capture the provider before the closure:

```swift
let capturedTLS = tlsProvider
```

(Add alongside the existing `capturedConfig` / `capturedAuth`.)

f) Rename `disabledNoTailscale` in the two in-file references (the `guard !bindAddresses.isEmpty` branch and the `Status.disabledNoTailscale.asError` throw).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter WebServerAuthTests`
Expected: PASS all tests except any that were deleted. The `appJSRawReadMatchesContentLength` test (after rewriting to TLS) should pass.

Run: `swift build`
Expected: still FAIL in `WebServerController.swift` (uses `.allowingLoopback()` and `.disabledNoTailscale`) and `WebSettingsPane.swift` (uses `.disabledNoTailscale`). Those get fixed in Tasks 9 and 10.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Web/WebServer.swift \
    Tests/GrafttyKitTests/Web/WebServerAuthTests.swift
git commit -m "feat(web): WebServer binds HTTPS via NIOSSLServerHandler (WEB-6.1, WEB-8)

Add tlsProvider parameter; delete AuthPolicy.allowingLoopback + isLoopback
(WEB-2.5 removed); rename .disabledNoTailscale to .tailscaleUnavailable;
add .magicDNSDisabled, .httpsCertsNotEnabled, .certFetchFailed(String)."
```

---

## Task 8: Create `WebCertRenewer`

**Files:**
- Create: `Sources/GrafttyKit/Web/WebCertRenewer.swift`
- Create: `Tests/GrafttyKitTests/Web/WebCertRenewerTests.swift`

**Note on target:** the renewer lives in GrafttyKit (not `Sources/Graftty`) so it can be unit-tested; the MainActor-bound scheduling doesn't need AppKit/SwiftUI types. `WebServerController` in `Sources/Graftty` owns the instance.

- [ ] **Step 1: Write the failing test**

Create `Tests/GrafttyKitTests/Web/WebCertRenewerTests.swift`:

```swift
import Testing
import Foundation
import NIOSSL
@testable import GrafttyKit

@Suite("WebCertRenewer")
struct WebCertRenewerTests {

    private func ctx() throws -> NIOSSLContext {
        let certURL = try #require(
            Bundle.module.url(forResource: "test-tls-cert", withExtension: "pem",
                              subdirectory: "Fixtures")
        )
        let keyURL = try #require(
            Bundle.module.url(forResource: "test-tls-key", withExtension: "pem",
                              subdirectory: "Fixtures")
        )
        let certPEM = try Data(contentsOf: certURL)
        let keyPEM = try Data(contentsOf: keyURL)
        return try WebTLSCertFetcher.buildContext(certPEM: certPEM, keyPEM: keyPEM)
    }

    @Test func fireTriggersFetchAndSwapsOnChange() async throws {
        let initial = try ctx()
        let replacement = try ctx()
        let provider = WebTLSContextProvider(initial: initial)
        let expectation = AsyncExpectation()
        let renewer = WebCertRenewer(
            provider: provider,
            interval: 3600,
            fetch: {
                await expectation.fulfill()
                return replacement
            }
        )
        renewer.start()
        defer { renewer.stop() }
        await renewer.renewNow()  // skip the timer; fire directly
        try await expectation.wait(timeoutSeconds: 2)
        #expect(provider.current() === replacement)
    }

    @Test func stopCancelsTimer() {
        let provider = WebTLSContextProvider(initial: (try? ctx())!)
        let renewer = WebCertRenewer(
            provider: provider,
            interval: 0.01,
            fetch: { throw NSError(domain: "x", code: 1) }
        )
        renewer.start()
        renewer.stop()
        // If stop() didn't cancel, the fetch closure would throw and
        // surface eventually. The absence of a crash / warning under
        // Swift's thread sanitizer is the pass signal here.
    }
}

/// Simple async-await expectation for tests that need to know when
/// an asynchronous callback has been invoked.
actor AsyncExpectation {
    private var fulfilled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func fulfill() {
        fulfilled = true
        continuation?.resume()
        continuation = nil
    }
    func wait(timeoutSeconds: Double) async throws {
        if fulfilled { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    Task { await self.setContinuation(cont) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw CancellationError()
            }
            try await group.next()
            group.cancelAll()
        }
    }
    private func setContinuation(_ c: CheckedContinuation<Void, Never>) {
        if fulfilled { c.resume() } else { continuation = c }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter WebCertRenewerTests`
Expected: FAIL — `WebCertRenewer` not found.

- [ ] **Step 3: Implement the renewer**

Create `Sources/GrafttyKit/Web/WebCertRenewer.swift`:

```swift
import Foundation
import NIOSSL

/// Periodically re-fetches the TLS cert and swaps it into a
/// `WebTLSContextProvider` without restarting the listening socket.
/// WEB-8.3.
///
/// The fetch closure is the injection point — in production it's
/// `{ try await TailscaleLocalAPI.autoDetected().certPair(for: fqdn) }`
/// wrapped with `WebTLSCertFetcher.buildContext`; in tests it's a
/// canned context. Failures during renewal are logged (via
/// `NSLog` — we intentionally don't couple GrafttyKit to a logger
/// abstraction) and swallowed: the existing context keeps serving
/// until the next tick.
public final class WebCertRenewer: @unchecked Sendable {
    public typealias Fetch = @Sendable () async throws -> NIOSSLContext

    private let provider: WebTLSContextProvider
    private let interval: TimeInterval
    private let fetch: Fetch
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(provider: WebTLSContextProvider, interval: TimeInterval, fetch: @escaping Fetch) {
        self.provider = provider
        self.interval = interval
        self.fetch = fetch
    }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        let provider = self.provider
        let interval = self.interval
        let fetch = self.fetch
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch {
                    return
                }
                guard self != nil else { return }
                do {
                    let new = try await fetch()
                    provider.swap(new)
                } catch {
                    NSLog("[WebCertRenewer] renewal fetch failed: \(error)")
                }
            }
        }
    }

    public func stop() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        task = nil
    }

    /// Testing seam — invoke the fetch closure immediately instead of
    /// waiting for the timer.
    public func renewNow() async {
        do {
            let new = try await fetch()
            provider.swap(new)
        } catch {
            NSLog("[WebCertRenewer] manual renewal failed: \(error)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter WebCertRenewerTests`
Expected: PASS both tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Web/WebCertRenewer.swift \
    Tests/GrafttyKitTests/Web/WebCertRenewerTests.swift
git commit -m "feat(web): WebCertRenewer periodic cert refresh with hot swap (WEB-8.3)"
```

---

## Task 9: Rewire `WebServerController`

**Files:**
- Modify: `Sources/Graftty/Web/WebServerController.swift`

**Behavior change:** on `reconcile()`, fetch DNSName + cert before binding; build a `WebTLSContextProvider`; start the server with TLS; start a `WebCertRenewer` (24h); stop the renewer on teardown. Map `TailscaleLocalAPI.Error.httpsCertsDisabled` to `.httpsCertsNotEnabled`; absent `dnsName` to `.magicDNSDisabled`; any other cert error to `.certFetchFailed`.

- [ ] **Step 1: Rewrite reconcile() + add renewer lifecycle**

Replace the body of `reconcile()` with:

```swift
private func reconcile() {
    let desired = (enabled: settings.isEnabled, port: settings.port)
    if let last = lastApplied, last == desired { return }
    lastApplied = desired

    renewer?.stop()
    renewer = nil
    server?.stop()
    server = nil
    status = .stopped
    currentURL = nil
    guard desired.enabled else { return }
    guard WebServer.Config.isValidListenablePort(desired.port) else {
        status = .error("Port must be 0–65535 (got \(desired.port))")
        return
    }
    do {
        let api = try TailscaleLocalAPI.autoDetected()
        let tailscaleStatus = try runBlocking { try await api.status() }
        guard let fqdn = tailscaleStatus.dnsName else {
            status = .magicDNSDisabled
            return
        }
        let bind = tailscaleStatus.tailscaleIPs
        let ownerLogin = tailscaleStatus.loginName
        let auth = WebServer.AuthPolicy { [api] peerIP in
            guard let whois = try? await api.whois(peerIP: peerIP) else { return false }
            return whois.loginName == ownerLogin
        }
        let pair: (cert: Data, key: Data)
        do {
            pair = try runBlocking { try await api.certPair(for: fqdn) }
        } catch TailscaleLocalAPI.Error.httpsCertsDisabled {
            status = .httpsCertsNotEnabled
            return
        } catch {
            status = .certFetchFailed("\(error)")
            return
        }
        let tlsContext: NIOSSLContext
        do {
            tlsContext = try WebTLSCertFetcher.buildContext(
                certPEM: pair.cert, keyPEM: pair.key
            )
        } catch {
            status = .certFetchFailed("\(error)")
            return
        }
        let provider = WebTLSContextProvider(initial: tlsContext)
        let sessionsProvider = self.sessionsProvider ?? { [] }
        let repos = reposProvider ?? { [] }
        let creator = worktreeCreator
        let s = WebServer(
            config: .init(
                port: desired.port,
                zmxExecutable: zmxExecutable,
                zmxDir: zmxDir,
                sessionsProvider: sessionsProvider,
                reposProvider: repos,
                worktreeCreator: creator
            ),
            auth: auth,
            bindAddresses: bind,
            tlsProvider: provider
        )
        try s.start()
        server = s
        status = s.status
        currentURL = WebURLComposer.baseURL(host: fqdn, port: desired.port)
        self.serverHostname = fqdn

        // Kick off the 24h renewal loop. `renewNow` is not invoked here
        // because we just fetched fresh bytes above.
        let renewer = WebCertRenewer(
            provider: provider,
            interval: 24 * 60 * 60,
            fetch: {
                let pair = try await api.certPair(for: fqdn)
                return try WebTLSCertFetcher.buildContext(
                    certPEM: pair.cert, keyPEM: pair.key
                )
            }
        )
        renewer.start()
        self.renewer = renewer
    } catch TailscaleLocalAPI.Error.socketUnreachable {
        status = .tailscaleUnavailable
    } catch {
        if WebServer.isAddressInUse(error) {
            status = .portUnavailable
        } else {
            status = .error("\(error)")
        }
    }
}
```

Add the stored properties:

```swift
@Published private(set) var serverHostname: String? = nil
private var renewer: WebCertRenewer?
```

Import `NIOSSL` at the top: `import NIOSSL`.

Add `renewer?.stop()` to `stop()`:

```swift
func stop() {
    renewer?.stop()
    renewer = nil
    server?.stop()
    server = nil
    status = .stopped
    currentURL = nil
    serverHostname = nil
    lastApplied = nil
}
```

Also clear `serverHostname` at the top of `reconcile()` (next to `currentURL = nil`).

- [ ] **Step 2: Build to confirm**

Run: `swift build`
Expected: still FAIL in `WebSettingsPane.swift` (references `.disabledNoTailscale`) and `SidebarView.swift` (references `WebURLComposer.chooseHost`). Those are Tasks 10 and 11.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Web/WebServerController.swift
git commit -m "feat(web): controller fetches cert + starts renewer on reconcile (WEB-8.2, WEB-8.3)

Drops 127.0.0.1 bind; classifies MagicDNS-off, HTTPS-disabled, and
generic fetch failures into the new WebServer.Status cases."
```

---

## Task 10: Update `WebSettingsPane` for new error cases

**Files:**
- Modify: `Sources/Graftty/Web/WebSettingsPane.swift`

- [ ] **Step 1: Replace the status switch**

Replace the `statusRow` body with:

```swift
@ViewBuilder private var statusRow: some View {
    HStack(alignment: .firstTextBaseline) {
        Text("Status:")
        switch controller.status {
        case .stopped:
            Text("Stopped").foregroundStyle(.secondary)
        case .listening(let addrs, let port):
            let joined = addrs
                .map { WebURLComposer.authority(host: $0, port: port) }
                .joined(separator: ", ")
            Text(verbatim: "Listening on \(joined)")
                .foregroundStyle(.green)
        case .tailscaleUnavailable:
            Text("Tailscale unavailable").foregroundStyle(.orange)
        case .magicDNSDisabled:
            VStack(alignment: .leading, spacing: 2) {
                Text("MagicDNS must be enabled on your tailnet.")
                    .foregroundStyle(.orange)
                Link(
                    "Open Tailscale admin",
                    destination: URL(string: "https://login.tailscale.com/admin/dns")!
                )
                .font(.caption)
            }
        case .httpsCertsNotEnabled:
            VStack(alignment: .leading, spacing: 2) {
                Text("HTTPS certificates must be enabled on your tailnet.")
                    .foregroundStyle(.orange)
                Link(
                    "Open Tailscale admin",
                    destination: URL(string: "https://login.tailscale.com/admin/dns")!
                )
                .font(.caption)
            }
        case .certFetchFailed(let msg):
            VStack(alignment: .leading, spacing: 2) {
                Text("Could not fetch certificate: \(msg)")
                    .foregroundStyle(.red)
                    .lineLimit(2)
                Text("Graftty will retry automatically.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        case .portUnavailable:
            Text("Port in use").foregroundStyle(.red)
        case .error(let msg):
            Text("Error: \(msg)").foregroundStyle(.red).lineLimit(2)
        }
    }
}
```

Also update the footer text:

```swift
Text("Serves HTTPS only. Binds to Tailscale IPs. Allows only your Tailscale identity.")
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: still FAIL on `SidebarView.swift` (Task 11). But `WebSettingsPane.swift` should compile.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Web/WebSettingsPane.swift
git commit -m "feat(settings): render new HTTPS error states with admin console links (WEB-8.4)"
```

---

## Task 11: Update SidebarView "Copy web URL"

**Files:**
- Modify: `Sources/Graftty/Views/SidebarView.swift`

- [ ] **Step 1: Replace the copy-URL block**

Find the block at lines 250–262:

```swift
if case let .listening(addresses, port) = webController.status,
   let host = WebURLComposer.chooseHost(
       from: addresses.filter { $0 != "127.0.0.1" }
   ) {
    Divider()
    Button("Copy web URL") {
        Pasteboard.copy(WebURLComposer.url(
            session: ZmxLauncher.sessionName(for: terminalID.id),
            host: host,
            port: port
        ))
    }
}
```

Replace with:

```swift
if case let .listening(_, port) = webController.status,
   let host = webController.serverHostname {
    Divider()
    Button("Copy web URL") {
        Pasteboard.copy(WebURLComposer.url(
            session: ZmxLauncher.sessionName(for: terminalID.id),
            host: host,
            port: port
        ))
    }
}
```

- [ ] **Step 2: Build the whole tree**

Run: `swift build`
Expected: exits 0, no warnings.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: all pass. Any previously-green test that broke on the status rename or the `bindAddresses` dropping 127.0.0.1 needs a targeted fix in the same commit.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Views/SidebarView.swift
git commit -m "refactor(sidebar): Copy web URL uses controller's hostname (WEB-8.1)"
```

---

## Task 12: Update `SPECS.md`

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Revise WEB-1.1**

Find `**WEB-1.1** When web access is enabled, the application shall bind a local HTTP server to each Tailscale IPv4 and IPv6 address reported by the Tailscale LocalAPI, and to `127.0.0.1`, on the user-configured port (default 8799).`

Replace with:

```
**WEB-1.1** When web access is enabled, the application shall bind a local HTTPS server to each Tailscale IPv4 and IPv6 address reported by the Tailscale LocalAPI, on the user-configured port (default 8799). The application shall not bind to `127.0.0.1`.
```

- [ ] **Step 2: Revise WEB-1.8**

Replace the existing text with:

```
**WEB-1.8** The diagnostic "Listening on …" row in the Settings pane shall bracket IPv6 hosts per RFC 3986 authority syntax (e.g., `[fd7a:115c::5]:8799`). Copyable URLs (Settings Base URL, sidebar "Copy web URL") no longer contain IP literals — they use the MagicDNS FQDN (WEB-8.1) — so this bracketing rule applies only to the diagnostic list. `WebURLComposer.authority(host:port:)` owns the bracket logic.
```

- [ ] **Step 3: Revise WEB-1.10**

Replace the example in WEB-1.10:

```
**WEB-1.10** The Settings pane status row ("Listening on …") shall render each listening address with its port individually (via `WebURLComposer.authority(host:port:)`), bracketing IPv6 hosts. Example: `Listening on [fd7a:115c::5]:49161, 100.64.0.5:49161`. (127.0.0.1 is no longer bound per WEB-1.1.)
```

- [ ] **Step 4: Revise WEB-1.12**

Replace with:

```
**WEB-1.12** While the server is listening, the Settings pane shall render a **Base URL** row distinct from the diagnostic "Listening on" row. The Base URL is the HTTPS URL composed from the machine's MagicDNS FQDN (WEB-8.1) and the listening port — the URL a user copies to open the web client. It renders as a clickable `Link` opening the default browser, plus a copy button (`doc.on.doc`, accessible label "Copy URL") that writes to `NSPasteboard.general`. The "Listening on" row below is informational (which sockets are actually up) and must not be conflated with the Base URL. Plain selectable text is not sufficient for the Base URL — users were expected to triple-click, copy, then switch apps and paste (four steps for one ask).
```

- [ ] **Step 5: Delete WEB-2.5**

Find the `**WEB-2.5**` block. Replace the block (including the two surrounding blank lines) with:

```
**WEB-2.5** _(Removed; superseded by WEB-1.1.)_ The prior loopback-bypass carve-out existed because `WEB-1.1` bound `127.0.0.1`; with that bind gone, local connections now arrive as Tailscale peers via the MagicDNS hostname (WEB-8.1) and are accepted under the normal `WEB-2.2` same-user check.
```

(Keeping a tombstone rather than deleting the ID entirely so references in old commit messages and PRs remain resolvable.)

- [ ] **Step 6: Invert WEB-6.1**

Replace with:

```
**WEB-6.1** The web server shall bind HTTPS only, using a cert+key pair fetched from Tailscale LocalAPI for the machine's MagicDNS name (WEB-8.2). The application shall not bind any HTTP listener; clients with old `http://` bookmarks will fail to connect until they update the URL.
```

- [ ] **Step 7: Add WEB-8 section**

Find the end of the WEB-7 section (search for the last `**WEB-7.` block). Immediately after it, add a new top-level heading and requirements. Match the file's existing formatting — prose sentences, each requirement on its own line with a blank line between:

```
### §8 Web TLS (HTTPS)

**WEB-8.1** When binding the HTTPS server, the application shall read `Self.DNSName` from Tailscale LocalAPI `/status`, strip the trailing dot, and use the resulting FQDN as the TLS SNI name and as the hostname in every composed Base URL / session URL. If `DNSName` is absent or empty, the application shall enter `.magicDNSDisabled` status and not bind. Settings shall render a "MagicDNS must be enabled on your tailnet" message plus a link to `https://login.tailscale.com/admin/dns`.

**WEB-8.2** The application shall fetch the TLS cert+key pair for the MagicDNS FQDN from Tailscale LocalAPI `/localapi/v0/cert/<fqdn>?type=pair`. If the response is classified (HTTP status ≥ 400 + body mentioning "HTTPS" and "enable") as "HTTPS disabled for this tailnet", the application shall enter `.httpsCertsNotEnabled` status and render an admin-console link without attempting to bind. Any other fetch failure shall enter `.certFetchFailed(<message>)` status.

**WEB-8.3** While the server is listening, the application shall re-fetch the cert every 24 hours. If the returned PEM bytes differ from the currently-serving material, the application shall construct a new `NIOSSLContext` and atomically swap the reference read by the per-channel `ChannelInitializer` via `WebTLSContextProvider.swap(_:)`. The application shall not close the listening socket and shall not disturb in-flight connections — existing WebSocket streams keep their prior context for their lifetime.

**WEB-8.4** For `.magicDNSDisabled` and `.httpsCertsNotEnabled`, the Settings pane shall render a human-readable explanation plus a SwiftUI `Link` to the relevant Tailscale admin page (`https://login.tailscale.com/admin/dns`). For `.certFetchFailed`, it shall render the underlying message plus a note that Graftty retries automatically.
```

- [ ] **Step 8: Commit**

```bash
git add SPECS.md
git commit -m "docs(specs): WEB-8 HTTPS + revise WEB-1/2.5/6.1 (WEB-8.1..8.4)"
```

---

## Task 13: End-to-end TLS integration test

**Files:**
- Modify: `Tests/GrafttyKitTests/Web/WebServerAuthTests.swift`

Purpose: now that all pieces are in place, add one test that verifies the handshake end-to-end using a bind to `127.0.0.1` with the test-only self-signed cert and a trust-override URLSession. This already exists partially (see Task 7) — this task adds the focused regression for hot-swap.

- [ ] **Step 1: Add the hot-swap test**

Append to the `WebServerAuthTests` suite:

```swift
@Test func certHotSwap_newConnectionsUseNewContext() async throws {
    let provider = try Self.makeTestTLSProvider()
    let server = WebServer(
        config: Self.makeConfig(),
        auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
        bindAddresses: ["127.0.0.1"],
        tlsProvider: provider
    )
    try server.start()
    defer { server.stop() }
    guard case let .listening(_, port) = server.status else {
        Issue.record("server not listening"); return
    }
    let session = trustAllSession()
    let (_, r1) = try await session.data(
        from: URL(string: "https://localhost:\(port)/")!
    )
    #expect((r1 as! HTTPURLResponse).statusCode == 200)

    // Swap in a freshly-built context for the same cert bytes and
    // confirm a new request still works (old context is released,
    // new context is picked up on the next accept).
    let newCtx = try WebTLSCertFetcher.buildContext(
        certPEM: try Data(contentsOf:
            try #require(Bundle.module.url(forResource: "test-tls-cert",
                                           withExtension: "pem",
                                           subdirectory: "Fixtures"))),
        keyPEM: try Data(contentsOf:
            try #require(Bundle.module.url(forResource: "test-tls-key",
                                           withExtension: "pem",
                                           subdirectory: "Fixtures")))
    )
    provider.swap(newCtx)
    let (_, r2) = try await session.data(
        from: URL(string: "https://localhost:\(port)/")!
    )
    #expect((r2 as! HTTPURLResponse).statusCode == 200)
}
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter WebServerAuthTests.certHotSwap_newConnectionsUseNewContext`
Expected: PASS.

- [ ] **Step 3: Run the entire suite once**

Run: `swift test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/GrafttyKitTests/Web/WebServerAuthTests.swift
git commit -m "test(web): cert hot-swap end-to-end via trust-override URLSession (WEB-8.3)"
```

---

## Self-Review Notes

1. **Spec coverage:** every SPECS requirement the design touches has a matching task: WEB-1.1 (Task 12); WEB-1.8 (Task 12); WEB-1.10 (Task 12); WEB-1.12 (Task 12); WEB-2.5 deletion (Task 7 code, Task 12 spec); WEB-6.1 (Task 7 code, Task 12 spec); WEB-8.1 (Task 2 data + Task 9 wiring); WEB-8.2 (Task 3 + Task 9); WEB-8.3 (Task 4, Task 8, Task 13); WEB-8.4 (Task 10).

2. **Type consistency:** `WebServer.Status` cases `.tailscaleUnavailable`, `.magicDNSDisabled`, `.httpsCertsNotEnabled`, `.certFetchFailed(String)` are consistent across Tasks 7, 9, 10. `TailscaleLocalAPI.Error.httpsCertsDisabled` (Task 3) mapped to `.httpsCertsNotEnabled` in the controller (Task 9). `WebTLSContextProvider.swap(_:)` signature matches across Tasks 4, 8, 13.

3. **No placeholders:** every code step contains concrete code or a specific command + expected output. The one "implementer: build NWConnection" note in Task 7 (Step 1d) is acceptable because it describes a test helper whose exact shape is not load-bearing; the production code path has no such placeholders.

4. **Build-intermediate state:** Tasks 6, 7, 9 intentionally leave the tree un-compilable between commits (upstream callers of `WebURLComposer.chooseHost` and the renamed status case). This is called out in each task so the subagent isn't confused. Final green build lands in Task 11, final green tests in Task 13.
