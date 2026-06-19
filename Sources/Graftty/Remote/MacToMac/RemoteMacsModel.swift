import Combine
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

enum RemoteMacPairingSaveResult: Sendable {
    case paired(PinnedHost)
    case denied
    case failed(String)
}

@MainActor
final class RemoteMacsModel: ObservableObject {
    @Published private(set) var savedRemoteMacs: [RemoteMac] = []
    @Published private(set) var discoveryCandidates: [GrafttyBonjourCandidate] = []
    @Published private(set) var worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]] = [:]

    private let store: RemoteMacStore
    private let connectionRegistry: RemoteMacConnectionRegistry
    private var connectionStates: [RemoteMacIdentity: RemoteMacConnectionState] = [:]
    private var candidatesByIdentity: [RemoteMacIdentity: GrafttyBonjourCandidate] = [:]
    private var discoveryBrowser: RemoteMacDiscoveryBrowsing?

    init(
        store: RemoteMacStore? = nil,
        connectionRegistry: RemoteMacConnectionRegistry? = nil
    ) {
        self.store = store ?? RemoteMacStore()
        self.connectionRegistry = connectionRegistry ?? RemoteMacConnectionRegistry()
    }

    func loadSavedRemotes() async {
        await store.loadIfNeeded()
        savedRemoteMacs = store.remoteMacs
        for remoteMac in savedRemoteMacs {
            let identity = RemoteMacIdentity(remoteMac)
            connectionStates[identity] = connectionStates[identity] ?? .offline
        }
    }

    func connectionState(for identity: RemoteMacIdentity) -> RemoteMacConnectionState {
        connectionStates[identity] ?? .offline
    }

    @discardableResult
    func connect(to remoteMac: RemoteMac) async throws -> RemoteMacConnectionRegistry.Entry {
        let identity = RemoteMacIdentity(remoteMac)
        connectionStates[identity] = .connecting
        do {
            let entry = try await connectionRegistry.connect(to: remoteMac)
            connectionStates[identity] = .connected
            if let store = entry.paneEnvironment.worktreePanesStore {
                worktreePanesByRemote[identity] = await store.current
            }
            return entry
        } catch {
            connectionStates[identity] = .failed
            throw error
        }
    }

    func disconnect(identity: RemoteMacIdentity) {
        connectionRegistry.disconnect(identity: identity)
        connectionStates[identity] = .offline
        worktreePanesByRemote[identity] = nil
    }

    func openTerminalSession(
        identity: RemoteMacIdentity,
        sessionName: String
    ) async throws -> any WebSocketClient & Sendable {
        try await connectionRegistry.openTerminalSession(
            identity: identity,
            sessionName: sessionName
        )
    }

    func setDiscoveryBrowser(_ discoveryBrowser: RemoteMacDiscoveryBrowsing?) {
        self.discoveryBrowser = discoveryBrowser
    }

    func startDiscovery() {
        discoveryBrowser?.start()
    }

    func stopDiscovery() {
        discoveryBrowser?.stop()
    }

    func publishDiscoveryCandidate(_ candidate: GrafttyBonjourCandidate) throws {
        let identity = RemoteMacIdentity(candidate)
        candidatesByIdentity[identity] = candidate
        discoveryCandidates = candidatesByIdentity.values.sorted {
            if $0.discoveredAt == $1.discoveredAt {
                return $0.label < $1.label
            }
            return $0.discoveredAt > $1.discoveredAt
        }

        guard let existing = savedRemoteMacs.first(where: { RemoteMacIdentity($0) == identity }) else {
            return
        }

        let refreshed = GrafttyBonjourBrowser.remoteMac(from: candidate, existing: existing)
        try store.add(refreshed)
        savedRemoteMacs = store.remoteMacs
        // Rediscovery (Bonjour TTL refresh) must not downgrade a live
        // connection back to `.discovered`; only note reachability when the
        // remote is otherwise idle.
        switch connectionState(for: identity) {
        case .connecting, .connected:
            break
        case .offline, .discovered, .failed, .needsPairing:
            connectionStates[identity] = .discovered
        }
    }

    func recordPairingResult(_ result: RemoteMacPairingSaveResult) throws {
        guard case .paired(let pinnedHost) = result else { return }

        let remoteMac = RemoteMac(
            id: pinnedHost.id,
            label: pinnedHost.displayName,
            fingerprint: pinnedHost.fingerprint,
            lastKnownBaseURL: Self.baseURL(fromPairingURL: pinnedHost.pairingURL),
            addedAt: pinnedHost.pinnedAt,
            lastUsedAt: pinnedHost.lastConnectedAt,
            lastDiscoveredAt: nil
        )
        try store.add(remoteMac)
        savedRemoteMacs = store.remoteMacs
        connectionStates[RemoteMacIdentity(remoteMac)] = .offline
    }

    private static func baseURL(fromPairingURL pairingURL: URL) -> URL? {
        guard var components = URLComponents(url: pairingURL, resolvingAgainstBaseURL: false) else {
            return pairingURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum RemoteMacAccessServices {
    typealias SignalingOfferAcceptor = @Sendable (SignalingOffer) async -> LANSignalingOfferResult

    /// Per-bucket cap on the unauthenticated LAN pairing/signaling endpoints.
    /// The server is reachable pre-trust on `0.0.0.0`, and a legitimate
    /// pairing makes ~1 request per bucket, so this is generous enough to
    /// never affect a real user while throttling a flood from an on-network
    /// attacker (without it the handler defaults to `.disabled`).
    static let lanRateLimit = LANRemoteAccessRateLimit(maxRequests: 60, window: 60)

    @MainActor
    static func makeLANRouteHandler(
        lanBaseURLProvider: @escaping @Sendable () -> URL,
        hostPairingCoordinator: HostPairingCoordinator,
        acceptSignalingOffer: @escaping SignalingOfferAcceptor
    ) -> LANRemoteAccessRouteHandler {
        LANRemoteAccessRouteHandler(
            lanBaseURLProvider: lanBaseURLProvider,
            rateLimit: lanRateLimit,
            beginPairing: { validFor, lanBaseURL in
                await hostPairingCoordinator.beginPairing(
                    validFor: validFor,
                    lanBaseURL: lanBaseURL
                )
            },
            handleIntroduce: { request in
                await hostPairingCoordinator.handleIntroduce(request)
            },
            handleAwaitOutcome: { request in
                await hostPairingCoordinator.handleAwaitOutcome(request)
            },
            handleSignalingOffer: acceptSignalingOffer
        )
    }
}
