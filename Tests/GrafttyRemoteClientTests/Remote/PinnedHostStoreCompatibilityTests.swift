import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyRemoteClient

/// On-disk compatibility net for `PinnedHostStore` after its move onto
/// `JSONFileStore` (#488). The legacy envelope and coder setup are frozen
/// copies of what the store shipped with before the migration.
@Suite("PinnedHostStore on-disk compatibility")
struct PinnedHostStoreCompatibilityTests {

    private struct LegacyEnvelope: Codable {
        var version: Int
        var hosts: [PinnedHost]
    }

    @Test("pinned-hosts.json keeps the earlier writer's bytes and the earlier reader decodes it")
    func pinnedHostStoreCompatibility() throws {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(1...32))
        let pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let host = PinnedHost(
            id: RemoteDeviceID(value: "host-1"),
            kind: .mac,
            publicKey: try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation),
            displayName: "Studio",
            pinnedAt: pinnedAt,
            lastConnectedAt: pinnedAt.addingTimeInterval(60),
            pairingURL: URL(string: "https://studio.local:8799/pair")!
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyBytes = try encoder.encode(LegacyEnvelope(version: RemoteAccessProtocol.version, hosts: [host]))

        // The store creates its directory on first write.
        try PinnedHostStore(directory: dir).add(host)
        let fileURL = dir.appendingPathComponent("pinned-hosts.json")
        let written = try Data(contentsOf: fileURL)
        #expect(written == legacyBytes)
        #expect(try decoder.decode(LegacyEnvelope.self, from: written).hosts == [host])

        try legacyBytes.write(to: fileURL)
        #expect(try PinnedHostStore(directory: dir).list() == [host])
    }
}
