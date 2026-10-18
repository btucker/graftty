import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// The opaque encrypted body relayed by graftty-server and opened by the phone.
/// Each push uses a fresh HPKE context so delivery order does not matter.
public struct PushRelayEnvelope: Codable, Sendable, Equatable {
    public let encap: Data
    public let ciphertext: Data
    public static let maximumCiphertextBytes = 3 * 1024
    private static let info = Data("graftty.push.v1".utf8)

    public enum Failure: Error, Equatable { case payloadTooLarge }

    public init(encap: Data, ciphertext: Data) {
        self.encap = encap
        self.ciphertext = ciphertext
    }

    public static func seal(_ event: RemoteNotificationEvent, publicKey: Data) throws -> Self {
        let data = try JSONEncoder().encode(event)
        // ChaChaPoly adds a 16-byte authentication tag.
        guard data.count + 16 <= maximumCiphertextBytes else { throw Failure.payloadTooLarge }
        let key = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly, info: info)
        return try .init(encap: sender.encapsulatedKey, ciphertext: sender.seal(data))
    }

    public func open(privateKey: Data) throws -> RemoteNotificationEvent {
        guard ciphertext.count <= Self.maximumCiphertextBytes else { throw Failure.payloadTooLarge }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: Self.info, encapsulatedKey: encap)
        return try JSONDecoder().decode(RemoteNotificationEvent.self, from: recipient.open(ciphertext))
    }
}

/// JSON representation of graftty-server/proto/push.proto. Its bytes are base64,
/// field names are camelCase, and enums use their full protobuf names.
public struct PushRelayRequest: Encodable, Sendable {
    public struct Target: Encodable, Sendable {
        public let phoneDeviceId: String
        public let hpkeEncap: Data
        public let ciphertext: Data

        public init(phoneDeviceId: String, hpkeEncap: Data, ciphertext: Data) {
            self.phoneDeviceId = phoneDeviceId
            self.hpkeEncap = hpkeEncap
            self.ciphertext = ciphertext
        }
    }

    public let clientEventId: String
    public let sourceDeviceName: String
    public let targets: [Target]
    public let eventType = "EVENT_TYPE_AGENT_MSG"
    public let priority = "PRIORITY_HIGH"

    public enum Failure: Error, Equatable { case invalidRequest }

    public init(clientEventId: String, sourceDeviceName: String, targets: [Target]) throws {
        guard !clientEventId.isEmpty, (1...10).contains(targets.count),
              Set(targets.map(\.phoneDeviceId)).count == targets.count,
              targets.allSatisfy({ !$0.phoneDeviceId.isEmpty && !$0.hpkeEncap.isEmpty
                  && !$0.ciphertext.isEmpty && $0.ciphertext.count <= PushRelayEnvelope.maximumCiphertextBytes })
        else { throw Failure.invalidRequest }
        // The relay's 3KB ciphertext guard does not include base64 expansion
        // or its APNs wrapper. Match that wrapper before submitting a request
        // that APNs would reject for exceeding its 4096-byte alert limit.
        for target in targets {
            let payload: [String: Any] = [
                "aps": ["alert": ["title": "Graftty", "body": ""], "mutable-content": 1, "sound": "default"],
                "encrypted": ["encap": target.hpkeEncap.base64EncodedString(), "ciphertext": target.ciphertext.base64EncodedString()],
                "meta": ["event_type": 4, "source_device_name": sourceDeviceName, "tier": 4]
            ]
            guard try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]).count <= 4096
            else { throw PushRelayEnvelope.Failure.payloadTooLarge }
        }
        self.clientEventId = clientEventId
        self.sourceDeviceName = sourceDeviceName
        self.targets = targets
    }
}

public struct PushRelayResponse: Decodable, Sendable {
    public enum Status: String, Decodable, Sendable {
        case delivered = "PUSH_STATUS_DELIVERED"
        case nagged = "PUSH_STATUS_NAGGED"
        case batched = "PUSH_STATUS_BATCHED"
    }
    public let status: Status
    public let todayCount: UInt32
    public let tier: String
    public let plan: String
}
