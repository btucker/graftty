import Foundation
import Testing
@testable import GrafttyProtocol

@Suite
struct RemoteDeviceIdentityTests {

    // MARK: RemoteDeviceID

    @Test("RemoteDeviceID: generate() produces a non-empty ID")
    func generateProducesNonEmptyID() {
        let id = RemoteDeviceID.generate()
        #expect(!id.value.isEmpty)
    }

    @Test("RemoteDeviceID: two generate() calls produce distinct IDs")
    func generateProducesUniqueIDs() {
        let a = RemoteDeviceID.generate()
        let b = RemoteDeviceID.generate()
        #expect(a != b)
    }

    @Test("RemoteDeviceID: init(value:) round-trips Codable")
    func deviceIDCodable() throws {
        let id = RemoteDeviceID(value: "test-device-123")
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(RemoteDeviceID.self, from: data)
        #expect(decoded == id)
    }

    // MARK: RemoteDeviceKind

    @Test("RemoteDeviceKind: all cases encode as expected string raw values")
    func deviceKindRawValues() throws {
        let encoder = JSONEncoder()
        let macData = try encoder.encode(RemoteDeviceKind.mac)
        let iphoneData = try encoder.encode(RemoteDeviceKind.iphone)
        let ipadData = try encoder.encode(RemoteDeviceKind.ipad)
        #expect(String(decoding: macData, as: UTF8.self) == #""mac""#)
        #expect(String(decoding: iphoneData, as: UTF8.self) == #""iphone""#)
        #expect(String(decoding: ipadData, as: UTF8.self) == #""ipad""#)
    }

    @Test("RemoteDeviceKind: Codable round-trips all cases")
    func deviceKindCodable() throws {
        for kind in [RemoteDeviceKind.mac, .iphone, .ipad] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(RemoteDeviceKind.self, from: data)
            #expect(decoded == kind)
        }
    }

    // MARK: RemoteIdentityPublicKey

    @Test("RemoteIdentityPublicKey: init(rawRepresentation:) accepts exactly 32 bytes")
    func publicKeyAccepts32Bytes() throws {
        let bytes = Data(repeating: 0xAB, count: 32)
        let key = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        #expect(key.rawRepresentation == bytes)
    }

    @Test("RemoteIdentityPublicKey: init(rawRepresentation:) rejects non-32-byte input")
    func publicKeyRejectsWrongLength() {
        #expect(throws: (any Error).self) {
            _ = try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0, count: 31))
        }
        #expect(throws: (any Error).self) {
            _ = try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0, count: 33))
        }
        #expect(throws: (any Error).self) {
            _ = try RemoteIdentityPublicKey(rawRepresentation: Data())
        }
    }

    @Test("RemoteIdentityPublicKey: Codable round-trips bytes faithfully")
    func publicKeyCodable() throws {
        let bytes = Data((0..<32).map { UInt8($0) })
        let key = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let data = try JSONEncoder().encode(key)
        let decoded = try JSONDecoder().decode(RemoteIdentityPublicKey.self, from: data)
        #expect(decoded == key)
        #expect(decoded.rawRepresentation == bytes)
    }

    @Test("RemoteIdentityPublicKey: Equatable compares by raw bytes")
    func publicKeyEquality() throws {
        let bytes = Data(repeating: 0x42, count: 32)
        let a = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let b = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let c = try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 0x43, count: 32))
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: RemoteIdentityFingerprint

    @Test("RemoteIdentityFingerprint: fingerprint is stable — same key bytes produce same fingerprint")
    func fingerprintIsStable() throws {
        let bytes = Data(repeating: 0x7F, count: 32)
        let key = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let fp1 = RemoteIdentityFingerprint(of: key)
        let fp2 = RemoteIdentityFingerprint(of: key)
        #expect(fp1 == fp2)
        #expect(fp1.rawBytes == fp2.rawBytes)
        #expect(fp1.display == fp2.display)
    }

    @Test("RemoteIdentityFingerprint: fingerprint is displayable — non-empty human-readable string")
    func fingerprintIsDisplayable() throws {
        let bytes = Data((0..<32).map { UInt8($0) })
        let key = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let fp = RemoteIdentityFingerprint(of: key)
        #expect(!fp.display.isEmpty)
        // Display format: uppercase hex bytes grouped in 4-byte blocks separated by spaces
        // Each block is 8 hex chars; 8 blocks total for 32 bytes = "XXXXXXXX XXXXXXXX ..."
        let parts = fp.display.split(separator: " ")
        #expect(parts.count == 8)
        for part in parts {
            #expect(part.count == 8)
            #expect(part == part.uppercased())
            // All chars are hex digits
            #expect(part.allSatisfy { $0.isHexDigit })
        }
    }

    @Test("RemoteIdentityFingerprint: fingerprint depends only on canonical public key bytes")
    func fingerprintDependsOnlyOnKeyBytes() throws {
        let bytes = Data(repeating: 0x11, count: 32)
        let keyA = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let keyB = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let fpA = RemoteIdentityFingerprint(of: keyA)
        let fpB = RemoteIdentityFingerprint(of: keyB)
        #expect(fpA == fpB)

        // Different bytes → different fingerprint
        let otherBytes = Data(repeating: 0x22, count: 32)
        let keyC = try RemoteIdentityPublicKey(rawRepresentation: otherBytes)
        let fpC = RemoteIdentityFingerprint(of: keyC)
        #expect(fpA != fpC)
    }

    @Test("RemoteIdentityFingerprint: Codable round-trips")
    func fingerprintCodable() throws {
        let bytes = Data(repeating: 0xBE, count: 32)
        let key = try RemoteIdentityPublicKey(rawRepresentation: bytes)
        let fp = RemoteIdentityFingerprint(of: key)
        let data = try JSONEncoder().encode(fp)
        let decoded = try JSONDecoder().decode(RemoteIdentityFingerprint.self, from: data)
        #expect(decoded == fp)
        #expect(decoded.display == fp.display)
    }
}
