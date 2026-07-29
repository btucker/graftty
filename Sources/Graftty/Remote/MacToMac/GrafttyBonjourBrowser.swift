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
    private struct ServiceKey: Hashable {
        var name: String
        var type: String
        var domain: String

        init(_ service: NetService) {
            self.name = service.name
            self.type = service.type
            self.domain = service.domain
        }
    }

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
    private let onCandidateRemoved: (RemoteMacIdentity) -> Void
    private var pendingServices: [ObjectIdentifier: NetService] = [:]
    private var identityByServiceKey: [ServiceKey: RemoteMacIdentity] = [:]
    private var serviceKeysByIdentity: [RemoteMacIdentity: Set<ServiceKey>] = [:]
    private(set) var candidates: [GrafttyBonjourCandidate] = []
    private var isBrowsing = false

    init(
        localDeviceID: RemoteDeviceID,
        localFingerprint: RemoteIdentityFingerprint,
        supportedProtocolVersions: Set<String>,
        browser: NetServiceBrowser = NetServiceBrowser(),
        onCandidate: @escaping (GrafttyBonjourCandidate) -> Void,
        onCandidateRemoved: @escaping (RemoteMacIdentity) -> Void = { _ in }
    ) {
        self.localDeviceID = localDeviceID
        self.localFingerprint = localFingerprint
        self.supportedProtocolVersions = supportedProtocolVersions
        self.browser = browser
        self.onCandidate = onCandidate
        self.onCandidateRemoved = onCandidateRemoved
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
        let removedIdentities = Set(candidates.map(RemoteMacIdentity.init))
        candidates.removeAll()
        identityByServiceKey.removeAll()
        serviceKeysByIdentity.removeAll()
        for identity in removedIdentities {
            onCandidateRemoved(identity)
        }
    }

    func publishResolvedService(
        _ service: ResolvedService,
        discoveredAt: Date = Date()
    ) {
        publishResolvedService(service, discoveredAt: discoveredAt, serviceKey: nil)
    }

    func publishResolvedService(
        _ service: ResolvedService,
        discoveredAt: Date = Date(),
        originatingService: NetService
    ) {
        publishResolvedService(
            service,
            discoveredAt: discoveredAt,
            serviceKey: ServiceKey(originatingService)
        )
    }

    private func publishResolvedService(
        _ service: ResolvedService,
        discoveredAt: Date,
        serviceKey: ServiceKey?
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

        let identity = RemoteMacIdentity(candidate)
        if let serviceKey {
            if let previousIdentity = identityByServiceKey[serviceKey],
               previousIdentity != identity {
                removeServiceKey(serviceKey, from: previousIdentity)
            }
            identityByServiceKey[serviceKey] = identity
            serviceKeysByIdentity[identity, default: []].insert(serviceKey)
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
            routes: [RemoteConnectionRoute(kind: .lan, baseURL: candidate.baseURL)],
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

    private func removeResolvedService(_ service: NetService) {
        let key = ServiceKey(service)
        guard let identity = identityByServiceKey.removeValue(forKey: key) else {
            return
        }
        removeServiceKey(key, from: identity)
    }

    private func removeServiceKey(
        _ key: ServiceKey,
        from identity: RemoteMacIdentity
    ) {
        var keys = serviceKeysByIdentity[identity] ?? []
        keys.remove(key)
        guard keys.isEmpty else {
            serviceKeysByIdentity[identity] = keys
            return
        }
        serviceKeysByIdentity[identity] = nil
        candidates.removeAll { RemoteMacIdentity($0) == identity }
        onCandidateRemoved(identity)
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
        removeResolvedService(service)
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
        publishResolvedService(service, originatingService: sender)
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        forget(sender)
    }
}
