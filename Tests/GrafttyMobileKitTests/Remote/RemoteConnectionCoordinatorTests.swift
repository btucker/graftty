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
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
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
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
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
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
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
        try await RemoteConnectionTestSupport.pollUntil(timeout: .seconds(10)) { await gate.enteredCount >= 1 }
        await gate.open()

        let r1 = await first
        let r2 = await second
        #expect(r1 == nil)
        #expect(r2 == nil)
        #expect(counter.count == 1, "expected exactly one negotiation, factory was called \(counter.count) times")
    }

    // MARK: - Busy (503) is retryable, not permanently cached — but is
    // still subject to the failure cooldown (A3(b)): a 503 is not a
    // PERMANENT failure, so retrying once the cooldown expires is fine;
    // hammering the host again a millisecond later is exactly what the
    // cooldown exists to prevent.

    @Test(.timeLimit(.minutes(1)))
    func busyResponseReturnsNilAndRetriesAfterCooldownExpires() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
        let counter = CallCounter()
        let clock = MutableClock()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { request, _ in
                Self.httpResponse(for: request, statusCode: 503, body: "host is busy")
            }),
            connectionFactory: { key, fp in counter.increment(); return RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp) },
            now: { clock.now() }
        )

        let first = await coordinator.connection(for: host)
        #expect(first == nil)
        #expect(counter.count == 1)

        // Advancing the injected clock (not a real 30s wait) past the
        // cooldown is what proves this is a TEMPORARY, not permanent,
        // failure — see `cooldownSkipsNegotiationWithoutClockAdvance`
        // below for the complementary proof that a call BEFORE the
        // cooldown expires does NOT retry.
        clock.advance(by: 31)

        let second = await coordinator.connection(for: host)
        #expect(second == nil)
        #expect(counter.count == 2, "a 503 must not be cached as a PERMANENT failure — a call after the cooldown expires should retry")
    }

    // MARK: - Failure cooldown (A3(b))

    @Test(.timeLimit(.minutes(1)))
    func cooldownSkipsNegotiationWithoutClockAdvance() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
        let counter = CallCounter()
        let clock = MutableClock()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { request, _ in
                Self.httpResponse(for: request, statusCode: 503, body: "host is busy")
            }),
            connectionFactory: { key, fp in counter.increment(); return RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp) },
            now: { clock.now() }
        )

        let first = await coordinator.connection(for: host)
        #expect(first == nil)
        #expect(counter.count == 1)

        // No clock advance: still within the 30s cooldown window.
        let second = await coordinator.connection(for: host)
        #expect(second == nil)
        #expect(counter.count == 1, "a call within the cooldown window must fast-nil WITHOUT negotiating again")
    }

    @Test(.timeLimit(.minutes(2)))
    func invalidateClearsCooldownAllowingImmediateRetry() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
        let counter = CallCounter()
        let clock = MutableClock()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { request, _ in
                Self.httpResponse(for: request, statusCode: 503, body: "host is busy")
            }),
            connectionFactory: { key, fp in counter.increment(); return RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp) },
            now: { clock.now() }
        )

        let first = await coordinator.connection(for: host)
        #expect(first == nil)
        #expect(counter.count == 1)

        // `invalidate(host:)` is the exact call `RootView`'s background
        // scenePhase path makes — a user-driven fresh start must not be
        // blocked by a stale cooldown from a background-era failure (see
        // `invalidate`'s doc comment). No clock advance: proves this is
        // `invalidate` clearing the cooldown, not the cooldown expiring
        // on its own.
        await coordinator.invalidate(host: host)

        let second = await coordinator.connection(for: host)
        #expect(second == nil)
        #expect(counter.count == 2, "invalidate(host:) must clear the cooldown so the very next call negotiates again")
    }

    /// This test's subject is cooldown bookkeeping (`cooldownUntil` is
    /// only ever populated on the FAILURE exit of `negotiate` — see
    /// `fail(host:)` — never on success), not whether a second real
    /// end-to-end WebRTC handshake can complete. `connectionFactory`'s
    /// counter increments the instant `negotiate` calls it — before the
    /// offer/answer exchange even starts — so "the second call wasn't
    /// blocked by a cooldown" is fully proven by `counter.count == 2`
    /// regardless of whether that second attempt goes on to succeed.
    ///
    /// The second attempt therefore fails fast at the signaling step
    /// (`exchangeCount`-gated 503, exactly like
    /// `busyResponseReturnsNilAndRetriesAfterCooldownExpires`'s already-
    /// covered failure path) instead of running a second real loopback
    /// data-channel negotiation. Two real negotiations per test made this
    /// specifically the marginal one under full-suite load on CI: the
    /// FIRST negotiation itself intermittently missed
    /// `RemoteHostConnection`'s 30s `dataChannelOpenTimedOut` on a loaded
    /// simulator (`negotiated` came back `nil`), even though every other
    /// loopback test in the same run — each paying that cost once, not
    /// twice — passed. Cutting this test to one real negotiation removes
    /// one of the suite's real-WebRTC data points without weakening the
    /// assertion it's actually making.
    @Test(.timeLimit(.minutes(2)))
    func successfulNegotiationLeavesNoCooldownForSubsequentRenegotiation() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
        let counter = CallCounter()
        let box = ConnectionBox()
        let clock = MutableClock()
        let exchangeCount = CallCounter()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { request, body in
                exchangeCount.increment()
                if exchangeCount.count == 1 {
                    return try await Self.successTransport(box: box)(request, body)
                }
                return Self.httpResponse(for: request, statusCode: 503, body: "host is busy")
            }),
            connectionFactory: { key, fp in
                counter.increment()
                let connection = RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp)
                box.set(connection)
                return connection
            },
            now: { clock.now() }
        )

        let negotiated = await coordinator.connection(for: host)
        let live = try #require(negotiated)
        #expect(counter.count == 1)

        // Evict via the SAME terminal-transition path
        // `terminalStateChangeEvictsFromRegistry` exercises, then —
        // crucially — retry with NO clock advance. If a successful
        // negotiation ever left a cooldown entry behind, this would
        // fast-nil WITHOUT ever calling `connectionFactory` again, and
        // `counter.count` would stay at 1.
        await live.close()
        try await RemoteConnectionTestSupport.pollUntil(timeout: .seconds(5)) {
            _ = await coordinator.connection(for: host)
            return counter.count == 2
        }
        #expect(counter.count == 2, "a successful negotiation must not leave a cooldown behind for the host")
    }

    // MARK: - Eviction on terminal state change

    @Test(.timeLimit(.minutes(2)))
    func terminalStateChangeEvictsFromRegistry() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
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
        var again: RemoteHostConnection?
        try await RemoteConnectionTestSupport.pollUntil(timeout: .seconds(5)) {
            again = await coordinator.connection(for: host)
            return again !== live
        }
        #expect(counter.count == 2, "eviction should allow a fresh negotiation on the next call")
        await again?.close()
    }

    // MARK: - Register-then-verify (A2(i))

    /// Best-effort regression test, NOT a deterministic RED reproduction:
    /// the race `negotiate`'s register-then-verify guard closes — a
    /// terminal transition landing in the single `await` gap between
    /// `liveConnections[host.id] = connection` and the immediately
    /// following `await connection.state` — depends on WebRTC's internal
    /// ICE/DataChannel-close callback timing relative to actor-hop
    /// scheduling, which this harness has no way to pin exactly. Killing
    /// the answerer shortly after the handshake completes lands the
    /// terminal transition SOMEWHERE close to that gap, sometimes
    /// exercising the new inline guard and sometimes the pre-existing
    /// async `onStateChange` eviction path instead — either is
    /// acceptable, because what this test actually verifies is the
    /// user-visible invariant BOTH paths exist to uphold: the registry
    /// must never stay wedged on a connection whose peer is already gone.
    @Test(.timeLimit(.minutes(1)))
    func negotiationWhosePeerDiesImmediatelyIsNeverLeftRegisteredAsLive() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
        let box = ConnectionBox()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { request, body in
                let offer = try JSONDecoder().decode(SignalingOffer.self, from: body)
                let answerer = TestAnswerer()
                let rtcOffer = RTCSessionDescription(type: .offer, sdp: offer.sdp)
                let rtcAnswer = try await answerer.accept(offer: rtcOffer)
                if let connection = box.get() {
                    await connection.bindIceCandidates(to: answerer)
                    await answerer.bindIceCandidates(to: connection)
                }
                box.retain(answerer)
                // Kill the far side shortly after standing up — races
                // the client's own post-registration verify. See this
                // test's doc comment for why this is best-effort, not a
                // pinned reproduction.
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    await answerer.close()
                }
                let answer = SignalingAnswer(sdp: rtcAnswer.sdp)
                let data = try JSONEncoder().encode(answer)
                return Self.httpResponseSuccess(for: request, data: data)
            }),
            connectionFactory: { key, fp in
                let connection = RemoteHostConnection(clientKey: key, expectedHostFingerprint: fp)
                box.set(connection)
                return connection
            }
        )

        let firstResult = await coordinator.connection(for: host)

        // If the guard caught the death inline, `firstResult` is already
        // `nil` and there's nothing further to prove. Otherwise, poll
        // until the dead connection is no longer the one on offer — the
        // pre-existing async `onStateChange` eviction path is the
        // fallback net if the inline guard's exact window was missed.
        try await RemoteConnectionTestSupport.pollUntil(timeout: .seconds(20)) {
            guard let firstResult else { return true }
            let again = await coordinator.connection(for: host)
            return again !== firstResult
        }
    }

    // MARK: - invalidate(host:) closes and evicts

    @Test(.timeLimit(.minutes(2)))
    func invalidateClosesAndEvictsTheLiveConnection() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
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
        await again?.close()
    }

    // MARK: - invalidateAll() — W3 review wave B1 (RootView's `.background`-only teardown)

    @Test(.timeLimit(.minutes(2)))
    func invalidateAllEvictsEveryLiveConnection() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let hostA = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
        let hostB = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
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

        // Negotiated sequentially (not concurrently) — `box` holds only
        // the MOST RECENT connection, which `successTransport` reads to
        // route ICE candidates, so overlapping negotiations against one
        // shared box would race. Nothing about `invalidateAll` itself
        // requires concurrent negotiation to exercise "evicts EVERY live
        // host," only that more than one host is registered at once.
        let liveA = try #require(await coordinator.connection(for: hostA))
        let liveB = try #require(await coordinator.connection(for: hostB))
        #expect(counter.count == 2)

        await coordinator.invalidateAll()

        #expect(await liveA.state == .closed)
        #expect(await liveB.state == .closed)

        // Eviction proof: the next call for either host must negotiate
        // fresh rather than returning the (closed) cached connection.
        let againA = await coordinator.connection(for: hostA)
        #expect(againA !== liveA)
        #expect(counter.count == 3)
        await againA?.close()
    }

    @Test(.timeLimit(.minutes(2)))
    func invalidateAllEvictsInFlightAttemptWithoutRegisteringItsResult() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
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

        // As in `invalidateDuringInFlightNegotiationEvictsOnCompletionRatherThanRegistering`,
        // wait until the negotiation is genuinely parked at the gate
        // before invoking `invalidateAll` — proves this isn't racing a
        // negotiation that already finished.
        try await RemoteConnectionTestSupport.pollUntil(timeout: .seconds(10)) { await gate.enteredCount >= 1 }
        await coordinator.invalidateAll()
        await gate.open()

        let result = await negotiated
        #expect(result == nil, "a connection invalidated mid-negotiation via invalidateAll must never be handed back")
        #expect(counter.count == 1, "invalidateAll must not itself trigger a second negotiation")

        let firstConnection = try #require(box.get())
        #expect(await firstConnection.state == .closed, "the in-flight negotiation's result must be closed, not left dangling")

        let again = await coordinator.connection(for: host)
        #expect(counter.count == 2, "a fresh call after invalidateAll must negotiate again")
        #expect(again !== firstConnection)
        await again?.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidateAllClearsCooldownAllowingImmediateRetry() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
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

        // No live connection exists for this host (negotiation failed) —
        // invalidateAll must still clear its cooldown, matching
        // `invalidate(host:)`'s unconditional-clear behavior (see that
        // method's doc comment): a background→foreground cycle must not
        // leave a stale cooldown blocking the very next dial.
        await coordinator.invalidateAll()

        let second = await coordinator.connection(for: host)
        #expect(second == nil, "still a 503 — no clock advance, no successful negotiation swapped in")
        #expect(counter.count == 2, "invalidateAll must clear the cooldown so the very next call negotiates again")
    }

    // MARK: - isPaired(_:) — same source of truth as connection(for:)'s gate (Task-3 finding 3)

    @Test(.timeLimit(.minutes(1)))
    func isPairedFalseForHostWithNoRemoteDeviceID() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let coordinator = RemoteConnectionCoordinator(
            directory: dir,
            signaling: SignalingClient(transport: { _, _ in throw Self.unreachable })
        )
        let host = Host(label: "Unpaired", baseURL: URL(string: "https://host.local:9999")!, remoteDeviceID: nil)

        #expect(!coordinator.isPaired(host))
    }

    @Test(.timeLimit(.minutes(1)))
    func isPairedFalseForRemoteDeviceIDWithNoPinnedEntry() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
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
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
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
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
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
        try await RemoteConnectionTestSupport.pollUntil(timeout: .seconds(10)) { await gate.enteredCount >= 1 }
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
        // mid-flight invalidation) — proving `invalidatedAttempts` only
        // ever marks the ONE attempt it was recorded against, not every
        // future attempt for the same host.
        let again = await coordinator.connection(for: host)
        #expect(counter.count == 2, "a fresh call after invalidate-mid-flight must negotiate again, not reuse the evicted connection")
        let secondConnection = try #require(again, "a fresh negotiation with no further invalidation should succeed normally")
        #expect(secondConnection !== firstConnection)
        await secondConnection.close()
    }

    // MARK: - Stale eviction guard

    @Test(.timeLimit(.minutes(1)))
    func staleTerminalNotificationDoesNotEvictANewerConnection() async throws {
        let dir = try RemoteConnectionTestSupport.makeTempDirectory()
        let host = try RemoteConnectionTestSupport.makePairedHost(directory: dir)
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
        coordinator.registerLiveConnectionForTesting(newer, hostID: host.id)
        coordinator.evict(hostID: host.id, connectionIdentity: ObjectIdentifier(stale))

        let result = await coordinator.connection(for: host)
        #expect(result === newer, "a stale connection's terminal notification must not evict a newer, live connection")
    }

    // MARK: - Helpers

    private nonisolated static let unreachable = NSError(domain: "RemoteConnectionCoordinatorTests", code: -1)

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

}

// MARK: - Shared test helpers (also used by `RemoteConnectionReconnectTests`)
//
// Namespaced under an enum (rather than bare top-level declarations) at
// `internal` access — this file's/target's default — because
// `RemoteHostConnectionLoopbackTests.swift` separately declares its OWN
// file-`private` `pollUntil`/`PollTimeout` with the identical signature;
// bare top-level `internal` declarations of the same name collide with
// that file's `private` ones at the WHOLE-MODULE redeclaration check
// (access control doesn't partition top-level name lookup the way it
// does for type members). Namespacing sidesteps that without touching
// `RemoteHostConnectionLoopbackTests.swift`, which is out of this dedupe's
// scope.
//
// `makeTempDirectory`/`makePairedHost`/`pollUntil`/`PollTimeout` were
// byte-identical copies duplicated across `RemoteConnectionCoordinatorTests.swift`
// and `RemoteConnectionReconnectTests.swift` — consolidated here so both
// files reference one definition. `LoopbackPeer`/`ConnectionBox`/
// `httpResponseSuccess` etc. are NOT consolidated: they're
// `RemoteConnectionReconnectTests`' own SSH-flavored variants of ideas
// that also appear here in a WebRTC-only flavor, not true duplicates —
// see that file's own doc comment on `LoopbackPeer` (deferred to a W5
// sweep).
enum RemoteConnectionTestSupport {
    static func makeTempDirectory() throws -> URL {
        let dir = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pairs a host with a pinned host record in `directory`'s
    /// `PinnedHostStore`, mirroring what a real pairing flow
    /// (`PairDeviceFlowView.buildModel`) would have persisted. `serverKey`
    /// defaults to a freshly generated key (the common case — most
    /// callers don't need to know it up front); reconnect tests that must
    /// seed a host-side SSH server with the SAME key the pinned record
    /// trusts pass it explicitly.
    static func makePairedHost(
        directory: URL,
        serverKey: Curve25519.Signing.PrivateKey? = nil
    ) throws -> Host {
        let hostKey = serverKey ?? Curve25519.Signing.PrivateKey()
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

    /// Poll until `condition()` returns true or the deadline expires.
    /// Used instead of arbitrary `Task.sleep` so a test exits promptly on
    /// success but still fails clearly when the condition genuinely
    /// doesn't hold.
    /// `stage` is evaluated only when the poll times out, so
    /// interpolating live counters into it yields an at-timeout snapshot.
    /// Label every poll in multi-stage tests — an unlabeled timeout is
    /// attributed to the @Test declaration line and is undiagnosable
    /// from CI logs (the IPAD-5.2 flake hid two distinct root causes
    /// behind one generic timeout).
    static func pollUntil(
        timeout: Duration,
        interval: Duration = .milliseconds(50),
        stage: @autoclosure () -> String = "",
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: interval)
        }
        throw PollTimeout(timeout: timeout, stage: stage())
    }

    struct PollTimeout: Error, CustomStringConvertible {
        let timeout: Duration
        var stage: String = ""
        var description: String {
            stage.isEmpty
                ? "pollUntil timed out after \(timeout)"
                : "pollUntil timed out after \(timeout) at stage: \(stage)"
        }
    }
}

/// Thread-safe call counter for asserting how many times a stubbed
/// `connectionFactory` was invoked.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    func increment() { lock.lock(); _count += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
}

/// Controllable clock for the failure-cooldown tests: `now()` — matching
/// `RemoteConnectionCoordinator.init`'s `now` seam's signature exactly so
/// it can be passed as `clock.now` — returns a fixed instant that only
/// moves when the test calls `advance(by:)`, so "cooldown expired"
/// behavior doesn't need a real 30s wait.
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date = Date()) {
        self.current = date
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock()
    }
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
