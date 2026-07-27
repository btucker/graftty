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
    @Published private var connectionStates: [RemoteMacIdentity: RemoteMacConnectionState] = [:]
    private var connectAttemptIDs: [RemoteMacIdentity: UUID] = [:]
    private var candidatesByIdentity: [RemoteMacIdentity: GrafttyBonjourCandidate] = [:]
    private var discoveryBrowser: RemoteMacDiscoveryBrowsing?
    private var discoveryLeaseCount = 0

    init(
        store: RemoteMacStore? = nil,
        connectionRegistry: RemoteMacConnectionRegistry? = nil
    ) {
        self.store = store ?? RemoteMacStore()
        let registry = connectionRegistry ?? RemoteMacConnectionRegistry()
        self.connectionRegistry = registry
        registry.onPaneSnapshot = { [weak self] identity, snapshot in
            self?.worktreePanesByRemote[identity] = snapshot
        }
        registry.onConnectionStateChange = { [weak self] identity, state in
            guard let self else { return }
            // A host-key mismatch is classified from the typed SSH error in
            // `connect(to:)`. Its transport also publishes a generic terminal
            // state, sometimes before and sometimes after that error arrives.
            // Once classified, no generic callback may erase the actionable
            // trust state.
            guard self.connectionStates[identity] != .needsPairing else {
                self.worktreePanesByRemote[identity] = nil
                return
            }
            self.connectAttemptIDs[identity] = nil
            switch state {
            case .failed:
                self.connectionStates[identity] = .failed
            case .closed:
                self.connectionStates[identity] = .offline
            case .idle, .connecting, .connected:
                return
            }
            self.worktreePanesByRemote[identity] = nil
        }
    }

    func loadSavedRemotes() async {
        await store.loadIfNeeded()
        savedRemoteMacs = store.remoteMacs
        for remoteMac in savedRemoteMacs {
            let identity = RemoteMacIdentity(remoteMac)
            if let candidate = candidatesByIdentity[identity] {
                let refreshed = GrafttyBonjourBrowser.remoteMac(
                    from: candidate,
                    existing: remoteMac
                )
                do {
                    try store.add(refreshed)
                } catch {
                    NSLog(
                        "[Graftty] failed to reconcile discovered remote Mac after load: %@",
                        String(describing: error)
                    )
                }
                connectionStates[identity] = .discovered
            } else {
                connectionStates[identity] = connectionStates[identity] ?? .offline
            }
        }
        savedRemoteMacs = store.remoteMacs
    }

    func connectionState(for identity: RemoteMacIdentity) -> RemoteMacConnectionState {
        connectionStates[identity] ?? .offline
    }

    @discardableResult
    func connect(to remoteMac: RemoteMac) async throws -> RemoteMacConnectionRegistry.Entry {
        let identity = RemoteMacIdentity(remoteMac)
        let attemptID = UUID()
        connectAttemptIDs[identity] = attemptID
        connectionStates[identity] = .connecting
        do {
            let entry = try await connectionRegistry.connect(to: remoteMac)
            let paneSnapshot: [WorktreePanes]?
            if let store = entry.paneEnvironment.worktreePanesStore {
                paneSnapshot = await store.current
            } else {
                paneSnapshot = nil
            }
            guard connectAttemptIDs[identity] == attemptID else {
                throw CancellationError()
            }
            connectAttemptIDs[identity] = nil
            connectionStates[identity] = .connected
            if let paneSnapshot {
                worktreePanesByRemote[identity] = paneSnapshot
            }
            return entry
        } catch {
            let requiresPairing = Self.requiresPairing(after: error)
            let attemptIsCurrent = connectAttemptIDs[identity] == attemptID
            let terminalCallbackFinishedAttempt = requiresPairing
                && connectAttemptIDs[identity] == nil
                && connectionStates[identity] == .failed
            if attemptIsCurrent || terminalCallbackFinishedAttempt {
                connectAttemptIDs[identity] = nil
                connectionStates[identity] = requiresPairing ? .needsPairing : .failed
            }
            throw error
        }
    }

    func disconnect(identity: RemoteMacIdentity) {
        connectAttemptIDs[identity] = nil
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
        discoveryLeaseCount += 1
        if discoveryLeaseCount == 1 {
            discoveryBrowser?.start()
        }
    }

    func stopDiscovery() {
        guard discoveryLeaseCount > 0 else { return }
        discoveryLeaseCount -= 1
        guard discoveryLeaseCount == 0 else { return }
        discoveryBrowser?.stop()
        clearDiscoveryCandidates()
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
        case .connecting, .connected, .needsPairing:
            break
        case .offline, .discovered, .failed:
            connectionStates[identity] = .discovered
        }
    }

    func removeDiscoveryCandidate(identity: RemoteMacIdentity) {
        guard candidatesByIdentity.removeValue(forKey: identity) != nil else {
            return
        }
        discoveryCandidates = candidatesByIdentity.values.sorted {
            if $0.discoveredAt == $1.discoveredAt {
                return $0.label < $1.label
            }
            return $0.discoveredAt > $1.discoveredAt
        }
        if connectionState(for: identity) == .discovered {
            connectionStates[identity] = .offline
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

    private static func requiresPairing(after error: Error) -> Bool {
        guard case PinnedHostKeyError.hostKeyMismatch = error else {
            return false
        }
        return true
    }

    private func clearDiscoveryCandidates() {
        let removedIdentities = Array(candidatesByIdentity.keys)
        candidatesByIdentity.removeAll()
        discoveryCandidates.removeAll()
        for identity in removedIdentities where connectionState(for: identity) == .discovered {
            connectionStates[identity] = .offline
        }
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
        hostPairingCoordinator: RemoteMacHostPairingCoordinator,
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
