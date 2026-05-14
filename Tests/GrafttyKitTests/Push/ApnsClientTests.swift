import Foundation
import Testing
@testable import GrafttyKit

@Suite("ApnsClient", .serialized)
struct ApnsClientTests {
    // Throwaway P-256 key, freshly generated. Used only to validate request shape.
    // Generated with:
    //   openssl ecparam -name prime256v1 -genkey -noout \
    //     | openssl pkcs8 -topk8 -nocrypt
    private let testP8: String = """
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgF9kBjIW3+AefkWxl
XMZrLvfMwhLkHoBGkgSC1TFAHOChRANCAAQxffJ86Gb0IGAAkHl4kNZaeqTgZTPn
vLAePnyHBFgS0u/z+bY2ihrNu7huU0SeM+RGxzuJkiw3ixtOOz+eSdaq
-----END PRIVATE KEY-----
"""

    private func makeClient(stub: @escaping @Sendable (URLRequest) -> (Int, Data?)) throws -> ApnsClient {
        APNsStubProtocol.handler = stub
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [APNsStubProtocol.self]
        let session = URLSession(configuration: cfg)
        let jwt = try ApnsJWT(privateKeyPEM: testP8, keyID: "K", teamID: "T",
                              clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        return ApnsClient(jwt: jwt, session: session, topic: "com.quotably.graftty")
    }

    @Test("""
@spec PUSH-3.1: The APNs alert envelope shall use `apns-topic: com.quotably.graftty`, `apns-push-type: alert`, `apns-collapse-id: "<worktreePath>:<attentionTimestampISO>"`, and a `userInfo` payload matching `AgentStopNotification.content(...).userInfo`.
""")
    func push_3_1_alertHeaders() async throws {
        let capture = CapturedRequest()
        let client = try makeClient { req in
            capture.set(req)
            return (200, nil)
        }
        let env = try ApnsEnvelope.alert(
            topic: "com.quotably.graftty",
            worktreePath: "/r/wt",
            attentionTimestamp: Date(timeIntervalSince1970: 1_700_000_000),
            content: AgentStopNotification.content(
                runtime: .claude, worktreeName: "wt", worktreePath: "/r/wt",
                sessionID: "s1", timestamp: Date(timeIntervalSince1970: 1_700_000_000)))
        let result = try await client.send(env, to: PushDevice(token: "abc",
                                                               deviceName: "iPhone",
                                                               platform: "ios",
                                                               lastRegisteredAt: Date()))
        #expect(result == .delivered)
        let req = capture.value!
        #expect(req.url?.absoluteString.contains("/3/device/abc") == true)
        #expect(req.value(forHTTPHeaderField: "apns-topic") == "com.quotably.graftty")
        #expect(req.value(forHTTPHeaderField: "apns-push-type") == "alert")
        #expect(req.value(forHTTPHeaderField: "apns-collapse-id") != nil)
        #expect(req.value(forHTTPHeaderField: "authorization")?.hasPrefix("bearer ") == true)
    }

    @Test("""
@spec PUSH-6.1: When APNs returns `400 BadDeviceToken` or `410 Unregistered` for a device, the application shall remove the matching record from `PushDeviceStore`.
""")
    func push_6_1_unregistered() async throws {
        let client = try makeClient { _ in (410, Data(#"{"reason":"Unregistered"}"#.utf8)) }
        let env = try ApnsEnvelope.clear(topic: "com.quotably.graftty",
                                         worktreePath: "/r/wt",
                                         attentionTimestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let res = try await client.send(env, to: PushDevice(token: "x", deviceName: "x",
                                                            platform: "ios", lastRegisteredAt: Date()))
        #expect(res == .badDeviceToken)
    }

    @Test("""
@spec PUSH-6.2: When APNs returns `BadDeviceToken` for every device in the fanout of a single attention event sent to `api.push.apple.com`, the application shall retry the same fanout against `api.sandbox.push.apple.com` and cache the working endpoint in memory for the rest of the process lifetime.
""")
    func push_6_2_sandboxFallback() async throws {
        let calls = CallLog()
        let client = try makeClient { req in
            calls.append(req.url?.host ?? "")
            if req.url?.host == "api.push.apple.com" {
                return (400, Data(#"{"reason":"BadDeviceToken"}"#.utf8))
            } else {
                return (200, nil)
            }
        }
        let env = try ApnsEnvelope.clear(topic: "com.quotably.graftty",
                                         worktreePath: "/r/wt",
                                         attentionTimestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let devs = [PushDevice(token: "a", deviceName: "a", platform: "ios", lastRegisteredAt: Date())]
        let results = await client.sendFanout(env, to: devs)
        #expect(results.allSatisfy { $0.outcome == .delivered })
        let hosts1 = calls.snapshot()
        #expect(hosts1.contains("api.sandbox.push.apple.com"))
        // Second fanout should hit sandbox directly (endpoint cached).
        _ = await client.sendFanout(env, to: devs)
        let hosts2 = calls.snapshot()
        // After both fanouts: production count should still be 1 (only the first fanout tried it).
        #expect(hosts2.filter { $0 == "api.push.apple.com" }.count == 1)
    }
}

/// Holds the captured URLRequest for verification in the @Test (Swift 6
/// strict concurrency: closures can't capture mutable `inout`/`var`).
private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: URLRequest?
    func set(_ req: URLRequest) { lock.lock(); _value = req; lock.unlock() }
    var value: URLRequest? { lock.lock(); defer { lock.unlock() }; return _value }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [String] = []
    func append(_ host: String) { lock.lock(); _hosts.append(host); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return _hosts }
}

/// URLProtocol stub used by ApnsClient tests.
final class APNsStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data?))!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/2", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
