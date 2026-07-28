import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyRemoteClient

@Suite("SignalingClient — POSTs SignalingOffer to /v1/rtc/offer and decodes SignalingAnswer.")
struct SignalingClientTests {

    @Test
    func postsOfferAsJsonAndDecodesAnswer() async throws {
        let capturedRequest = CapturedRequest()
        let fake: SignalingClient.Transport = { request, body in
            capturedRequest.record(request: request, body: body)
            let answer = SignalingAnswer(sdp: "v=0\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\n")
            let data = try JSONEncoder().encode(answer)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (data, response)
        }
        let client = SignalingClient(transport: fake)
        let baseURL = URL(string: "https://mac.example.local:54321")!
        let offer = SignalingOffer(clientDeviceID: "ios-device-123", sdp: "v=0\n")

        let answer = try await client.exchange(baseURL: baseURL, offer: offer)

        #expect(answer.sdp.hasPrefix("v=0"))
        #expect(capturedRequest.method == "POST")
        #expect(capturedRequest.url == URL(string: "https://mac.example.local:54321/v1/rtc/offer"))
        let body = try #require(capturedRequest.body)
        let decoded = try JSONDecoder().decode(SignalingOffer.self, from: body)
        #expect(decoded.clientDeviceID == "ios-device-123")
        #expect(decoded.sdp == "v=0\n")
    }

    @Test
    func reportsHttpErrorWithStatusAndBody() async throws {
        let fake: SignalingClient.Transport = { request, _ in
            let body = Data("{\"error\":\"not paired\"}".utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        }
        let client = SignalingClient(transport: fake)
        do {
            _ = try await client.exchange(
                baseURL: URL(string: "https://example.local")!,
                offer: SignalingOffer(clientDeviceID: "x", sdp: "")
            )
            Issue.record("expected throw")
        } catch let error as SignalingClient.Error {
            guard case .http(let status, _) = error else {
                Issue.record("expected .http, got \(error)")
                return
            }
            #expect(status == 403)
        }
    }

    @Test
    func reportsDecodeFailureWhenAnswerIsMalformed() async throws {
        let fake: SignalingClient.Transport = { request, _ in
            let body = Data("not json".utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (body, response)
        }
        let client = SignalingClient(transport: fake)
        do {
            _ = try await client.exchange(
                baseURL: URL(string: "https://example.local")!,
                offer: SignalingOffer(clientDeviceID: "x", sdp: "")
            )
            Issue.record("expected throw")
        } catch let error as SignalingClient.Error {
            guard case .decode = error else {
                Issue.record("expected .decode, got \(error)")
                return
            }
        }
    }
}

private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (url: URL?, method: String?, body: Data?) = (nil, nil, nil)

    var url: URL? { lock.withLock { storage.url } }
    var method: String? { lock.withLock { storage.method } }
    var body: Data? { lock.withLock { storage.body } }

    func record(request: URLRequest, body: Data) {
        lock.withLock {
            storage = (request.url, request.httpMethod, body)
        }
    }
}
