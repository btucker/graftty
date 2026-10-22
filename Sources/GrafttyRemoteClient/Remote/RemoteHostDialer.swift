#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
import Foundation
import GrafttyProtocol

/// The signed SDP exchange shared by the Mac-to-Mac registry and the mobile
/// coordinator. Attempt tracking, eviction and failure policy stay with each
/// caller.
public enum RemoteHostDialer {
    /// Creates an offer on `link`, exchanges it with the pinned host over the
    /// first reachable route, and applies the answer. `checkpoint` runs on the
    /// caller's actor after each step so a superseded attempt stops before its
    /// next network round trip.
    ///
    /// Returns the pin refreshed with the routes, winning route and
    /// wake-on-LAN details the host just signed. Nothing is persisted; see
    /// `persistRefreshedPin`.
    public static func negotiate(
        _ link: some WebRTCHostLink,
        signaling: SignalingClient,
        pinnedHost: PinnedHost,
        routes: [RemoteConnectionRoute],
        clientKey: Curve25519.Signing.PrivateKey,
        clientDeviceID: RemoteDeviceID,
        replacingExistingConnection: Bool,
        connectedAt now: () -> Date,
        isolation: isolated (any Actor)? = #isolation,
        checkpoint: () throws -> Void = {}
    ) async throws -> PinnedHost {
        let offerSDP = try await link.createOfferSDP()
        try checkpoint()
        let exchange = try await signaling.authenticatedExchange(
            routes: routes,
            hostDeviceID: pinnedHost.id,
            hostPublicKey: pinnedHost.publicKey,
            clientDeviceID: clientDeviceID,
            clientKey: clientKey,
            sdp: offerSDP,
            replacesExistingConnection: replacingExistingConnection,
            wakeOnLAN: pinnedHost.wakeOnLAN
        )
        try checkpoint()
        try await link.applyAnswerSDP(exchange.answer.sdp)
        try checkpoint()
        var refreshed = pinnedHost
        refreshed.routes = exchange.answer.routes
        refreshed.lastSuccessfulRoute = exchange.route
        refreshed.wakeOnLAN = exchange.wakeOnLAN
        refreshed.lastConnectedAt = now()
        return refreshed
    }

    /// Saves a pin refreshed by a successful connection. A missing pin means
    /// trust was revoked while negotiation was in flight, so that error is
    /// rethrown to fail the connection; any other store failure is only
    /// reported, because the connection itself is usable.
    public static func persistRefreshedPin(
        _ pin: PinnedHost,
        using update: (PinnedHost) throws -> Void,
        onFailure: (any Error) -> Void
    ) throws {
        do {
            try update(pin)
        } catch PinnedHostStore.Error.notFound {
            throw PinnedHostStore.Error.notFound
        } catch {
            onFailure(error)
        }
    }
}
