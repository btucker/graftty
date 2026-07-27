import CryptoKit
import Foundation
import GrafttyRemoteClient
import Testing
@testable import Graftty
@testable import GrafttyKit
import GrafttyProtocol

@Suite("RemoteMacsModel")
@MainActor
struct RemoteMacsModelTests {
    private func tempStoreURL() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("remote-macs.json")
    }

    private func fingerprint(_ byte: UInt8) throws -> RemoteIdentityFingerprint {
        try RemoteIdentityFingerprint(rawBytes: Data(repeating: byte, count: 32))
    }

    private func publicKey() throws -> RemoteIdentityPublicKey {
        try RemoteIdentityPublicKey(
            rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
    }

    private func remoteMac(
        id: RemoteDeviceID = RemoteDeviceID(value: "studio-mac"),
        label: String = "Studio Mac",
        fingerprintByte: UInt8 = 0x22,
        baseURL: URL? = URL(string: "http://old.local:9000"),
        addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> RemoteMac {
        RemoteMac(
            id: id,
            label: label,
            fingerprint: try fingerprint(fingerprintByte),
            lastKnownBaseURL: baseURL,
            addedAt: addedAt
        )
    }

    private func candidate(
        id: RemoteDeviceID = RemoteDeviceID(value: "studio-mac"),
        label: String = "Studio MacBook",
        fingerprintByte: UInt8 = 0x22,
        baseURL: URL = URL(string: "http://studio.local:9443")!,
        discoveredAt: Date = Date(timeIntervalSince1970: 1_720_000_000)
    ) throws -> GrafttyBonjourCandidate {
        GrafttyBonjourCandidate(
            deviceID: id,
            label: label,
            fingerprint: try fingerprint(fingerprintByte),
            baseURL: baseURL,
            protocolVersion: GrafttyBonjourService.discoveryVersion,
            pairingStatus: .required,
            discoveredAt: discoveredAt
        )
    }

    private func makeModel(store: RemoteMacStore) -> RemoteMacsModel {
        RemoteMacsModel(store: store)
    }

    @Test("saved remotes load from RemoteMacStore")
    func savedRemotesLoadFromStore() async throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let remote = try remoteMac()
        try store.add(remote)
        let model = makeModel(store: store)

        await model.loadSavedRemotes()

        #expect(model.savedRemoteMacs == [remote])
        #expect(model.connectionState(for: RemoteMacIdentity(remote)) == .offline)
    }

    @Test("discovery candidate for a saved remote marks it discovered and refreshes address")
    func discoveryCandidateRefreshesSavedRemote() async throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let existing = try remoteMac(label: "Old Name")
        try store.add(existing)
        let model = makeModel(store: store)
        await model.loadSavedRemotes()

        let discovered = try candidate()
        try model.publishDiscoveryCandidate(discovered)

        let identity = RemoteMacIdentity(discovered)
        #expect(model.connectionState(for: identity) == .discovered)
        let saved = try #require(model.savedRemoteMacs.first)
        #expect(saved.label == "Studio MacBook")
        #expect(saved.lastKnownBaseURL == URL(string: "http://studio.local:9443"))
        #expect(saved.lastDiscoveredAt == discovered.discoveredAt)
        #expect(saved.addedAt == existing.addedAt)
    }

    @Test("discovered candidates do not become saved rows until explicitly paired")
    func candidatesStayTransientUntilSaved() async throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let model = makeModel(store: store)
        await model.loadSavedRemotes()

        let discovered = try candidate()
        try model.publishDiscoveryCandidate(discovered)

        #expect(model.savedRemoteMacs.isEmpty)
        #expect(model.discoveryCandidates == [discovered])
        #expect(try store.get(id: discovered.deviceID, fingerprint: discovered.fingerprint) == nil)
    }

    @Test("discovery browser starts and stops only by explicit model action")
    func discoveryBrowserStartsAndStopsExplicitly() async throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let model = makeModel(store: store)
        let browser = FakeDiscoveryBrowser()

        model.setDiscoveryBrowser(browser)
        #expect(browser.startCount == 0)
        #expect(browser.stopCount == 0)

        model.startDiscovery()
        model.stopDiscovery()

        #expect(browser.startCount == 1)
        #expect(browser.stopCount == 1)
    }

    @Test("""
    @spec REMOTE-12.11: While multiple Add Remote Mac sheets use discovery, \
    the application shall keep the shared browser active until the final \
    sheet releases its discovery lease.
    """)
    func discoveryLeasesAreReferenceCounted() throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let model = makeModel(store: store)
        let browser = FakeDiscoveryBrowser()
        model.setDiscoveryBrowser(browser)

        model.startDiscovery()
        model.startDiscovery()
        model.stopDiscovery()

        #expect(browser.startCount == 1)
        #expect(browser.stopCount == 0)

        model.stopDiscovery()
        #expect(browser.stopCount == 1)
    }

    @Test("ending discovery clears transient candidates")
    func endingDiscoveryClearsTransientCandidates() async throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let model = makeModel(store: store)
        let browser = FakeDiscoveryBrowser()
        model.setDiscoveryBrowser(browser)
        model.startDiscovery()
        try model.publishDiscoveryCandidate(candidate())
        #expect(model.discoveryCandidates.count == 1)

        model.stopDiscovery()

        #expect(model.discoveryCandidates.isEmpty)
    }

    @Test("initial load reconciles a candidate that arrived while disk loading was suspended")
    func initialLoadReconcilesAlreadyDiscoveredCandidate() async throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let existing = try remoteMac(label: "Old Name")
        try store.add(existing)
        let model = makeModel(store: store)
        let discovered = try candidate()

        try model.publishDiscoveryCandidate(discovered)
        await model.loadSavedRemotes()

        let identity = RemoteMacIdentity(discovered)
        #expect(model.connectionState(for: identity) == .discovered)
        #expect(model.savedRemoteMacs.first?.label == discovered.label)
        #expect(model.savedRemoteMacs.first?.lastKnownBaseURL == discovered.baseURL)
    }

    @Test("connection registry reuses one entry per remote identity")
    func registryReusesEntryPerIdentity() async throws {
        let registry = RemoteMacConnectionRegistry(factory: { remoteMac, identity in
            RemoteMacConnectionRegistry.Entry(
                id: UUID(),
                identity: identity,
                remoteMac: remoteMac,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                connection: RemoteMacsModelTestConnection(),
                paneEnvironment: .empty
            )
        })
        let first = try remoteMac(
            id: RemoteDeviceID(value: "same-device"),
            fingerprintByte: 0x11
        )
        let sameIdentity = try remoteMac(
            id: RemoteDeviceID(value: "same-device"),
            label: "Renamed",
            fingerprintByte: 0x11
        )
        let rotatedKey = try remoteMac(
            id: RemoteDeviceID(value: "same-device"),
            fingerprintByte: 0x22
        )

        let firstEntry = try await registry.connect(to: first)
        let reusedEntry = try await registry.connect(to: sameIdentity)
        let secondEntry = try await registry.connect(to: rotatedKey)

        #expect(firstEntry.id == reusedEntry.id)
        #expect(firstEntry.identity == RemoteMacIdentity(first))
        #expect(secondEntry.id != firstEntry.id)
        #expect(secondEntry.identity == RemoteMacIdentity(rotatedKey))
        #expect(registry.activeConnectionCount == 2)
    }

    @Test("""
    @spec REMOTE-12.8: If the user disconnects a Remote Mac while connection \
    setup is suspended, the late setup result shall not overwrite the explicit \
    offline state.
    """)
    func disconnectWinsOverSuspendedConnectResult() async throws {
        let gate = RemoteMacsModelConnectGate()
        let registry = RemoteMacConnectionRegistry(factory: { remoteMac, identity in
            await gate.wait()
            return RemoteMacConnectionRegistry.Entry(
                id: UUID(),
                identity: identity,
                remoteMac: remoteMac,
                createdAt: Date(),
                connection: RemoteMacsModelTestConnection(),
                paneEnvironment: .empty
            )
        })
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let remote = try remoteMac()
        let identity = RemoteMacIdentity(remote)
        let model = RemoteMacsModel(store: store, connectionRegistry: registry)

        let connect = Task { try await model.connect(to: remote) }
        await gate.waitUntilStarted()
        model.disconnect(identity: identity)
        await gate.release()
        _ = try? await connect.value

        #expect(model.connectionState(for: identity) == .offline)
    }

    @Test("live panes snapshots from registry update sidebar projection")
    func livePaneSnapshotsUpdateSidebarProjection() async throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let registry = RemoteMacConnectionRegistry(factory: { remoteMac, identity in
            RemoteMacConnectionRegistry.Entry(
                id: UUID(),
                identity: identity,
                remoteMac: remoteMac,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                connection: RemoteMacsModelTestConnection(),
                paneEnvironment: .empty
            )
        })
        let remote = try remoteMac()
        let model = RemoteMacsModel(store: store, connectionRegistry: registry)
        let snapshot = [
            WorktreePanes(
                path: "/Users/me/project",
                displayName: "project",
                repoDisplayName: "project",
                displayBranch: "main",
                state: .running,
                isMainCheckout: true,
                prBadge: nil,
                stats: nil,
                attentionText: nil,
                layout: nil
            ),
        ]

        registry.onPaneSnapshot(RemoteMacIdentity(remote), snapshot)

        #expect(model.worktreePanesByRemote[RemoteMacIdentity(remote)] == snapshot)
    }

    @Test("""
    @spec REMOTE-12.4: When Mac-to-Mac pairing succeeds, the application \
    shall persist a saved Remote Mac using the pinned host identity, \
    fingerprint, display name, and signaling base URL.
    """)
    func pairingSuccessSavesPinnedHost() async throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let model = makeModel(store: store)
        await model.loadSavedRemotes()
        let key = try publicKey()
        let pinned = PinnedHost(
            id: RemoteDeviceID(value: "paired-host"),
            kind: .mac,
            publicKey: key,
            displayName: "Paired Studio",
            pinnedAt: Date(timeIntervalSince1970: 1_710_000_000),
            lastConnectedAt: nil,
            pairingURL: URL(string: "http://paired.local:9443/v1/pairing")!
        )

        try model.recordPairingResult(.paired(pinned))

        let identity = RemoteMacIdentity(
            id: pinned.id,
            fingerprint: RemoteIdentityFingerprint(of: key)
        )
        let saved = try #require(model.savedRemoteMacs.first)
        #expect(saved.id == pinned.id)
        #expect(saved.label == "Paired Studio")
        #expect(saved.fingerprint == identity.fingerprint)
        #expect(saved.lastKnownBaseURL == URL(string: "http://paired.local:9443"))
        #expect(try store.get(id: pinned.id, fingerprint: identity.fingerprint) != nil)
    }

    @Test("pairing denial or failure does not save")
    func pairingDenialOrFailureDoesNotSave() async throws {
        let store = RemoteMacStore(storeURL: try tempStoreURL())
        let model = makeModel(store: store)
        await model.loadSavedRemotes()

        try model.recordPairingResult(.denied)
        try model.recordPairingResult(.failed("host rejected pairing"))

        #expect(model.savedRemoteMacs.isEmpty)
        #expect(store.remoteMacs.isEmpty)
    }

    @Test("LAN route handler uses host pairing coordinator and maps host busy")
    func lanRouteHandlerWiresPairingAndHostBusy() async throws {
        let fixture = try HostPairingCoordinatorTestFixture.make()
        defer { fixture.cleanup() }
        let routeHandler = RemoteMacAccessServices.makeLANRouteHandler(
            lanBaseURLProvider: { URL(string: "http://studio.local:9443")! },
            hostPairingCoordinator: fixture.coordinator,
            acceptSignalingOffer: { _ in
                .hostBusy("host is already handling an offer")
            }
        )

        let beginResponse = await routeHandler.handle(
            method: .POST,
            path: "/v1/pairing/begin",
            body: Data()
        )
        #expect(beginResponse.status == 200)
        let payload = try JSONDecoder.iso8601().decode(PairingPayload.self, from: beginResponse.body)
        guard case .awaitingClient(let activePayload, _) = await fixture.server.currentState() else {
            Issue.record("Expected begin route to call HostPairingCoordinator")
            return
        }
        #expect(activePayload.nonce == payload.nonce)

        let offerBody = try JSONEncoder.iso8601().encode(
            SignalingOffer(clientDeviceID: "client", sdp: "v=0\n")
        )
        let offerResponse = await routeHandler.handle(
            method: .POST,
            path: "/v1/rtc/offer",
            body: offerBody
        )

        #expect(offerResponse.status == 503)
        let error = try JSONDecoder.iso8601().decode(PairingErrorResponse.self, from: offerResponse.body)
        #expect(error.code == .hostBusy)
    }
}

private final class FakeDiscoveryBrowser: RemoteMacDiscoveryBrowsing {
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }
}

private actor RemoteMacsModelConnectGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private struct RemoteMacsModelTestConnection: RemoteMacHostConnection {
    func createOfferSDP() async throws -> String {
        "v=0\n"
    }

    func applyAnswerSDP(_ sdp: String) async throws {}

    func makePanesStateDriver(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void
    ) async throws -> any PanesStateChannelDriver {
        RemoteMacsModelTestPanesStateDriver()
    }

    func makePaneControlDriver() async throws -> any PaneControlChannelDriver {
        RemoteMacsModelTestPaneControlDriver()
    }

    func openTerminalSession(sessionName: String) async throws -> any WebSocketClient & Sendable {
        RemoteMacsModelTestWebSocketClient()
    }

    func close() async {}
}

private struct RemoteMacsModelTestPanesStateDriver: PanesStateChannelDriver {
    func open() async throws {}
    func close() {}
}

private struct RemoteMacsModelTestPaneControlDriver: PaneControlChannelDriver {
    func open() async throws {}
    func close() {}

    func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        .ok
    }
}

private final class RemoteMacsModelTestWebSocketClient: WebSocketClient, @unchecked Sendable {
    func send(_ frame: WebSocketFrame) async throws {}
    func receive() async throws -> WebSocketFrame { .binary(Data()) }
    func close() {}
}

private struct HostPairingCoordinatorTestFixture {
    let dir: URL
    let server: HostPairingServer
    let coordinator: RemoteMacHostPairingCoordinator

    @MainActor
    static func make() throws -> HostPairingCoordinatorTestFixture {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let identityStore = HostIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let peerStore = TrustedPeerStore(directory: dir)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            hostDeviceID: RemoteDeviceID(value: "host-mac"),
            hostKind: .mac,
            hostDisplayName: "Host Mac",
            pairingURLProvider: { URL(string: "http://studio.local:9443/v1/pairing")! }
        )
        let server = HostPairingServer(session: session)
        return HostPairingCoordinatorTestFixture(
            dir: dir,
            server: server,
            coordinator: RemoteMacHostPairingCoordinator(server: server)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: dir)
    }
}
