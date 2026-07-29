import CryptoKit
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit

@Suite("PairingHTTPServer Tests")
struct PairingHTTPServerTests {

    // MARK: Helpers

    /// One-shot per-test fixture: a fresh temp dir, primed identity store,
    /// a `HostPairingServer` wrapping it, and a `PairingHTTPServer`
    /// listening on an ephemeral loopback port.
    private struct Fixture {
        let dir: URL
        let pairingServer: HostPairingServer
        let httpServer: PairingHTTPServer
        let port: Int
        let privateKey: CryptoKit.Curve25519.Signing.PrivateKey

        func cleanup() async {
            await httpServer.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func makeFixture(now: @escaping () -> Date = { Date() }) async throws -> Fixture {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let identityStore = HostIdentityStore(directory: dir)
        let privateKey = try identityStore.generateAndPersist()
        let peerStore = TrustedPeerStore(directory: dir)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            now: now,
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            pairingURLProvider: { URL(string: "https://host.local:8800/v2/pairing")! }
        )
        let pairingServer = HostPairingServer(session: session)
        let httpServer = PairingHTTPServer(pairingServer: pairingServer)
        let port = try await httpServer.start(host: "127.0.0.1", port: 0)

        return Fixture(
            dir: dir,
            pairingServer: pairingServer,
            httpServer: httpServer,
            port: port,
            privateKey: privateKey
        )
    }

    /// Runs `body` against a fresh fixture, guaranteeing `cleanup()` runs
    /// even if `body` throws or an assertion fails partway through — the
    /// listener must always be torn down so ephemeral ports don't leak
    /// across tests.
    private func withFixture(
        now: @escaping () -> Date = { Date() },
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let fx = try await makeFixture(now: now)
        do {
            try await body(fx)
        } catch {
            await fx.cleanup()
            throw error
        }
        await fx.cleanup()
    }

    private func makeClientPublicKey(byte: UInt8 = 0xCC) -> RemoteIdentityPublicKey {
        try! RemoteIdentityPublicKey(rawRepresentation: Data(repeating: byte, count: 32))
    }

    private func makeIntroduceRequest(
        nonce: RemotePairingNonce,
        clientKeyByte: UInt8 = 0xCC
    ) -> PairingIntroduceRequest {
        PairingIntroduceRequest(
            nonce: nonce,
            clientPublicKey: makeClientPublicKey(byte: clientKeyByte),
            clientDeviceID: RemoteDeviceID(value: "client-123"),
            clientKind: .iphone,
            clientDisplayName: "Client iPhone"
        )
    }

    /// Builds the same fixture pieces as `makeFixture` but does NOT call
    /// `start()` — used by lifecycle-race tests that need to drive
    /// `start()`/`stop()` themselves (including concurrently).
    private func makeUnstartedServer() throws -> (dir: URL, httpServer: PairingHTTPServer) {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let identityStore = HostIdentityStore(directory: dir)
        _ = try identityStore.generateAndPersist()
        let peerStore = TrustedPeerStore(directory: dir)
        let session = HostPairingSession(
            identityStore: identityStore,
            peerStore: peerStore,
            now: { Date() },
            hostDeviceID: .generate(),
            hostKind: .mac,
            hostDisplayName: "Test Mac",
            pairingURLProvider: { URL(string: "https://host.local:8800/v2/pairing")! }
        )
        let pairingServer = HostPairingServer(session: session)
        let httpServer = PairingHTTPServer(pairingServer: pairingServer)
        return (dir, httpServer)
    }

    /// Yield until at least `count` long-poll waiters are registered.
    /// Mirrors `HostPairingServerTests.waitForWaiters` so the await-outcome
    /// test doesn't race the actor's scheduling under load.
    private func waitForWaiters(on server: HostPairingServer, atLeast count: Int) async {
        while await server.pendingWaiterCount < count {
            await Task.yield()
        }
    }

    private static let encoder = JSONEncoder.iso8601()
    private static let decoder = JSONDecoder.iso8601()

    /// POSTs a JSON-encoded body to `path` on the fixture's listener and
    /// returns the raw status code + body bytes, leaving decoding (success
    /// shape vs. `PairingErrorResponse`) to the caller.
    private func post(
        _ path: String,
        port: Int,
        body: some Encodable
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return (0, data)
        }
        return (http.statusCode, data)
    }

    private func get(_ path: String, port: Int) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            Issue.record("Expected HTTPURLResponse")
            return 0
        }
        return http.statusCode
    }

    // MARK: - introduce round trip

    @Test("POST /v2/pairing/introduce with a valid request returns 200 and the host's public key")
    func introduceRoundTrip() async throws {
        try await withFixture { fx in
            let payload = try await fx.pairingServer.start(validFor: 300)
            let (status, data) = try await self.post(
                "/v2/pairing/introduce",
                port: fx.port,
                body: self.makeIntroduceRequest(nonce: payload.nonce)
            )
            #expect(status == 200)
            let response = try Self.decoder.decode(PairingIntroduceResponse.self, from: data)
            let expected = try RemoteIdentityPublicKey(
                rawRepresentation: fx.privateKey.publicKey.rawRepresentation
            )
            #expect(response.hostPublicKey == expected)
        }
    }

    // MARK: - introduce with a fabricated nonce

    @Test("POST /v2/pairing/introduce with an unknown nonce returns a non-2xx PairingErrorResponse")
    func introduceWrongNonce() async throws {
        try await withFixture { fx in
            _ = try await fx.pairingServer.start()
            let (status, data) = try await self.post(
                "/v2/pairing/introduce",
                port: fx.port,
                body: self.makeIntroduceRequest(nonce: RemotePairingNonce.generate())
            )
            #expect(!(200..<300).contains(status))
            let error = try Self.decoder.decode(PairingErrorResponse.self, from: data)
            #expect(error.code == .unknownNonce)
        }
    }

    // MARK: - await-outcome long-poll

    @Test("POST /v2/pairing/await-outcome suspends until confirm() then returns outcome=confirmed")
    func awaitOutcomeResolvesOnConfirm() async throws {
        try await withFixture { fx in
            let payload = try await fx.pairingServer.start()
            let (introduceStatus, _) = try await self.post(
                "/v2/pairing/introduce",
                port: fx.port,
                body: self.makeIntroduceRequest(nonce: payload.nonce)
            )
            #expect(introduceStatus == 200)

            async let outcomeCall = self.post(
                "/v2/pairing/await-outcome",
                port: fx.port,
                body: PairingAwaitOutcomeRequest(nonce: payload.nonce)
            )

            await self.waitForWaiters(on: fx.pairingServer, atLeast: 1)
            try await fx.pairingServer.confirm()

            let (status, data) = try await outcomeCall
            #expect(status == 200)
            let response = try Self.decoder.decode(PairingOutcomeResponse.self, from: data)
            #expect(response.outcome == .confirmed)
        }
    }

    // MARK: - unknown path

    @Test("GET on a path other than the two pairing routes returns 404")
    func unknownPathIs404() async throws {
        try await withFixture { fx in
            let status = try await self.get("/nope", port: fx.port)
            #expect(status == 404)
        }
    }

    // MARK: - wrong method

    @Test("GET /v2/pairing/introduce returns 405")
    func getIs405() async throws {
        try await withFixture { fx in
            let status = try await self.get("/v2/pairing/introduce", port: fx.port)
            #expect(status == 405)
        }
    }

    // MARK: - REMOTE-1.4

    @Test("""
    @spec REMOTE-1.4: While no pairing session is active, the host shall not accept connections on the pairing endpoint; the pairing listener runs only for the lifetime of an active pairing session.
    """)
    func listenerStopsAcceptingConnectionsAfterStop() async throws {
        try await withFixture { fx in
            let port = fx.port
            await fx.httpServer.stop()

            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v2/pairing/introduce")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(
                self.makeIntroduceRequest(nonce: RemotePairingNonce.generate())
            )

            do {
                _ = try await URLSession.shared.data(for: request)
                Issue.record("Expected the connection to fail after stop()")
            } catch let error as URLError {
                // Expected: connection refused (or similar) once the
                // listener has been torn down.
                _ = error
            }
        }
    }

    // MARK: - lifecycle race helpers

    /// Runs `body` against a fresh unstarted server + its own temp dir
    /// (via `makeUnstartedServer`), guaranteeing `stop()` + directory
    /// cleanup run even if `body` throws partway through — mirrors
    /// `withFixture`'s do/catch discipline for the lifecycle-race tests
    /// below, which build their own server instead of going through
    /// `makeFixture`.
    private func withUnstartedServer(
        _ body: (URL, PairingHTTPServer) async throws -> Void
    ) async throws {
        let (dir, httpServer) = try makeUnstartedServer()
        func cleanup() async {
            await httpServer.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        do {
            try await body(dir, httpServer)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    private struct GateTimeoutError: Swift.Error {}

    /// Awaits the next value from `stream`, racing it against `timeout`
    /// so a `start()` that fails (or otherwise never reaches the gate)
    /// before yielding a port turns into a clean test failure instead of
    /// hanging the suite forever.
    private func expectPort(from stream: AsyncStream<Int>, timeout: Duration = .seconds(5)) async throws -> Int {
        try await withThrowingTaskGroup(of: Int?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let port = try await group.next() ?? nil else {
                throw GateTimeoutError()
            }
            return port
        }
    }

    // MARK: - lifecycle races

    /// Actors only interleave at suspension points. `start()` suspends at
    /// `bootstrap.bind(...).get()`, so a naive `precondition(group == nil)`
    /// check made before that suspension lets two concurrent `start()`
    /// calls both pass the check, both bind a live listener, and orphan
    /// the loser's event-loop-group thread + socket with no way to stop
    /// them. The fix must claim the lifecycle transition synchronously,
    /// before the first `await`, so exactly one of two concurrent callers
    /// wins.
    @Test("Concurrent start() calls are serialized across the actor's suspension point: exactly one binds the listener and the other fails deterministically")
    func concurrentStartsAreSerializedAcrossSuspension() async throws {
        try await withUnstartedServer { _, httpServer in
            @Sendable func attemptStart() async -> Swift.Result<Int, Error> {
                do {
                    return .success(try await httpServer.start(host: "127.0.0.1", port: 0))
                } catch {
                    return .failure(error)
                }
            }

            async let first = attemptStart()
            async let second = attemptStart()
            let results = await [first, second]

            let successes = results.compactMap { try? $0.get() }
            let failures = results.compactMap { result -> Error? in
                if case .failure(let error) = result { return error }
                return nil
            }

            #expect(successes.count == 1, "expected exactly one start() to bind the listener, got \(successes)")
            #expect(failures.count == 1, "expected exactly one start() to fail, got \(failures)")
        }
    }

    /// Same suspension-interleaving hazard as `start()`, but for `stop()`:
    /// two concurrent `stop()` calls must not both attempt to close the
    /// channel / shut down the group — the second must observe the
    /// in-progress teardown and become a safe no-op rather than racing
    /// the first.
    @Test("Concurrent stop() calls after a successful start() are safe: both complete without hanging or throwing, and the listener stops accepting connections")
    func concurrentStopsAreSafe() async throws {
        try await withUnstartedServer { _, httpServer in
            let port = try await httpServer.start(host: "127.0.0.1", port: 0)

            async let firstStop: Void = httpServer.stop()
            async let secondStop: Void = httpServer.stop()
            _ = await (firstStop, secondStop)

            do {
                _ = try await self.get("/nope", port: port)
                Issue.record("Expected the connection to fail after concurrent stop()")
            } catch is URLError {
                // Expected: connection refused once the listener has been
                // torn down.
            }
        }
    }

    /// `start()` suspends at `bind`; a `stop()` that interleaves there
    /// observes `.starting` but nil channel/group, so its teardown is a
    /// no-op and it resets the lifecycle to `.idle`. If the resuming
    /// `start()` then unconditionally records the bound channel and goes
    /// `.running`, the caller is left with a live listener it believes
    /// is stopped — violating REMOTE-1.4's guarantee. The interleaving
    /// is driven deterministically via the test-only start-resume gate,
    /// which widens the exact same suspension window.
    @Test("stop() interleaved during start()'s bind suspension leaves no live listener: start() throws stoppedDuringStart and the bound port refuses connections")
    func stopDuringStartLeavesNoLiveListener() async throws {
        try await withUnstartedServer { _, httpServer in
            let (portStream, portCont) = AsyncStream.makeStream(of: Int.self)
            let (releaseStream, releaseCont) = AsyncStream.makeStream(of: Void.self)
            await httpServer.setStartResumeGateForTesting { boundPort in
                portCont.yield(boundPort)
                var release = releaseStream.makeAsyncIterator()
                _ = await release.next()
            }

            async let startResult: Swift.Result<Int, Error> = {
                do {
                    return .success(try await httpServer.start(host: "127.0.0.1", port: 0))
                } catch {
                    return .failure(error)
                }
            }()

            // start() has bound the socket and is parked inside the gate.
            let boundPort = try await self.expectPort(from: portStream)

            // stop() interleaves: sees `.starting`, finds nothing recorded to
            // tear down, and resets the lifecycle to `.idle`.
            await httpServer.stop()

            // Release start(); it must NOT resume into `.running`.
            releaseCont.yield(())

            switch await startResult {
            case .success(let port):
                Issue.record("Expected start() to fail after an interleaved stop(); got a live listener on port \(port)")
            case .failure(let error):
                #expect(error as? PairingHTTPServer.LifecycleError == .stoppedDuringStart)
            }

            do {
                _ = try await self.get("/nope", port: boundPort)
                Issue.record("Expected the connection to fail: the caller believes the server is stopped")
            } catch is URLError {
                // Expected: the just-bound channel was closed before start()
                // returned, so nothing is listening on the bound port.
            }

            // The lifecycle must be back at .idle with no orphaned resources:
            // a fresh start()/stop() cycle works (gate removed so the fresh
            // start doesn't park in it).
            await httpServer.setStartResumeGateForTesting(nil)
            let freshPort = try await httpServer.start(host: "127.0.0.1", port: 0)
            #expect(freshPort > 0)
        }
    }

    /// The three-way interleaving A1 fixes: `start()` A parks at bind
    /// (via the test-only resume gate); a `stop()` interleaves, sees
    /// nothing recorded to tear down (A hasn't stored its channel/group
    /// yet), and resets the lifecycle to `.idle`; a fresh `start()` B
    /// claims `.idle` → `.starting` and ALSO parks at bind (both A and B
    /// are suspended inside the gate at once — this double-parking is
    /// what makes the two `.starting` claims genuinely ambiguous without
    /// call identity); A is released first, then B.
    ///
    /// Before the identity-carrying `Lifecycle` cases, A's post-bind
    /// check was a bare `guard lifecycle == .starting`, which — while B
    /// was still parked holding that exact same bare state — passed
    /// against B's claim. A would then record its own (stale,
    /// already-superseded) channel as `.running` and return success;
    /// when B resumed next, it would see `.running` already claimed and
    /// close its own good channel, throwing `stoppedDuringStart` for the
    /// wrong call. (Releasing B before A, or letting B run straight
    /// through without parking, never exercises the ambiguity: by the
    /// time A resumes, `lifecycle` is unambiguously `.running`, which
    /// even the bare-enum guard correctly rejects — the bug only shows
    /// up when two `.starting` claims are simultaneously live.) The
    /// invariant this test enforces: the caller whose claim is current
    /// (B) keeps its listener live, and the stale resume (A) fails and
    /// closes only its own channel.
    @Test("Three-way start()/stop()/start() interleaving: the newer start()'s listener stays live and the stale resume closes only its own channel")
    func threeWayStartStopStartInterleavingLeavesNewerListenerLive() async throws {
        try await withUnstartedServer { _, httpServer in
            actor Gate {
                private var callCount = 0
                private let portCont: AsyncStream<Int>.Continuation
                private let releaseA: AsyncStream<Void>
                private let releaseB: AsyncStream<Void>

                init(portCont: AsyncStream<Int>.Continuation, releaseA: AsyncStream<Void>, releaseB: AsyncStream<Void>) {
                    self.portCont = portCont
                    self.releaseA = releaseA
                    self.releaseB = releaseB
                }

                /// Every call parks: the first (A) waits on `releaseA`,
                /// the second (B) waits on `releaseB`, so the test can
                /// release them in either order.
                func waitForRelease(port: Int) async {
                    callCount += 1
                    let isFirstCall = callCount == 1
                    portCont.yield(port)
                    let stream = isFirstCall ? releaseA : releaseB
                    var iterator = stream.makeAsyncIterator()
                    _ = await iterator.next()
                }
            }

            let (portStream, portCont) = AsyncStream.makeStream(of: Int.self)
            let (releaseAStream, releaseACont) = AsyncStream.makeStream(of: Void.self)
            let (releaseBStream, releaseBCont) = AsyncStream.makeStream(of: Void.self)
            let gate = Gate(portCont: portCont, releaseA: releaseAStream, releaseB: releaseBStream)
            await httpServer.setStartResumeGateForTesting { port in await gate.waitForRelease(port: port) }

            // A starts and parks after binding.
            async let aResult: Swift.Result<Int, Error> = {
                do {
                    return .success(try await httpServer.start(host: "127.0.0.1", port: 0))
                } catch {
                    return .failure(error)
                }
            }()
            let aPort = try await self.expectPort(from: portStream)

            // stop() interleaves while A is parked: observes `.starting`,
            // has nothing recorded to tear down, resets lifecycle to `.idle`.
            await httpServer.stop()

            // B starts fresh, claims `.starting`, binds, and ALSO parks —
            // both A and B are now suspended at their post-bind checkpoint
            // with `lifecycle` bare-indistinguishable between their two
            // `.starting` claims.
            async let bResult: Swift.Result<Int, Error> = {
                do {
                    return .success(try await httpServer.start(host: "127.0.0.1", port: 0))
                } catch {
                    return .failure(error)
                }
            }()
            let bPort = try await self.expectPort(from: portStream)

            // Release A first: its claim must lose to B's, which is still
            // parked (and therefore still "current") at this instant.
            releaseACont.yield(())
            switch await aResult {
            case .success(let port):
                Issue.record("Expected A's stale resume to fail; got a live listener on port \(port)")
            case .failure(let error):
                #expect(error as? PairingHTTPServer.LifecycleError == .stoppedDuringStart)
            }

            // Now release B: its claim is still current and must win.
            releaseBCont.yield(())
            switch await bResult {
            case .success(let port):
                #expect(port == bPort)
            case .failure(let error):
                Issue.record("Expected B's resume to succeed; got \(error)")
            }

            // Invariant: B's listener is still live and reachable...
            let bStatus = try await self.get("/nope", port: bPort)
            #expect(bStatus == 404)

            // ...and A's own (stale) channel was closed, not B's.
            do {
                _ = try await self.get("/nope", port: aPort)
                Issue.record("Expected A's stale channel to be closed, leaving nothing listening on its port")
            } catch is URLError {
                // Expected.
            }
        }
    }
}
