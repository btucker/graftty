import CryptoKit
import Foundation

/// A physical network interface remembered while the host is awake.
/// @spec REMOTE-2.9: When preparing a LAN wake packet, the application shall encode six FF bytes followed by sixteen repetitions of a valid unicast hardware address and reject malformed, zero, or multicast addresses.
public struct WakeOnLANTarget: Codable, Sendable, Equatable, Hashable {
    public let macAddress: String
    public let ipv4Address: String

    public init(macAddress: String, ipv4Address: String) {
        self.macAddress = macAddress
        self.ipv4Address = ipv4Address
    }

    public var magicPacket: Data? {
        let components = macAddress.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 6, components.allSatisfy({ component in
            component.utf8.count == 2 && component.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }) else {
            return nil
        }
        let bytes = components.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, bytes[0] & 1 == 0, bytes.contains(where: { $0 != 0 }) else {
            return nil
        }
        var packet = Data(repeating: 255, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: bytes) }
        return packet
    }
}

/// Independently signed so older v2 clients can ignore this optional extension
/// without changing the existing signaling transcript.
public struct WakeOnLANAdvertisement: Codable, Sendable, Equatable, Hashable {
    public let hostDeviceID: RemoteDeviceID
    public let targets: [WakeOnLANTarget]
    public let signature: Data

    public init(
        hostDeviceID: RemoteDeviceID,
        targets: [WakeOnLANTarget],
        signingKey: Curve25519.Signing.PrivateKey
    ) throws {
        self.hostDeviceID = hostDeviceID
        self.targets = targets
        self.signature = try signingKey.signature(for: Self.transcript(hostDeviceID, targets))
    }

    public func isValid(for hostID: RemoteDeviceID, using publicKey: RemoteIdentityPublicKey) -> Bool {
        guard hostDeviceID == hostID,
            !targets.isEmpty, targets.count <= 16,
            targets.allSatisfy({ $0.magicPacket != nil }),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey.rawRepresentation),
            let transcript = try? Self.transcript(hostDeviceID, targets)
        else { return false }
        return key.isValidSignature(signature, for: transcript)
    }

    private static func transcript(_ hostID: RemoteDeviceID, _ targets: [WakeOnLANTarget]) throws -> Data {
        struct Payload: Encodable {
            let domain = "graftty.wake-on-lan.v1"
            let hostDeviceID: RemoteDeviceID
            let targets: [WakeOnLANTarget]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(hostDeviceID: hostID, targets: targets))
    }
}
