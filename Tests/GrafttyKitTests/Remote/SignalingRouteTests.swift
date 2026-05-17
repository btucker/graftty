import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

// Boot helper: starts a real NIO WebServer on port 0 with an injected
// signalingHandler. Mirrors the pattern in WebServerWorktreeEndpointTests.
private struct TestWebServer {
    let port: Int
    let server: WebServer

    func stop() { server.stop() }

    static func start(
        signalingHandler: (@Sendable (SignalingOffer) async -> WebServer.SignalingHandlerOutcome)? = nil
    ) async throws -> TestWebServer {
        let config = WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            signalingHandler: signalingHandler
        )
        let server = WebServer(
            config: config,
            auth: WebServer.AuthPolicy(isAllowed: { _ in true }),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        guard case let .listening(_, port) = server.status else {
            throw NSError(domain: "SignalingRouteTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "server did not start"])
        }
        return TestWebServer(port: port, server: server)
    }
}

@Suite("POST /v1/rtc/offer — signaling route returns SignalingAnswer from injected handler.")
struct SignalingRouteTests {

    @Test
    func postOfferReturnsAnswerFromHandler() async throws {
        if skipInCI() { return }
        let server = try await TestWebServer.start { offer in
            #expect(offer.clientDeviceID == "ios-device-abc")
            return .success(SignalingAnswer(sdp: "v=0\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\n"))
        }
        defer { server.stop() }

        let url = URL(string: "https://127.0.0.1:\(server.port)/v1/rtc/offer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let offer = SignalingOffer(clientDeviceID: "ios-device-abc", sdp: "v=0\n")
        let body = try JSONEncoder().encode(offer)

        let (data, response) = try await withTrustAllSession { session in
            try await session.upload(for: request, from: body)
        }
        let http = try #require(response as? HTTPURLResponse)

        #expect(http.statusCode == 200)
        let answer = try JSONDecoder().decode(SignalingAnswer.self, from: data)
        #expect(answer.sdp.contains("webrtc-datachannel"))
    }

    @Test
    func malformedOfferReturns400() async throws {
        if skipInCI() { return }
        let server = try await TestWebServer.start { _ in
            .success(SignalingAnswer(sdp: ""))
        }
        defer { server.stop() }

        let url = URL(string: "https://127.0.0.1:\(server.port)/v1/rtc/offer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Data("not-json".utf8)

        let (_, response) = try await withTrustAllSession { session in
            try await session.upload(for: request, from: body)
        }
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 400)
    }

    @Test
    func missingHandlerReturns503() async throws {
        if skipInCI() { return }
        let server = try await TestWebServer.start(signalingHandler: nil)
        defer { server.stop() }

        let url = URL(string: "https://127.0.0.1:\(server.port)/v1/rtc/offer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(SignalingOffer(clientDeviceID: "x", sdp: ""))

        let (_, response) = try await withTrustAllSession { session in
            try await session.upload(for: request, from: body)
        }
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 503)
    }

    @Test
    func handlerReturningInvalidYields400() async throws {
        if skipInCI() { return }
        let server = try await TestWebServer.start { _ in
            .invalid("offer references unknown device")
        }
        defer { server.stop() }

        let url = URL(string: "https://127.0.0.1:\(server.port)/v1/rtc/offer")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(SignalingOffer(clientDeviceID: "x", sdp: ""))

        let (_, response) = try await withTrustAllSession { session in
            try await session.upload(for: request, from: body)
        }
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 400)
    }
}
