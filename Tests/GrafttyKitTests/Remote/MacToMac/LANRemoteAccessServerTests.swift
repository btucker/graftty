import CryptoKit
import Darwin
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit

@Suite("LANRemoteAccessServer", .serialized)
struct LANRemoteAccessServerTests {

    @Test("server starts on an ephemeral localhost port and reports the actual listener port")
    func startsAndReportsActualPort() throws {
        let server = Self.makeServer()
        try server.start()
        defer { server.stop() }

        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }
        #expect(port > 0)
        #expect(port != server.config.port)
    }

    @Test("default production config uses the stable dual-stack listener")
    func defaultConfigUsesStableDualStackListener() {
        let config = LANRemoteAccessServer.Config()

        #expect(config.port == RemoteAccessProtocol.pairedAccessPort)
        #expect(config.bindHost == "::")
    }

    @Test("""
    @spec REMOTE-2.4: Native paired-device access shall use one stable dual-stack \
    HTTP listener on port 8800 for LAN, MagicDNS, and Tailscale-IP routes. \
    Browser Web Access shall remain an independent HTTPS service and shall not \
    be used for native signaling.
    """)
    func wildcardListenerIsDualStack() throws {
        let server = Self.makeServer(
            config: .init(port: 0, bindHost: "::")
        )
        try server.start()
        defer { server.stop() }
        let port = try #require(server.listeningPort)

        #expect(Self.canConnectToLocalhost(port: port))
        #expect(Self.canConnectToIPv6Loopback(port: port))
    }

    @Test("a stopped stable listener can be rebound on the same port")
    func stoppedListenerCanRebindSamePort() throws {
        let first = Self.makeServer(
            config: .init(port: 0, bindHost: "::")
        )
        try first.start()
        let port = try #require(first.listeningPort)
        first.stop()

        let rebound = Self.makeServer(
            config: .init(port: port, bindHost: "::")
        )
        try rebound.start()
        defer { rebound.stop() }

        #expect(rebound.listeningPort == port)
        #expect(Self.canConnectToLocalhost(port: port))
        #expect(Self.canConnectToIPv6Loopback(port: port))
    }

    @Test("POST /v2/pairing/begin returns JSON through a real socket")
    func postPairingBeginReturnsJSONThroughSocket() async throws {
        let server = Self.makeServer()
        try server.start()
        defer { server.stop() }
        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/pairing/begin")!)
        request.httpMethod = "POST"

        let (data, response) = try await URLSession.shared.upload(for: request, from: Data())
        guard let http = response as? HTTPURLResponse else {
            Issue.record("response was not HTTPURLResponse")
            return
        }

        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true)
        let payload = try JSONDecoder.iso8601().decode(PairingPayload.self, from: data)
        #expect(payload.hostDisplayName == "Test Mac")
        #expect(payload.pairingURL == URL(string: "http://host.local:9999/v2/pairing")!)
    }

    @Test("POST /v2/pairing/begin uses request Host header for pairing URL")
    func postPairingBeginUsesRequestHostHeader() throws {
        let server = Self.makeServer()
        try server.start()
        defer { server.stop() }
        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }

        let request = """
        POST /v2/pairing/begin HTTP/1.1\r
        Host: bonjour-host.local:\(port)\r
        Content-Length: 0\r
        \r

        """
        let response = try Self.sendRawHTTPRequest(request, port: port)
        let body = try #require(response.components(separatedBy: "\r\n\r\n").last)
        let payload = try JSONDecoder.iso8601().decode(PairingPayload.self, from: Data(body.utf8))

        #expect(response.contains("200 OK"))
        #expect(payload.pairingURL == URL(string: "http://bonjour-host.local:\(port)/v2/pairing")!)
    }

    @Test("GET /repos returns 404 rather than serving legacy web routes")
    func reposReturns404() async throws {
        let server = Self.makeServer()
        try server.start()
        defer { server.stop() }
        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }

        let (data, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(port)/repos")!
        )
        guard let http = response as? HTTPURLResponse else {
            Issue.record("response was not HTTPURLResponse")
            return
        }

        #expect(http.statusCode == 404)
        let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: data)
        #expect(error.code == PairingErrorResponse.Code.noActiveSession)
    }

    @Test("pairing begin route enforces rate limiting through the server")
    func pairingBeginRateLimitThroughSocket() async throws {
        let server = Self.makeServer(rateLimit: LANRemoteAccessRateLimit(maxRequests: 1, window: 60))
        try server.start()
        defer { server.stop() }
        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }
        let url = URL(string: "http://127.0.0.1:\(port)/v2/pairing/begin")!

        var first = URLRequest(url: url)
        first.httpMethod = "POST"
        let (_, firstResponse) = try await URLSession.shared.upload(for: first, from: Data())
        guard let firstHTTP = firstResponse as? HTTPURLResponse else {
            Issue.record("first response was not HTTPURLResponse")
            return
        }
        #expect(firstHTTP.statusCode == 200)

        var second = URLRequest(url: url)
        second.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.upload(for: second, from: Data())
        guard let http = response as? HTTPURLResponse else {
            Issue.record("response was not HTTPURLResponse")
            return
        }

        #expect(http.statusCode == 429)
        let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: data)
        #expect(error.code == PairingErrorResponse.Code.rateLimited)
    }

    @Test("RTC offer route enforces rate limiting through the server")
    func rtcOfferRateLimitThroughSocket() async throws {
        let server = Self.makeServer(rateLimit: LANRemoteAccessRateLimit(maxRequests: 1, window: 60))
        try server.start()
        defer { server.stop() }
        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }
        let url = URL(string: "http://127.0.0.1:\(port)/v2/rtc/challenge")!
        let body = try JSONEncoder.iso8601().encode(
            SignalingChallengeRequest(clientDeviceID: RemoteDeviceID(value: "client-v2"),
                clientNonce: Data(repeating: 0x11, count: 32),
                signingKey: Curve25519.Signing.PrivateKey()))

        var first = URLRequest(url: url)
        first.httpMethod = "POST"
        first.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, firstResponse) = try await URLSession.shared.upload(for: first, from: body)
        guard let firstHTTP = firstResponse as? HTTPURLResponse else {
            Issue.record("first response was not HTTPURLResponse")
            return
        }
        #expect(firstHTTP.statusCode != 429)

        var second = URLRequest(url: url)
        second.httpMethod = "POST"
        second.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: second, from: body)
        guard let http = response as? HTTPURLResponse else {
            Issue.record("response was not HTTPURLResponse")
            return
        }

        #expect(http.statusCode == 429)
        let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: data)
        #expect(error.code == PairingErrorResponse.Code.rateLimited)
    }

    @Test("request bodies exceeding the configured cap return 413")
    func bodyCapReturns413() async throws {
        let server = Self.makeServer(
            config: LANRemoteAccessServer.Config(port: 0, bindHost: "127.0.0.1", maxBodyBytes: 4)
        )
        try server.start()
        defer { server.stop() }
        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/rtc/offer")!)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.upload(for: request, from: Data("too large".utf8))
        guard let http = response as? HTTPURLResponse else {
            Issue.record("response was not HTTPURLResponse")
            return
        }

        #expect(http.statusCode == 413)
        #expect(data.isEmpty == false)
    }

    @Test("pipelined requests on one connection only receive one response")
    func pipelinedRequestsOnlyServeFirstResponse() throws {
        let counter = RequestCounter()
        let server = Self.makeServer(beginPairing: { _, lanBaseURL in
            counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            do {
                return .success(try Self.makePayload(pairingURL: lanBaseURL))
            } catch {
                return .failure(PairingErrorResponse(code: .internalError, error: "\(error)"))
            }
        })
        try server.start()
        defer { server.stop() }
        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }

        let request = """
        POST /v2/pairing/begin HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Content-Length: 0\r
        Connection: keep-alive\r
        \r
        POST /v2/pairing/begin HTTP/1.1\r
        Host: 127.0.0.1:\(port)\r
        Content-Length: 0\r
        Connection: keep-alive\r
        \r

        """
        let response = try Self.sendRawHTTPRequest(request, port: port)

        #expect(Self.httpResponseCount(in: response) == 1)
        #expect(response.contains("200 OK"))
        #expect(counter.value == 1)
    }

    @Test("stop closes active child channels while a route is in flight")
    func stopClosesActiveChildChannelsWithInFlightRoute() async throws {
        let fixture = try Self.makeHostPairingFixture()
        defer { fixture.cleanup() }
        let payload = try await fixture.server.start()
        let introduce = await fixture.server.handleIntroduce(
            Self.makeIntroduceRequest(nonce: payload.nonce)
        )
        guard case .success = introduce else {
            Issue.record("expected introduce to move pairing into pending confirmation")
            return
        }

        let routeHandler = LANRemoteAccessRouteHandler(
            lanBaseURLProvider: { URL(string: "http://host.local:9999")! },
            beginPairing: { _, _ in
                .failure(PairingErrorResponse(code: .pairingBusy, error: "not exercised"))
            },
            handleIntroduce: { request in
                await fixture.server.handleIntroduce(request)
            },
            handleAwaitOutcome: { request in
                await fixture.server.handleAwaitOutcome(request)
            },
            handleSignalingChallenge: { _ in
                .failure(PairingErrorResponse(code: .authenticationFailed, error: "not exercised"))
            },
            handleSignalingOffer: { _ in
                .hostBusy("not exercised")
            }
        )
        let server = LANRemoteAccessServer(
            config: .init(port: 0, bindHost: "127.0.0.1"),
            routeHandler: routeHandler
        )
        try server.start()
        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }

        let body = try JSONEncoder.iso8601().encode(PairingAwaitOutcomeRequest(nonce: payload.nonce))
        let requestTask = Task {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/pairing/await-outcome")!)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            _ = try? await URLSession.shared.upload(for: request, from: body)
        }

        let waiterRegistered = await Self.waitUntil(timeout: 1.0) {
            await fixture.server.pendingWaiterCount == 1
        }
        #expect(waiterRegistered)
        let start = Date()
        server.stop()
        let elapsed = Date().timeIntervalSince(start)
        requestTask.cancel()
        let waiterRemoved = await Self.waitUntil(timeout: 1.0) {
            await fixture.server.pendingWaiterCount == 0
        }
        if !waiterRemoved {
            await fixture.server.cancel()
        }
        _ = await requestTask.result

        #expect(elapsed < 1.0)
        #expect(waiterRemoved)
        #expect(server.listeningPort == nil)
        #expect(Self.canConnectToLocalhost(port: port) == false)
    }

    @Test("stop closes the listener")
    func stopClosesListener() throws {
        let server = Self.makeServer()
        try server.start()
        guard let port = server.listeningPort else {
            Issue.record("server did not report a listening port")
            return
        }

        server.stop()

        #expect(Self.canConnectToLocalhost(port: port) == false)
        #expect(server.listeningPort == nil)
    }

    private static func makeServer(
        config: LANRemoteAccessServer.Config = .init(port: 0, bindHost: "127.0.0.1"),
        rateLimit: LANRemoteAccessRateLimit = .disabled,
        beginPairing: @escaping LANRemoteAccessRouteHandler.BeginPairing = { _, lanBaseURL in
            do {
                return .success(try makePayload(pairingURL: lanBaseURL))
            } catch {
                return .failure(PairingErrorResponse(code: .internalError, error: "\(error)"))
            }
        }
    ) -> LANRemoteAccessServer {
        LANRemoteAccessServer(
            config: config,
            routeHandler: makeHandler(rateLimit: rateLimit, beginPairing: beginPairing)
        )
    }

    private static func makeHandler(
        rateLimit: LANRemoteAccessRateLimit = .disabled,
        beginPairing: @escaping LANRemoteAccessRouteHandler.BeginPairing
    ) -> LANRemoteAccessRouteHandler {
        LANRemoteAccessRouteHandler(
            lanBaseURLProvider: { URL(string: "http://host.local:9999")! },
            rateLimit: rateLimit,
            beginPairing: beginPairing,
            handleIntroduce: { _ in
                .failure(PairingErrorResponse(code: .noActiveSession, error: "not exercised"))
            },
            handleAwaitOutcome: { _ in
                .failure(PairingErrorResponse(code: .noActiveSession, error: "not exercised"))
            },
            handleSignalingChallenge: { _ in
                .failure(PairingErrorResponse(code: .authenticationFailed, error: "not exercised"))
            },
            handleSignalingOffer: { _ in
                .invalid("not exercised")
            }
        )
    }

    private struct HostPairingFixture {
        let dir: URL
        let server: HostPairingServer

        func cleanup() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private final class RequestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock {
                count += 1
            }
        }
    }

    private static func makeHostPairingFixture() throws -> HostPairingFixture {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let identityStore = HostIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let peerStore = TrustedPeerStore(directory: dir)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            pairingURLProvider: { URL(string: "https://host.local:8800/v2/pairing")! }
        )
        return HostPairingFixture(dir: dir, server: HostPairingServer(session: session))
    }

    private static func makeIntroduceRequest(nonce: RemotePairingNonce) -> PairingIntroduceRequest {
        PairingIntroduceRequest(
            nonce: nonce,
            clientPublicKey: try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0xCC, count: 32)),
            clientDeviceID: RemoteDeviceID(value: "client-123"),
            clientKind: .iphone,
            clientDisplayName: "Client iPhone"
        )
    }

    private static func makePayload(pairingURL: URL) throws -> PairingPayload {
        let publicKey = try RemoteIdentityPublicKey(
            rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        return PairingPayload(
            hostDeviceID: RemoteDeviceID(value: "host-1"),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            hostPublicKeyFingerprint: RemoteIdentityFingerprint(of: publicKey),
            nonce: .generate(),
            expiry: Date(timeIntervalSince1970: 1_800_000_000),
            pairingURL: pairingURL
        )
    }

    private static func canConnectToLocalhost(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static func canConnectToIPv6Loopback(port: Int) -> Bool {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = in_port_t(port).bigEndian
        let parsed = "::1".withCString {
            inet_pton(AF_INET6, $0, &address.sin6_addr)
        }
        guard parsed == 1 else { return false }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) { sockaddrPointer in
                connect(
                    descriptor,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_in6>.size)
                )
            }
        }
        return result == 0
    }

    private static func sendRawHTTPRequest(_ request: String, port: Int) throws -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let bytes = Array(request.utf8)
        let sent = bytes.withUnsafeBytes { buffer in
            send(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard sent == bytes.count else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let received = recv(descriptor, &buffer, buffer.count, 0)
            if received > 0 {
                response.append(buffer, count: received)
            } else {
                break
            }
        }
        return String(data: response, encoding: .utf8) ?? ""
    }

    private static func httpResponseCount(in response: String) -> Int {
        response.components(separatedBy: "HTTP/1.1 ").count - 1
    }

    private static func waitUntil(
        timeout seconds: Double,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() {
                return true
            }
            await Task.yield()
        }
        return await condition()
    }
}
