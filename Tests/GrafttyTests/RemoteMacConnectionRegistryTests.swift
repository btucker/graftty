import CryptoKit
import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("RemoteMacConnectionRegistry")
@MainActor
struct RemoteMacConnectionRegistryTests {
    @Test("@spec REMOTE-12.21: If a saved Mac's fingerprint differs from its current pin, then the application shall report a host-key mismatch that requires pairing before any WebRTC offer, signaling request, or direct SSH connect.", .timeLimit(.minutes(1)), arguments: [RemoteHostTransport.webRTC, .directSSH])
    func rotatedPinFailsBeforeDialing(transport: RemoteHostTransport) async throws {
        var remote = try makeRemoteMac()
        remote.transport = transport
        remote.directEndpoint = try DirectSSHEndpoint(host: "studio.local", port: 8801)
        remote.fingerprint = try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0x33, count: 32))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x62, count: 32))
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pins = PinnedHostStore(directory: directory)
        let pin = PinnedHost(
            id: remote.id, kind: .mac,
            publicKey: try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation),
            displayName: remote.label, pinnedAt: remote.addedAt,
            pairingURL: try #require(remote.lastKnownBaseURL)
        )
        try pins.add(pin)
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let registry = makeRegistry(
            signalingTransport: { _, _ in
                Issue.record("Mismatched pin must fail before signaling")
                throw URLError(.unsupportedURL)
            },
            pinnedHostProvider: { try? pins.get(id: $0) },
            connectionFactory: { _, _ in connection },
            directConnectionFactory: { _, _ in connection }
        )
        let store = RemoteMacStore(storeURL: directory.appendingPathComponent("remote-macs.json"))
        try store.add(remote)
        let model = RemoteMacsModel(
            store: store, connectionRegistry: registry,
            maintenancePins: pins
        )
        await model.loadSavedRemotes()
        await #expect(throws: PinnedHostKeyError.hostKeyMismatch(expected: remote.fingerprint, offered: pin.fingerprint)) {
            _ = try await model.connect(to: remote)
        }
        #expect(await connection.createOfferCallCount == 0)
        #expect(await connection.directEndpoints.isEmpty)
        #expect(await connection.closeCount == 1)
        #expect(registry.activeConnectionCount == 0)
        #expect(model.connectionState(for: RemoteMacIdentity(remote)) == .needsPairing)
    }

    @Test("@spec REMOTE-12.20: When a saved Mac's pin has a last successful route absent from its saved routes, the application shall include that refreshed route in the next authenticated dial.")
    func dialIncludesPinsLastSuccessfulRoute() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
        let stale = RemoteConnectionRoute(kind: .lan, baseURL: URL(string: "http://stale.local:8800")!)
        let current = RemoteConnectionRoute(kind: .tailscaleDNS, baseURL: URL(string: "http://current.tailnet.ts.net:8800")!)
        let remote = RemoteMac(
            id: RemoteDeviceID(value: "studio-mac"), label: "Studio",
            fingerprint: RemoteIdentityFingerprint(of: publicKey),
            lastKnownBaseURL: stale.baseURL, routes: [stale], lastSuccessfulRoute: stale
        )
        let pin = PinnedHost(
            id: remote.id, kind: .mac, publicKey: publicKey, displayName: remote.label,
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000), pairingURL: stale.baseURL,
            routes: [], lastSuccessfulRoute: current
        )
        let registry = makeRegistry(signalingTransport: { request, body in
            guard request.url?.host == current.baseURL.host else { throw URLError(.cannotConnectToHost) }
            if request.url?.path == "/v2/rtc/challenge" {
                let probe = try JSONDecoder.iso8601().decode(SignalingChallengeRequest.self, from: body)
                return try authenticatedSignalingResponse(url: request.url!, value: SignalingChallengeResponse(
                    hostDeviceID: remote.id, clientDeviceID: probe.clientDeviceID, clientNonce: probe.clientNonce,
                    hostNonce: Data(repeating: 0x72, count: 32),
                    expiresAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 30),
                    routes: [current], signingKey: key
                ))
            }
            let offer = try JSONDecoder.iso8601().decode(AuthenticatedSignalingOffer.self, from: body)
            return try authenticatedSignalingResponse(url: request.url!, value: AuthenticatedSignalingAnswer(
                offer: offer, sdp: "v=0\nanswer\n", routes: [current], signingKey: key
            ))
        }, pinnedHostProvider: { _ in pin })
        _ = try await registry.connect(to: remote)
        #expect(registry.activeConnectionCount == 1)
        await registry.disconnectAndWait(identity: RemoteMacIdentity(remote))
    }

    @Test("missing base URL fails closed")
    func missingBaseURLFailsClosed() async throws {
        let registry = makeRegistry(signalingTransport: { request, _ in
            Issue.record("Signaling should not be called for \(request)")
            throw URLError(.badURL)
        })
        let remote = try makeRemoteMac(baseURL: nil)

        await #expect(throws: RemoteMacConnectionRegistry.ConnectionError.missingBaseURL(RemoteMacIdentity(remote))) {
            _ = try await registry.connect(to: remote)
        }
        #expect(registry.activeConnectionCount == 0)
    }

    @Test("""
    @spec REMOTE-12.5: When the user connects to a saved Remote Mac, the \
    application shall complete the authenticated route race and signed WebRTC \
    offer/answer exchange, apply the answer, and open the remote pane-state and \
    pane-control environment.
    """)
    func successfulConnectPostsOfferAndAppliesAnswer() async throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostPublicKey = try RemoteIdentityPublicKey(
            rawRepresentation: hostKey.publicKey.rawRepresentation
        )
        let route = RemoteConnectionRoute(
            kind: .lan,
            baseURL: URL(string: "http://studio.local:8800")!
        )
        let refreshedRoute = RemoteConnectionRoute(
            kind: .tailscaleDNS,
            baseURL: URL(string: "http://studio.tailnet.ts.net:8800")!
        )
        let remote = RemoteMac(
            id: RemoteDeviceID(value: "studio-mac"),
            label: "Studio Mac",
            fingerprint: RemoteIdentityFingerprint(of: hostPublicKey),
            lastKnownBaseURL: route.baseURL,
            routes: [route]
        )
        let pinned = PinnedHost(
            id: remote.id,
            kind: .mac,
            publicKey: hostPublicKey,
            displayName: remote.label,
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_000),
            pairingURL: route.baseURL.appendingPathComponent("v2/pairing"),
            routes: [route]
        )
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let captured = CapturedSignalingRequest()
        let updatedPin = CapturedPinnedHost()
        let registry = makeRegistry(
            signalingTransport: { request, body in
                captured.record(request: request, body: body)
                switch request.url?.path {
                case "/v2/rtc/challenge":
                    let probe = try JSONDecoder.iso8601().decode(
                        SignalingChallengeRequest.self,
                        from: body
                    )
                    let challenge = try SignalingChallengeResponse(
                        hostDeviceID: remote.id,
                        clientDeviceID: probe.clientDeviceID,
                        clientNonce: probe.clientNonce,
                        hostNonce: Data(repeating: 0x72, count: 32),
                        expiresAt: Date(
                            timeIntervalSince1970:
                                floor(Date().timeIntervalSince1970) + 30
                        ),
                        routes: [route, refreshedRoute],
                        signingKey: hostKey
                    )
                    return try authenticatedSignalingResponse(
                        url: request.url!,
                        value: challenge
                    )
                case "/v2/rtc/offer":
                    let offer = try JSONDecoder.iso8601().decode(
                        AuthenticatedSignalingOffer.self,
                        from: body
                    )
                    let answer = try AuthenticatedSignalingAnswer(
                        offer: offer,
                        sdp: "v=0\nanswer\n",
                        routes: [route, refreshedRoute],
                        signingKey: hostKey
                    )
                    return try authenticatedSignalingResponse(
                        url: request.url!,
                        value: answer
                    )
                default:
                    throw URLError(.unsupportedURL)
                }
            },
            pinnedHostProvider: { _ in pinned },
            pinnedHostUpdater: { updatedPin.record($0) },
            connectionFactory: { _, _ in connection }
        )

        let entry = try await registry.connect(to: remote)

        #expect(entry.identity == RemoteMacIdentity(remote))
        #expect(captured.url == URL(string: "http://studio.local:8800/v2/rtc/offer"))
        let offerBody = try #require(captured.body)
        let offer = try JSONDecoder.iso8601().decode(
            AuthenticatedSignalingOffer.self,
            from: offerBody
        )
        #expect(offer.clientDeviceID == RemoteDeviceID(value: "client-mac"))
        #expect(offer.sdp == "v=0\noffer\n")
        #expect(await connection.appliedAnswers == ["v=0\nanswer\n"])
        #expect(entry.paneEnvironment.worktreePanesStore != nil)
        #expect(entry.paneEnvironment.paneControlClient != nil)
        #expect(updatedPin.value?.routes == [route, refreshedRoute])
        #expect(updatedPin.value?.lastSuccessfulRoute == route)
    }

    @Test("""
    @spec REMOTE-12.6: While connection setup or a live connection already \
    exists for a Remote Mac identity, repeated connect requests shall reuse \
    that one connection rather than dial another transport.
    """)
    func connectReusesInflightAndActiveConnection() async throws {
        let gate = OfferGate()
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n", offerGate: gate)
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection }
        )
        let remote = try makeRemoteMac()

        let first = Task { try await registry.connect(to: remote) }
        await gate.waitUntilOfferStarted()
        let second = Task { try await registry.connect(to: remote) }
        await Task.yield()
        #expect(await connection.createOfferCallCount == 1)

        await gate.releaseOffer()
        let firstEntry = try await first.value
        let secondEntry = try await second.value
        let activeEntry = try await registry.connect(to: remote)

        #expect(firstEntry.id == secondEntry.id)
        #expect(activeEntry.id == firstEntry.id)
        #expect(await connection.createOfferCallCount == 1)
        #expect(registry.activeConnectionCount == 1)
    }

    @Test("""
    @spec REMOTE-22.37: When a caller cancels while sharing another caller's connection attempt, the application shall reject the cancelled caller without cancelling the shared connection.
    """)
    func cancelledSharedWaiterPreservesOwner() async throws {
        let gate = OfferGate()
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n", offerGate: gate)
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection }
        )
        let remote = try makeRemoteMac()
        let owner = Task { try await registry.connect(to: remote) }
        await gate.waitUntilOfferStarted()
        var waiterEntered = false
        let waiter = Task {
            waiterEntered = true
            return try await registry.connect(to: remote)
        }
        while !waiterEntered { await Task.yield() }
        waiter.cancel()
        await gate.releaseOffer()
        let entry = try await owner.value
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(registry.activeConnectionCount == 1)
        #expect(try await registry.connect(to: remote).id == entry.id)
        #expect(await connection.closeCount == 0)
    }

    @Test("explicit reconnect signs replacement intent into its signaling offer")
    func explicitReconnectSignsReplacementIntent() async throws {
        let captured = CapturedSignalingRequest()
        let registry = makeRegistry(
            signalingTransport: { request, body in
                captured.record(request: request, body: body)
                return try signalingResponse(
                    url: request.url!,
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
                )
            }
        )

        _ = try await registry.connect(
            to: makeRemoteMac(),
            replacingExistingHostConnection: true
        )

        let body = try #require(captured.body)
        let offer = try JSONDecoder.iso8601().decode(
            AuthenticatedSignalingOffer.self,
            from: body
        )
        #expect(offer.replacesExistingConnection == true)
    }

    @Test("a replacement request upgrades an ordinary in-flight connection attempt")
    func replacementUpgradesOrdinaryInflightAttempt() async throws {
        let gate = OfferGate()
        let firstConnection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\nordinary\n",
            offerGate: gate
        )
        let replacementConnection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\nreplacement\n"
        )
        let connections = RemoteMacConnectionSequence([
            firstConnection,
            replacementConnection,
        ])
        let captured = CapturedSignalingRequest()
        let registry = makeRegistry(
            signalingTransport: { request, body in
                captured.record(request: request, body: body)
                return try signalingResponse(
                    url: request.url!,
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connections.next() }
        )
        let remote = try makeRemoteMac()

        let ordinary = Task { try await registry.connect(to: remote) }
        await gate.waitUntilOfferStarted()
        let replacement = Task {
            try await registry.connect(
                to: remote,
                replacingExistingHostConnection: true
            )
        }
        await gate.releaseOffer()

        await #expect(throws: CancellationError.self) {
            _ = try await ordinary.value
        }
        _ = try await replacement.value
        let body = try #require(captured.body)
        let offer = try JSONDecoder.iso8601().decode(
            AuthenticatedSignalingOffer.self,
            from: body
        )
        #expect(offer.sdp.hasPrefix("v=0\nreplacement\n"))
        #expect(offer.hasSignedReplacementIntentMarker)
        #expect(offer.replacesExistingConnection == true)
        #expect(await firstConnection.closeCount == 1)
        #expect(await replacementConnection.createOfferCallCount == 1)
    }

    @Test("entry opens terminal sessions on demand")
    func entryOpensTerminalSessionsOnDemand() async throws {
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection }
        )
        let entry = try await registry.connect(to: try makeRemoteMac())

        _ = try await registry.openTerminalSession(identity: entry.identity, sessionName: "main")

        #expect(await connection.openedTerminalSessions == ["main"])
    }

    @Test("empty pane environment fails connection and closes transport")
    func emptyPaneEnvironmentFailsConnectionAndClosesTransport() async throws {
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let remote = try makeRemoteMac()
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection },
            paneEnvironmentBuilder: { _, _, _ in .empty }
        )

        await #expect(throws: RemoteMacConnectionRegistry.ConnectionError.paneEnvironmentUnavailable(RemoteMacIdentity(remote))) {
            _ = try await registry.connect(to: remote)
        }

        #expect(await connection.closeCount == 1)
        #expect(registry.activeConnectionCount == 0)
    }

    @Test("signaling failure closes the allocated transport")
    func signalingFailureClosesAllocatedTransport() async throws {
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let registry = makeRegistry(
            signalingTransport: { _, _ in
                throw URLError(.cannotConnectToHost)
            },
            connectionFactory: { _, _ in connection }
        )

        await #expect(throws: (any Error).self) {
            _ = try await registry.connect(to: makeRemoteMac())
        }

        #expect(await connection.closeCount == 1)
        #expect(registry.activeConnectionCount == 0)
    }

    @Test("disconnect rejects and closes a cancellation-insensitive late success")
    func disconnectRejectsLateSuccess() async throws {
        let gate = OfferGate()
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noffer\n",
            offerGate: gate
        )
        let remote = try makeRemoteMac()
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection }
        )

        let connectTask = Task { try await registry.connect(to: remote) }
        await gate.waitUntilOfferStarted()
        registry.disconnect(identity: RemoteMacIdentity(remote))
        await gate.releaseOffer()

        await #expect(throws: CancellationError.self) {
            _ = try await connectTask.value
        }
        #expect(await connection.closeCount == 1)
        #expect(registry.activeConnectionCount == 0)
    }

    @Test("terminal connection state evicts only the matching live entry")
    func terminalStateEvictsLiveEntry() async throws {
        let connection = FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection }
        )
        let remote = try makeRemoteMac()
        _ = try await registry.connect(to: remote)
        #expect(registry.activeConnectionCount == 1)

        await connection.transition(to: .failed(reason: "ICE failed"))
        for _ in 0..<20 where registry.activeConnectionCount != 0 {
            await Task.yield()
        }

        #expect(registry.activeConnectionCount == 0)
        await #expect(throws: RemoteMacConnectionRegistry.ConnectionError.notConnected(RemoteMacIdentity(remote))) {
            _ = try await registry.openTerminalSession(
                identity: RemoteMacIdentity(remote),
                sessionName: "main"
            )
        }
    }

    @Test("@spec REMOTE-6.19: If a connected Mac's panes-state feed fails, then the application shall report the feed as unhealthy while retaining the host connection and its terminal, pane-control, and team channels.", .timeLimit(.minutes(1)))
    func panesStateRecoveryPreservesLiveEntryAndFencesOldCallbacks() async throws {
        let snapshots = RemoteMacSnapshotEmitter()
        let closes = RemoteMacPaneCloseEmitter()
        // Retain the registry-facing callbacks too. Replaying these bypasses
        // the shared store's fence and exercises the registry's generation.
        let ownerSnapshots = RemoteMacSnapshotEmitter()
        let ownerCloses = RemoteMacPaneCloseEmitter()
        let recorder = RemoteMacSnapshotRecorder()
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noffer\n", snapshotEmitter: snapshots, paneCloseEmitter: closes)
        let stateRecorder = RemoteMacConnectionStateRecorder()
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection },
            paneEnvironmentBuilder: { host, onSnapshot, onClosed in
                ownerSnapshots.install(onSnapshot)
                ownerCloses.install(onClosed)
                return await RemoteMacPaneEnvironment.build(
                    remoteHost: host, onSnapshot: onSnapshot, onClosed: onClosed)
            },
            onPaneSnapshot: { identity, rows in recorder.record(identity: identity, snapshot: rows) }
        )
        registry.onConnectionStateChange = { identity, state in
            stateRecorder.record(identity: identity, state: state)
        }
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        defer { registry.disconnect(identity: identity) }
        let original = try await registry.connect(to: remote)
        let originalStore = try #require(original.paneEnvironment.worktreePanesStore)
        let control = try #require(original.paneEnvironment.paneControlClient)
        let terminal = try #require(
            try await registry.openTerminalSession(identity: identity, sessionName: "retained") as? FakeWebSocketClient)
        try await terminal.send(.text("before-recovery"))
        #expect(try await terminal.receive() == .text("before-recovery"))
        let oldRows = [makeWorktreeSnapshot(path: "/removed")]
        await snapshots.emit(oldRows)
        await recorder.waitForCount(1)

        let failures = RemoteMacTestEvents<String>()
        var feedFailures: [String] = []
        registry.onPaneFeedFailure = { failedIdentity, reason in
            #expect(failedIdentity == identity)
            feedFailures.append(reason)
            failures.send(reason)
        }
        await closes.emit("relay-ended")
        #expect(await failures.next() == "panes-state channel closed")
        #expect(registry.activeConnectionCount == 1)
        #expect(stateRecorder.states.isEmpty)
        #expect(await connection.closeCount == 0)
        #expect(try await registry.sendPaneControl(identity: identity, request: .equalize(target: "retained")) == .ok)

        let recovery = Task { try await registry.renewPaneFeed(identity: identity) }
        await snapshots.waitUntilInstalled(2)
        await closes.waitUntilInstalled(2)
        let freshRows = [makeWorktreeSnapshot(path: "/added")]
        await snapshots.emit(freshRows)
        try await recovery.value
        let recovered = try await registry.connect(to: remote)
        let recoveredStore = try #require(recovered.paneEnvironment.worktreePanesStore)
        #expect(recovered.id == original.id)
        #expect((recovered.connection as? FakeRemoteMacHostConnection) === connection)
        #expect(recoveredStore !== originalStore)
        #expect(recovered.paneEnvironment.paneControlClient === control)
        #expect(await registry.panesSnapshot(for: identity) == .snapshot(freshRows))
        #expect(await originalStore.connectionState == .closed(reason: "panes-state channel closed"))
        #expect(await connection.createOfferCallCount == 1)
        #expect(await connection.closeCount == 0)
        #expect(await connection.openedTerminalSessions == ["retained"])
        #expect(!terminal.isClosed)
        try await terminal.send(.text("after-recovery"))
        #expect(try await terminal.receive() == .text("after-recovery"))
        #expect(try await registry.sendPaneControl(identity: identity, request: .equalize(target: "retained")) == .ok)

        let staleRows = [makeWorktreeSnapshot(path: "/late-old")]
        await ownerSnapshots.emit(staleRows)
        await ownerCloses.emit("late-old-close")
        #expect(recorder.snapshots.last == freshRows)
        #expect(!recorder.snapshots.contains(staleRows))
        #expect(feedFailures == ["panes-state channel closed"])
        #expect(await registry.panesSnapshot(for: identity) == .snapshot(freshRows))
        #expect(registry.activeConnectionCount == 1)
        #expect(stateRecorder.states.isEmpty)
        await registry.disconnectAndWait(identity: identity)
        #expect(await connection.closeCount == 1)
        #expect(terminal.isClosed)
    }

    @Test("@spec REMOTE-12.22: When a cached Mac connection's pane feed is replaced while its transport state is being read, the registry shall use the current pane environment when returning the connection or tearing it down.", .timeLimit(.minutes(1)), arguments: [false, true])
    func cachedConnectionStateReadPreservesRecoveredEnvironment(terminal: Bool) async throws {
        let snapshots = RemoteMacSnapshotEmitter()
        let closes = RemoteMacPaneCloseEmitter()
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noriginal\n", snapshotEmitter: snapshots, paneCloseEmitter: closes)
        let replacement = FakeRemoteMacHostConnection(offerSDP: "v=0\nreplacement\n")
        let sequence = RemoteMacConnectionSequence([connection, replacement])
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in sequence.next() }
        )
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        defer { registry.disconnect(identity: identity) }
        let original = try await registry.connect(to: remote)
        let failures = RemoteMacTestEvents<String>()
        registry.onPaneFeedFailure = { _, reason in failures.send(reason) }
        await closes.emit("original-ended")
        #expect(await failures.next() == "panes-state channel closed")

        let stateRead = RemoteMacStateReadGate()
        defer { stateRead.release() }
        await connection.blockNextStateRead(on: stateRead)
        let cachedConnect = Task { try await registry.connect(to: remote) }
        await stateRead.waitUntilStarted()

        // The cached connect holds a copy of the old entry across its actor
        // hop. Install a new store before allowing that read to finish.
        let recovery = Task { try await registry.renewPaneFeed(identity: identity) }
        await snapshots.waitUntilInstalled(2)
        await closes.waitUntilInstalled(2)
        let freshRows = [makeWorktreeSnapshot(path: "/recovered")]
        await snapshots.emit(freshRows)
        try await recovery.value
        let recovered = try await registry.connect(to: remote)
        let recoveredStore = try #require(recovered.paneEnvironment.worktreePanesStore)
        #expect(recoveredStore !== original.paneEnvironment.worktreePanesStore)
        #expect(await registry.panesSnapshot(for: identity) == .snapshot(freshRows))

        if terminal { await connection.setStateWithoutNotification(.closed) }
        stateRead.release()
        let returned = try await cachedConnect.value
        if terminal {
            #expect(returned.id != original.id)
            #expect(await recoveredStore.connectionState == .closed(reason: "unsubscribed"))
        } else {
            #expect(returned.id == original.id)
            #expect(returned.paneEnvironment.worktreePanesStore === recoveredStore)
            let current = try await registry.connect(to: remote)
            #expect(current.paneEnvironment.worktreePanesStore === recoveredStore)
            #expect(await registry.panesSnapshot(for: identity) == .snapshot(freshRows))
            #expect(await recoveredStore.connectionState == .subscribed)
        }
    }

    @Test("disconnect before a recovering pane feed's first snapshot closes its pending channel and rejects late frames", .timeLimit(.minutes(1)))
    func disconnectDuringPaneFeedRecoveryCannotRestoreEntry() async throws {
        let snapshots = RemoteMacSnapshotEmitter()
        let closes = RemoteMacPaneCloseEmitter()
        let recorder = RemoteMacSnapshotRecorder()
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noffer\n", snapshotEmitter: snapshots, paneCloseEmitter: closes)
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(url: request.url!, answer: TestSignalingAnswer(sdp: "v=0\nanswer\n"))
            },
            connectionFactory: { _, _ in connection },
            onPaneSnapshot: { identity, rows in recorder.record(identity: identity, snapshot: rows) }
        )
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        defer { registry.disconnect(identity: identity) }
        _ = try await registry.connect(to: remote)
        let originalRows = [makeWorktreeSnapshot(path: "/original")]
        await snapshots.emit(originalRows)
        await recorder.waitForCount(1)
        let failures = RemoteMacTestEvents<String>()
        registry.onPaneFeedFailure = { _, reason in failures.send(reason) }
        await closes.emit("original-ended")
        #expect(await failures.next() == "panes-state channel closed")

        let recovery = Task { try await registry.renewPaneFeed(identity: identity) }
        await snapshots.waitUntilInstalled(2)
        await closes.waitUntilInstalled(2)
        let pendingDriver = try #require(await connection.panesDrivers.last)
        await pendingDriver.waitUntilOpened()
        // The replacement has opened but has never received its first frame.
        // Disconnect must clean it up whether it has reached the pending-store
        // map or is still returning from the shared subscription's open.
        await registry.disconnectAndWait(identity: identity)
        await #expect(throws: (any Error).self) { try await recovery.value }
        await pendingDriver.waitUntilClosed()
        #expect(pendingDriver.closeCount == 1)
        #expect(registry.activeConnectionCount == 0)
        #expect(await connection.closeCount == 1)
        await snapshots.emit([makeWorktreeSnapshot(path: "/late-pending")])
        await closes.emit("late-pending-close")
        #expect(recorder.snapshots == [originalRows])
        #expect(registry.activeConnectionCount == 0)
        #expect(await registry.panesSnapshot(for: identity) == nil)
        #expect(await connection.createOfferCallCount == 1)
    }

    @Test("panes-state closure during setup cannot activate an entry")
    func panesStateClosureDuringSetupFailsConnection() async throws {
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noffer\n",
            closePanesDuringOpenReason: "closed-during-open"
        )
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection }
        )
        let remote = try makeRemoteMac()

        await #expect(throws: (any Error).self) {
            _ = try await registry.connect(to: remote)
        }

        #expect(registry.activeConnectionCount == 0)
        #expect(await connection.closeCount == 1)
    }

    @Test("""
    @spec REMOTE-12.12: If a cached Remote Mac connection is already in a \
    terminal state when connect is requested, the registry shall evict and \
    close it before dialing a fresh transport.
    """)
    func cachedTerminalConnectionIsRedialed() async throws {
        let first = FakeRemoteMacHostConnection(offerSDP: "v=0\nfirst\n")
        let second = FakeRemoteMacHostConnection(offerSDP: "v=0\nsecond\n")
        let sequence = RemoteMacConnectionSequence([first, second])
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in sequence.next() }
        )
        let remote = try makeRemoteMac()

        let firstEntry = try await registry.connect(to: remote)
        await first.setStateWithoutNotification(.closed)
        let secondEntry = try await registry.connect(to: remote)

        #expect(secondEntry.id != firstEntry.id)
        #expect(await first.closeCount == 1)
        #expect(await second.createOfferCallCount == 1)
    }

    @Test("""
    @spec REMOTE-12.13: When an obsolete Remote Mac pane subscription emits \
    after disconnect or replacement, the registry shall discard that snapshot \
    instead of overwriting the current sidebar projection.
    """)
    func stalePaneSnapshotAfterDisconnectIsDiscarded() async throws {
        let emitter = RemoteMacSnapshotEmitter()
        let recorder = RemoteMacSnapshotRecorder()
        let connection = FakeRemoteMacHostConnection(
            offerSDP: "v=0\noffer\n",
            snapshotEmitter: emitter
        )
        let registry = makeRegistry(
            signalingTransport: { request, _ in
                try signalingResponse(
                    url: request.url!,
                    answer: TestSignalingAnswer(sdp: "v=0\nanswer\n")
                )
            },
            connectionFactory: { _, _ in connection },
            onPaneSnapshot: { identity, snapshot in
                recorder.record(identity: identity, snapshot: snapshot)
            }
        )
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        _ = try await registry.connect(to: remote)
        let liveSnapshot = [makeWorktreeSnapshot(path: "/live")]
        await emitter.emit(liveSnapshot)
        await recorder.waitForCount(1)

        registry.disconnect(identity: identity)
        await emitter.emit([makeWorktreeSnapshot(path: "/stale")])

        #expect(recorder.snapshots == [liveSnapshot])
    }

    @Test("@spec REMOTE-20.8: If direct SSH is selected without an explicit endpoint, then the application shall reject the connection before dialing a transport.")
    func directConnectionRequiresEndpoint() async throws {
        var remote = try makeRemoteMac(baseURL: nil)
        remote.transport = .directSSH
        let registry = makeRegistry(signalingTransport: { _, _ in throw URLError(.unsupportedURL) })
        await #expect(throws: RemoteMacConnectionRegistry.ConnectionError.missingDirectEndpoint(RemoteMacIdentity(remote))) {
            _ = try await registry.connect(to: remote)
        }
    }

    @Test("@spec REMOTE-20.9: When a saved direct SSH host connects or reconnects, the application shall dial its explicit endpoint and build the pane environment without a WebRTC signaling exchange.")
    func directConnectionBypassesSignalingAndReconnects() async throws {
        var remote = try makeRemoteMac(baseURL: nil)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x62, count: 32))
        remote.fingerprint = RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation))
        remote.transport = .directSSH
        remote.directEndpoint = try DirectSSHEndpoint(host: "linux.example", port: 8801)
        let connection = FakeRemoteMacHostConnection(offerSDP: "unused")
        let registry = makeRegistry(
            signalingTransport: { _, _ in Issue.record("Direct SSH used signaling"); throw URLError(.unsupportedURL) },
            connectionFactory: { _, _ in Issue.record("Direct SSH allocated WebRTC"); return connection },
            directConnectionFactory: { _, _ in connection }
        )
        let first = try await registry.connect(to: remote)
        #expect(await connection.directEndpoints == [remote.directEndpoint!])
        #expect(await connection.createOfferCallCount == 0)
        #expect(registry.activeConnectionCount == 1)
        await registry.disconnectAndWait(identity: RemoteMacIdentity(remote))
        let second = try await registry.connect(to: remote, replacingExistingHostConnection: true)
        #expect(first.id != second.id)
        #expect(await connection.directEndpoints.count == 2)
        await registry.disconnectAndWait(identity: RemoteMacIdentity(remote))
    }

    private func makeRegistry(
        signalingTransport: @escaping SignalingClient.Transport,
        pinnedHostProvider: RemoteMacConnectionRegistry.PinnedHostProvider? = nil,
        pinnedHostUpdater: RemoteMacConnectionRegistry.PinnedHostUpdater? = nil,
        connectionFactory: @escaping RemoteMacConnectionRegistry.HostConnectionFactory = { _, _ in
            FakeRemoteMacHostConnection(offerSDP: "v=0\noffer\n")
        },
        directConnectionFactory: @escaping RemoteMacConnectionRegistry.DirectHostConnectionFactory = { _, _ in
            FakeRemoteMacHostConnection(offerSDP: "unused")
        },
        paneEnvironmentBuilder: @escaping RemoteMacConnectionRegistry.PaneEnvironmentBuilder = { remoteHost, onSnapshot, onClosed in
            await RemoteMacPaneEnvironment.build(
                remoteHost: remoteHost,
                onSnapshot: onSnapshot,
                onClosed: onClosed
            )
        },
        onPaneSnapshot: @escaping RemoteMacConnectionRegistry.PaneSnapshotHandler = { _, _ in }
    ) -> RemoteMacConnectionRegistry {
        let defaultHostKey = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(repeating: 0x62, count: 32)
        )
        let defaultHostPublicKey = try! RemoteIdentityPublicKey(
            rawRepresentation: defaultHostKey.publicKey.rawRepresentation
        )
        let defaultRoute = RemoteConnectionRoute(
            kind: .lan,
            baseURL: URL(string: "http://studio.local:9443")!
        )
        let effectivePinnedHostProvider = pinnedHostProvider ?? { id in
            PinnedHost(
                id: id,
                kind: .mac,
                publicKey: defaultHostPublicKey,
                displayName: "Studio Mac",
                pinnedAt: Date(timeIntervalSince1970: 1_700_000_000),
                pairingURL: defaultRoute.baseURL.appendingPathComponent("v2/pairing"),
                routes: [defaultRoute]
            )
        }
        let effectiveTransport: SignalingClient.Transport
        if pinnedHostProvider != nil {
            effectiveTransport = signalingTransport
        } else {
            effectiveTransport = { request, body in
                switch request.url?.path {
                case "/v2/rtc/challenge":
                    let probe = try JSONDecoder.iso8601().decode(
                        SignalingChallengeRequest.self,
                        from: body
                    )
                    let challenge = try SignalingChallengeResponse(
                        hostDeviceID: RemoteDeviceID(value: "studio-mac"),
                        clientDeviceID: probe.clientDeviceID,
                        clientNonce: probe.clientNonce,
                        hostNonce: Data(repeating: 0x63, count: 32),
                        expiresAt: Date(
                            timeIntervalSince1970:
                                floor(Date().timeIntervalSince1970) + 30
                        ),
                        routes: [defaultRoute],
                        signingKey: defaultHostKey
                    )
                    return try authenticatedSignalingResponse(
                        url: request.url!,
                        value: challenge
                    )
                case "/v2/rtc/offer":
                    let legacyResponse = try await signalingTransport(request, body)
                    let legacyAnswer = try JSONDecoder().decode(
                        TestSignalingAnswer.self,
                        from: legacyResponse.0
                    )
                    let offer = try JSONDecoder.iso8601().decode(
                        AuthenticatedSignalingOffer.self,
                        from: body
                    )
                    let answer = try AuthenticatedSignalingAnswer(
                        offer: offer,
                        sdp: legacyAnswer.sdp,
                        routes: [defaultRoute],
                        signingKey: defaultHostKey
                    )
                    return try authenticatedSignalingResponse(
                        url: request.url!,
                        value: answer
                    )
                default:
                    throw URLError(.unsupportedURL)
                }
            }
        }
        return RemoteMacConnectionRegistry(
            identityProvider: {
                try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x41, count: 32))
            },
            clientDeviceID: RemoteDeviceID(value: "client-mac"),
            pinnedHostProvider: effectivePinnedHostProvider,
            pinnedHostUpdater: pinnedHostUpdater,
            signalingClient: SignalingClient(transport: effectiveTransport),
            connectionFactory: connectionFactory,
            directConnectionFactory: directConnectionFactory,
            paneEnvironmentBuilder: paneEnvironmentBuilder,
            onPaneSnapshot: onPaneSnapshot
        )
    }
}

private func makeWorktreeSnapshot(path: String) -> WorktreePanes {
    WorktreePanes(
        path: path,
        displayName: URL(fileURLWithPath: path).lastPathComponent,
        repoDisplayName: "repo",
        displayBranch: "main",
        state: .running,
        isMainCheckout: true,
        prBadge: nil,
        stats: nil,
        attentionText: nil,
        layout: nil
    )
}

private struct TestSignalingAnswer: Codable {
    let sdp: String
}

private func signalingResponse(url: URL, answer: TestSignalingAnswer) throws -> (Data, HTTPURLResponse) {
    (
        try JSONEncoder().encode(answer),
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    )
}

private func authenticatedSignalingResponse<Value: Encodable>(
    url: URL,
    value: Value
) throws -> (Data, HTTPURLResponse) {
    (
        try JSONEncoder.iso8601().encode(value),
        HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
    )
}

private func makeRemoteMac(
    id: RemoteDeviceID = RemoteDeviceID(value: "studio-mac"),
    label: String = "Studio Mac",
    baseURL: URL? = URL(string: "http://studio.local:9443"),
    addedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> RemoteMac {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x62, count: 32))
    let publicKey = try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
    return RemoteMac(
        id: id,
        label: label,
        fingerprint: RemoteIdentityFingerprint(of: publicKey),
        lastKnownBaseURL: baseURL,
        addedAt: addedAt
    )
}

private final class CapturedSignalingRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: (url: URL?, body: Data?) = (nil, nil)

    var url: URL? { lock.withLock { storage.url } }
    var body: Data? { lock.withLock { storage.body } }

    func record(request: URLRequest, body: Data) {
        lock.withLock {
            storage = (request.url, body)
        }
    }
}

private final class CapturedPinnedHost: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: PinnedHost?

    var value: PinnedHost? {
        lock.withLock { storage }
    }

    func record(_ host: PinnedHost) {
        lock.withLock {
            storage = host
        }
    }
}

private actor OfferGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        if released { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilOfferStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseOffer() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class RemoteMacConnectionSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [FakeRemoteMacHostConnection]

    init(_ connections: [FakeRemoteMacHostConnection]) {
        self.connections = connections
    }

    func next() -> FakeRemoteMacHostConnection {
        lock.withLock { connections.removeFirst() }
    }
}

private final class RemoteMacTestEvents<Value: Sendable>: Sendable {
    private let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init() { (stream, continuation) = AsyncStream<Value>.makeStream() }
    deinit { continuation.finish() }
    func send(_ value: Value) { continuation.yield(value) }
    func next() async -> Value? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}

private final class RemoteMacStateReadGate: Sendable {
    private let started = RemoteMacTestEvents<Void>()
    private let released = RemoteMacTestEvents<Void>()

    func wait() async {
        started.send(())
        _ = await released.next()
    }

    func waitUntilStarted() async { _ = await started.next() }
    func release() { released.send(()) }
}

private final class RemoteMacSnapshotEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var onSnapshot: (@Sendable ([WorktreePanes]) async -> Void)?
    private var installationCount = 0
    private let installations = RemoteMacTestEvents<Int>()

    func install(_ onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void) {
        let count = lock.withLock {
            self.onSnapshot = onSnapshot
            installationCount += 1
            return installationCount
        }
        installations.send(count)
    }

    func waitUntilInstalled(_ count: Int) async {
        while let installed = await installations.next() {
            if installed >= count { return }
        }
    }

    func emit(_ snapshot: [WorktreePanes]) async {
        await lock.withLock { onSnapshot }?(snapshot)
    }
}

private final class RemoteMacSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[WorktreePanes]] = []
    private let changes = RemoteMacTestEvents<Int>()

    var snapshots: [[WorktreePanes]] {
        lock.withLock { storage }
    }

    func record(identity _: RemoteMacIdentity, snapshot: [WorktreePanes]) {
        let count = lock.withLock { storage.append(snapshot); return storage.count }
        changes.send(count)
    }

    func waitForCount(_ count: Int) async {
        while let recorded = await changes.next() {
            if recorded >= count { return }
        }
    }
}

private final class RemoteMacPaneCloseEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private var onClosed: (@Sendable (String) async -> Void)?
    private var installationCount = 0
    private let installations = RemoteMacTestEvents<Int>()

    func install(_ onClosed: @escaping @Sendable (String) async -> Void) {
        let count = lock.withLock {
            self.onClosed = onClosed
            installationCount += 1
            return installationCount
        }
        installations.send(count)
    }

    func waitUntilInstalled(_ count: Int) async {
        while let installed = await installations.next() {
            if installed >= count { return }
        }
    }

    func emit(_ reason: String) async {
        await lock.withLock { onClosed }?(reason)
    }
}

private final class RemoteMacConnectionStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage:
        [(RemoteMacIdentity, RemoteHostConnection.State)] = []

    var states: [(RemoteMacIdentity, RemoteHostConnection.State)] {
        lock.withLock { storage }
    }

    func record(
        identity: RemoteMacIdentity,
        state: RemoteHostConnection.State
    ) {
        lock.withLock { storage.append((identity, state)) }
    }
}

private actor FakeRemoteMacHostConnection: RemoteHostLinkFake, DirectHostLink {
    private let offerSDP: String
    private let offerGate: OfferGate?
    private let snapshotEmitter: RemoteMacSnapshotEmitter?
    private let paneCloseEmitter: RemoteMacPaneCloseEmitter?
    private let closePanesDuringOpenReason: String?
    private var createOfferCalls = 0
    private(set) var directEndpoints: [DirectSSHEndpoint] = []
    private var appliedAnswerStorage: [String] = []
    private var openedTerminalSessionStorage: [String] = []
    private var terminalClients: [FakeWebSocketClient] = []
    private(set) var panesDrivers: [FakePanesStateDriver] = []
    private var closeCallCount = 0
    private var currentState: RemoteHostConnection.State = .connected
    private var stateHandler: (@Sendable (RemoteHostConnection.State) -> Void)?
    private var nextStateReadGate: RemoteMacStateReadGate?

    init(
        offerSDP: String,
        offerGate: OfferGate? = nil,
        snapshotEmitter: RemoteMacSnapshotEmitter? = nil,
        paneCloseEmitter: RemoteMacPaneCloseEmitter? = nil,
        closePanesDuringOpenReason: String? = nil
    ) {
        self.offerSDP = offerSDP
        self.offerGate = offerGate
        self.snapshotEmitter = snapshotEmitter
        self.paneCloseEmitter = paneCloseEmitter
        self.closePanesDuringOpenReason = closePanesDuringOpenReason
    }

    var createOfferCallCount: Int { createOfferCalls }
    var appliedAnswers: [String] { appliedAnswerStorage }
    var openedTerminalSessions: [String] { openedTerminalSessionStorage }
    var closeCount: Int { closeCallCount }

    func setOnStateChange(
        _ handler: (@Sendable (RemoteHostConnection.State) -> Void)?
    ) {
        stateHandler = handler
    }

    var state: RemoteHostConnection.State {
        get async {
            let gate = nextStateReadGate
            nextStateReadGate = nil
            await gate?.wait()
            return currentState
        }
    }

    func blockNextStateRead(on gate: RemoteMacStateReadGate) {
        nextStateReadGate = gate
    }

    func transition(to newState: RemoteHostConnection.State) {
        currentState = newState
        stateHandler?(newState)
    }

    func setStateWithoutNotification(_ newState: RemoteHostConnection.State) {
        currentState = newState
    }

    func connect(host: String, port: Int) throws {
        directEndpoints.append(try DirectSSHEndpoint(host: host, port: port))
        currentState = .connected
    }

    func createOfferSDP() async throws -> String {
        createOfferCalls += 1
        await offerGate?.markStartedAndWaitForRelease()
        return offerSDP
    }

    func applyAnswerSDP(_ sdp: String) async throws {
        appliedAnswerStorage.append(sdp)
    }

    func makePanesStateDriver(originAware _: Bool) -> any PanesStateSubscriptionDriver {
        let driver = FakePanesStateDriver(
            snapshotEmitter: snapshotEmitter,
            paneCloseEmitter: paneCloseEmitter,
            closeDuringOpenReason: closePanesDuringOpenReason
        )
        panesDrivers.append(driver)
        return driver
    }

    func makePaneControlDriver() async throws -> any PaneControlChannelDriver {
        FakePaneControlDriver()
    }

    func openTerminalClient(sessionName: String, preferPaged _: Bool) -> any WebSocketClient & Sendable {
        openedTerminalSessionStorage.append(sessionName)
        let client = FakeWebSocketClient()
        terminalClients.append(client)
        return client
    }

    func close() async {
        terminalClients.forEach { $0.close() }
        closeCallCount += 1
        currentState = .closed
        stateHandler?(.closed)
    }
}

private final class FakePanesStateDriver: PanesStateSubscriptionDriver, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshotEmitter: RemoteMacSnapshotEmitter?
    private let paneCloseEmitter: RemoteMacPaneCloseEmitter?
    private let closeDuringOpenReason: String?
    private var onClosed: PanesStateChannelClient.OnClosed = { _ in }
    private var closes = 0
    private let opened = RemoteMacTestEvents<Void>()
    private let closed = RemoteMacTestEvents<Void>()
    var closeCount: Int { lock.withLock { closes } }
    func waitUntilOpened() async { _ = await opened.next() }
    func waitUntilClosed() async { _ = await closed.next() }

    init(
        snapshotEmitter: RemoteMacSnapshotEmitter?,
        paneCloseEmitter: RemoteMacPaneCloseEmitter?,
        closeDuringOpenReason: String?
    ) {
        self.snapshotEmitter = snapshotEmitter
        self.paneCloseEmitter = paneCloseEmitter
        self.closeDuringOpenReason = closeDuringOpenReason
    }

    func setCallbacks(
        onSnapshot: @escaping PanesStateChannelClient.OnSnapshot,
        onClosed: @escaping PanesStateChannelClient.OnClosed
    ) {
        snapshotEmitter?.install(onSnapshot)
        paneCloseEmitter?.install(onClosed)
        lock.withLock { self.onClosed = onClosed }
    }

    func open() async throws {
        opened.send(())
        if let closeDuringOpenReason {
            await lock.withLock { onClosed }(closeDuringOpenReason)
        }
    }

    func close() {
        lock.withLock { closes += 1 }
        closed.send(())
    }
}

private final class FakePaneControlDriver: PaneControlChannelDriver, @unchecked Sendable {
    func open() async throws {}
    func close() {}
    func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        .ok
    }
}

private final class FakeWebSocketClient: WebSocketClient, @unchecked Sendable {
    private enum Failure: Error { case closed }
    private let lock = NSLock()
    private var frames: [WebSocketFrame] = []
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }

    func send(_ frame: WebSocketFrame) async throws {
        try lock.withLock {
            guard !closed else { throw Failure.closed }
            frames.append(frame)
        }
    }
    func receive() async throws -> WebSocketFrame {
        try lock.withLock {
            guard !closed else { throw Failure.closed }
            return frames.isEmpty ? .binary(Data()) : frames.removeFirst()
        }
    }
    func close() { lock.withLock { closed = true } }
}
