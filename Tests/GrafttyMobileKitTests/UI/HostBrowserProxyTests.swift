#if canImport(UIKit)
import Foundation
import GrafttyRemoteClient
import Network
import Testing
import WebKit
@testable import GrafttyMobileKit

@MainActor
@Suite(.serialized)
struct HostBrowserProxyTests {
    @Test("@spec PORTS-5.13: When the host browser loads a worktree URL, the application shall send WebKit's HTTP request through the paired host's authenticated tunnel and render the host's response.", .timeLimit(.minutes(1)), arguments: ["127.0.0.1", "localhost", "[::1]", "example.invalid"])
    func webKitLoadsLoopbackPageThroughProxy(targetHost: String) async throws {
        let url = URL(string: "http://\(targetHost):32123/")!
        let network = HostBrowserNetwork()
        defer { network.stop() }
        let configuration = try await network.start(url: url, dataStoreIdentifier: UUID()) { socket, host, port, reply in
            #expect(host == targetHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
            #expect(port == 32123)
            try await Self.servePage("graftty-tunneled-page", socket: socket, reply: reply)
        }
        try await expectPage("graftty-tunneled-page", url: url, configuration: configuration)
    }

    private func expectPage(_ expected: String, url: URL, configuration: WKWebViewConfiguration) async throws {
        let view = WKWebView(frame: .zero, configuration: configuration)
        let navigation = NavigationProbe()
        view.navigationDelegate = navigation
        view.load(URLRequest(url: url))
        let deadline = ContinuousClock.now + .seconds(15)
        while !navigation.finished, navigation.failure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(navigation.failure == nil, "\(String(describing: navigation.failure))")
        try #require(navigation.finished)
        let body = try await view.evaluateJavaScript("document.body.textContent") as? String
        #expect(body == expected)
    }

    private static func servePage(_ body: String, socket: NWConnection, reply: Data) async throws {
        if !reply.isEmpty { try await BrowserProxy.send(reply, to: socket) }
        let request: Data = try await withCheckedThrowingContinuation { continuation in
            socket.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
        #expect(String(decoding: request, as: UTF8.self).hasPrefix("GET /"))
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        try await BrowserProxy.send(Data(response.utf8), to: socket)
        socket.cancel()
    }

    @Test func browserWindowsShareTheSameHostEndpoint() async throws {
        let first = HostBrowserNetwork(), second = HostBrowserNetwork()
        defer { first.stop(); second.stop() }
        let url = URL(string: "http://127.0.0.1:32124/")!
        let hostID = UUID()
        let connect: HostBrowserNetwork.Connector = { socket, _, _, reply in
            #expect(reply.isEmpty)
            try await BrowserProxy.send(Data("shared".utf8), to: socket)
            socket.cancel()
        }
        _ = try await first.start(url: url, dataStoreIdentifier: hostID) { _, _, _, _ in throw ExpectedFailure() }
        _ = try await second.start(url: url, dataStoreIdentifier: hostID, connect: connect)
        first.stop()
        let socket = NWConnection(host: "127.0.0.1", port: 32124, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.browser.shared.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(6, from: socket) == Data("shared".utf8))
    }

    @Test func closingSecondWindowPreservesFirstWindowsPublicHostProxy() async throws {
        let first = HostBrowserNetwork(), second = HostBrowserNetwork()
        defer { first.stop(); second.stop() }
        let url = URL(string: "http://example.invalid:32128/")!
        let hostID = UUID()
        let configuration = try await first.start(url: url, dataStoreIdentifier: hostID) { socket, _, _, reply in
            try await Self.servePage("surviving-window", socket: socket, reply: reply)
        }
        _ = try await second.start(url: url, dataStoreIdentifier: hostID) { _, _, _, _ in throw ExpectedFailure() }
        second.stop()
        try await expectPage("surviving-window", url: url, configuration: configuration)
    }

    @Test(arguments: ["127.0.0.1", "example.invalid"])
    func backgroundWindowsDisconnectedLeaseDoesNotBlockActiveWindow(targetHost: String) async throws {
        let first = HostBrowserNetwork(), second = HostBrowserNetwork()
        defer { first.stop(); second.stop() }
        let url = URL(string: "http://\(targetHost):32129/")!
        let hostID = UUID()
        let configuration = try await first.start(url: url, dataStoreIdentifier: hostID) { socket, _, _, reply in
            try await Self.servePage("active-window", socket: socket, reply: reply)
        }
        _ = try await second.start(url: url, dataStoreIdentifier: hostID) { _, _, _, _ in
            throw RemoteHostConnection.ConnectionError.notConnected
        }
        // A background scene can keep its browser view and lease while its
        // coordinator has closed. Do not stop the second browser here.
        try await expectPage("active-window", url: url, configuration: configuration)
    }

    @Test func conflictingMacCannotTakeOverAnotherHostsEndpoint() async throws {
        let first = HostBrowserNetwork(), second = HostBrowserNetwork()
        defer { first.stop(); second.stop() }
        let url = URL(string: "http://127.0.0.1:32126/")!
        _ = try await first.start(url: url, dataStoreIdentifier: UUID()) { socket, _, _, _ in
            try await BrowserProxy.send(Data("first".utf8), to: socket)
            socket.cancel()
        }
        do {
            _ = try await second.start(url: url, dataStoreIdentifier: UUID()) { socket, _, _, _ in socket.cancel() }
            Issue.record("A different Mac took over the active endpoint")
        } catch {
            #expect(error.localizedDescription.contains("another Mac"))
        }
        let socket = NWConnection(host: "127.0.0.1", port: 32126, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.browser.conflict.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(5, from: socket) == Data("first".utf8))
    }

    @Test func supersededStartCannotStopItsReplacement() async throws {
        let network = HostBrowserNetwork()
        defer { network.stop() }
        let url = URL(string: "http://127.0.0.1:32127/")!
        let hostID = UUID()
        let connect: HostBrowserNetwork.Connector = { socket, _, _, _ in
            try await BrowserProxy.send(Data("current".utf8), to: socket)
            socket.cancel()
        }
        let first = Task { try await network.start(url: url, dataStoreIdentifier: hostID, connect: connect) }
        await Task.yield()
        _ = try await network.start(url: url, dataStoreIdentifier: hostID, connect: connect)
        _ = try? await first.value
        let socket = NWConnection(host: "127.0.0.1", port: 32127, using: .tcp)
        socket.start(queue: DispatchQueue(label: "graftty.browser.replacement.test"))
        defer { socket.cancel() }
        #expect(try await Self.receive(7, from: socket) == Data("current".utf8))
    }

    @Test func loopbackDefaultPortIgnoresSchemeCase() throws {
        let endpoint = try #require(HostBrowserNetwork.LoopbackEndpoint(url: URL(string: "HTTPS://localhost/")!))
        #expect(endpoint.port == 443)
        #expect(HostBrowserNetwork.LoopbackEndpoint(url: URL(string: "HTTP://localhost/")!)?.port == 80)
    }

    @Test func rapidBrowserRestartReleasesItsPreviousEndpoint() async throws {
        let network = HostBrowserNetwork()
        defer { network.stop() }
        let url = URL(string: "http://127.0.0.1:32125/")!
        let hostID = UUID()
        for _ in 0..<20 {
            _ = try await network.start(url: url, dataStoreIdentifier: hostID) { socket, _, _, _ in socket.cancel() }
        }
    }

    @Test("WebKit uses the authenticated SOCKS proxy for every domain without failover")
    func webKitConfigurationUsesProxy() async throws {
        let proxy = try BrowserProxy { _, _, _ in }
        let port = try await proxy.start()
        defer { proxy.stop() }
        let dataStoreID = UUID(uuidString: "8B2C0D79-593D-43E0-84ED-65F34236DB14")!
        let config = HostBrowserProxyConfiguration.make(
            proxy: proxy,
            port: port,
            dataStoreIdentifier: dataStoreID
        )
        #expect(config.websiteDataStore.isPersistent)
        #expect(config.websiteDataStore.identifier == dataStoreID)
        let settings = try #require(config.websiteDataStore.proxyConfigurations.first)
        #expect(config.websiteDataStore.proxyConfigurations.count == 1)
        #expect(settings.allowFailover == false)
        #expect(settings.matchDomains == ["", "localhost", "127.0.0.1", "::1"])
    }

    @Test("The SOCKS proxy forwards localhost unchanged to the paired Mac")
    func localhostIsResolvedByHost() async throws {
        try await expectForwarded(host: "localhost", port: 3000)
    }

    @Test("The SOCKS proxy forwards public hostnames unchanged to the paired Mac")
    func publicHostnameIsResolvedByHost() async throws {
        try await expectForwarded(host: "example.invalid", port: 443)
    }

    private func expectForwarded(host: String, port: Int) async throws {
        let expectedHost = host
        let expectedPort = port
        let proxy = try BrowserProxy { socket, requestedHost, requestedPort in
            #expect(requestedHost == expectedHost)
            #expect(requestedPort == expectedPort)
            try await BrowserProxy.send(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), to: socket)
            socket.cancel()
        }
        let proxyPort = try await proxy.start()
        defer { proxy.stop() }

        let socket = try await authenticatedConnection(to: proxy, port: proxyPort)
        defer { socket.cancel() }
        let hostname = Data(host.utf8)
        var request = Data([5, 1, 0, 3, UInt8(hostname.count)])
        request.append(hostname)
        request.append(contentsOf: [UInt8(port / 256), UInt8(port % 256)])
        try await BrowserProxy.send(request, to: socket)
        let reply = try await Self.receive(10, from: socket)
        #expect(reply[0] == 5)
        #expect(reply[1] == 0)
    }

    @Test("SOCKS CONNECT failures return an RFC 1928 failure reply", .timeLimit(.minutes(1)))
    func connectFailureReturnsProtocolReply() async throws {
        let proxy = try BrowserProxy { _, _, _ in throw ExpectedFailure() }
        let port = try await proxy.start()
        defer { proxy.stop() }

        let socket = try await authenticatedConnection(to: proxy, port: port)
        defer { socket.cancel() }

        let hostname = Data("example.invalid".utf8)
        var request = Data([5, 1, 0, 3, UInt8(hostname.count)])
        request.append(hostname)
        request.append(contentsOf: [0, 80])
        try await BrowserProxy.send(request, to: socket)
        let reply = try await Self.receive(10, from: socket)
        #expect(reply[0] == 5)
        #expect(reply[1] == 1)
    }

    private func authenticatedConnection(to proxy: BrowserProxy, port: UInt16) async throws -> NWConnection {
        let socket = NWConnection(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: port)),
            using: .tcp
        )
        socket.start(queue: DispatchQueue(label: "graftty.browser.proxy.test-client"))

        try await BrowserProxy.send(Data([5, 1, 2]), to: socket)
        #expect(try await Self.receive(2, from: socket) == Data([5, 2]))

        let user = Data(proxy.username.utf8)
        let password = Data(proxy.password.utf8)
        var auth = Data([1, UInt8(user.count)])
        auth.append(user)
        auth.append(UInt8(password.count))
        auth.append(password)
        try await BrowserProxy.send(auth, to: socket)
        #expect(try await Self.receive(2, from: socket) == Data([1, 0]))
        return socket
    }

    private static func receive(_ count: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    private struct ExpectedFailure: Error {}
}

@MainActor
private final class NavigationProbe: NSObject, WKNavigationDelegate {
    var finished = false
    var failure: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
}
#endif
