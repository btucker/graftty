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
        let task: Task<Entry, Error>
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

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id
                && lhs.identity == rhs.identity
                && lhs.remoteMac == rhs.remoteMac
                && lhs.createdAt == rhs.createdAt
        }
    }

    typealias ConnectionFactory = @MainActor @Sendable (RemoteMac, RemoteMacIdentity) async throws -> Entry
    typealias IdentityProvider = @MainActor @Sendable () throws -> Curve25519.Signing.PrivateKey
    typealias HostConnectionFactory = @MainActor @Sendable (
        Curve25519.Signing.PrivateKey,
        RemoteIdentityFingerprint
    ) -> any RemoteMacHostConnection
    typealias PaneEnvironmentBuilder = @Sendable (
        RemoteMacPaneEnvironmentHost?,
        @escaping @Sendable ([WorktreePanes]) async -> Void
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
    }

    private var entries: [RemoteMacIdentity: Entry] = [:]
    private var inFlight: [RemoteMacIdentity: InFlightAttempt] = [:]
    private let legacyFactory: ConnectionFactory?
    private let identityProvider: IdentityProvider
    private let clientDeviceID: RemoteDeviceID
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
        self.legacyFactory = factory
        self.identityProvider = {
            try identityStore.loadOrGenerateAndPersist()
        }
        self.clientDeviceID = Self.defaultClientDeviceID()
        self.signalingClient = SignalingClient()
        self.connectionFactory = { clientKey, expectedHostFingerprint in
            LiveRemoteMacHostConnection(
                connection: RemoteHostConnection(
                    clientKey: clientKey,
                    expectedHostFingerprint: expectedHostFingerprint
                )
            )
        }
        self.paneEnvironmentBuilder = { remoteHost, onSnapshot in
            await RemoteMacPaneEnvironment.build(remoteHost: remoteHost, onSnapshot: onSnapshot)
        }
        self.onPaneSnapshot = { _, _ in }
        self.onConnectionStateChange = { _, _ in }
        self.now = { Date() }
    }

    init(
        identityProvider: @escaping IdentityProvider,
        clientDeviceID: RemoteDeviceID,
        signalingClient: SignalingClient,
        connectionFactory: @escaping HostConnectionFactory,
        paneEnvironmentBuilder: @escaping PaneEnvironmentBuilder,
        onPaneSnapshot: @escaping PaneSnapshotHandler = { _, _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.legacyFactory = nil
        self.identityProvider = identityProvider
        self.clientDeviceID = clientDeviceID
        self.signalingClient = signalingClient
        self.connectionFactory = connectionFactory
        self.paneEnvironmentBuilder = paneEnvironmentBuilder
        self.onPaneSnapshot = onPaneSnapshot
        self.onConnectionStateChange = { _, _ in }
        self.now = now
    }

    func connect(to remoteMac: RemoteMac) async throws -> Entry {
        let identity = RemoteMacIdentity(remoteMac)
        if var existing = entries[identity] {
            existing.remoteMac = remoteMac
            entries[identity] = existing
            return existing
        }

        if let pending = inFlight[identity] {
            let completed = try await pending.task.value
            guard var current = entries[identity], current.id == completed.id else {
                throw CancellationError()
            }
            current.remoteMac = remoteMac
            entries[identity] = current
            return current
        }

        let attemptID = UUID()
        let task = Task { @MainActor in
            let entry: Entry
            if let legacyFactory {
                entry = try await legacyFactory(remoteMac, identity)
            } else {
                entry = try await dial(
                    remoteMac: remoteMac,
                    identity: identity,
                    attemptID: attemptID
                )
            }
            try ensureCurrentAttempt(attemptID, identity: identity)
            entries[identity] = entry

            let state = await entry.connection.currentState()
            guard !state.isTerminal else {
                if entries[identity]?.id == entry.id {
                    entries[identity] = nil
                }
                await close(entry)
                throw ConnectionError.connectionTerminated(identity)
            }
            return entry
        }
        inFlight[identity] = InFlightAttempt(id: attemptID, task: task)
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
        if let entry = entries.removeValue(forKey: identity) {
            Task { await close(entry) }
        }
        if let attempt = inFlight.removeValue(forKey: identity) {
            attempt.task.cancel()
        }
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

    private func dial(
        remoteMac: RemoteMac,
        identity: RemoteMacIdentity,
        attemptID: UUID
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
            let offerSDP = try await connection.createOfferSDP()
            try ensureCurrentAttempt(attemptID, identity: identity)
            let answer = try await signalingClient.exchange(
                baseURL: baseURL,
                offer: SignalingOffer(clientDeviceID: clientDeviceID.value, sdp: offerSDP)
            )
            try ensureCurrentAttempt(attemptID, identity: identity)
            try await connection.applyAnswerSDP(answer.sdp)
            try ensureCurrentAttempt(attemptID, identity: identity)
            let environment = await paneEnvironmentBuilder(connection) { [onPaneSnapshot] snapshot in
                await onPaneSnapshot(identity, snapshot)
            }
            paneEnvironment = environment
            try ensureCurrentAttempt(attemptID, identity: identity)
            guard !environment.isEmpty else {
                throw ConnectionError.paneEnvironmentUnavailable(identity)
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

    private func close(_ entry: Entry) async {
        await entry.connection.setOnStateChange(nil)
        await entry.paneEnvironment.close()
        await entry.connection.close()
    }

    private static func defaultClientDeviceID() -> RemoteDeviceID {
        let key = "remoteMac.localDeviceID"
        if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
            return RemoteDeviceID(value: value)
        }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return RemoteDeviceID(value: value)
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
    func close() async
}

extension RemoteMacHostConnection {
    func setOnStateChange(
        _ handler: (@Sendable (RemoteHostConnection.State) -> Void)?
    ) async {}

    func currentState() async -> RemoteHostConnection.State {
        .connected
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
        try await connection.makePanesStateClient(
            onSnapshot: onSnapshot,
            onClosed: onClosed
        )
    }

    func makePaneControlDriver() async throws -> any PaneControlChannelDriver {
        try await connection.makePaneControlClient()
    }

    func openTerminalSession(sessionName: String) async throws -> any WebSocketClient & Sendable {
        try await connection.openTerminalSession(sessionName: sessionName)
    }

    func close() async {
        await connection.close()
    }
}
