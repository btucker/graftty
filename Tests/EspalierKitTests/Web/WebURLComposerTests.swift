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
