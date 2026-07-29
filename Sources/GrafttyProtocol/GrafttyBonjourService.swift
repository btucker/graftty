import Foundation

public enum GrafttyBonjourService {
    public static let serviceType = "_graftty._tcp."
    public static let domain = "local."
    public static let discoveryVersion = "1"

    public enum PairingStatus: String, Codable, Sendable, Hashable {
        case required
        case pairedOnly = "paired-only"
    }

    public enum TXTError: Error, Equatable {
        case missingField(String)
        case invalidFingerprint
        case invalidPairingStatus(String)
    }

    public struct DiscoveryMetadata: Codable, Sendable, Hashable {
        public var version: String
        public var deviceID: RemoteDeviceID
        public var label: String
        public var fingerprint: RemoteIdentityFingerprint
        public var protocolVersion: String
        public var pairingStatus: PairingStatus

        public init(
            version: String = GrafttyBonjourService.discoveryVersion,
            deviceID: RemoteDeviceID,
            label: String,
            fingerprint: RemoteIdentityFingerprint,
            protocolVersion: String,
            pairingStatus: PairingStatus
        ) {
            self.version = version
            self.deviceID = deviceID
            self.label = label
            self.fingerprint = fingerprint
            self.protocolVersion = protocolVersion
            self.pairingStatus = pairingStatus
        }
    }

    public static func encodeTXT(_ metadata: DiscoveryMetadata) throws -> Data {
        txtRecord(from: [
            "version": metadata.version,
            "deviceID": metadata.deviceID.value,
            "label": metadata.label,
            "fingerprint": canonicalFingerprint(metadata.fingerprint),
            "proto": metadata.protocolVersion,
            "pairing": metadata.pairingStatus.rawValue,
        ])
    }

    public static func decodeTXT(_ data: Data) throws -> DiscoveryMetadata {
        let dictionary = dictionary(fromTXTRecord: data)
        let version = try required("version", in: dictionary)
        let deviceID = try RemoteDeviceID(value: required("deviceID", in: dictionary))
        let label = dictionary["label"] ?? ""
        let fingerprintHex = try required("fingerprint", in: dictionary)
        let protocolVersion = try required("proto", in: dictionary)
        let pairingRaw = try required("pairing", in: dictionary)
        guard let pairingStatus = PairingStatus(rawValue: pairingRaw) else {
            throw TXTError.invalidPairingStatus(pairingRaw)
        }
        return DiscoveryMetadata(
            version: version,
            deviceID: deviceID,
            label: label,
            fingerprint: try fingerprint(fromCanonicalHex: fingerprintHex),
            protocolVersion: protocolVersion,
            pairingStatus: pairingStatus
        )
    }

    public static func filterCandidates(
        _ candidates: [DiscoveryMetadata],
        localDeviceID: RemoteDeviceID,
        localFingerprint: RemoteIdentityFingerprint,
        supportedProtocolVersions: Set<String>
    ) -> [DiscoveryMetadata] {
        var seen = Set<Identity>()
        var filtered: [DiscoveryMetadata] = []
        for candidate in candidates {
            guard candidate.version == discoveryVersion else {
                continue
            }
            guard candidate.deviceID != localDeviceID || candidate.fingerprint != localFingerprint else {
                continue
            }
            guard isProtocolCompatible(
                advertisedProtocol: candidate.protocolVersion,
                supportedProtocolVersions: supportedProtocolVersions
            ) else {
                continue
            }
            let identity = Identity(deviceID: candidate.deviceID, fingerprint: candidate.fingerprint)
            guard seen.insert(identity).inserted else {
                continue
            }
            filtered.append(candidate)
        }
        return filtered
    }

    public static func dictionary(fromTXTRecord data: Data) -> [String: String] {
        NetService.dictionary(fromTXTRecord: data).reduce(into: [String: String]()) { result, entry in
            result[entry.key] = String(data: entry.value, encoding: .utf8) ?? ""
        }
    }

    public static func txtRecord(from dictionary: [String: String]) -> Data {
        let values = dictionary.mapValues { Data($0.utf8) }
        return NetService.data(fromTXTRecord: values)
    }

    private struct Identity: Hashable {
        var deviceID: RemoteDeviceID
        var fingerprint: RemoteIdentityFingerprint
    }

    private static func required(_ key: String, in dictionary: [String: String]) throws -> String {
        guard let value = dictionary[key], !value.isEmpty else {
            throw TXTError.missingField(key)
        }
        return value
    }

    /// Returns whether an advertised exact version or inclusive numeric
    /// range overlaps the versions this client supports.
    public static func isProtocolCompatible(
        advertisedProtocol: String,
        supportedProtocolVersions: Set<String>
    ) -> Bool {
        guard !advertisedProtocol.isEmpty else { return false }
        if supportedProtocolVersions.contains(advertisedProtocol) {
            return true
        }

        let bounds = advertisedProtocol.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let lower = Int(bounds[0]),
              let upper = Int(bounds[1]),
              lower <= upper
        else {
            return false
        }

        return supportedProtocolVersions.contains { version in
            guard let value = Int(version) else { return false }
            return lower...upper ~= value
        }
    }

    private static func canonicalFingerprint(_ fingerprint: RemoteIdentityFingerprint) -> String {
        fingerprint.rawBytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(fromCanonicalHex hex: String) throws -> RemoteIdentityFingerprint {
        guard hex.count == 64 else {
            throw TXTError.invalidFingerprint
        }
        var bytes = Data()
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw TXTError.invalidFingerprint
            }
            bytes.append(byte)
            index = next
        }
        do {
            return try RemoteIdentityFingerprint(rawBytes: bytes)
        } catch {
            throw TXTError.invalidFingerprint
        }
    }
}
