#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite("GhosttyKeybindingsFetcher", .serialized)
struct GhosttyKeybindingsFetcherTests {
    private let baseURL = URL(string: "https://keybindings.test")!

    @Test("""
    @spec IPAD-9.1: When iPad selects or refreshes a host, it shall fetch the host-resolved Ghostty keybindings from GET /ghostty-keybindings, decode raw action-name keys for forward compatibility, and expose only known GhosttyAction chords through GhosttyKeybindBridge.
    """)
    func validJSONDecodesKnownActionsAndDropsUnknownActions() async {
        let session = Self.session(statusCode: 200, body: #"""
        {
          "bindings": {
            "new_split:right": { "key": "d", "modifiers": 8 },
            "host_future_action": { "key": "x", "modifiers": 8 }
          }
        }
        """#)

        let bridge = await GhosttyKeybindingsFetcher.fetchUncached(baseURL: baseURL, session: session)

        #expect(bridge[.newSplitRight] == ShortcutChord(key: "d", modifiers: [.command]))
        #expect(bridge.allChords.count == 1)
    }

    @Test
    func non2xxReturnsEmptyBridge() async {
        let session = Self.session(statusCode: 500, body: #"{"bindings":{}}"#)

        let bridge = await GhosttyKeybindingsFetcher.fetchUncached(baseURL: baseURL, session: session)

        #expect(bridge.allChords.isEmpty)
    }

    @Test
    func malformedJSONReturnsEmptyBridge() async {
        let session = Self.session(statusCode: 200, body: #"{"bindings":"nope"}"#)

        let bridge = await GhosttyKeybindingsFetcher.fetchUncached(baseURL: baseURL, session: session)

        #expect(bridge.allChords.isEmpty)
    }

    @Test
    @MainActor
    func cachedFetchAvoidsSecondNetworkCallForSameBaseURL() async {
        SharedURLProtocolStub.install(
            responses: [
                .init(statusCode: 200, body: #"""
                {"bindings":{"new_split:right":{"key":"d","modifiers":8}}}
                """#),
                .init(statusCode: 200, body: #"""
                {"bindings":{"new_split:right":{"key":"x","modifiers":8}}}
                """#),
            ]
        )
        defer {
            GhosttyKeybindingsFetcher.invalidateCache(for: baseURL)
            SharedURLProtocolStub.uninstall()
        }

        let first = await GhosttyKeybindingsFetcher.fetch(baseURL: baseURL)
        let second = await GhosttyKeybindingsFetcher.fetch(baseURL: baseURL)

        #expect(first[.newSplitRight] == ShortcutChord(key: "d", modifiers: [.command]))
        #expect(second[.newSplitRight] == ShortcutChord(key: "d", modifiers: [.command]))
        #expect(SharedURLProtocolStub.requestCount == 1)
    }

    @Test
    @MainActor
    func cacheInvalidationForcesRefetch() async {
        SharedURLProtocolStub.install(
            responses: [
                .init(statusCode: 200, body: #"""
                {"bindings":{"new_split:right":{"key":"d","modifiers":8}}}
                """#),
                .init(statusCode: 200, body: #"""
                {"bindings":{"new_split:right":{"key":"x","modifiers":8}}}
                """#),
            ]
        )
        defer {
            GhosttyKeybindingsFetcher.invalidateCache(for: baseURL)
            SharedURLProtocolStub.uninstall()
        }

        let first = await GhosttyKeybindingsFetcher.fetch(baseURL: baseURL)
        GhosttyKeybindingsFetcher.invalidateCache(for: baseURL)
        let second = await GhosttyKeybindingsFetcher.fetch(baseURL: baseURL)

        #expect(first[.newSplitRight] == ShortcutChord(key: "d", modifiers: [.command]))
        #expect(second[.newSplitRight] == ShortcutChord(key: "x", modifiers: [.command]))
        #expect(SharedURLProtocolStub.requestCount == 2)
    }

    private static func session(statusCode: Int, body: String) -> URLSession {
        URLProtocolStub.install(responses: [.init(statusCode: statusCode, body: body)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }
}

private struct StubResponse {
    let statusCode: Int
    let body: String
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responses: [StubResponse] = []

    static func install(responses: [StubResponse]) {
        lock.withLock {
            self.responses = responses
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "keybindings.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = Self.lock.withLock {
            Self.responses.isEmpty
                ? StubResponse(statusCode: 500, body: "")
                : Self.responses.removeFirst()
        }
        respond(with: response)
    }

    override func stopLoading() {}

    func respond(with stub: StubResponse) {
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SharedURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var responses: [StubResponse] = []
    private static var installed = false
    private(set) static var requestCount = 0

    static func install(responses: [StubResponse]) {
        lock.withLock {
            self.responses = responses
            requestCount = 0
            if !installed {
                URLProtocol.registerClass(Self.self)
                installed = true
            }
        }
    }

    static func uninstall() {
        lock.withLock {
            if installed {
                URLProtocol.unregisterClass(Self.self)
                installed = false
            }
            responses = []
            requestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "keybindings.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = Self.lock.withLock {
            Self.requestCount += 1
            return Self.responses.isEmpty
                ? StubResponse(statusCode: 500, body: "")
                : Self.responses.removeFirst()
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
