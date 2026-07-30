#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
struct SessionWebSocketURLTests {
    // The daemon classifies a `/ws` connection's display-client kind from the
    // transport (`declaredDisplayClientKind`): an `X-Graftty-Client-Kind`
    // header, a `GrafttyMobile` User-Agent, or a `client=ios` query param.
    // `URLSessionWebSocketClient` connects with a bare URL (no custom header /
    // User-Agent), so the query param is the only signal the iOS app can send.
    @Test("""
    @spec IOS-4.22: When the explicit legacy Web Access compatibility path constructs a session WebSocket URL, it shall advertise the display-client kind via a `client=ios` query parameter so older daemons classify the connection as `.ios`. Production paired-device sessions shall use the authenticated terminal subsystem and shall not select this compatibility path automatically (`IOS-4.28`).
    """)
    func webSocketURLAdvertisesIOSClientKind() throws {
        let base = URL(string: "https://host.example:8443")!
        let url = RootView.makeWebSocketURL(base: base, session: "my session")

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "wss")
        #expect(components.path == "/ws")
        let items = components.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "session", value: "my session")))
        #expect(items.contains(URLQueryItem(name: "client", value: "ios")))
    }
}
#endif
