#if canImport(UIKit)
import Foundation
import GrafttyRemoteClient
import Network
import Testing
import WebKit
@testable import GrafttyMobileKit

@MainActor
struct HostBrowserProxyTests {
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
#endif
