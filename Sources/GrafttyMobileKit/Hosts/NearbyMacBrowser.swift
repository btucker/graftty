#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Observation

/// A resolved `_graftty._tcp` advertisement from a Mac running Graftty's
/// device-pairing listener. The address is a routing hint only; pairing pins
/// and verifies `fingerprint` before the candidate becomes a saved Mac.
public struct NearbyMac: Identifiable, Hashable, Sendable {
    public var id: String {
        "\(deviceID.value)|\(fingerprint.rawBytes.base64EncodedString())"
    }

    public let deviceID: RemoteDeviceID
    public let label: String
    public let fingerprint: RemoteIdentityFingerprint
    public let baseURL: URL
    public let pairingStatus: GrafttyBonjourService.PairingStatus

    public init(
        deviceID: RemoteDeviceID,
        label: String,
        fingerprint: RemoteIdentityFingerprint,
        baseURL: URL,
        pairingStatus: GrafttyBonjourService.PairingStatus
    ) {
        self.deviceID = deviceID
        self.label = label
        self.fingerprint = fingerprint
        self.baseURL = baseURL
        self.pairingStatus = pairingStatus
    }
}

struct NearbyMacServiceKey: Hashable {
    let name: String
    let type: String
    let domain: String

    init(name: String, type: String, domain: String) {
        self.name = name
        self.type = type
        self.domain = domain
    }

    init(_ service: NetService) {
        self.init(
            name: service.name,
            type: service.type,
            domain: service.domain
        )
    }
}

/// Tracks every resolved service separately, then publishes one most-recent
/// routing hint per device identity. A candidate therefore survives until
/// its final Bonjour service disappears, while a re-resolved service cannot
/// leave its previous identity behind as a ghost row.
struct NearbyMacCandidateRegistry {
    private struct Entry {
        let candidate: NearbyMac
        let sequence: UInt64
    }

    private var entriesByService: [NearbyMacServiceKey: Entry] = [:]
    private var nextSequence: UInt64 = 0

    mutating func publish(
        _ candidate: NearbyMac,
        for service: NearbyMacServiceKey
    ) {
        nextSequence &+= 1
        entriesByService[service] = Entry(
            candidate: candidate,
            sequence: nextSequence
        )
    }

    mutating func remove(_ service: NearbyMacServiceKey) {
        entriesByService[service] = nil
    }

    mutating func removeAll() {
        entriesByService.removeAll()
    }

    var candidates: [NearbyMac] {
        var latestByIdentity: [String: Entry] = [:]
        for entry in entriesByService.values {
            if let current = latestByIdentity[entry.candidate.id],
               current.sequence > entry.sequence {
                continue
            }
            latestByIdentity[entry.candidate.id] = entry
        }
        return latestByIdentity.values
            .map(\.candidate)
            .sorted {
                $0.label.localizedCaseInsensitiveCompare($1.label)
                    == .orderedAscending
            }
    }
}

/// Bonjour discovery shared by the picker and the app-level address refresh.
/// `NetService` delivers delegate callbacks on the run loop where browsing
/// started; production starts it from SwiftUI's main actor.
@Observable
public final class NearbyMacBrowser: NSObject {
    public private(set) var candidates: [NearbyMac] = []
    public private(set) var isSearching = false
    public private(set) var errorMessage: String?

    private let browser: NetServiceBrowser
    private var resolving: [ObjectIdentifier: NetService] = [:]
    private var registry = NearbyMacCandidateRegistry()

    public override convenience init() {
        self.init(browser: NetServiceBrowser())
    }

    init(browser: NetServiceBrowser) {
        self.browser = browser
        super.init()
    }

    public func start() {
        guard !isSearching else { return }
        isSearching = true
        errorMessage = nil
        browser.delegate = self
        browser.searchForServices(
            ofType: GrafttyBonjourService.serviceType,
            inDomain: GrafttyBonjourService.domain
        )
    }

    public func stop() {
        browser.stop()
        browser.delegate = nil
        isSearching = false
        for service in resolving.values {
            service.stop()
            service.delegate = nil
        }
        resolving.removeAll()
        registry.removeAll()
        candidates = []
    }

    static func candidate(
        name: String,
        hostName: String?,
        port: Int,
        txtRecordData: Data?
    ) -> NearbyMac? {
        guard (1...65_535).contains(port),
              let txtRecordData,
              let metadata = try? GrafttyBonjourService.decodeTXT(txtRecordData),
              metadata.version == GrafttyBonjourService.discoveryVersion,
              GrafttyBonjourService.isProtocolCompatible(
                  advertisedProtocol: metadata.protocolVersion,
                  supportedProtocolVersions: [
                      GrafttyBonjourService.discoveryVersion
                  ]
              ),
              let hostName
        else {
            return nil
        }
        let host = hostName.trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        )
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        guard let baseURL = components.url else { return nil }
        return NearbyMac(
            deviceID: metadata.deviceID,
            label: metadata.label.isEmpty ? name : metadata.label,
            fingerprint: metadata.fingerprint,
            baseURL: baseURL,
            pairingStatus: metadata.pairingStatus
        )
    }

    private func remember(_ service: NetService) {
        resolving[ObjectIdentifier(service)] = service
    }

    private func forget(_ service: NetService) {
        service.delegate = nil
        resolving[ObjectIdentifier(service)] = nil
    }
}

extension NearbyMacBrowser: NetServiceBrowserDelegate {
    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        service.delegate = self
        remember(service)
        service.resolve(withTimeout: 5)
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        registry.remove(NearbyMacServiceKey(service))
        candidates = registry.candidates
        forget(service)
    }

    public func netServiceBrowserDidStopSearch(
        _ browser: NetServiceBrowser
    ) {
        isSearching = false
    }

    public func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        isSearching = false
        errorMessage = "Nearby Mac discovery is unavailable."
    }
}

extension NearbyMacBrowser: NetServiceDelegate {
    public func netServiceDidResolveAddress(_ sender: NetService) {
        defer { forget(sender) }
        guard let candidate = Self.candidate(
            name: sender.name,
            hostName: sender.hostName,
            port: sender.port,
            txtRecordData: sender.txtRecordData()
        ) else {
            return
        }
        registry.publish(candidate, for: NearbyMacServiceKey(sender))
        candidates = registry.candidates
    }

    public func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        forget(sender)
    }
}
#endif
