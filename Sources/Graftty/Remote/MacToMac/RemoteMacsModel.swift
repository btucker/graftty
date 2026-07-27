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
    enum RelayError: Error, Equatable {
        case unknownPaneAlias(String)
        case unexpectedManagementResponse
    }
    @Published private(set) var savedRemoteMacs: [RemoteMac] = []
    @Published private(set) var discoveryCandidates: [GrafttyBonjourCandidate] = []
    @Published private(set) var worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]] = [:]
    @Published private(set) var repositoriesByRemote:
        [RemoteMacIdentity: [RemoteRepositoryInfo]] = [:]
    @Published private(set) var notificationActivation:
        RemoteNotificationEvent?

    private let store: RemoteMacStore
    private let connectionRegistry: RemoteMacConnectionRegistry
    let relayRouter: RemoteWorktreeRelayRouter
    var onRemoteNotification: ((RemoteNotificationEvent) -> Void)?
    @Published private var connectionStates: [RemoteMacIdentity: RemoteMacConnectionState] = [:]
    private struct ConnectAttempt {
        let id: UUID
        let task: Task<RemoteMacConnectionRegistry.Entry, Error>
    }
    private var connectAttemptIDs: [RemoteMacIdentity: UUID] = [:]
    private var connectAttempts: [RemoteMacIdentity: ConnectAttempt] = [:]
    private var candidatesByIdentity: [RemoteMacIdentity: GrafttyBonjourCandidate] = [:]
    private var discoveryBrowser: RemoteMacDiscoveryBrowsing?
    private var discoveryLeaseCount = 0
    private var notificationSnapshotsPrimed: Set<RemoteMacIdentity> = []
    private var activeAttentionByRemote:
        [RemoteMacIdentity: Set<RemoteAttentionKey>] = [:]

    private struct RemoteAttentionKey: Hashable {
        let worktreeID: String
        let paneID: String?
        let text: String
        let kind: RemoteNotificationEvent.Kind
    }

    init(
        store: RemoteMacStore? = nil,
        connectionRegistry: RemoteMacConnectionRegistry? = nil,
        relayRouter: RemoteWorktreeRelayRouter? = nil
    ) {
        self.store = store ?? RemoteMacStore()
        let registry = connectionRegistry ?? RemoteMacConnectionRegistry()
        self.connectionRegistry = registry
        self.relayRouter = relayRouter ?? RemoteWorktreeRelayRouter()
        registry.onPaneSnapshot = { [weak self] identity, snapshot in
            self?.applyPaneSnapshot(snapshot, from: identity)
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
                self.repositoriesByRemote[identity] = nil
                self.resetNotificationSnapshot(for: identity)
                self.refreshRelayRoutes()
                return
            }
            switch state {
            case .failed:
                self.connectionStates[identity] = .failed
            case .closed:
                self.connectionStates[identity] = .offline
            case .idle, .connecting, .connected:
                return
            }
            self.worktreePanesByRemote[identity] = nil
            self.repositoriesByRemote[identity] = nil
            self.resetNotificationSnapshot(for: identity)
            self.refreshRelayRoutes()
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
        if let pending = connectAttempts[identity] {
            return try await pending.task.value
        }
        let attemptID = UUID()
        connectAttemptIDs[identity] = attemptID
        connectionStates[identity] = .connecting
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.performConnect(
                to: remoteMac,
                identity: identity,
                attemptID: attemptID
            )
        }
        connectAttempts[identity] = ConnectAttempt(id: attemptID, task: task)
        return try await task.value
    }

    private func performConnect(
        to remoteMac: RemoteMac,
        identity: RemoteMacIdentity,
        attemptID: UUID
    ) async throws -> RemoteMacConnectionRegistry.Entry {
        do {
            let entry = try await connectionRegistry.connect(to: remoteMac)
            guard connectAttemptIDs[identity] == attemptID else {
                throw CancellationError()
            }
            connectAttemptIDs[identity] = nil
            if connectAttempts[identity]?.id == attemptID {
                connectAttempts[identity] = nil
            }
            connectionStates[identity] = .connected
            // The panes channel publishes an initial snapshot through
            // `onPaneSnapshot`. Reading `store.current` here races that first
            // frame: an empty default can incorrectly prime notification
            // state, then replay durable attention when the real first frame
            // arrives.
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
                worktreePanesByRemote[identity] = nil
                repositoriesByRemote[identity] = nil
                resetNotificationSnapshot(for: identity)
                refreshRelayRoutes()
            }
            if connectAttempts[identity]?.id == attemptID {
                connectAttempts[identity] = nil
            }
            throw error
        }
    }

    func disconnect(identity: RemoteMacIdentity) {
        connectAttemptIDs[identity] = nil
        connectAttempts.removeValue(forKey: identity)?.task.cancel()
        connectionRegistry.disconnect(identity: identity)
        connectionStates[identity] = .offline
        worktreePanesByRemote[identity] = nil
        repositoriesByRemote[identity] = nil
        resetNotificationSnapshot(for: identity)
        refreshRelayRoutes()
    }

    func activateRemoteNotification(_ event: RemoteNotificationEvent) {
        notificationActivation = event
    }

    func consumeRemoteNotificationActivation() {
        notificationActivation = nil
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

    func sendRelayedPaneControl(
        _ request: PaneControlRequest
    ) async -> PaneControlResponse? {
        let translated: PaneControlRequest
        let identity: RemoteMacIdentity
        switch request {
        case let .split(target, direction):
            guard let route = relayRouter.resolvePane(target) else { return nil }
            identity = route.identity
            translated = .split(target: route.sessionName, direction: direction)
        case .close(let target):
            guard let route = relayRouter.resolvePane(target) else { return nil }
            identity = route.identity
            translated = .close(target: route.sessionName)
        case let .swap(source, target):
            guard let sourceRoute = relayRouter.resolvePane(source),
                  let targetRoute = relayRouter.resolvePane(target),
                  sourceRoute.identity == targetRoute.identity,
                  sourceRoute.worktreePath == targetRoute.worktreePath else {
                return nil
            }
            identity = sourceRoute.identity
            translated = .swap(
                source: sourceRoute.sessionName,
                target: targetRoute.sessionName
            )
        }
        do {
            return try await connectionRegistry.sendPaneControl(
                identity: identity,
                request: translated
            )
        } catch {
            return .error(
                code: "downstream-unavailable",
                message: String(describing: error)
            )
        }
    }

    func sendWorktreeManagement(
        identity: RemoteMacIdentity,
        request: WorktreeManagementRequest
    ) async throws -> WorktreeManagementResponse {
        try await connectionRegistry.sendWorktreeManagement(
            identity: identity,
            request: request
        )
    }

    func repositories(on remoteMac: RemoteMac) async throws
        -> [RemoteRepositoryInfo] {
        _ = try await connect(to: remoteMac)
        let response = try await sendWorktreeManagement(
            identity: RemoteMacIdentity(remoteMac),
            request: .listRepositories
        )
        guard case .repositories(let repositories) = response else {
            throw RelayError.unexpectedManagementResponse
        }
        return repositories.filter { ($0.origin?.relayDepth ?? 0) == 0 }
    }

    @discardableResult
    func refreshRepositories(on remoteMac: RemoteMac) async throws
        -> [RemoteRepositoryInfo] {
        let repositories = try await repositories(on: remoteMac)
        repositoriesByRemote[RemoteMacIdentity(remoteMac)] = repositories
        return repositories
    }

    func createWorktree(
        on remoteMac: RemoteMac,
        repositoryID: String,
        worktreeName: String,
        branch: BranchSelection
    ) async -> WorktreeManagementResponse {
        let existingSource: RemoteRepositoryInfo.Branch.Source?
        switch branch {
        case .createNew:
            existingSource = nil
        case .useExisting(_, let source):
            switch source {
            case .local:
                existingSource = .local
            case .remoteOnly:
                existingSource = .remoteOnly
            }
        }
        let response = await forwardManagement(
            identity: RemoteMacIdentity(remoteMac),
            request: .create(
                repositoryID: repositoryID,
                worktreeName: worktreeName,
                branchName: branch.branchName,
                existingSource: existingSource
            )
        )
        _ = try? await refreshRepositories(on: remoteMac)
        return response
    }

    func deleteWorktree(
        on remoteMac: RemoteMac,
        worktreePath: String,
        force: Bool
    ) async -> WorktreeManagementResponse {
        let identity = RemoteMacIdentity(remoteMac)
        let response = await forwardManagement(
            identity: identity,
            request: .delete(worktreeID: worktreePath, force: force)
        )
        if case .deleted = response {
            removeCachedWorktree(path: worktreePath, from: identity)
        }
        return response
    }

    func pullDefaultBranch(
        on remoteMac: RemoteMac,
        repositoryID: String
    ) async -> WorktreeManagementResponse {
        let response = await forwardManagement(
            identity: RemoteMacIdentity(remoteMac),
            request: .pullDefaultBranch(repositoryID: repositoryID)
        )
        _ = try? await refreshRepositories(on: remoteMac)
        return response
    }

    func acknowledge(
        on remoteMac: RemoteMac,
        worktreePath: String,
        paneSessionName: String? = nil
    ) async {
        _ = await forwardManagement(
            identity: RemoteMacIdentity(remoteMac),
            request: .acknowledge(
                worktreeID: worktreePath,
                paneID: paneSessionName
            )
        )
    }

    func promotedRepositoriesForRelay() async -> [RemoteRepositoryInfo] {
        var promoted: [RemoteRepositoryInfo] = []
        for remoteMac in savedRemoteMacs
        where connectionState(for: RemoteMacIdentity(remoteMac)) == .connected {
            do {
                let repositories = try await repositories(on: remoteMac)
                promoted += relayRouter.promotedRepositories(
                    repositories,
                    from: remoteMac
                )
            } catch {
                continue
            }
        }
        return promoted
    }

    func sendRelayedWorktreeManagement(
        _ request: WorktreeManagementRequest
    ) async -> WorktreeManagementResponse? {
        switch request {
        case .listRepositories:
            return .repositories(await promotedRepositoriesForRelay())

        case let .create(repositoryID, worktreeName, branchName, existingSource):
            guard let route = relayRouter.resolveRepository(repositoryID) else {
                return nil
            }
            do {
                let response = try await sendWorktreeManagement(
                    identity: route.identity,
                    request: .create(
                        repositoryID: route.repositoryID,
                        worktreeName: worktreeName,
                        branchName: branchName,
                        existingSource: existingSource
                    )
                )
                guard case let .created(worktreeID, paneID) = response else {
                    return response
                }
                let promoted = relayRouter.registerCreatedWorktree(
                    identity: route.identity,
                    path: worktreeID,
                    paneSessionName: paneID
                )
                return .created(
                    worktreeID: promoted.worktreeID,
                    paneID: promoted.paneID
                )
            } catch {
                return Self.downstreamManagementError(error)
            }

        case .pullDefaultBranch(let repositoryID):
            guard let route = relayRouter.resolveRepository(repositoryID) else {
                return nil
            }
            return await forwardManagement(
                identity: route.identity,
                request: .pullDefaultBranch(repositoryID: route.repositoryID)
            )

        case let .delete(worktreeID, force):
            guard let route = relayRouter.resolveWorktree(worktreeID) else {
                return nil
            }
            let response = await forwardManagement(
                identity: route.identity,
                request: .delete(worktreeID: route.path, force: force)
            )
            if case .deleted = response {
                removeCachedWorktree(
                    path: route.path,
                    from: route.identity
                )
            }
            return response

        case let .acknowledge(worktreeID, paneID):
            guard let worktreeRoute = relayRouter.resolveWorktree(worktreeID)
            else { return nil }
            let downstreamPaneID: String?
            if let paneID {
                guard let paneRoute = relayRouter.resolvePane(paneID),
                      paneRoute.identity == worktreeRoute.identity,
                      paneRoute.worktreePath == worktreeRoute.path else {
                    return nil
                }
                downstreamPaneID = paneRoute.sessionName
            } else {
                downstreamPaneID = nil
            }
            return await forwardManagement(
                identity: worktreeRoute.identity,
                request: .acknowledge(
                    worktreeID: worktreeRoute.path,
                    paneID: downstreamPaneID
                )
            )
        }
    }

    private func forwardManagement(
        identity: RemoteMacIdentity,
        request: WorktreeManagementRequest
    ) async -> WorktreeManagementResponse {
        do {
            return try await sendWorktreeManagement(
                identity: identity,
                request: request
            )
        } catch {
            return Self.downstreamManagementError(error)
        }
    }

    private static func downstreamManagementError(
        _ error: Error
    ) -> WorktreeManagementResponse {
        .error(
            code: "downstream-unavailable",
            message: String(describing: error),
            forceAllowed: false,
            shortStatus: nil
        )
    }

    func promotedWorktreesForRelay() -> [WorktreePanes] {
        relayRouter.promotedWorktrees(
            snapshots: worktreePanesByRemote,
            remoteMacs: savedRemoteMacs
        )
    }

    private func refreshRelayRoutes() {
        _ = relayRouter.promotedWorktrees(
            snapshots: worktreePanesByRemote,
            remoteMacs: savedRemoteMacs
        )
    }

    func openRelayedTerminal(alias: String) async throws -> RelayedTerminalByteStream {
        guard let target = relayRouter.resolvePane(alias),
              let remoteMac = savedRemoteMacs.first(where: {
                  RemoteMacIdentity($0) == target.identity
              }) else {
            throw RelayError.unknownPaneAlias(alias)
        }
        _ = try await connect(to: remoteMac)
        let client = try await openTerminalSession(
            identity: target.identity,
            sessionName: target.sessionName
        )
        return RelayedTerminalByteStream(client: client)
    }

    private func applyPaneSnapshot(
        _ snapshot: [WorktreePanes],
        from identity: RemoteMacIdentity
    ) {
        worktreePanesByRemote[identity] = snapshot
        processAttentionTransitions(snapshot, from: identity)
        refreshRelayRoutes()
    }

    private func processAttentionTransitions(
        _ snapshot: [WorktreePanes],
        from identity: RemoteMacIdentity
    ) {
        let current = attentionEvents(in: snapshot, from: identity)
        let currentKeys = Set(current.map(\.key))
        guard notificationSnapshotsPrimed.contains(identity) else {
            let previous = activeAttentionByRemote[identity]
            notificationSnapshotsPrimed.insert(identity)
            activeAttentionByRemote[identity] = currentKeys
            // A first-ever snapshot may be arbitrarily old, so it only seeds
            // the baseline. On reconnect, compare with the final pre-disconnect
            // baseline and collapse newly observed offline attention into one
            // actionable summary.
            guard let previous else { return }
            let additions = current.filter { !previous.contains($0.key) }
            if let summary = makeReconnectSummary(
                for: additions.map(\.event),
                from: identity
            ) {
                onRemoteNotification?(summary)
            }
            return
        }
        let previous = activeAttentionByRemote[identity] ?? []
        activeAttentionByRemote[identity] = currentKeys
        for item in current where !previous.contains(item.key) {
            onRemoteNotification?(item.event)
        }
    }

    private func attentionEvents(
        in snapshot: [WorktreePanes],
        from identity: RemoteMacIdentity
    ) -> [(key: RemoteAttentionKey, event: RemoteNotificationEvent)] {
        guard let remoteMac = savedRemoteMacs.first(where: {
            RemoteMacIdentity($0) == identity
        }) else { return [] }

        var events: [(RemoteAttentionKey, RemoteNotificationEvent)] = []
        for worktree in snapshot
        where (worktree.origin?.relayDepth ?? 0) == 0 {
            let origin = worktree.origin ?? WorktreeOrigin(
                deviceID: remoteMac.id,
                deviceLabel: remoteMac.label,
                relayDepth: 0
            )
            if let text = worktree.attentionText {
                events.append(makeAttentionEvent(
                    remoteMac: remoteMac,
                    origin: origin,
                    worktree: worktree,
                    paneID: nil,
                    text: text,
                    kind: .userNotify
                ))
            }
            for leaf in worktree.layout?.leaves ?? [] {
                guard let text = leaf.attentionText else { continue }
                let kind: RemoteNotificationEvent.Kind
                switch leaf.attentionSource {
                case .agentStop:
                    kind = .agentStop
                case .userNotify:
                    kind = .userNotify
                case .commandFinished, .none:
                    continue
                }
                events.append(makeAttentionEvent(
                    remoteMac: remoteMac,
                    origin: origin,
                    worktree: worktree,
                    paneID: leaf.sessionName,
                    text: text,
                    kind: kind
                ))
            }
        }
        return events
    }

    private func makeAttentionEvent(
        remoteMac: RemoteMac,
        origin: WorktreeOrigin,
        worktree: WorktreePanes,
        paneID: String?,
        text: String,
        kind: RemoteNotificationEvent.Kind
    ) -> (RemoteAttentionKey, RemoteNotificationEvent) {
        let key = RemoteAttentionKey(
            worktreeID: worktree.path,
            paneID: paneID,
            text: text,
            kind: kind
        )
        let worktreeName = worktree.displayName.isEmpty
            ? worktree.displayBranch
            : worktree.displayName
        let title = kind == .agentStop
            ? text
            : "Notification from \(remoteMac.label)"
        let body = kind == .agentStop
            ? "\(worktreeName) on \(remoteMac.label) is waiting for you."
            : "\(worktreeName): \(text)"
        return (key, RemoteNotificationEvent(
            id: UUID(),
            kind: kind,
            origin: origin,
            originFingerprint: RemoteMacIdentity(remoteMac).fingerprint,
            worktreeID: worktree.path,
            paneID: paneID,
            title: title,
            body: body,
            timestamp: Date()
        ))
    }

    private func makeReconnectSummary(
        for events: [RemoteNotificationEvent],
        from identity: RemoteMacIdentity
    ) -> RemoteNotificationEvent? {
        guard let first = events.first,
              let remoteMac = savedRemoteMacs.first(where: {
                  RemoteMacIdentity($0) == identity
              }) else {
            return nil
        }
        let itemCount = events.count
        let worktreeCount = Set(events.map(\.worktreeID)).count
        let itemNoun = itemCount == 1 ? "item" : "items"
        let worktreeNoun = worktreeCount == 1 ? "worktree" : "worktrees"
        let verb = itemCount == 1 ? "needs" : "need"
        return RemoteNotificationEvent(
            id: UUID(),
            kind: .reconnectSummary,
            origin: first.origin,
            originFingerprint: identity.fingerprint,
            worktreeID: first.worktreeID,
            paneID: first.paneID,
            title: "\(remoteMac.label) needs attention",
            body: """
            \(itemCount) \(itemNoun) across \(worktreeCount) remote \
            \(worktreeNoun) \(verb) attention.
            """,
            timestamp: Date()
        )
    }

    private func resetNotificationSnapshot(for identity: RemoteMacIdentity) {
        notificationSnapshotsPrimed.remove(identity)
        // Preserve the final connected snapshot as the reconnect baseline.
        // Without it, unchanged durable badges would be misreported as newly
        // accumulated offline attention.
    }

    private func removeCachedWorktree(
        path: String,
        from identity: RemoteMacIdentity
    ) {
        worktreePanesByRemote[identity]?.removeAll { $0.path == path }
        refreshRelayRoutes()
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
