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

    @Test("""
    @spec WEB-1.9: When `WebURLComposer.url(session:host:port:)` percent-encodes the session name for interpolation into the URL path, it shall use `CharacterSet.urlPathAllowed` rather than `urlQueryAllowed`. The latter leaves reserved path/query/fragment separators (`?`, `#`) unescaped, so a session name containing `?` would cause the browser to parse the URL as path-and-query and the client router would see only the prefix. Graftty's own session names per `ZMX-2.1` never include such characters, but socket clients producing custom session names would otherwise silently break.
    """)
    func sessionNameWithPathSeparatorIsEscaped() {
        let url = WebURLComposer.url(session: "a?b", host: "h.ts.net", port: 1)
        #expect(url == "https://h.ts.net:1/session/a%3Fb")
        let fragmentURL = WebURLComposer.url(session: "a#b", host: "h.ts.net", port: 1)
        #expect(fragmentURL == "https://h.ts.net:1/session/a%23b")
    }

    @Test func sessionNameWithFragmentSeparatorIsEscaped() {
        let url = WebURLComposer.url(session: "a#b", host: "h.ts.net", port: 1)
        #expect(url == "https://h.ts.net:1/session/a%23b")
    }

    // `authority(host:port:)` remains for the diagnostic bind-list
    // ("Listening on …"). Its IPv6-bracketing behavior (WEB-1.10) is
    // preserved even though baseURL/url no longer exercise it.
    @Test("""
    @spec WEB-1.10: The Settings pane status row ("Listening on …") shall render each listening address with its port individually (via `WebURLComposer.authority(host:port:)`), bracketing IPv6 hosts. Example: `Listening on [fd7a:115c::5]:49161, 100.64.0.5:49161`. (127.0.0.1 is no longer bound per WEB-1.1.)
    """)
    func authorityBracketsIPv6() {
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
