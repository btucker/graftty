#if canImport(UIKit)
import CryptoKit
import Foundation
import GrafttyProtocol
import Testing
import WebRTC
@testable import GrafttyMobileKit

/// Tests for `RemoteConnectionCoordinator` — negotiate-on-demand, in-flight
/// dedup, registry, and eviction. Stubs `SignalingClient.Transport` (no
/// real network) and the `connectionFactory` test seam (to count/capture
/// constructed connections), but the negotiation body itself still drives
/// a REAL `RemoteHostConnection` through `createOffer()`/`applyAnswer()`
/// against an in-process WebRTC-only `TestAnswerer` (copied from
/// `RemoteHostConnectionLoopbackTests.swift` per that suite's
/// copy-don't-extract precedent) — there's no protocol seam for the SDK
/// layer itself.
@MainActor
@Suite("RemoteConnectionCoordinator — negotiate-on-demand, dedup, registry, eviction (W3 Task 2).", .serialized)
struct RemoteConnectionCoordinatorTests {

    // MARK: - Fast-nil for unpaired hosts

    @Test(.timeLimit(.minutes(1)))
    func hostWithNoRemoteDeviceIDReturnsNilWithoutNegotiating() async throws {
        let dir = try Self.makeTempDirectory()
        let counter = CallCounter()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { _, _ in Issue.record("transport should not be called"); throw Self.unreachable }),
            connectionFactory: { key, fp in counter.increment(); return RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp) }
        )
        let host = Host(label: "Unpaired", baseURL: URL(string: "https://host.local:9999")!, remoteDeviceID: nil)

        let result = await coordinator.connection(for: host)

        #expect(result == nil)
        #expect(counter.count == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func hostWithRemoteDeviceIDButNoPinnedEntryReturnsNilWithoutNegotiating() async throws {
        let dir = try Self.makeTempDirectory()
        let counter = CallCounter()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { _, _ in Issue.record("transport should not be called"); throw Self.unreachable }),
            connectionFactory: { key, fp in counter.increment(); return RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp) }
        )
        // remoteDeviceID set, but never added to PinnedHostStore.
        let host = Host(
            label: "Never paired",
            baseURL: URL(string: "https://host.local:9999")!,
            remoteDeviceID: .generate()
        )

        let result = await coordinator.connection(for: host)

        #expect(result == nil)
        #expect(counter.count == 0)
    }

    // MARK: - In-flight dedup

    @Test(.timeLimit(.minutes(1)))
    func concurrentCallsForSameHostDedupToOneNegotiation() async throws {
        let dir = try Self.makeTempDirectory()
        let host = try Self.makePairedHost(directory: dir)
        let counter = CallCounter()
        let gate = Gate()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { request, _ in
                await gate.wait()
                return Self.httpResponse(for: request, statusCode: 503, body: "host is busy")
            }),
            connectionFactory: { key, fp in counter.increment(); return RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp) }
        )

        async let first = coordinator.connection(for: host)
        async let second = coordinator.connection(for: host)

        // Wait until the first negotiation has actually reached (and
        // parked at) the gate before releasing it — proves the second
        // call is deduped onto the SAME in-flight Task rather than just
        // happening to arrive after the first already finished. 10s
        // (not 5s) because `createOffer()`'s real ICE-gathering wait can
        // ride its own 5s internal timeout on the simulator before the
        // negotiation ever reaches this transport.
        try await Self.pollUntil(timeout: .seconds(10)) { await gate.enteredCount >= 1 }
        await gate.open()

        let r1 = await first
        let r2 = await second
        #expect(r1 == nil)
        #expect(r2 == nil)
        #expect(counter.count == 1, "expected exactly one negotiation, factory was called \(counter.count) times")
    }

    // MARK: - Busy (503) is retryable, not permanently cached

    @Test(.timeLimit(.minutes(1)))
    func busyResponseReturnsNilAndRetriesOnNextCall() async throws {
        let dir = try Self.makeTempDirectory()
        let host = try Self.makePairedHost(directory: dir)
        let counter = CallCounter()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { request, _ in
                Self.httpResponse(for: request, statusCode: 503, body: "host is busy")
            }),
            connectionFactory: { key, fp in counter.increment(); return RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp) }
        )

        let first = await coordinator.connection(for: host)
        #expect(first == nil)
        #expect(counter.count == 1)

        let second = await coordinator.connection(for: host)
        #expect(second == nil)
        #expect(counter.count == 2, "a 503 must not be cached as a permanent failure — the second call should retry")
    }

    // MARK: - Eviction on terminal state change

    @Test(.timeLimit(.minutes(2)))
    func terminalStateChangeEvictsFromRegistry() async throws {
        let dir = try Self.makeTempDirectory()
        let host = try Self.makePairedHost(directory: dir)
        let counter = CallCounter()
        let box = ConnectionBox()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: Self.successTransport(box: box)),
            connectionFactory: { key, fp in
                counter.increment()
                let connection = RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp)
                box.set(connection)
                return connection
            }
        )

        let negotiated = await coordinator.connection(for: host)
        let live = try #require(negotiated)
        #expect(counter.count == 1)

        // Fire a terminal transition on the live connection directly —
        // this is the same `.failed`/`.closed` path Task 1 wired
        // `onStateChange` to observe, which the coordinator registered
        // BEFORE `createOffer()`.
        await live.close()

        // Eviction happens asynchronously (the observer hops back onto
        // the coordinator's actor via a `Task`); poll for the effect
        // rather than asserting immediately.
        try await Self.pollUntil(timeout: .seconds(5)) {
            let again = await coordinator.connection(for: host)
            return again !== live
        }
        #expect(counter.count == 2, "eviction should allow a fresh negotiation on the next call")
    }

    // MARK: - invalidate(host:) closes and evicts

    @Test(.timeLimit(.minutes(2)))
    func invalidateClosesAndEvictsTheLiveConnection() async throws {
        let dir = try Self.makeTempDirectory()
        let host = try Self.makePairedHost(directory: dir)
        let counter = CallCounter()
        let box = ConnectionBox()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: Self.successTransport(box: box)),
            connectionFactory: { key, fp in
                counter.increment()
                let connection = RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp)
                box.set(connection)
                return connection
            }
        )

        let negotiated = await coordinator.connection(for: host)
        let live = try #require(negotiated)
        #expect(counter.count == 1)

        await coordinator.invalidate(host: host)

        #expect(await live.state == .closed)
        let again = await coordinator.connection(for: host)
        #expect(again !== live, "invalidate must evict so the next call negotiates fresh")
        #expect(counter.count == 2)
    }

    // MARK: - isPaired(_:) — same source of truth as connection(for:)'s gate (Task-3 finding 3)

    @Test(.timeLimit(.minutes(1)))
    func isPairedFalseForHostWithNoRemoteDeviceID() async throws {
        let dir = try Self.makeTempDirectory()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { _, _ in throw Self.unreachable })
        )
        let host = Host(label: "Unpaired", baseURL: URL(string: "https://host.local:9999")!, remoteDeviceID: nil)

        #expect(!coordinator.isPaired(host))
    }

    @Test(.timeLimit(.minutes(1)))
    func isPairedFalseForRemoteDeviceIDWithNoPinnedEntry() async throws {
        let dir = try Self.makeTempDirectory()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { _, _ in throw Self.unreachable })
        )
        // remoteDeviceID set, but never added to PinnedHostStore — the
        // same combination `hostWithRemoteDeviceIDButNoPinnedEntryReturnsNilWithoutNegotiating`
        // exercises against `connection(for:)`.
        let host = Host(
            label: "Never paired",
            baseURL: URL(string: "https://host.local:9999")!,
            remoteDeviceID: .generate()
        )

        #expect(!coordinator.isPaired(host))
    }

    @Test(.timeLimit(.minutes(1)))
    func isPairedTrueForHostWithMatchingPinnedEntry() async throws {
        let dir = try Self.makeTempDirectory()
        let host = try Self.makePairedHost(directory: dir)
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { _, _ in throw Self.unreachable })
        )

        #expect(coordinator.isPaired(host))
    }

    // MARK: - invalidate(host:) mid-negotiation (Task 4: scenePhase-flapping interleaving)

    /// Reproduces background→foreground→background flapping fast enough
    /// that `invalidate(host:)` lands WHILE a negotiation for the same
    /// host is still in flight: the negotiation is parked at `gate` (its
    /// `signaling.exchange` call), `invalidate` fires before the gate is
    /// released, and the chosen "let it finish, then evict" behavior
    /// means the negotiation's own result — even though it's a
    /// successful one — must never be registered as a live connection.
    @Test(.timeLimit(.minutes(2)))
    func invalidateDuringInFlightNegotiationEvictsOnCompletionRatherThanRegistering() async throws {
        let dir = try Self.makeTempDirectory()
        let host = try Self.makePairedHost(directory: dir)
        let counter = CallCounter()
        let box = ConnectionBox()
        let gate = Gate()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { request, body in
                await gate.wait()
                return try await Self.successTransport(box: box)(request, body)
            }),
            connectionFactory: { key, fp in
                counter.increment()
                let connection = RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp)
                box.set(connection)
                return connection
            }
        )

        async let negotiated = coordinator.connection(for: host)

        // Wait until the negotiation has actually reached (and parked
        // at) the gate before invalidating — proves `invalidate` lands
        // WHILE the negotiation is genuinely in flight, not after it
        // already completed.
        try await Self.pollUntil(timeout: .seconds(10)) { await gate.enteredCount >= 1 }
        await coordinator.invalidate(host: host)
        await gate.open()

        let result = await negotiated
        #expect(result == nil, "a connection invalidated mid-negotiation must never be handed back to the caller")
        #expect(counter.count == 1, "exactly one negotiation attempt — invalidate must not have started a second one")

        // No zombie registration: the (successfully negotiated, then
        // evicted) connection must be closed and absent from the
        // registry.
        let firstConnection = try #require(box.get(), "the negotiation reached the connectionFactory before invalidate fired")
        #expect(await firstConnection.state == .closed)

        // The NEXT call must negotiate fresh (not silently return the
        // evicted connection, and not be permanently poisoned by the
        // mid-flight invalidation) — proving `invalidatedWhileInFlight`
        // is a one-shot flag cleared once the in-flight negotiation it
        // applied to resolves.
        let again = await coordinator.connection(for: host)
        #expect(counter.count == 2, "a fresh call after invalidate-mid-flight must negotiate again, not reuse the evicted connection")
        let secondConnection = try #require(again, "a fresh negotiation with no further invalidation should succeed normally")
        #expect(secondConnection !== firstConnection)
    }

    // MARK: - Stale eviction guard

    @Test(.timeLimit(.minutes(1)))
    func staleTerminalNotificationDoesNotEvictANewerConnection() async throws {
        let dir = try Self.makeTempDirectory()
        let host = try Self.makePairedHost(directory: dir)
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { _, _ in throw Self.unreachable })
        )
        let staleKey = Curve25519.Signing.PrivateKey()
        let staleFingerprint = RemoteIdentityFingerprint(
            of: try RemoteIdentityPublicKey(rawRepresentation: staleKey.publicKey.rawRepresentation)
        )
        let stale = RemoteHostConnection(clientKey: staleKey, expectedHostFingerprint: staleFingerprint)
        let newer = RemoteHostConnection(clientKey: staleKey, expectedHostFingerprint: staleFingerprint)

        // Seed the registry with `newer` the same way a real negotiation
        // would (there's no public setter — `evict` reads/writes the
        // same private `liveConnections` dictionary the negotiation path
        // populates, so registering `newer` first via a private-storage
        // round-trip isn't available from a `@testable import` test
        // without a real negotiation). Directly exercise the guard
        // instead: evicting with `stale`'s identity while `newer` is
        // registered must be a no-op.
        await coordinator.registerLiveConnectionForTesting(newer, hostID: host.id)
        await coordinator.evict(hostID: host.id, connectionIdentity: ObjectIdentifier(stale))

        let result = await coordinator.connection(for: host)
        #expect(result === newer, "a stale connection's terminal notification must not evict a newer, live connection")
    }

    // MARK: - Helpers

    private nonisolated static let unreachable = NSError(domain: "RemoteConnectionCoordinatorTests", code: -1)

    private static func makeTempDirectory() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pairs `host` with a freshly generated pinned host record in
    /// `directory`'s `PinnedHostStore`, mirroring what a real pairing
    /// flow (`PairDeviceFlowView.buildModel`) would have persisted.
    private static func makePairedHost(directory: URL) throws -> Host {
        let hostKey = Curve25519.Signing.PrivateKey()
        let hostPublicKey = try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)
        let remoteDeviceID = RemoteDeviceID.generate()
        let pinnedStore = PinnedHostStore(directory: directory)
        try pinnedStore.add(PinnedHost(
            id: remoteDeviceID,
            kind: .mac,
            publicKey: hostPublicKey,
            displayName: "Test host",
            pinnedAt: Date(),
            pairingURL: URL(string: "https://host.local:9999")!
        ))
        return Host(
            label: "Test host",
            baseURL: URL(string: "https://host.local:9999")!,
            remoteDeviceID: remoteDeviceID
        )
    }

    private nonisolated static func httpResponse(for request: URLRequest, statusCode: Int, body: String) -> (Data, HTTPURLResponse) {
        let data = Data("{\"error\":\"\(body)\"}".utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (data, response)
    }

    /// A `SignalingClient.Transport` that answers every offer with a real
    /// in-process `TestAnswerer`, routing ICE candidates both ways via
    /// `box`'s captured connection so the handshake reliably completes —
    /// test-only plumbing (production has no ICE-candidate signaling
    /// round-trip; both sides embed their full candidate set in the
    /// initial SDP via non-trickle gathering, same as `WebRTCHostAgent
    /// .acceptOffer`). `TestAnswerer` is retained for the connection's
    /// lifetime via the closure's own capture.
    private nonisolated static func successTransport(box: ConnectionBox) -> SignalingClient.Transport {
        { request, body in
            let offer = try JSONDecoder().decode(SignalingOffer.self, from: body)
            let answerer = TestAnswerer()
            let rtcOffer = RTCSessionDescription(type: .offer, sdp: offer.sdp)
            let rtcAnswer = try await answerer.accept(offer: rtcOffer)
            if let connection = box.get() {
                await connection.bindIceCandidates(to: answerer)
                await answerer.bindIceCandidates(to: connection)
            }
            box.retain(answerer)
            let answer = SignalingAnswer(sdp: rtcAnswer.sdp)
            let data = try JSONEncoder().encode(answer)
            return Self.httpResponseSuccess(for: request, data: data)
        }
    }

    private nonisolated static func httpResponseSuccess(for request: URLRequest, data: Data) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }

    private static func pollUntil(
        timeout: Duration,
        interval: Duration = .milliseconds(50),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: interval)
        }
        throw PollTimeout(timeout: timeout)
    }

    private struct PollTimeout: Error, CustomStringConvertible {
        let timeout: Duration
        var description: String { "pollUntil timed out after \(timeout)" }
    }
}

/// Thread-safe call counter for asserting how many times a stubbed
/// `connectionFactory` was invoked.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func increment() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}

/// Holds the most recently factory-created `RemoteHostConnection` (so the
/// fake transport can route ICE candidates to/from it) plus every
/// `TestAnswerer` created during the test (so they aren't deallocated —
/// and their `RTCPeerConnection`s torn down — before the handshake
/// completes). Test-only plumbing; production has no equivalent.
private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RemoteHostConnection?
    private var retained: [TestAnswerer] = []

    func set(_ connection: RemoteHostConnection) {
        lock.lock(); current = connection; lock.unlock()
    }

    func get() -> RemoteHostConnection? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func retain(_ answerer: TestAnswerer) {
        lock.lock(); retained.append(answerer); lock.unlock()
    }
}

/// Continuation-based gate: `wait()` parks until `open()` is called (or
/// returns immediately if already open). Used to hold a negotiation
/// in-flight long enough for a concurrent caller to observe it and dedup,
/// rather than racing on wall-clock timing.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    func wait() async {
        enteredCount += 1
        if opened { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

/// Test-only WebRTC answerer — verbatim copy of `TestAnswerer` from
/// `RemoteHostConnectionLoopbackTests.swift` (that suite's own doc
/// comment establishes copy-don't-extract as the precedent for this
/// helper). Speaks raw WebRTC only, no SSH — sufficient here because
/// `RemoteHostConnection.applyAnswer` only waits for the LOCAL
/// DataChannel to open and the local SSH handler to install, not for the
/// remote peer to complete a real SSH handshake.
private actor TestAnswerer: WebRTCIceCandidateReceiver {
    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private nonisolated let delegate = AnswererDelegate()
    private nonisolated let dataChannelDelegate = AnswererDataChannelDelegate()
    private var pendingLocalCandidates: [RTCIceCandidate] = []
    private var iceCandidateTarget: RemoteHostConnection?
    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var gatheringTimeoutTask: Task<Void, Never>?
    private static let gatheringTimeout: Duration = .seconds(5)

    init() {
        self.factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil)
        delegate.onIceCandidate = { [weak self] candidate in
            Task { await self?.routeLocalIceCandidate(candidate) }
        }
        delegate.onDataChannel = { [weak self] dc in
            guard let self else { return }
            dc.delegate = self.dataChannelDelegate
            Task { await self.captureDataChannel(dc) }
        }
    }

    private func captureDataChannel(_ dc: RTCDataChannel) {
        self.dataChannel = dc
    }

    private func routeLocalIceCandidate(_ candidate: RTCIceCandidate) async {
        if let target = iceCandidateTarget {
            try? await target.addRemoteIceCandidate(candidate)
        } else {
            pendingLocalCandidates.append(candidate)
        }
    }

    func accept(offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        let config = RemoteHostConnection.defaultConfig()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: delegate) else {
            throw NSError(domain: "TestAnswerer", code: 1)
        }
        self.peerConnection = pc

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let answer = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.answer(for: constraints) { sdp, error in
                if let error { continuation.resume(throwing: error); return }
                guard let sdp else { continuation.resume(throwing: NSError(domain: "TestAnswerer", code: 2)); return }
                continuation.resume(returning: sdp)
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        await waitForIceGatheringComplete(pc)
        return pc.localDescription ?? answer
    }

    private func waitForIceGatheringComplete(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.gatheringContinuation = continuation
            delegate.onIceGatheringComplete = { [weak self] in
                Task { await self?.handleIceGatheringComplete() }
            }
            if pc.iceGatheringState == .complete {
                handleIceGatheringComplete()
                return
            }
            self.gatheringTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.gatheringTimeout)
                await self?.handleIceGatheringComplete()
            }
        }
    }

    private func handleIceGatheringComplete() {
        let pending = gatheringContinuation
        gatheringContinuation = nil
        delegate.onIceGatheringComplete = nil
        gatheringTimeoutTask?.cancel()
        gatheringTimeoutTask = nil
        pending?.resume()
    }

    func bindIceCandidates(to client: RemoteHostConnection) {
        self.iceCandidateTarget = client
        let drained = pendingLocalCandidates
        pendingLocalCandidates.removeAll()
        Task {
            for candidate in drained {
                try? await client.addRemoteIceCandidate(candidate)
            }
        }
    }

    func addRemoteIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let pc = peerConnection else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close() {
        if let pending = gatheringContinuation {
            gatheringContinuation = nil
            delegate.onIceGatheringComplete = nil
            gatheringTimeoutTask?.cancel()
            gatheringTimeoutTask = nil
            pending.resume()
        }
        dataChannel?.close()
        peerConnection?.close()
        iceCandidateTarget = nil
        pendingLocalCandidates.removeAll()
    }
}

private final class AnswererDelegate: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    nonisolated(unsafe) var onDataChannel: (@Sendable (RTCDataChannel) -> Void)?
    nonisolated(unsafe) var onIceGatheringComplete: (@Sendable () -> Void)?
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            onIceGatheringComplete?()
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onIceCandidate?(candidate)
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        onDataChannel?(dataChannel)
    }
}

private final class AnswererDataChannelDelegate: NSObject, RTCDataChannelDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onMessage: (@Sendable (Data) -> Void)?
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        onMessage?(buffer.data)
    }
}
#endif
