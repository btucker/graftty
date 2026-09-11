import CryptoKit
import Foundation
import Testing
@testable import GrafttyProtocol

struct WakeOnLANTests {
    @Test("@spec REMOTE-2.9: When preparing a LAN wake packet, the application shall encode six FF bytes followed by sixteen repetitions of a valid unicast hardware address and reject malformed, zero, or multicast addresses.")
    func magicPacket() throws {
        let target = WakeOnLANTarget(macAddress: "02:11:22:33:44:55", ipv4Address: "192.168.1.10")
        let packet = try #require(target.magicPacket)
        #expect(packet.count == 102)
        #expect(packet.prefix(6) == Data(repeating: 255, count: 6))
        for offset in stride(from: 6, to: 102, by: 6) {
            #expect(packet[offset..<offset + 6] == Data([2, 17, 34, 51, 68, 85]))
        }
        for invalid in ["", "02:11:22:33:44", "02:11:22:33:44:555", "02:11:22:33:44:GG", "+2:11:22:33:44:55", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "01:11:22:33:44:55"] {
            #expect(WakeOnLANTarget(macAddress: invalid, ipv4Address: "192.168.1.10").magicPacket == nil)
        }
    }

    @Test("@spec REMOTE-2.10: If a host supplies wake addresses, then the client shall use them only after verifying a signature binding those addresses to the paired host identity.")
    func signedAdvertisement() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        let hostID = RemoteDeviceID(value: "host")
        let advertisement = try WakeOnLANAdvertisement(
            hostDeviceID: hostID,
            targets: [WakeOnLANTarget(macAddress: "02:11:22:33:44:55", ipv4Address: "192.168.1.10")],
            signingKey: key
        )
        let data = try JSONEncoder().encode(advertisement)
        let decoded = try JSONDecoder().decode(WakeOnLANAdvertisement.self, from: data)
        #expect(decoded.isValid(for: hostID, using: publicKey))
        #expect(!decoded.isValid(for: RemoteDeviceID(value: "other"), using: publicKey))
        let tampered = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "192.168.1.10", with: "192.168.1.11")
        let modified = try JSONDecoder().decode(WakeOnLANAdvertisement.self, from: Data(tampered.utf8))
        #expect(!modified.isValid(for: hostID, using: publicKey))
    }
}
