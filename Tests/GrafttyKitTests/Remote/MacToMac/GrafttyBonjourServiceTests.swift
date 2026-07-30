import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit

@Suite("GrafttyBonjourService Tests")
struct GrafttyBonjourServiceTests {

    private func fingerprint(_ byte: UInt8 = 0xAA) throws -> RemoteIdentityFingerprint {
        try RemoteIdentityFingerprint(rawBytes: Data(repeating: byte, count: 32))
    }

    private func metadata(
        deviceID: RemoteDeviceID = RemoteDeviceID(value: "mac-1"),
        label: String = "Studio Mac",
        fingerprintByte: UInt8 = 0xAA,
        protocolVersion: String = "2",
        pairingStatus: GrafttyBonjourService.PairingStatus = .required
    ) throws -> GrafttyBonjourService.DiscoveryMetadata {
        GrafttyBonjourService.DiscoveryMetadata(
            version: GrafttyBonjourService.discoveryVersion,
            deviceID: deviceID,
            label: label,
            fingerprint: try fingerprint(fingerprintByte),
            protocolVersion: protocolVersion,
            pairingStatus: pairingStatus
        )
    }

    @Test("encodes canonical discovery metadata")
    func encodesCanonicalDiscoveryMetadata() throws {
        let metadata = try metadata()
        let txt = try GrafttyBonjourService.encodeTXT(metadata)
        let decodedDictionary = GrafttyBonjourService.dictionary(fromTXTRecord: txt)

        #expect(GrafttyBonjourService.serviceType == "_graftty._tcp.")
        #expect(GrafttyBonjourService.domain == "local.")
        #expect(decodedDictionary["version"] == "2")
        #expect(decodedDictionary["deviceID"] == "mac-1")
        #expect(decodedDictionary["fingerprint"] == String(repeating: "aa", count: 32))
        #expect(decodedDictionary["proto"] == "2")
        #expect(decodedDictionary["pairing"] == "required")
    }

    @Test("rejects missing identity fields")
    func rejectsMissingIdentityFields() throws {
        let metadata = try metadata()
        var txt = try GrafttyBonjourService.encodeTXT(metadata)
        var dictionary = GrafttyBonjourService.dictionary(fromTXTRecord: txt)

        dictionary["deviceID"] = nil
        txt = GrafttyBonjourService.txtRecord(from: dictionary)
        #expect(throws: GrafttyBonjourService.TXTError.missingField("deviceID")) {
            _ = try GrafttyBonjourService.decodeTXT(txt)
        }

        dictionary = GrafttyBonjourService.dictionary(fromTXTRecord: try GrafttyBonjourService.encodeTXT(metadata))
        dictionary["fingerprint"] = nil
        txt = GrafttyBonjourService.txtRecord(from: dictionary)
        #expect(throws: GrafttyBonjourService.TXTError.missingField("fingerprint")) {
            _ = try GrafttyBonjourService.decodeTXT(txt)
        }
    }

    @Test("filters self and dedupes by identity")
    func filtersSelfAndDedupesByIdentity() throws {
        let selfID = RemoteDeviceID(value: "self")
        let selfFingerprint = try fingerprint(0x01)
        let selfMetadata = try metadata(deviceID: selfID, fingerprintByte: 0x01)
        let first = try metadata(deviceID: RemoteDeviceID(value: "other"), label: "First", fingerprintByte: 0x02)
        let duplicate = try metadata(deviceID: RemoteDeviceID(value: "other"), label: "Duplicate", fingerprintByte: 0x02)
        let changedIdentity = try metadata(deviceID: RemoteDeviceID(value: "other"), label: "Changed", fingerprintByte: 0x03)

        let filtered = GrafttyBonjourService.filterCandidates(
            [selfMetadata, first, duplicate, changedIdentity],
            localDeviceID: selfID,
            localFingerprint: selfFingerprint,
            supportedProtocolVersions: ["2"]
        )

        #expect(filtered.map(\.label) == ["First", "Changed"])
    }

    @Test("filters protocol-incompatible candidates")
    func filtersProtocolIncompatibleCandidates() throws {
        let compatible = try metadata(label: "Compatible", protocolVersion: "2")
        let compatibleRange = try metadata(
            deviceID: RemoteDeviceID(value: "range"),
            label: "Compatible Range",
            fingerprintByte: 0xCC,
            protocolVersion: "1-2"
        )
        let incompatible = try metadata(
            deviceID: RemoteDeviceID(value: "old"),
            label: "Old",
            fingerprintByte: 0xBB,
            protocolVersion: "1"
        )
        let malformed = try metadata(
            deviceID: RemoteDeviceID(value: "malformed"),
            label: "Malformed",
            fingerprintByte: 0xDD,
            protocolVersion: "2-"
        )

        let filtered = GrafttyBonjourService.filterCandidates(
            [compatible, compatibleRange, incompatible, malformed],
            localDeviceID: RemoteDeviceID(value: "self"),
            localFingerprint: try fingerprint(0x01),
            supportedProtocolVersions: ["2"]
        )

        #expect(filtered.map(\.label) == ["Compatible", "Compatible Range"])
    }

    @Test("filters discovery schema-incompatible candidates")
    func filtersDiscoverySchemaIncompatibleCandidates() throws {
        let compatible = try metadata(label: "Compatible")
        let incompatible = GrafttyBonjourService.DiscoveryMetadata(
            version: "3",
            deviceID: RemoteDeviceID(value: "future"),
            label: "Future",
            fingerprint: try fingerprint(0xCC),
            protocolVersion: "2",
            pairingStatus: .required
        )

        let filtered = GrafttyBonjourService.filterCandidates(
            [compatible, incompatible],
            localDeviceID: RemoteDeviceID(value: "self"),
            localFingerprint: try fingerprint(0x01),
            supportedProtocolVersions: ["2"]
        )

        #expect(filtered.map(\.label) == ["Compatible"])
    }

    @Test("round-trips pairing status")
    func roundTripsPairingStatus() throws {
        for status in [GrafttyBonjourService.PairingStatus.required, .pairedOnly] {
            let metadata = try metadata(pairingStatus: status)
            let decoded = try GrafttyBonjourService.decodeTXT(
                try GrafttyBonjourService.encodeTXT(metadata)
            )

            #expect(decoded.pairingStatus == status)
        }
    }
}
