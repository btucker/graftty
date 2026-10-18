import Foundation
import Testing
@testable import GrafttyProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

@Suite struct PushRelayTests {
    private var event: RemoteNotificationEvent {
        .init(id: UUID(), kind: .agentStop,
              origin: .init(deviceID: .init(value: "paired-mac"), deviceLabel: "Mac", relayDepth: 0),
              worktreeID: "worktree-42", paneID: "pane-7", title: "Review notifications",
              body: "Which delivery policy should we use?", timestamp: Date())
    }

    @Test("@spec NOTIF-1.15: When preparing a Graftty-server push, the application shall encrypt notification content and routing identity for each phone using HPKE, and reject tampered or oversized ciphertext.")
    func encryptsForOnePhone() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let original = event
        let encrypted = try PushRelayEnvelope.seal(original, publicKey: key.publicKey.rawRepresentation)
        #expect(try encrypted.open(privateKey: key.rawRepresentation) == original)
        #expect(!encrypted.ciphertext.contains(Data(original.body.utf8)))
        #expect(throws: (any Error).self) {
            try encrypted.open(privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        }
        var bytes = encrypted.ciphertext
        bytes[bytes.startIndex] ^= 1
        #expect(throws: (any Error).self) {
            try PushRelayEnvelope(encap: encrypted.encap, ciphertext: bytes).open(privateKey: key.rawRepresentation)
        }
        let large = RemoteNotificationEvent(id: UUID(), kind: .agentStop, origin: original.origin,
            worktreeID: original.worktreeID, paneID: nil, title: original.title,
            body: String(repeating: "x", count: 4000), timestamp: original.timestamp)
        #expect(throws: PushRelayEnvelope.Failure.payloadTooLarge) {
            try PushRelayEnvelope.seal(large, publicKey: key.publicKey.rawRepresentation)
        }
    }

    @Test("@spec NOTIF-1.16: When encoding a Graftty-server push request, the application shall use the relay's protojson field names, enum names, base64 bytes, and a stable event identifier for retries.")
    func matchesRelayWireContract() throws {
        let target = PushRelayRequest.Target(phoneDeviceId: "phone", hpkeEncap: Data([1, 2]), ciphertext: Data([3, 4]))
        let request = try PushRelayRequest(clientEventId: "event", sourceDeviceName: "Mac", targets: [target])
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["clientEventId"] as? String == "event")
        #expect(json["eventType"] as? String == "EVENT_TYPE_AGENT_MSG")
        #expect(json["priority"] as? String == "PRIORITY_HIGH")
        let phone = try #require((json["targets"] as? [[String: Any]])?.first)
        #expect(phone["phoneDeviceId"] as? String == "phone")
        #expect(phone["hpkeEncap"] as? String == "AQI=")
        #expect(phone["ciphertext"] as? String == "AwQ=")
        #expect(throws: (any Error).self) {
            try PushRelayRequest(clientEventId: "event", sourceDeviceName: "Mac", targets: [])
        }
        #expect(throws: (any Error).self) {
            try PushRelayRequest(clientEventId: "event", sourceDeviceName: "Mac", targets: (0..<11).map {
                .init(phoneDeviceId: "phone-\($0)", hpkeEncap: Data([1, 2]), ciphertext: Data([3, 4]))
            })
        }
    }
}
