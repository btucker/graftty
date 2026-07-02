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
/// `inFlightNegotiations`) is read and mutated from UI call sites
/// (Task 3's `RootView`) with no synchronization of its own — actor
/// isolation is that synchronization. Every mutation site in this file
/// is synchronous up to its first `await`, which is what makes the
/// dedup check-then-insert on `inFlightNegotiations` atomic: two
/// concurrent calls to `connection(for:)` for the same host are always
/// processed one at a time by the MainActor's serial executor, so the
/// second call is guaranteed to observe the first call's freshly-stored
/// `Task` before it has a chance to start its own.
@MainActor
public final class RemoteConnectionCoordinator: ObservableObject {

    private let identityStore: ClientIdentityStore
    private let deviceIDStore: ClientDeviceIDStore
    private let pinnedHostStore: PinnedHostStore
    private let signaling: SignalingClient
    private let connectionFactory: (Curve25519.Signing.PrivateKey, RemoteIdentityFingerprint) -> RemoteHostConnection

    /// Successfully negotiated, still-live connections, keyed by `Host.id`.
    private var liveConnections: [UUID: RemoteHostConnection] = [:]

    /// At most one in-flight negotiation `Task` per host. Concurrent
    /// callers for the same host await this same `Task` instead of
    /// starting a second negotiation (and, downstream, a second
    /// `POST /v1/rtc/offer` — which would hit `WebRTCHostAgent`'s own
    /// `HostError.busy` guard on the host side).
    private var inFlightNegotiations: [UUID: Task<RemoteHostConnection?, Never>] = [:]

    /// Hosts whose `invalidate(host:)` call landed while a negotiation
    /// for that host was still in flight — i.e. scenePhase flapping
    /// (background → foreground → background) fast enough that a
    /// foreground rebuild's negotiation hadn't finished before the next
    /// background teardown fired. `negotiate(host:pinnedHost:)` consults
    /// this set in the same uninterrupted (no-`await`) stretch where it
    /// would otherwise register the freshly negotiated connection, so
    /// EVERY awaiter of that negotiation (the original caller and any
    /// concurrent dedup'd callers via `inFlightNegotiations`) observes
    /// the same `nil` outcome — closing the connection instead of
    /// resurrecting one the app already asked to tear down.
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
    private var invalidatedWhileInFlight: Set<UUID> = []

    private static let logger = Logger(
        subsystem: "com.quotably.graftty",
        category: "remote-connection-coordinator"
    )

    /// `directory` mirrors the one-directory construction pattern used by
    /// `PairDeviceFlowView.buildModel`: the client identity key, the
    /// client's stable device ID, and the pinned-host records all live
    /// as sibling files under the same directory.
    ///
    /// `connectionFactory` is a test seam — tests substitute a closure
    /// that records invocations (to assert negotiate-once dedup) while
    /// still returning a real `RemoteHostConnection` (there's no
    /// protocol to mock: the type is a concrete `actor` wrapping the
    /// WebRTC SDK). `nil` (production default) builds the connection
    /// directly.
    public init(
        directory: URL = ClientIdentityStore.defaultDirectory,
        signaling: SignalingClient = SignalingClient(),
        connectionFactory: ((Curve25519.Signing.PrivateKey, RemoteIdentityFingerprint) -> RemoteHostConnection)? = nil
    ) {
        self.identityStore = ClientIdentityStore(directory: directory)
        self.deviceIDStore = ClientDeviceIDStore(directory: directory)
        self.pinnedHostStore = PinnedHostStore(directory: directory)
        self.signaling = signaling
        self.connectionFactory = connectionFactory ?? { clientKey, expectedHostFingerprint in
            RemoteHostConnection(clientKey: clientKey, expectedHostFingerprint: expectedHostFingerprint)
        }
    }

    /// Returns a live connection for `host`, negotiating one if none
    /// exists yet. Returns `nil` fast when `host` isn't paired
    /// (`remoteDeviceID` is `nil`, or `PinnedHostStore` has no matching
    /// entry) and `nil` when negotiation fails for any reason — callers
    /// fall back to `/ws` in both cases and cannot tell them apart,
    /// which is intentional: neither case should ever crash the caller.
    public func connection(for host: Host) async -> RemoteHostConnection? {
        guard let pinnedHost = pinnedHost(for: host) else { return nil }

        if let live = liveConnections[host.id] {
            return live
        }
        if let inFlight = inFlightNegotiations[host.id] {
            return await inFlight.value
        }

        let task = Task<RemoteHostConnection?, Never> { [weak self] in
            await self?.negotiate(host: host, pinnedHost: pinnedHost)
        }
        inFlightNegotiations[host.id] = task
        let result = await task.value
        // Safe to clear unconditionally: while this entry is non-nil, every
        // OTHER concurrent caller takes the `inFlight.value` branch above
        // instead of storing a new Task, so nothing can have overwritten
        // this dictionary slot between `await task.value` resuming and this
        // line running (no suspension point in between).
        inFlightNegotiations[host.id] = nil
        return result
    }

    /// Evicts and closes the live connection for `host`, if any. Used by
    /// background teardown and reconnect paths that need to force a
    /// fresh negotiation on next use.
    ///
    /// If a negotiation for `host` is still in flight (IPAD-5.1 fired
    /// mid-`IPAD-5.2` rebuild), there is no live connection to remove
    /// yet — instead this marks the host in `invalidatedWhileInFlight`
    /// so `negotiate(host:pinnedHost:)` self-evicts the moment that
    /// negotiation finishes, rather than silently registering a
    /// connection the app already asked to tear down.
    public func invalidate(host: Host) async {
        if inFlightNegotiations[host.id] != nil {
            invalidatedWhileInFlight.insert(host.id)
        }
        guard let connection = liveConnections.removeValue(forKey: host.id) else { return }
        await connection.close()
    }

    /// Single source of truth for "is `host` paired" — the same
    /// two-part check `connection(for:)` performs before ever attempting
    /// to negotiate (a non-nil `remoteDeviceID` AND a matching
    /// `PinnedHostStore` entry). `SingleSessionView.remoteFallbackSeverity`
    /// reads this so its `/ws`-fallback log-level gate can't drift from
    /// the coordinator's actual pairing gate.
    public func isPaired(_ host: Host) -> Bool {
        pinnedHost(for: host) != nil
    }

    private func pinnedHost(for host: Host) -> PinnedHost? {
        guard let remoteDeviceID = host.remoteDeviceID else { return nil }
        return (try? pinnedHostStore.get(id: remoteDeviceID)) ?? nil
    }

    /// Full negotiation body: build the connection, wire the terminal-state
    /// observer BEFORE `createOffer()` (so no drop between construction and
    /// observation), exchange SDP via `signaling`, and register on success.
    /// Any failure — including a `503`/busy signaling response — closes the
    /// half-built connection and returns `nil` without touching the
    /// registry, so the host is free to retry on the very next call.
    private func negotiate(host: Host, pinnedHost: PinnedHost) async -> RemoteHostConnection? {
        // One-shot per attempt: cleared here regardless of outcome so a
        // FUTURE negotiation for this host starts with a clean flag.
        defer { invalidatedWhileInFlight.remove(host.id) }
        guard let clientKey = try? identityStore.loadOrGenerateAndPersist() else {
            Self.logger.warning("no client identity available; cannot negotiate with host \(host.id, privacy: .public)")
            return nil
        }
        guard let clientDeviceID = try? deviceIDStore.loadOrGenerateAndPersist() else {
            Self.logger.warning("no client device id available; cannot negotiate with host \(host.id, privacy: .public)")
            return nil
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
            // like any other non-2xx response — logged and retried on the
            // next call, never cached as a permanent failure.
            Self.logger.warning("negotiation with host \(host.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            await connection.close()
            return nil
        }

        // No `await` between this check and registration below — see
        // `invalidatedWhileInFlight`'s doc comment for why that makes
        // this check race-free against a concurrent `invalidate(host:)`.
        guard !invalidatedWhileInFlight.contains(host.id) else {
            await connection.close()
            return nil
        }

        liveConnections[host.id] = connection
        return connection
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
