#if canImport(UIKit)
import Foundation
import GrafttyRemoteClient
import Network
import Testing
import WebKit
@testable import GrafttyMobileKit

@MainActor
struct HostBrowserProxyTests {
    @Test(
        "WebKit proxies local and public hostnames through the paired Mac",
        .timeLimit(.minutes(2)),
        arguments: ["http://localhost:39381", "http://example.invalid:39382"]
    )
    func requestedHostUsesProxy(urlText: String) async throws {
        let url = try #require(URL(string: urlText))
        let proxy = try BrowserProxy { socket, host, port in
            #expect(host == url.host)
            #expect(port == url.port)
            try await BrowserProxy.send(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), to: socket)
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: data ?? Data()) }
                }
            }
            try await BrowserProxy.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nviaProxy".utf8), to: socket)
            socket.cancel()
        }
        let port = try await proxy.start()
        defer { proxy.stop() }
        let dataStoreID = url.host == "localhost"
            ? UUID(uuidString: "6C4279E9-27AE-4C31-93B7-7B086064BFE5")!
            : UUID(uuidString: "8B2C0D79-593D-43E0-84ED-65F34236DB14")!
        let config = HostBrowserProxyConfiguration.make(
            proxy: proxy,
            port: port,
            dataStoreIdentifier: dataStoreID
        )
        #expect(config.websiteDataStore.isPersistent)
        #expect(config.websiteDataStore.identifier == dataStoreID)
        let view = WKWebView(frame: .zero, configuration: config)
        let result = BrowserNavigationResult()
        view.navigationDelegate = result
        view.load(URLRequest(url: url))
        // A cold WebKit network process can take more than 15 seconds to
        // become responsive on a newly booted CI simulator.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !result.finished && result.error == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(result.error == nil)
        #expect(result.finished)
        if result.finished {
            #expect(try await view.evaluateJavaScript("document.body.textContent") as? String == "viaProxy")
        }
        view.stopLoading()
    }

    @Test("SOCKS CONNECT failures return an RFC 1928 failure reply", .timeLimit(.minutes(1)))
    func connectFailureReturnsProtocolReply() async throws {
        let proxy = try BrowserProxy { _, _, _ in throw ExpectedFailure() }
        let port = try await proxy.start()
        defer { proxy.stop() }

        let socket = NWConnection(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: port)),
            using: .tcp
        )
        socket.start(queue: DispatchQueue(label: "graftty.browser.proxy.failure-test"))
        defer { socket.cancel() }

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

        let hostname = Data("example.invalid".utf8)
        var request = Data([5, 1, 0, 3, UInt8(hostname.count)])
        request.append(hostname)
        request.append(contentsOf: [0, 80])
        try await BrowserProxy.send(request, to: socket)
        let reply = try await Self.receive(10, from: socket)
        #expect(reply[0] == 5)
        #expect(reply[1] == 1)
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
private final class BrowserNavigationResult: NSObject, WKNavigationDelegate {
    var finished = false
    var error: String?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
    }
}
#endif
