import Foundation
import GrafttyKit
import GrafttyProtocol

struct GrafttyBonjourCandidate: Equatable, Identifiable {
    var id: String {
        "\(deviceID.value)|\(fingerprint.rawBytes.base64EncodedString())"
    }

    var deviceID: RemoteDeviceID
    var label: String
    var fingerprint: RemoteIdentityFingerprint
    var baseURL: URL
    var protocolVersion: String
    var pairingStatus: GrafttyBonjourService.PairingStatus
    var discoveredAt: Date
}

final class GrafttyBonjourBrowser: NSObject {
    struct ResolvedService {
        var name: String
        var hostName: String?
        var port: Int
        var txtRecordData: Data?

        init(
            name: String,
            hostName: String?,
            port: Int,
            txtRecordData: Data?
        ) throws {
            guard (1...65_535).contains(port) else {
                throw ResolutionError.invalidPort(port)
            }
            self.name = name
            self.hostName = hostName
            self.port = port
            self.txtRecordData = txtRecordData
        }

        init(netService: NetService) throws {
            try self.init(
                name: netService.name,
                hostName: netService.hostName,
                port: netService.port,
                txtRecordData: netService.txtRecordData()
            )
        }
    }

    enum ResolutionError: Error, Equatable {
        case invalidPort(Int)
    }

    private let browser: NetServiceBrowser
    private let localDeviceID: RemoteDeviceID
    private let localFingerprint: RemoteIdentityFingerprint
    private let supportedProtocolVersions: Set<String>
    private let onCandidate: (GrafttyBonjourCandidate) -> Void
    private var pendingServices: [ObjectIdentifier: NetService] = [:]
    private(set) var candidates: [GrafttyBonjourCandidate] = []
    private var isBrowsing = false

    init(
        localDeviceID: RemoteDeviceID,
        localFingerprint: RemoteIdentityFingerprint,
        supportedProtocolVersions: Set<String>,
        browser: NetServiceBrowser = NetServiceBrowser(),
        onCandidate: @escaping (GrafttyBonjourCandidate) -> Void
    ) {
        self.localDeviceID = localDeviceID
        self.localFingerprint = localFingerprint
        self.supportedProtocolVersions = supportedProtocolVersions
        self.browser = browser
        self.onCandidate = onCandidate
        super.init()
    }

    func start() {
        guard !isBrowsing else { return }
        isBrowsing = true
        browser.delegate = self
        browser.searchForServices(
            ofType: GrafttyBonjourService.serviceType,
            inDomain: GrafttyBonjourService.domain
        )
    }

    func stop() {
        browser.stop()
        browser.delegate = nil
        isBrowsing = false
        for service in pendingServices.values {
            service.stop()
            service.delegate = nil
        }
        pendingServices.removeAll()
    }

    func publishResolvedService(
        _ service: ResolvedService,
        discoveredAt: Date = Date()
    ) {
        guard let candidate = Self.candidate(
            from: service,
            localDeviceID: localDeviceID,
            localFingerprint: localFingerprint,
            supportedProtocolVersions: supportedProtocolVersions,
            discoveredAt: discoveredAt
        ) else {
            return
        }

        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[index] = candidate
        } else {
            candidates.append(candidate)
        }
        onCandidate(candidate)
    }

    static func candidate(
        from service: ResolvedService,
        localDeviceID: RemoteDeviceID,
        localFingerprint: RemoteIdentityFingerprint,
        supportedProtocolVersions: Set<String>,
        discoveredAt: Date
    ) -> GrafttyBonjourCandidate? {
        guard let txtRecordData = service.txtRecordData,
              let metadata = try? GrafttyBonjourService.decodeTXT(txtRecordData),
              let filtered = GrafttyBonjourService.filterCandidates(
                  [metadata],
                  localDeviceID: localDeviceID,
                  localFingerprint: localFingerprint,
                  supportedProtocolVersions: supportedProtocolVersions
              ).first,
              let baseURL = baseURL(hostName: service.hostName, port: service.port)
        else {
            return nil
        }

        return GrafttyBonjourCandidate(
            deviceID: filtered.deviceID,
            label: filtered.label.isEmpty ? service.name : filtered.label,
            fingerprint: filtered.fingerprint,
            baseURL: baseURL,
            protocolVersion: filtered.protocolVersion,
            pairingStatus: filtered.pairingStatus,
            discoveredAt: discoveredAt
        )
    }

    static func remoteMac(
        from candidate: GrafttyBonjourCandidate,
        existing: RemoteMac?
    ) -> RemoteMac {
        RemoteMac(
            id: candidate.deviceID,
            label: candidate.label,
            fingerprint: candidate.fingerprint,
            lastKnownBaseURL: candidate.baseURL,
            addedAt: existing?.addedAt ?? candidate.discoveredAt,
            lastUsedAt: existing?.lastUsedAt,
            lastDiscoveredAt: candidate.discoveredAt
        )
    }

    private func remember(_ service: NetService) {
        pendingServices[ObjectIdentifier(service)] = service
    }

    private func forget(_ service: NetService) {
        service.delegate = nil
        pendingServices.removeValue(forKey: ObjectIdentifier(service))
    }

    private static func baseURL(hostName: String?, port: Int) -> URL? {
        guard let hostName else { return nil }
        let trimmedHost = hostName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmedHost.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = trimmedHost
        components.port = port
        return components.url
    }
}

protocol RemoteMacDiscoveryBrowsing: AnyObject {
    func start()
    func stop()
}

extension GrafttyBonjourBrowser: RemoteMacDiscoveryBrowsing {}

extension GrafttyBonjourBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        remember(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        forget(service)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isBrowsing = false
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        isBrowsing = false
    }
}

extension GrafttyBonjourBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { forget(sender) }
        guard let service = try? ResolvedService(netService: sender) else { return }
        publishResolvedService(service)
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        forget(sender)
    }
}
