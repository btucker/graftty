import Foundation
import Testing
@testable import Graftty
@testable import GrafttyKit
import GrafttyProtocol

@Suite("Remote Mac Bonjour Runtime")
struct RemoteMacBonjourTests {
    private let localDeviceID = RemoteDeviceID(value: "local-mac")

    private func fingerprint(_ byte: UInt8) throws -> RemoteIdentityFingerprint {
        try RemoteIdentityFingerprint(rawBytes: Data(repeating: byte, count: 32))
    }

    private func txt(
        deviceID: RemoteDeviceID = RemoteDeviceID(value: "remote-mac"),
        label: String = "Studio Mac",
        fingerprintByte: UInt8 = 0x22,
        protocolVersion: String = "1",
        pairingStatus: GrafttyBonjourService.PairingStatus = .required
    ) throws -> Data {
        try GrafttyBonjourService.encodeTXT(
            GrafttyBonjourService.DiscoveryMetadata(
                deviceID: deviceID,
                label: label,
                fingerprint: try fingerprint(fingerprintByte),
                protocolVersion: protocolVersion,
                pairingStatus: pairingStatus
            )
        )
    }

    @Test("advertiser prepares canonical TXT data")
    func advertiserPreparesCanonicalTXTData() throws {
        let txtRecord = try GrafttyBonjourAdvertiser.txtRecordData(
            label: "Studio Mac",
            deviceID: RemoteDeviceID(value: "host-mac"),
            fingerprint: try fingerprint(0x11),
            protocolVersion: "1-2",
            pairingStatus: .pairedOnly
        )

        let metadata = try GrafttyBonjourService.decodeTXT(txtRecord)
        #expect(metadata.label == "Studio Mac")
        #expect(metadata.deviceID == RemoteDeviceID(value: "host-mac"))
        #expect(metadata.fingerprint == (try fingerprint(0x11)))
        #expect(metadata.protocolVersion == "1-2")
        #expect(metadata.pairingStatus == .pairedOnly)
    }

    @Test("advertiser rejects invalid ports before publishing")
    func advertiserRejectsInvalidPortsBeforePublishing() throws {
        let advertiser = GrafttyBonjourAdvertiser(
            port: 70_000,
            label: "Studio Mac",
            deviceID: RemoteDeviceID(value: "host-mac"),
            fingerprint: try fingerprint(0x11),
            protocolVersion: "1"
        )

        #expect(throws: GrafttyBonjourAdvertiser.StartError.invalidPort(70_000)) {
            try advertiser.start()
        }
    }

    @Test("maps TXT data from a resolved service to candidate")
    func mapsTXTDataFromResolvedServiceToCandidate() throws {
        let discoveredAt = Date(timeIntervalSince1970: 1_710_000_000)
        let service = try GrafttyBonjourBrowser.ResolvedService(
            name: "Graftty on Studio",
            hostName: "studio.local.",
            port: 9443,
            txtRecordData: txt()
        )

        let candidate = try #require(
            GrafttyBonjourBrowser.candidate(
                from: service,
                localDeviceID: localDeviceID,
                localFingerprint: try fingerprint(0x01),
                supportedProtocolVersions: ["1"],
                discoveredAt: discoveredAt
            )
        )

        #expect(candidate.deviceID == RemoteDeviceID(value: "remote-mac"))
        #expect(candidate.label == "Studio Mac")
        #expect(candidate.fingerprint == (try fingerprint(0x22)))
        #expect(candidate.baseURL.absoluteString == "http://studio.local:9443")
        #expect(candidate.pairingStatus == .required)
        #expect(candidate.discoveredAt == discoveredAt)
    }

    @Test("self candidates are ignored")
    func selfCandidatesAreIgnored() throws {
        let localFingerprint = try fingerprint(0x44)
        let service = try GrafttyBonjourBrowser.ResolvedService(
            name: "Self",
            hostName: "self.local.",
            port: 9443,
            txtRecordData: txt(
                deviceID: localDeviceID,
                fingerprintByte: 0x44
            )
        )

        let candidate = GrafttyBonjourBrowser.candidate(
            from: service,
            localDeviceID: localDeviceID,
            localFingerprint: localFingerprint,
            supportedProtocolVersions: ["1"],
            discoveredAt: Date()
        )

        #expect(candidate == nil)
    }

    @Test("protocol-incompatible candidates are not published")
    func protocolIncompatibleCandidatesAreNotPublished() throws {
        final class PublishedCandidates {
            var values: [GrafttyBonjourCandidate] = []
        }
        let published = PublishedCandidates()
        let browser = try GrafttyBonjourBrowser(
            localDeviceID: localDeviceID,
            localFingerprint: fingerprint(0x01),
            supportedProtocolVersions: ["1"]
        ) { candidate in
            published.values.append(candidate)
        }
        let service = try GrafttyBonjourBrowser.ResolvedService(
            name: "Old",
            hostName: "old.local.",
            port: 9443,
            txtRecordData: txt(protocolVersion: "0")
        )

        browser.publishResolvedService(service, discoveredAt: Date())

        #expect(published.values.isEmpty)
        #expect(browser.candidates.isEmpty)
    }

    @Test("pairing status is carried into published candidates")
    func pairingStatusIsCarriedIntoPublishedCandidates() throws {
        var published: GrafttyBonjourCandidate?
        let browser = try GrafttyBonjourBrowser(
            localDeviceID: localDeviceID,
            localFingerprint: fingerprint(0x01),
            supportedProtocolVersions: ["1"]
        ) { candidate in
            published = candidate
        }
        let service = try GrafttyBonjourBrowser.ResolvedService(
            name: "Known",
            hostName: "known.local.",
            port: 9443,
            txtRecordData: txt(pairingStatus: .pairedOnly)
        )

        browser.publishResolvedService(service, discoveredAt: Date())

        #expect(published?.pairingStatus == .pairedOnly)
        #expect(browser.candidates.first?.pairingStatus == .pairedOnly)
    }

    @Test("resolved candidates refresh RemoteMac discovery URL")
    func resolvedCandidatesRefreshRemoteMacDiscoveryURL() throws {
        let discoveredAt = Date(timeIntervalSince1970: 1_720_000_000)
        let existing = RemoteMac(
            id: RemoteDeviceID(value: "remote-mac"),
            label: "Old Name",
            fingerprint: try fingerprint(0x22),
            lastKnownBaseURL: URL(string: "http://old.local:8080"),
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastDiscoveredAt: nil
        )
        let candidate = GrafttyBonjourCandidate(
            deviceID: RemoteDeviceID(value: "remote-mac"),
            label: "Studio Mac",
            fingerprint: try fingerprint(0x22),
            baseURL: try #require(URL(string: "http://studio.local:9443")),
            protocolVersion: "1",
            pairingStatus: .required,
            discoveredAt: discoveredAt
        )

        let refreshed = GrafttyBonjourBrowser.remoteMac(
            from: candidate,
            existing: existing
        )

        #expect(refreshed.id == existing.id)
        #expect(refreshed.addedAt == existing.addedAt)
        #expect(refreshed.lastUsedAt == existing.lastUsedAt)
        #expect(refreshed.label == "Studio Mac")
        #expect(refreshed.lastKnownBaseURL?.absoluteString == "http://studio.local:9443")
        #expect(refreshed.lastDiscoveredAt == discoveredAt)
    }
}
