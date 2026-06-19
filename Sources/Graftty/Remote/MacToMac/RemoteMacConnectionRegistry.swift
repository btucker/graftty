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
    typealias PaneEnvironmentBuilder = @Sendable (RemoteMacPaneEnvironmentHost?) async -> RemoteMacPaneEnvironment

    enum ConnectionError: Error, Equatable, Sendable {
        case missingBaseURL(RemoteMacIdentity)
        case notConnected(RemoteMacIdentity)
    }

    private var entries: [RemoteMacIdentity: Entry] = [:]
    private var inFlight: [RemoteMacIdentity: Task<Entry, Error>] = [:]
    private let legacyFactory: ConnectionFactory?
    private let identityProvider: IdentityProvider
    private let clientDeviceID: RemoteDeviceID
    private let signalingClient: SignalingClient
    private let connectionFactory: HostConnectionFactory
    private let paneEnvironmentBuilder: PaneEnvironmentBuilder
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
        self.paneEnvironmentBuilder = { remoteHost in
            await RemoteMacPaneEnvironment.build(remoteHost: remoteHost)
        }
        self.now = { Date() }
    }

    init(
        identityProvider: @escaping IdentityProvider,
        clientDeviceID: RemoteDeviceID,
        signalingClient: SignalingClient,
        connectionFactory: @escaping HostConnectionFactory,
        paneEnvironmentBuilder: @escaping PaneEnvironmentBuilder,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.legacyFactory = nil
        self.identityProvider = identityProvider
        self.clientDeviceID = clientDeviceID
        self.signalingClient = signalingClient
        self.connectionFactory = connectionFactory
        self.paneEnvironmentBuilder = paneEnvironmentBuilder
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
            var entry = try await pending.value
            entry.remoteMac = remoteMac
            entries[identity] = entry
            return entry
        }

        let task = Task { @MainActor in
            if let legacyFactory {
                return try await legacyFactory(remoteMac, identity)
            }
            return try await dial(remoteMac: remoteMac, identity: identity)
        }
        inFlight[identity] = task
        do {
            let entry = try await task.value
            entries[identity] = entry
            inFlight[identity] = nil
            return entry
        } catch {
            inFlight[identity] = nil
            throw error
        }
    }

    func disconnect(identity: RemoteMacIdentity) {
        if let entry = entries.removeValue(forKey: identity) {
            Task { await entry.connection.close() }
        }
        inFlight[identity]?.cancel()
        inFlight[identity] = nil
    }

    func disconnectAll() {
        for entry in entries.values {
            Task { await entry.connection.close() }
        }
        entries.removeAll()
        for task in inFlight.values {
            task.cancel()
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

    private func dial(remoteMac: RemoteMac, identity: RemoteMacIdentity) async throws -> Entry {
        guard let baseURL = remoteMac.lastKnownBaseURL else {
            throw ConnectionError.missingBaseURL(identity)
        }

        let clientKey = try identityProvider()
        let connection = connectionFactory(clientKey, identity.fingerprint)
        let offerSDP = try await connection.createOfferSDP()
        let answer = try await signalingClient.exchange(
            baseURL: baseURL,
            offer: SignalingOffer(clientDeviceID: clientDeviceID.value, sdp: offerSDP)
        )
        try await connection.applyAnswerSDP(answer.sdp)
        let paneEnvironment = await paneEnvironmentBuilder(connection)

        return Entry(
            id: UUID(),
            identity: identity,
            remoteMac: remoteMac,
            createdAt: now(),
            connection: connection,
            paneEnvironment: paneEnvironment
        )
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
    func createOfferSDP() async throws -> String
    func applyAnswerSDP(_ sdp: String) async throws
    func openTerminalSession(sessionName: String) async throws -> any WebSocketClient & Sendable
    func close() async
}

private final class LiveRemoteMacHostConnection: RemoteMacHostConnection, @unchecked Sendable {
    private let connection: RemoteHostConnection

    init(connection: RemoteHostConnection) {
        self.connection = connection
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
