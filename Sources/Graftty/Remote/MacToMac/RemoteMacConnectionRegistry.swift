import CryptoKit
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import WebRTC

struct RemoteMacIdentity: Hashable, Sendable {
    var id: RemoteDeviceID
    var fingerprint: RemoteIdentityFingerprint

    init(id: RemoteDeviceID, fingerprint: RemoteIdentityFingerprint) {
        self.id = id
        self.fingerprint = fingerprint
    }

    init(_ remoteMac: RemoteMac) {
        self.init(id: remoteMac.id, fingerprint: remoteMac.fingerprint)
    }

    init(_ candidate: GrafttyBonjourCandidate) {
        self.init(id: candidate.deviceID, fingerprint: candidate.fingerprint)
    }
}

@MainActor
final class RemoteMacConnectionRegistry {
    private struct InFlightAttempt {
        let id: UUID
        let replacesExistingHostConnection: Bool
        let task: Task<Entry, Error>
    }

    private struct DisconnectWork {
        let entry: Entry?
        let attempt: InFlightAttempt?
    }

    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let identity: RemoteMacIdentity
        var remoteMac: RemoteMac
        let createdAt: Date
        let connection: any RemoteMacHostConnection
        let paneEnvironment: RemoteMacPaneEnvironment

        func openTerminalSession(sessionName: String) async throws -> any WebSocketClient & Sendable {
            try await connection.openTerminalSession(sessionName: sessionName)
        }

        func sendPaneControl(
            _ request: PaneControlRequest
        ) async throws -> PaneControlResponse {
            guard let client = paneEnvironment.paneControlClient else {
                throw ConnectionError.paneEnvironmentUnavailable(identity)
            }
            switch request {
            case let .split(target, direction):
                return try await client.split(target: target, direction: direction)
            case .close(let target):
                return try await client.close(target: target)
            case let .swap(source, target):
                return try await client.swap(source: source, target: target)
            case .equalize(let target):
                return try await client.equalize(target: target)
            case let .resize(
                target,
                direction,
                amount,
                viewportExtent
            ):
                return try await client.resize(
                    target: target,
                    direction: direction,
                    amount: amount,
                    viewportExtent: viewportExtent
                )
            }
        }

        func sendWorktreeManagement(
            _ request: WorktreeManagementRequest
        ) async throws -> WorktreeManagementResponse {
            let driver = try await connection.makeWorktreeManagementDriver()
            let client = WorktreeManagementClient(driver: driver)
            try await client.open()
            do {
                let response = try await client.send(request)
                await client.close()
                return response
            } catch {
                await client.close()
                throw error
            }
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id
                && lhs.identity == rhs.identity
                && lhs.remoteMac == rhs.remoteMac
                && lhs.createdAt == rhs.createdAt
        }
    }

    typealias ConnectionFactory = @MainActor @Sendable (RemoteMac, RemoteMacIdentity) async throws -> Entry
    typealias IntentAwareConnectionFactory = @MainActor @Sendable (
        RemoteMac,
        RemoteMacIdentity,
        Bool
    ) async throws -> Entry
    typealias IdentityProvider = @MainActor @Sendable () throws -> Curve25519.Signing.PrivateKey
    typealias PinnedHostProvider = @Sendable (RemoteDeviceID) -> PinnedHost?
    typealias PinnedHostUpdater = @Sendable (PinnedHost) throws -> Void
    typealias HostConnectionFactory = @MainActor @Sendable (
        Curve25519.Signing.PrivateKey,
        RemoteIdentityFingerprint
    ) -> any RemoteMacHostConnection
    typealias PaneEnvironmentBuilder = @Sendable (
        RemoteMacPaneEnvironmentHost?,
        @escaping @Sendable ([WorktreePanes]) async -> Void,
        @escaping @Sendable (String) async -> Void
    ) async -> RemoteMacPaneEnvironment
    typealias PaneSnapshotHandler = @MainActor @Sendable (RemoteMacIdentity, [WorktreePanes]) -> Void
    typealias ConnectionStateHandler = @MainActor @Sendable (
        RemoteMacIdentity,
        RemoteHostConnection.State
    ) -> Void

    enum ConnectionError: Error, Equatable, Sendable {
        case missingBaseURL(RemoteMacIdentity)
        case notConnected(RemoteMacIdentity)
        case paneEnvironmentUnavailable(RemoteMacIdentity)
        case connectionTerminated(RemoteMacIdentity)
        case worktreeManagementUnavailable
        case teamMessagingUnavailable
    }

    private var entries: [RemoteMacIdentity: Entry] = [:]
    private var teamClients: [UUID: TeamChannelClient] = [:]
    private var reconnectOnTeamClose: Set<UUID> = []
    var canReconnectFromHost: @MainActor (RemoteMacIdentity) -> Bool = { _ in false }
    var onReconnectFromHost: @MainActor (Entry) async -> Void = { _ in }
    weak var teamRouter: RemoteTeamRouter?
    private var inFlight: [RemoteMacIdentity: InFlightAttempt] = [:]
    private var legacyFactory: IntentAwareConnectionFactory?
    private let identityProvider: IdentityProvider
    private let clientDeviceID: RemoteDeviceID
    private let pinnedHostProvider: PinnedHostProvider
    private let pinnedHostUpdater: PinnedHostUpdater?
    private let signalingClient: SignalingClient
    private let connectionFactory: HostConnectionFactory
    private let paneEnvironmentBuilder: PaneEnvironmentBuilder
    var onPaneSnapshot: PaneSnapshotHandler
    var onConnectionStateChange: ConnectionStateHandler
    private let now: @Sendable () -> Date

    var activeConnectionCount: Int {
        entries.count
    }

    init(factory: ConnectionFactory? = nil) {
        let identityStore = ClientIdentityStore(directory: ClientIdentityStore.defaultDirectory)
        let pinnedHostStore = PinnedHostStore(directory: PinnedHostStore.defaultDirectory)
        if let factory {
            self.legacyFactory = { remoteMac, identity, _ in
                try await factory(remoteMac, identity)
            }
        } else {
            self.legacyFactory = nil
        }
        self.identityProvider = {
            try identityStore.loadOrGenerateAndPersist()
        }
        self.clientDeviceID = Self.defaultClientDeviceID()
        self.pinnedHostProvider = { try? pinnedHostStore.get(id: $0) }
        self.pinnedHostUpdater = { try pinnedHostStore.update($0) }
        self.signalingClient = SignalingClient()
        self.connectionFactory = { clientKey, expectedHostFingerprint in
            LiveRemoteMacHostConnection(
                connection: RemoteHostConnection(
                    clientKey: clientKey,
                    expectedHostFingerprint: expectedHostFingerprint
                )
            )
        }
        self.paneEnvironmentBuilder = { remoteHost, onSnapshot, onClosed in
            await RemoteMacPaneEnvironment.build(
                remoteHost: remoteHost,
                onSnapshot: onSnapshot,
                onClosed: onClosed
            )
        }
        self.onPaneSnapshot = { _, _ in }
        self.onConnectionStateChange = { _, _ in }
        self.now = { Date() }
    }

    convenience init(
        intentAwareFactory: @escaping IntentAwareConnectionFactory
    ) {
        self.init(factory: nil)
        self.legacyFactory = intentAwareFactory
    }

    init(
        identityProvider: @escaping IdentityProvider,
        clientDeviceID: RemoteDeviceID,
        pinnedHostProvider: @escaping PinnedHostProvider,
        pinnedHostUpdater: PinnedHostUpdater? = nil,
        signalingClient: SignalingClient,
        connectionFactory: @escaping HostConnectionFactory,
        paneEnvironmentBuilder: @escaping PaneEnvironmentBuilder,
        onPaneSnapshot: @escaping PaneSnapshotHandler = { _, _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.legacyFactory = nil
        self.identityProvider = identityProvider
        self.clientDeviceID = clientDeviceID
        self.pinnedHostProvider = pinnedHostProvider
        self.pinnedHostUpdater = pinnedHostUpdater
        self.signalingClient = signalingClient
        self.connectionFactory = connectionFactory
        self.paneEnvironmentBuilder = paneEnvironmentBuilder
        self.onPaneSnapshot = onPaneSnapshot
        self.onConnectionStateChange = { _, _ in }
        self.now = now
    }

    func connect(
        to remoteMac: RemoteMac,
        replacingExistingHostConnection: Bool = false
    ) async throws -> Entry {
        try Task.checkCancellation()
        let identity = RemoteMacIdentity(remoteMac)
        if var existing = entries[identity] {
            let state = await existing.connection.currentState()
            guard entries[identity]?.id == existing.id else {
                return try await connect(
                    to: remoteMac,
                    replacingExistingHostConnection: replacingExistingHostConnection
                )
            }
            if state.isTerminal {
                entries[identity] = nil
                await close(existing)
            } else {
                existing.remoteMac = remoteMac
                entries[identity] = existing
                return existing
            }
        }

        var supersededAttempt: InFlightAttempt?
        if let pending = inFlight[identity] {
            if replacingExistingHostConnection,
               !pending.replacesExistingHostConnection {
                supersededAttempt = pending
            } else {
                let completed = try await pending.task.value
                guard var current = entries[identity],
                      current.id == completed.id else {
                    throw CancellationError()
                }
                current.remoteMac = remoteMac
                entries[identity] = current
                return current
            }
        }

        try Task.checkCancellation()
        let attemptID = UUID()
        let attemptToSupersede = supersededAttempt
        let task = Task { @MainActor in
            if let attemptToSupersede {
                attemptToSupersede.task.cancel()
                _ = try? await attemptToSupersede.task.value
                try ensureCurrentAttempt(attemptID, identity: identity)
            }
            let entry: Entry
            if let legacyFactory {
                entry = try await legacyFactory(
                    remoteMac,
                    identity,
                    replacingExistingHostConnection
                )
            } else {
                entry = try await dial(
                    remoteMac: remoteMac,
                    identity: identity,
                    attemptID: attemptID,
                    replacingExistingHostConnection: replacingExistingHostConnection
                )
            }
            do {
                try ensureCurrentAttempt(attemptID, identity: identity)
            } catch {
                await close(entry)
                throw error
            }
            entries[identity] = entry

            let state = await entry.connection.currentState()
            guard !state.isTerminal else {
                if entries[identity]?.id == entry.id {
                    entries[identity] = nil
                }
                await close(entry)
                throw ConnectionError.connectionTerminated(identity)
            }
            Task { await self.openTeamChannel(for: entry) }
            return entry
        }
        inFlight[identity] = InFlightAttempt(
            id: attemptID,
            replacesExistingHostConnection: replacingExistingHostConnection,
            task: task
        )
        do {
            let entry = try await task.value
            if inFlight[identity]?.id == attemptID {
                inFlight[identity] = nil
            }
            return entry
        } catch {
            if inFlight[identity]?.id == attemptID {
                inFlight[identity] = nil
            }
            throw error
        }
    }

    func disconnect(identity: RemoteMacIdentity) {
        let work = takeDisconnectWork(identity: identity)
        Task { await finishDisconnect(work) }
    }

    func disconnectAndWait(identity: RemoteMacIdentity) async {
        await finishDisconnect(takeDisconnectWork(identity: identity))
    }

    func disconnectAll() {
        for entry in entries.values {
            Task { await close(entry) }
        }
        entries.removeAll()
        for attempt in inFlight.values {
            attempt.task.cancel()
        }
        inFlight.removeAll()
    }

    func openTerminalSession(
        identity: RemoteMacIdentity,
        sessionName: String
    ) async throws -> any WebSocketClient & Sendable {
        guard let entry = entries[identity] else {
            throw ConnectionError.notConnected(identity)
        }
        return try await entry.openTerminalSession(sessionName: sessionName)
    }

    func sendPaneControl(
        identity: RemoteMacIdentity,
        request: PaneControlRequest
    ) async throws -> PaneControlResponse {
        guard let entry = entries[identity] else {
            throw ConnectionError.notConnected(identity)
        }
        return try await entry.sendPaneControl(request)
    }

    func sendWorktreeManagement(
        identity: RemoteMacIdentity,
        request: WorktreeManagementRequest
    ) async throws -> WorktreeManagementResponse {
        guard let entry = entries[identity] else {
            throw ConnectionError.notConnected(identity)
        }
        return try await entry.sendWorktreeManagement(request)
    }

    private func dial(
        remoteMac: RemoteMac,
        identity: RemoteMacIdentity,
        attemptID: UUID,
        replacingExistingHostConnection: Bool
    ) async throws -> Entry {
        guard let baseURL = remoteMac.lastKnownBaseURL else {
            throw ConnectionError.missingBaseURL(identity)
        }

        let clientKey = try identityProvider()
        let connection = connectionFactory(clientKey, identity.fingerprint)
        await observe(
            connection: connection,
            identity: identity,
            entryID: attemptID
        )

        var paneEnvironment: RemoteMacPaneEnvironment?
        do {
            var refreshedPinnedHost: PinnedHost?
            let offerSDP = try await connection.createOfferSDP()
            try ensureCurrentAttempt(attemptID, identity: identity)
            let answerSDP: String
            guard let pinnedHost = pinnedHostProvider(remoteMac.id) else {
                throw ConnectionError.notConnected(identity)
            }
            var routes: [RemoteConnectionRoute] = []
            if let lastSuccessful = remoteMac.lastSuccessfulRoute {
                routes.append(lastSuccessful)
            }
            routes.append(contentsOf: remoteMac.routes)
            routes.append(contentsOf: pinnedHost.routes)
            if routes.isEmpty {
                routes.append(RemoteConnectionRoute(kind: .lan, baseURL: baseURL))
            }
            let exchange = try await signalingClient.authenticatedExchange(
                routes: routes,
                hostDeviceID: remoteMac.id,
                hostPublicKey: pinnedHost.publicKey,
                clientDeviceID: clientDeviceID,
                clientKey: clientKey,
                sdp: offerSDP,
                replacesExistingConnection: replacingExistingHostConnection,
                wakeOnLAN: pinnedHost.wakeOnLAN
            )
            var refreshed = pinnedHost
            refreshed.routes = exchange.answer.routes
            refreshed.lastSuccessfulRoute = exchange.route
            refreshed.wakeOnLAN = exchange.wakeOnLAN
            refreshed.lastConnectedAt = now()
            refreshedPinnedHost = refreshed
            answerSDP = exchange.answer.sdp
            try ensureCurrentAttempt(attemptID, identity: identity)
            try await connection.applyAnswerSDP(answerSDP)
            try ensureCurrentAttempt(attemptID, identity: identity)
            let environment = await paneEnvironmentBuilder(
                connection,
                { [weak self] snapshot in
                    await self?.publishPaneSnapshot(
                        snapshot,
                        identity: identity,
                        entryID: attemptID
                    )
                },
                { [weak self] reason in
                    await self?.handlePaneChannelClose(
                        reason: reason,
                        identity: identity,
                        entryID: attemptID
                    )
                }
            )
            paneEnvironment = environment
            try ensureCurrentAttempt(attemptID, identity: identity)
            guard !environment.isEmpty else {
                throw ConnectionError.paneEnvironmentUnavailable(identity)
            }
            if let refreshedPinnedHost {
                do {
                    try pinnedHostUpdater?(refreshedPinnedHost)
                } catch PinnedHostStore.Error.notFound {
                    // Trust was revoked while negotiation was in flight.
                    throw PinnedHostStore.Error.notFound
                } catch {
                    NSLog(
                        "[Graftty] connected to remote Mac, but could not persist route metadata: %@",
                        String(describing: error)
                    )
                }
            }

            return Entry(
                id: attemptID,
                identity: identity,
                remoteMac: remoteMac,
                createdAt: now(),
                connection: connection,
                paneEnvironment: environment
            )
        } catch {
            await paneEnvironment?.close()
            await connection.setOnStateChange(nil)
            await connection.close()
            throw error
        }
    }

    private func ensureCurrentAttempt(
        _ attemptID: UUID,
        identity: RemoteMacIdentity
    ) throws {
        try Task.checkCancellation()
        guard inFlight[identity]?.id == attemptID else {
            throw CancellationError()
        }
    }

    private func observe(
        connection: any RemoteMacHostConnection,
        identity: RemoteMacIdentity,
        entryID: UUID
    ) async {
        await connection.setOnStateChange { [weak self] state in
            guard state.isTerminal else { return }
            Task { @MainActor [weak self] in
                self?.handleTerminalState(
                    state,
                    identity: identity,
                    entryID: entryID
                )
            }
        }
    }

    private func handleTerminalState(
        _ state: RemoteHostConnection.State,
        identity: RemoteMacIdentity,
        entryID: UUID
    ) {
        var matchedCurrentConnection = false
        if let attempt = inFlight[identity], attempt.id == entryID {
            inFlight[identity] = nil
            attempt.task.cancel()
            matchedCurrentConnection = true
        }
        if let entry = entries[identity], entry.id == entryID {
            entries[identity] = nil
            matchedCurrentConnection = true
            Task { await close(entry) }
        }
        guard matchedCurrentConnection else { return }
        onConnectionStateChange(identity, state)
    }

    private func handlePaneChannelClose(
        reason: String,
        identity: RemoteMacIdentity,
        entryID: UUID
    ) {
        handleTerminalState(
            .failed(reason: "panes-state channel closed: \(reason)"),
            identity: identity,
            entryID: entryID
        )
    }

    func sidebarSnapshot(for identity: RemoteMacIdentity) async -> SidebarSnapshot? {
        guard case .snapshot(_, let sidebar) = await panesSnapshot(for: identity) else { return nil }
        return sidebar
    }

    func panesSnapshot(for identity: RemoteMacIdentity) async -> PanesStateMessage? {
        guard let entry = entries[identity], let store = entry.paneEnvironment.worktreePanesStore else { return nil }
        let snapshot = await store.currentSnapshot
        guard entries[identity]?.id == entry.id else { return nil }
        return snapshot
    }

    private func publishPaneSnapshot(
        _ snapshot: [WorktreePanes],
        identity: RemoteMacIdentity,
        entryID: UUID
    ) {
        let isCurrentAttempt = inFlight[identity]?.id == entryID
        let isCurrentEntry = entries[identity]?.id == entryID
        guard isCurrentAttempt || isCurrentEntry else { return }
        onPaneSnapshot(identity, snapshot)
    }

    func isCurrentConnection(_ entry: Entry) -> Bool {
        entries[entry.identity]?.id == entry.id
    }

    func teamChannelClosed(_ entry: Entry) async {
        let reconnect = reconnectOnTeamClose.remove(entry.id) != nil
        teamClients[entry.id] = nil
        teamRouter?.unregister(deviceID: entry.identity.id, connectionID: entry.id)
        guard reconnect, isCurrentConnection(entry) else { return }
        await onReconnectFromHost(entry)
    }

    func handleTeamRequest(_ data: Data, for entry: Entry) async -> Data {
        if let request = try? JSONDecoder().decode(RemoteTeamRequest.self, from: data),
           request == .prepareReconnect {
            let response: RemoteTeamResponse
            if entries[entry.identity]?.id == entry.id, canReconnectFromHost(entry.identity) {
                reconnectOnTeamClose.insert(entry.id)
                response = .ok
            } else {
                response = .error("This host connection is no longer ready to reconnect; check the Remote Macs sidebar")
            }
            return (try? JSONEncoder().encode(response)) ?? Data()
        }
        return await teamRouter?.receive(from: entry.identity.id, data: data) ?? Data()
    }

    private func openTeamChannel(for entry: Entry) async {
        guard let router = teamRouter else { return }
        do {
            let client = try await entry.connection.makeTeamClient(
                handler: { [weak self] data in
                    await self?.handleTeamRequest(data, for: entry) ?? Data()
                },
                onClose: { [weak self] in
                    await self?.teamChannelClosed(entry)
                }
            )
            // Retain while opening so disconnect can close the subsystem too.
            guard entries[entry.identity]?.id == entry.id else {
                client.close()
                return
            }
            teamClients[entry.id] = client
            try await client.open()
            guard entries[entry.identity]?.id == entry.id,
                  teamClients[entry.id] != nil else {
                client.close()
                return
            }
            router.register(deviceID: entry.identity.id, connectionID: entry.id, label: entry.remoteMac.label) { data in
                try await client.send(data)
            }
        } catch {
            teamClients.removeValue(forKey: entry.id)?.close()
            router.unregister(deviceID: entry.identity.id, connectionID: entry.id)
            // Older Macs can continue providing terminals when they reject
            // the optional team subsystem.
        }
    }

    private func close(_ entry: Entry) async {
        reconnectOnTeamClose.remove(entry.id)
        teamRouter?.unregister(deviceID: entry.identity.id, connectionID: entry.id)
        teamClients.removeValue(forKey: entry.id)?.close()
        await entry.connection.setOnStateChange(nil)
        await entry.paneEnvironment.close()
        await entry.connection.close()
    }

    private func takeDisconnectWork(
        identity: RemoteMacIdentity
    ) -> DisconnectWork {
        let entry = entries.removeValue(forKey: identity)
        if let entry { teamRouter?.unregister(deviceID: identity.id, connectionID: entry.id) }
        let attempt = inFlight.removeValue(forKey: identity)
        attempt?.task.cancel()
        return DisconnectWork(entry: entry, attempt: attempt)
    }

    private func finishDisconnect(_ work: DisconnectWork) async {
        if let attempt = work.attempt {
            _ = try? await attempt.task.value
        }
        if let entry = work.entry {
            await close(entry)
        }
    }

    private static func defaultClientDeviceID() -> RemoteDeviceID {
        do {
            return try HostDeviceIDStore.shared.loadOrGenerateAndPersist()
        } catch {
            assertionFailure("Failed to persist the local remote device ID: \(error)")
            return RemoteDeviceID.generate()
        }
    }
}

protocol RemoteMacHostConnection: RemoteMacPaneEnvironmentHost {
    func setOnStateChange(
        _ handler: (@Sendable (RemoteHostConnection.State) -> Void)?
    ) async
    func currentState() async -> RemoteHostConnection.State
    func createOfferSDP() async throws -> String
    func applyAnswerSDP(_ sdp: String) async throws
    func openTerminalSession(sessionName: String) async throws -> any WebSocketClient & Sendable
    func makeWorktreeManagementDriver() async throws
        -> any WorktreeManagementChannelDriver
    func makeTeamClient(
        handler: @escaping @Sendable (Data) async -> Data,
        onClose: @escaping @Sendable () async -> Void
    ) async throws -> TeamChannelClient
    func close() async
}

extension RemoteMacHostConnection {
    func makeTeamClient(
        handler: @escaping @Sendable (Data) async -> Data,
        onClose: @escaping @Sendable () async -> Void
    ) async throws -> TeamChannelClient {
        throw RemoteMacConnectionRegistry.ConnectionError.teamMessagingUnavailable
    }

    func setOnStateChange(
        _ handler: (@Sendable (RemoteHostConnection.State) -> Void)?
    ) async {}

    func currentState() async -> RemoteHostConnection.State {
        .connected
    }

    func makeWorktreeManagementDriver() async throws
        -> any WorktreeManagementChannelDriver {
        throw RemoteMacConnectionRegistry.ConnectionError
            .worktreeManagementUnavailable
    }
}

private final class LiveRemoteMacHostConnection: RemoteMacHostConnection, @unchecked Sendable {
    private let connection: RemoteHostConnection

    init(connection: RemoteHostConnection) {
        self.connection = connection
    }

    func setOnStateChange(
        _ handler: (@Sendable (RemoteHostConnection.State) -> Void)?
    ) async {
        await connection.setOnStateChange(handler)
    }

    func currentState() async -> RemoteHostConnection.State {
        await connection.state
    }

    func createOfferSDP() async throws -> String {
        try await connection.createOffer().sdp
    }

    func applyAnswerSDP(_ sdp: String) async throws {
        try await connection.applyAnswer(
            RTCSessionDescription(type: .answer, sdp: sdp)
        )
    }

    func makePanesStateDriver(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void
    ) async throws -> any PanesStateChannelDriver {
        NegotiatingPanesStateDriver(
            connection: connection,
            onSnapshot: onSnapshot,
            onClosed: onClosed
        )
    }

    func makePaneControlDriver() async throws -> any PaneControlChannelDriver {
        try await connection.makePaneControlClient()
    }

    func openTerminalSession(sessionName: String) async throws -> any WebSocketClient & Sendable {
        try await connection.openTerminalSession(sessionName: sessionName, preferPaged: MacPagedTerminalRenderer.isSupported)
    }

    func makeWorktreeManagementDriver() async throws
        -> any WorktreeManagementChannelDriver {
        try await connection.makeWorktreeManagementClient()
    }

    func makeTeamClient(
        handler: @escaping @Sendable (Data) async -> Data,
        onClose: @escaping @Sendable () async -> Void
    ) async throws -> TeamChannelClient {
        try await connection.makeTeamClient(handler: handler, onClose: onClose)
    }

    func close() async {
        await connection.close()
    }
}

/// Prefers the origin-aware V2 snapshot channel, but explicitly negotiates it
/// so a Mac running an older Graftty can reject the subsystem and continue on
/// the V1 channel. V1 rows are treated as direct rows by the relay layer.
private final class NegotiatingPanesStateDriver:
    PanesStateChannelDriver,
    SidebarSnapshotProviding,
    PanesStateCallbacksConfigurable,
    @unchecked Sendable
{
    private enum NegotiationError: Error {
        case channelClosedDuringOpen(String)
    }

    private let connection: RemoteHostConnection
    private let lock = NSLock()
    private var onSnapshot: PanesStateChannelClient.OnSnapshot
    private var onClosed: PanesStateChannelClient.OnClosed
    var sidebarSnapshot: SidebarSnapshot? { lock.withLock { (activeClient ?? openingClient)?.sidebarSnapshot } }
    private var activeClient: PanesStateChannelClient?
    private var openingClient: PanesStateChannelClient?
    private var openingToken: UUID?
    private var activeToken: UUID?
    private var closeDuringOpen: [UUID: String] = [:]
    private var closed = false

    init(
        connection: RemoteHostConnection,
        onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
        onClosed: @escaping PanesStateChannelClient.OnClosed
    ) {
        self.connection = connection
        self.onSnapshot = onSnapshot
        self.onClosed = onClosed
    }

    func setCallbacks(
        onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
        onClosed: @escaping PanesStateChannelClient.OnClosed
    ) {
        lock.withLock {
            self.onSnapshot = onSnapshot
            self.onClosed = onClosed
        }
    }

    func open() async throws {
        guard lock.withLock({ !closed }) else {
            throw CancellationError()
        }
        do {
            let token = UUID()
            lock.withLock { openingToken = token }
            let v2 = try await makeClient(
                originAware: true,
                token: token
            )
            guard prepareToOpen(v2, token: token) else {
                v2.close()
                throw CancellationError()
            }
            try await v2.open()
            try activate(v2, token: token)
        } catch {
            let shouldStop = lock.withLock {
                openingClient = nil
                if let openingToken {
                    closeDuringOpen[openingToken] = nil
                }
                openingToken = nil
                return closed
            }
            guard !shouldStop else { throw CancellationError() }
            guard Self.isSubsystemRejection(error) else { throw error }

            let token = UUID()
            lock.withLock { openingToken = token }
            do {
                let legacy = try await makeClient(
                    originAware: false,
                    token: token
                )
                guard prepareToOpen(legacy, token: token) else {
                    legacy.close()
                    throw CancellationError()
                }
                try await legacy.open()
                try activate(legacy, token: token)
            } catch {
                lock.withLock {
                    openingClient = nil
                    openingToken = nil
                    closeDuringOpen[token] = nil
                }
                throw error
            }
        }
    }

    func close() {
        let clients = lock.withLock {
            closed = true
            return [openingClient, activeClient].compactMap { $0 }
        }
        clients.forEach { $0.close() }
    }

    private func makeClient(
        originAware: Bool,
        token: UUID
    ) async throws -> PanesStateChannelClient {
        try await connection.makePanesStateClient(
            onSnapshot: { [weak self] snapshot in
                guard let self else { return }
                let callback: PanesStateChannelClient.OnSnapshot? =
                    self.lock.withLock {
                    guard self.openingToken == token
                        || self.activeToken == token else {
                        return nil
                    }
                    return self.onSnapshot
                }
                guard let callback else { return }
                await callback(snapshot)
            },
            onClosed: { [weak self] reason in
                guard let self else { return }
                let callback: PanesStateChannelClient.OnClosed? =
                    self.lock.withLock {
                        if self.activeToken == token {
                            return self.onClosed
                        }
                        if self.openingToken == token {
                            self.closeDuringOpen[token] = reason
                        }
                        return nil
                    }
                guard let callback else { return }
                await callback(reason)
            },
            originAware: originAware,
            requestReply: true
        )
    }

    private func activate(
        _ client: PanesStateChannelClient,
        token: UUID
    ) throws {
        let closeReason: String? = lock.withLock {
            openingClient = nil
            openingToken = nil
            if let reason = closeDuringOpen.removeValue(forKey: token) {
                return reason
            }
            activeToken = token
            activeClient = client
            return nil
        }
        if let closeReason {
            client.close()
            throw NegotiationError.channelClosedDuringOpen(closeReason)
        }
    }

    private func prepareToOpen(
        _ client: PanesStateChannelClient,
        token: UUID
    ) -> Bool {
        lock.withLock {
            guard !closed, openingToken == token else { return false }
            openingClient = client
            return true
        }
    }

    private static func isSubsystemRejection(_ error: any Error) -> Bool {
        guard let clientError =
            error as? PanesStateChannelClient.ClientError else {
            return false
        }
        switch clientError {
        case .subsystemRejected:
            return true
        case .openFailed(let underlying):
            return isSubsystemRejection(underlying)
        case .channelClosed:
            return false
        case .timedOut:
            return false
        }
    }
}
