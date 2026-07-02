#if canImport(UIKit)
import CryptoKit
import Foundation
import GrafttyProtocol
import WebRTC
import os

/// Negotiates and caches per-host `RemoteHostConnection`s on demand.
///
/// `RootView`'s `/ws` fallback (Task 3) asks this coordinator for a
/// connection before falling back to the plain WebSocket transport.
/// `connection(for:)` is the single entry point: it fast-nils for a
/// host that isn't paired, returns an already-live connection, dedups
/// concurrent negotiation requests for the same host onto one in-flight
/// `Task`, and returns `nil` on ANY negotiation failure — including a
/// `503`/busy response from the host, which is a transient condition
/// and deliberately NOT cached as a permanent failure, so the very next
/// call retries from scratch.
///
/// `@MainActor` because the registry (`liveConnections`,
/// `inFlightAttempts`) is read and mutated from UI call sites (Task 3's
/// `RootView`) with no synchronization of its own — actor isolation is
/// that synchronization. Every mutation site in this file is synchronous
/// up to its first `await`, which is what makes the dedup
/// check-then-insert on `inFlightAttempts` atomic: two concurrent calls
/// to `connection(for:)` for the same host are always processed one at a
/// time by the MainActor's serial executor, so the second call is
/// guaranteed to observe the first call's freshly-stored `Task` before
/// it has a chance to start its own.
///
/// Not `ObservableObject`: nothing publishes through it (no `@Published`
/// properties) and no SwiftUI view holds it as `@StateObject`/reads it
/// via `@EnvironmentObject` — it's a plain reference type callers `await`
/// methods on.
@MainActor
public final class RemoteConnectionCoordinator {

    private let identityStore: ClientIdentityStore
    private let deviceIDStore: ClientDeviceIDStore
    private let pinnedHostStore: PinnedHostStore
    private let signaling: SignalingClient
    private let connectionFactory: (Curve25519.Signing.PrivateKey, RemoteIdentityFingerprint) -> RemoteHostConnection
    private let now: @Sendable () -> Date

    /// Successfully negotiated, still-live connections, keyed by `Host.id`.
    private var liveConnections: [UUID: RemoteHostConnection] = [:]

    /// One negotiation attempt, identified independently of the `Task`
    /// itself so `invalidate(host:)` can mark exactly THIS attempt as
    /// stale without the ambiguity a bare `Set<UUID>` keyed by `host.id`
    /// had: that older design let a SECOND attempt for the same host
    /// (started after the first one's slot was cleared) inherit a stray
    /// `invalidatedWhileInFlight` entry the first attempt's `defer` never
    /// got to clear if it was replaced rather than awaited to completion.
    /// Keying invalidation by attempt id instead of host id makes each
    /// attempt's identity — and the invalidation that targets it — a
    /// closed pair with no shared outer state to leak between attempts.
    private struct Attempt {
        let id: UUID
        let task: Task<RemoteHostConnection?, Never>
    }

    /// At most one in-flight negotiation `Task` per host. Concurrent
    /// callers for the same host await this same `Task` instead of
    /// starting a second negotiation (and, downstream, a second
    /// `POST /v1/rtc/offer` — which would hit `WebRTCHostAgent`'s own
    /// `HostError.busy` guard on the host side).
    private var inFlightAttempts: [UUID: Attempt] = [:]

    /// Attempt ids (see `Attempt`) whose `invalidate(host:)` call landed
    /// while that specific attempt was still in flight — i.e. scenePhase
    /// flapping (background → foreground → background) fast enough that
    /// a foreground rebuild's negotiation hadn't finished before the next
    /// background teardown fired. `negotiate(host:pinnedHost:attemptID:)`
    /// consults this set in the same uninterrupted (no-`await`) stretch
    /// where it would otherwise register the freshly negotiated
    /// connection, so EVERY awaiter of that negotiation (the original
    /// caller and any concurrent dedup'd callers via `inFlightAttempts`)
    /// observes the same `nil` outcome — closing the connection instead
    /// of resurrecting one the app already asked to tear down.
    ///
    /// Chosen behavior: let the in-flight negotiation finish, then evict
    /// (rather than cancelling its `Task`). `negotiate`'s own awaits —
    /// `signaling.exchange`, `connection.createOffer`/`applyAnswer` —
    /// have no cooperative-cancellation checkpoints of their own, so an
    /// actual `Task.cancel()` would either no-op or require threading
    /// `Task.isCancelled` checks through WebRTC/SSH setup code that
    /// doesn't have them today. Letting it finish and closing the result
    /// is simple, correct, and doesn't leave a half-negotiated
    /// `RTCPeerConnection` in an undefined state.
    private var invalidatedAttempts: Set<UUID> = []

    /// How long `connection(for:)` fast-nils a host WITHOUT negotiating
    /// after a negotiation attempt for it fails. Signaling is LAN/tailnet
    /// and normally sub-second; a failure (unreachable host, timed-out
    /// signaling request) is far more likely to still be true 30s later
    /// than to have resolved itself, so this avoids hammering a host that
    /// just told us (or timed out telling us) it can't be reached right
    /// now. `invalidate(host:)` clears this unconditionally — see its doc
    /// comment for why a user-driven foreground rebuild must never be
    /// blocked by a stale cooldown from a background-era failure.
    private static let failureCooldown: TimeInterval = 30

    /// Cooldown expiry per host, populated only on a FAILED negotiation
    /// (never on success, and never for the "invalidated mid-flight"
    /// outcome, which is an intentional teardown rather than a failure).
    private var cooldownUntil: [UUID: Date] = [:]

    private static let logger = Logger(
        subsystem: "com.quotably.graftty",
        category: "remote-connection-coordinator"
    )

    /// `directory` mirrors the one-directory construction pattern used by
    /// `PairDeviceFlowView.buildModel` (both now go through
    /// `ClientRemoteStores`): the client identity key, the client's
    /// stable device ID, and the pinned-host records all live as sibling
    /// files under the same directory.
    ///
    /// `connectionFactory` is a test seam — tests substitute a closure
    /// that records invocations (to assert negotiate-once dedup) while
    /// still returning a real `RemoteHostConnection` (there's no
    /// protocol to mock: the type is a concrete `actor` wrapping the
    /// WebRTC SDK). `nil` (production default) builds the connection
    /// directly.
    ///
    /// `now` is a test seam for the failure-cooldown clock — production
    /// uses wall-clock `Date()`; tests inject a controllable clock so
    /// cooldown-expiry behavior doesn't need a real 30s wait.
    public init(
        directory: URL = ClientIdentityStore.defaultDirectory,
        signaling: SignalingClient = SignalingClient(),
        connectionFactory: ((Curve25519.Signing.PrivateKey, RemoteIdentityFingerprint) -> RemoteHostConnection)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let stores = ClientRemoteStores(directory: directory)
        self.identityStore = stores.identityStore
        self.deviceIDStore = stores.deviceIDStore
        self.pinnedHostStore = stores.pinnedHostStore
        self.signaling = signaling
        self.connectionFactory = connectionFactory ?? { clientKey, expectedHostFingerprint in
            RemoteHostConnection(clientKey: clientKey, expectedHostFingerprint: expectedHostFingerprint)
        }
        self.now = now
    }

    /// Returns a live connection for `host`, negotiating one if none
    /// exists yet. Returns `nil` fast when `host` isn't paired
    /// (`remoteDeviceID` is `nil`, or `PinnedHostStore` has no matching
    /// entry), when `host` is within its post-failure cooldown window
    /// (see `failureCooldown`), and when negotiation fails for any
    /// reason — callers fall back to `/ws` in every case and cannot tell
    /// them apart, which is intentional: none of these should ever crash
    /// the caller.
    public func connection(for host: Host) async -> RemoteHostConnection? {
        guard let pinnedHost = pinnedHost(for: host) else { return nil }

        if let live = liveConnections[host.id] {
            return live
        }
        if let until = cooldownUntil[host.id], now() < until {
            return nil
        }
        if let inFlight = inFlightAttempts[host.id] {
            return await inFlight.task.value
        }

        let attemptID = UUID()
        let task = Task<RemoteHostConnection?, Never> { [weak self] in
            await self?.negotiate(host: host, pinnedHost: pinnedHost, attemptID: attemptID)
        }
        inFlightAttempts[host.id] = Attempt(id: attemptID, task: task)
        let result = await task.value
        // Clear only if the slot still holds THIS attempt: while it does,
        // every OTHER concurrent caller takes the `inFlight.task.value`
        // branch above instead of storing a new Task, so nothing can have
        // overwritten this slot between `await task.value` resuming and
        // this line running (no suspension point in between) — the check
        // is defensive precision, not a race fix.
        if inFlightAttempts[host.id]?.id == attemptID {
            inFlightAttempts[host.id] = nil
        }
        return result
    }

    /// Evicts and closes the live connection for `host`, if any, and
    /// unconditionally clears any post-failure cooldown for `host`.
    /// Used by background teardown and reconnect paths that need to
    /// force a fresh negotiation on next use.
    ///
    /// Clearing the cooldown unconditionally (not just when there was a
    /// live connection to close) matters for the background→foreground
    /// cycle: `invalidate(host:)` on backgrounding must not leave behind
    /// a cooldown that then blocks the foreground rebuild's immediate
    /// re-negotiation — `invalidate` is a user-driven fresh start, so it
    /// always wins over a stale failure timer.
    ///
    /// If a negotiation for `host` is still in flight (IPAD-5.1 fired
    /// mid-`IPAD-5.2` rebuild), there is no live connection to remove
    /// yet — instead this marks that attempt in `invalidatedAttempts` so
    /// `negotiate(host:pinnedHost:attemptID:)` self-evicts the moment
    /// that negotiation finishes, rather than silently registering a
    /// connection the app already asked to tear down.
    public func invalidate(host: Host) async {
        cooldownUntil[host.id] = nil
        if let inFlight = inFlightAttempts[host.id] {
            invalidatedAttempts.insert(inFlight.id)
        }
        guard let connection = liveConnections.removeValue(forKey: host.id) else { return }
        // Detach the observer BEFORE closing: this is an intentional,
        // caller-driven close, not a terminal signal the coordinator
        // needs to react to — without this, `close()`'s `.closed`
        // transition would still fire `onStateChange`, costing a
        // pointless `Task { await self?.evict(...) }` hop back in here
        // for a connection this method already removed from the
        // registry itself.
        await connection.setOnStateChange(nil)
        await connection.close()
    }

    /// Evicts and closes EVERY live connection, invalidates every
    /// in-flight negotiation attempt (per-attempt, via the same
    /// `invalidatedAttempts` mechanism `invalidate(host:)` uses), and
    /// unconditionally clears every host's failure cooldown. Used by
    /// `RootView`'s `.background` scenePhase transition: unlike
    /// `invalidate(host:)`, which only reaches whichever host a
    /// currently-mounted view happens to be watching, this closes the
    /// gap for a connection negotiated by a view that has since been
    /// popped off the navigation stack (and so has no `driveLifecycle`/
    /// `driveConnection` task left to call the per-host `invalidate`
    /// on background) — nothing survives into the background, and
    /// foreground re-negotiates every host from a clean slate.
    public func invalidateAll() async {
        cooldownUntil.removeAll()
        let hostIDs = Set(liveConnections.keys).union(inFlightAttempts.keys)
        for hostID in hostIDs {
            if let inFlight = inFlightAttempts[hostID] {
                invalidatedAttempts.insert(inFlight.id)
            }
            guard let connection = liveConnections.removeValue(forKey: hostID) else { continue }
            // See `invalidate(host:)`'s identical detach-before-close
            // comment: this is an intentional, caller-driven close, not
            // a terminal signal the coordinator needs to react to.
            await connection.setOnStateChange(nil)
            await connection.close()
        }
    }

    /// Single source of truth for "is `host` paired" — the same
    /// two-part check `connection(for:)` performs before ever attempting
    /// to negotiate (a non-nil `remoteDeviceID` AND a matching
    /// `PinnedHostStore` entry). `shouldLogFallbackLoudly`
    /// (`SessionLifecycleEnvironment.swift`) reads this so its
    /// `/ws`-fallback log-level gate can't drift from the coordinator's
    /// actual pairing gate.
    public func isPaired(_ host: Host) -> Bool {
        pinnedHost(for: host) != nil
    }

    private func pinnedHost(for host: Host) -> PinnedHost? {
        guard let remoteDeviceID = host.remoteDeviceID else { return nil }
        return (try? pinnedHostStore.get(id: remoteDeviceID)) ?? nil
    }

    /// Full negotiation body: build the connection, wire the terminal-state
    /// observer BEFORE `createOffer()` (so no drop between construction and
    /// observation), exchange SDP via `signaling`, register, then
    /// re-verify the connection is still alive post-registration. Any
    /// failure — including a `503`/busy signaling response, or the
    /// connection having died in the gap between registering and
    /// re-verifying — closes the connection, starts this host's failure
    /// cooldown, and returns `nil` without leaving anything in the
    /// registry, so the host is free to retry once the cooldown expires.
    private func negotiate(host: Host, pinnedHost: PinnedHost, attemptID: UUID) async -> RemoteHostConnection? {
        // One-shot per attempt: cleared here regardless of outcome so a
        // FUTURE attempt for this host starts with a clean flag.
        defer { invalidatedAttempts.remove(attemptID) }
        guard let clientKey = try? identityStore.loadOrGenerateAndPersist() else {
            Self.logger.warning("no client identity available; cannot negotiate with host \(host.id, privacy: .public)")
            return fail(host: host)
        }
        guard let clientDeviceID = try? deviceIDStore.loadOrGenerateAndPersist() else {
            Self.logger.warning("no client device id available; cannot negotiate with host \(host.id, privacy: .public)")
            return fail(host: host)
        }

        let connection = connectionFactory(clientKey, pinnedHost.fingerprint)
        let connectionIdentity = ObjectIdentifier(connection)
        await connection.setOnStateChange { [weak self] state in
            guard state.isTerminal else { return }
            Task { await self?.evict(hostID: host.id, connectionIdentity: connectionIdentity) }
        }

        do {
            let offer = try await connection.createOffer()
            let answer = try await signaling.exchange(
                baseURL: host.baseURL,
                offer: SignalingOffer(clientDeviceID: clientDeviceID.value, sdp: offer.sdp)
            )
            try await connection.applyAnswer(RTCSessionDescription(type: .answer, sdp: answer.sdp))
        } catch {
            // A 503 (host busy) surfaces here as `SignalingClient.Error.http`
            // like any other non-2xx response — logged, cooled down, and
            // retried once the cooldown expires; never cached as a
            // PERMANENT failure.
            Self.logger.warning("negotiation with host \(host.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await connection.close()
            return fail(host: host)
        }

        // No `await` between this check and registration below — see
        // `invalidatedAttempts`' doc comment for why that makes this
        // check race-free against a concurrent `invalidate(host:)`. This
        // is an intentional teardown, not a failure, so no cooldown.
        guard !invalidatedAttempts.contains(attemptID) else {
            await connection.close()
            return nil
        }

        liveConnections[host.id] = connection

        // Register-then-verify: the line above and this `await` are NOT
        // in the same uninterrupted stretch — this is a genuine new
        // suspension point, unlike the no-await check right before it.
        // Reasoning through what a concurrent `invalidate(host:)` sees if
        // it lands in EXACTLY this gap: registration already happened
        // (`liveConnections[host.id]` is visible), so `invalidate` takes
        // its normal live-connection branch — `removeValue` + `close` —
        // rather than the in-flight-attempt branch. That's coherent: the
        // connection gets torn down either way, just via the ordinary
        // path instead of `invalidatedAttempts`. What THIS check guards
        // against is different — a connection that went terminal on its
        // own (ICE failed, DataChannel closed) in the gap between
        // `applyAnswer` succeeding and this line, independent of any
        // `invalidate` call.
        let state = await connection.state
        if state.isTerminal {
            evict(hostID: host.id, connectionIdentity: connectionIdentity)
            await connection.close()
            return fail(host: host)
        }

        return connection
    }

    /// Starts (or refreshes) `host`'s failure cooldown and returns `nil`
    /// — the common tail of every FAILURE exit from `negotiate`. Not
    /// called for the "invalidated mid-flight" exit, which is an
    /// intentional teardown rather than a failure (see call site).
    private func fail(host: Host) -> RemoteHostConnection? {
        cooldownUntil[host.id] = now().addingTimeInterval(Self.failureCooldown)
        return nil
    }

    /// Removes `hostID`'s live connection if — and only if — it is still
    /// the exact connection identified by `connectionIdentity`. Guards
    /// against a stale terminal notification from a connection that was
    /// already evicted and replaced (e.g. a slow `.failed` report that
    /// lands after a newer negotiation for the same host already
    /// succeeded) from evicting the newer, live connection out from
    /// under a caller. `internal` (not `private`) so the guard itself is
    /// directly testable via `@testable import`.
    func evict(hostID: UUID, connectionIdentity: ObjectIdentifier) {
        guard
            let current = liveConnections[hostID],
            ObjectIdentifier(current) == connectionIdentity
        else {
            return
        }
        liveConnections.removeValue(forKey: hostID)
    }

    /// Test-only seam: seeds the registry directly, bypassing a real
    /// negotiation. Used by the stale-eviction-guard test to set up a
    /// KNOWN "newer" connection before exercising `evict` with a stale
    /// identity — `internal` so it's reachable via `@testable import`
    /// without being part of the public API.
    func registerLiveConnectionForTesting(_ connection: RemoteHostConnection, hostID: UUID) {
        liveConnections[hostID] = connection
    }
}
#endif
