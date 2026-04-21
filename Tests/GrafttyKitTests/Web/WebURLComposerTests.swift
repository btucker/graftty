import Testing
import Foundation
@testable import GrafttyKit

@Suite("WebURLComposer")
struct WebURLComposerTests {

    @Test func ipv4Url() {
        let url = WebURLComposer.url(session: "graftty-abcd1234", host: "100.64.0.5", port: 8799)
        #expect(url == "http://100.64.0.5:8799/session/graftty-abcd1234")
    }

    @Test func ipv6UrlBrackets() {
        let url = WebURLComposer.url(session: "graftty-abcd1234", host: "fd7a:115c::5", port: 8799)
        #expect(url == "http://[fd7a:115c::5]:8799/session/graftty-abcd1234")
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

    @Test func chooseHostSkipsEmptyStrings() {
        // Defensive: a Tailscale LocalAPI hiccup that returned an empty
        // `tailscaleIPs` entry would otherwise make chooseHost pick `""`
        // (empty has no `:`, matches the IPv4 predicate) and downstream
        // produce `http://:8799/` — malformed URI.
        #expect(WebURLComposer.chooseHost(from: ["", "100.64.0.5"]) == "100.64.0.5")
        #expect(WebURLComposer.chooseHost(from: ["", "fd7a:115c::5"]) == "fd7a:115c::5")
        #expect(WebURLComposer.chooseHost(from: ["", ""]) == nil)
    }

    @Test func chooseHostTrimsSurroundingWhitespace() {
        // Also defensive: protects against accidental whitespace from
        // parsing. Returns the trimmed value, not the padded one, so
        // the downstream URL composition doesn't produce `http:// 100.64.0.5:8799/`.
        #expect(WebURLComposer.chooseHost(from: [" 100.64.0.5 "]) == "100.64.0.5")
    }

    @Test func sessionNameIsPercentEscaped() {
        // Session names with unusual chars shouldn't happen today, but
        // we encode defensively.
        let url = WebURLComposer.url(session: "name with space", host: "100.64.0.5", port: 8799)
        #expect(url.contains("/session/name%20with%20space"))
    }

    /// WEB-1.9: the session name is interpolated into the URL PATH, so
    /// it must be percent-encoded with `urlPathAllowed` semantics — not
    /// `urlQueryAllowed`, which leaves `?` and `#` unescaped. The prior
    /// implementation used urlQueryAllowed, so a session name containing
    /// `?` would be split by the browser into path-vs-query, with the
    /// router seeing only the part before the `?`. Defensive — our own
    /// sessionNames per ZMX-2.1 are always `graftty-<8hex>` and never
    /// hit this — but closes the gap for any custom socket client.
    @Test func sessionNameWithPathSeparatorIsEscaped() {
        let url = WebURLComposer.url(session: "a?b", host: "h", port: 1)
        #expect(url == "http://h:1/session/a%3Fb")
    }

    @Test func sessionNameWithFragmentSeparatorIsEscaped() {
        let url = WebURLComposer.url(session: "a#b", host: "h", port: 1)
        #expect(url == "http://h:1/session/a%23b")
    }

    /// WEB-1.7: the Settings pane + sidebar display the server's root
    /// URL ("Copy web URL" without a specific session). This has to
    /// handle IPv6 the same way the session URL does — otherwise
    /// IPv6-only Tailscale setups render `http://fd7a:115c::5:8799/`
    /// which is a malformed URI (IPv6 authorities MUST be bracketed).
    @Test func baseURLBracketsIPv6Host() {
        let url = WebURLComposer.baseURL(host: "fd7a:115c::5", port: 8799)
        #expect(url == "http://[fd7a:115c::5]:8799/")
    }

    @Test func baseURLLeavesIPv4Alone() {
        let url = WebURLComposer.baseURL(host: "100.64.0.5", port: 8799)
        #expect(url == "http://100.64.0.5:8799/")
    }

    @Test func baseURLAcceptsHostnames() {
        let url = WebURLComposer.baseURL(host: "macbook-pro.taile2dd2b.ts.net", port: 8799)
        #expect(url == "http://macbook-pro.taile2dd2b.ts.net:8799/")
    }

    /// WEB-1.10: the Settings pane status row ("Listening on …")
    /// currently renders `addrs.joined(", "):port` which produces
    /// `Listening on fd7a:115c::5, 127.0.0.1:49161` — ambiguous
    /// whether `:49161` is part of the IPv6 or attaches only to the
    /// trailing IPv4, AND the IPv6 isn't bracketed. `authority`
    /// formats a single `<host>:<port>` unambiguously (brackets IPv6)
    /// so callers can join per-address.
    @Test func authorityBracketsIPv6() {
        #expect(WebURLComposer.authority(host: "fd7a:115c::5", port: 8799) == "[fd7a:115c::5]:8799")
    }

    @Test func authorityLeavesIPv4Alone() {
        #expect(WebURLComposer.authority(host: "100.64.0.5", port: 49161) == "100.64.0.5:49161")
    }

    @Test func authorityAcceptsHostname() {
        #expect(WebURLComposer.authority(host: "macbook.ts.net", port: 8799) == "macbook.ts.net:8799")
    }
}
