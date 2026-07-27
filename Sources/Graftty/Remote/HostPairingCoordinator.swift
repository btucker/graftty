import Combine
import Foundation
import GrafttyKit
import GrafttyProtocol

// MARK: - HostPairingCoordinator

/// Host-side pairing coordinator: the single object the Mac settings UI
/// binds to for the device-pairing ceremony.
///
/// Owns the whole pairing stack for one session — `HostPairingSession`
/// (state machine), `HostPairingServer` (async adapter), and
/// `PairingHTTPServer` (ephemeral LAN listener) — plus the 1s tick task
/// that drives expiry (`HostPairingServer.start` requires an external
/// `tick()`; this task is that driver, there is no parallel expiry
/// mechanism). On any terminal state the tick task calls `endPairing()`,
/// which stops the listener — upholding REMOTE-1.4's guarantee that the
/// pairing endpoint only accepts connections while a session is active.
@MainActor
public final class HostPairingCoordinator: ObservableObject {

    // MARK: Published state

    /// The current pairing-session state, refreshed by the tick task and
    /// after every UI action.
    @Published public private(set) var state: HostPairingSessionState = .idle

    /// The QR payload to display while `.awaitingClient`, `nil`
    /// otherwise. Derived from `state` rather than stored separately —
    /// the two could never disagree in practice, since every write site
    /// updated both together.
    public var payload: PairingPayload? {
        if case .awaitingClient(let payload, _) = state {
            return payload
        }
        return nil
    }

    /// Human-readable description of the most recent failure, or `nil`.
    @Published public private(set) var lastError: String?

    // MARK: Dependencies

    private let identityStore: HostIdentityStore
    private let trustedPeerStore: TrustedPeerStore
    private let deviceIDStore: HostDeviceIDStore
    private let hostDisplayName: String
    private let admission: HostPairingAdmission
    // `@MainActor`-isolated (not merely `@Sendable`) so the Mac settings UI
    // can capture `WebServerController` — a `@MainActor`-isolated,
    // non-`Sendable` class — directly. `beginPairing()` runs on this same
    // actor, so invoking the provider there is a same-actor call, not a
    // hop.
    private let webBaseURLProvider: @MainActor @Sendable () -> URL?

    // MARK: Session plumbing

    private var pairingServer: HostPairingServer?
    private var httpServer: PairingHTTPServer?
    private var tickTask: Task<Void, Never>?
    private var admissionLease: HostPairingAdmission.Lease?

    /// Bumped synchronously at the entry of both `beginPairing()` and
    /// `endPairing()`. `beginPairing()` captures its own generation
    /// before its first `await` and re-checks it after each one — if a
    /// concurrent `endPairing()` (or a newer `beginPairing()`) has since
    /// bumped the generation, this call's listener/session are stale:
    /// tear down the just-created `http`/`server` locally and return
    /// without ever assigning `self.httpServer`/`self.pairingServer`.
    /// Without this, `endPairing()` during the bind window sees nil
    /// fields, no-ops, and the listener that resumes afterward orphans
    /// for up to the session's ~300s validity.
    private var sessionGeneration = 0

    /// Test-only hook, awaited right after `http.start()` resolves and
    /// before the post-bind generation check. Mirrors
    /// `PairingHTTPServer.startResumeGateForTesting`: production's only
    /// real suspension in this window is the listener bind itself; this
    /// hook widens that same window so tests can park `beginPairing()`
    /// there deterministically to drive the same category of
    /// begin/end interleaving `sessionGeneration` guards against. `nil`
    /// (the default) is a no-op.
    var beginPairingResumeGateForTesting: (() async -> Void)?

    enum CoordinatorError: Swift.Error {
        case pairingURLConstructionFailed(host: String, port: Int)
    }

    // MARK: Init

    public convenience init(
        identityStore: HostIdentityStore,
        trustedPeerStore: TrustedPeerStore,
        deviceIDStore: HostDeviceIDStore,
        hostDisplayName: String,
        webBaseURLProvider: @escaping @MainActor @Sendable () -> URL?
    ) {
        self.init(
            identityStore: identityStore,
            trustedPeerStore: trustedPeerStore,
            deviceIDStore: deviceIDStore,
            hostDisplayName: hostDisplayName,
            webBaseURLProvider: webBaseURLProvider,
            admission: HostPairingAdmission()
        )
    }

    init(
        identityStore: HostIdentityStore,
        trustedPeerStore: TrustedPeerStore,
        deviceIDStore: HostDeviceIDStore,
        hostDisplayName: String,
        webBaseURLProvider: @escaping @MainActor @Sendable () -> URL?,
        admission: HostPairingAdmission
    ) {
        self.identityStore = identityStore
        self.trustedPeerStore = trustedPeerStore
        self.deviceIDStore = deviceIDStore
        self.hostDisplayName = hostDisplayName
        self.webBaseURLProvider = webBaseURLProvider
        self.admission = admission
    }

    // MARK: - UI actions

    /// Starts a pairing ceremony: brings up the LAN listener, builds a
    /// fresh session whose QR payload advertises
    /// `http://<primaryLANIPv4>:<boundPort>/v1/pairing`, publishes the
    /// payload, and starts the 1s tick task that drives expiry and
    /// terminal-state cleanup. Any previously active pairing is ended
    /// first. Failures land in `lastError`.
    public func beginPairing() async {
        // Bumped before `endPairing()` runs its own (synchronous) bump,
        // so this call's claim is current the moment `endPairing()`
        // returns — see `sessionGeneration`'s doc comment.
        sessionGeneration += 1
        await endPairing()
        let myGeneration = sessionGeneration
        lastError = nil
        guard let lease = admission.acquire() else {
            lastError = "Another pairing session is already active."
            return
        }
        admissionLease = lease
        do {
            let hostDeviceID = try deviceIDStore.loadOrGenerateAndPersist()
            // REMOTE-1.1: the identity key must exist before the session
            // will accept pairing requests; create it on first use.
            _ = try identityStore.loadOrGenerateAndPersist()

            // The session's `pairingURLProvider` must exist before the
            // listener (session → server → listener construction order),
            // but the URL is only known after the listener binds. This
            // plain local `var` breaks the cycle: it's captured by
            // reference (standard Swift closure semantics), written once
            // below after `http.start()` returns the bound port, and
            // read exactly once when `server.start()` first invokes the
            // provider — both strictly sequential on this actor, so no
            // lock is needed.
            var pairingURL = URL(string: "http://127.0.0.1\(PairingRoutes.basePath)")!
            let session = HostPairingSession(
                identityStore: identityStore,
                peerStore: trustedPeerStore,
                hostDeviceID: hostDeviceID,
                hostKind: .mac,
                hostDisplayName: hostDisplayName,
                webBaseURL: webBaseURLProvider(),
                pairingURLProvider: { pairingURL }
            )
            let server = HostPairingServer(session: session)
            let http = PairingHTTPServer(pairingServer: server)
            let boundPort = try await http.start()
            await beginPairingResumeGateForTesting?()
            // A concurrent `endPairing()` (or a newer `beginPairing()`)
            // that ran while we were suspended binding the listener has
            // bumped `sessionGeneration` — our fields are stale before
            // we ever publish them. Tear down this call's own `http`
            // locally and bail without touching `self.httpServer`/
            // `self.pairingServer`, rather than resuming into a live
            // listener the caller believes was stopped.
            guard sessionGeneration == myGeneration else {
                await http.stop()
                releaseAdmission(lease)
                return
            }
            do {
                // Fall back to loopback when no LAN interface is up so
                // same-machine flows (and tests) still work; a phone
                // can't reach it, but neither could any other address.
                let lanHost = LANAddress.primaryIPv4() ?? "127.0.0.1"
                var components = URLComponents()
                components.scheme = "http"
                components.host = lanHost
                components.port = boundPort
                components.path = PairingRoutes.basePath
                guard let resolvedURL = components.url else {
                    throw CoordinatorError.pairingURLConstructionFailed(host: lanHost, port: boundPort)
                }
                pairingURL = resolvedURL

                _ = try await server.start(validFor: PairingProtocolDefaults.sessionValidity)
                guard sessionGeneration == myGeneration else {
                    await http.stop()
                    releaseAdmission(lease)
                    return
                }
                self.pairingServer = server
                self.httpServer = http
                applyState(await server.currentState())
                startTicking(server: server)
            } catch {
                await http.stop()
                throw error
            }
        } catch {
            releaseAdmission(lease)
            lastError = "\(error)"
        }
    }

    /// User confirmed the verification code: persists the introduced
    /// peer (REMOTE-1.3) and publishes the resulting state. The tick
    /// task observes the terminal `.confirmed` state and tears the
    /// listener down.
    public func confirm() async {
        guard let server = pairingServer else { return }
        do {
            try await server.confirm()
        } catch {
            lastError = "\(error)"
        }
        applyState(await server.currentState())
    }

    /// User denied the pairing request. Nothing is persisted; the tick
    /// task observes the terminal `.denied` state and tears down.
    public func deny() async {
        guard let server = pairingServer else { return }
        await server.deny()
        applyState(await server.currentState())
    }

    /// Cancels the session AND stops the listener (also called on
    /// terminal states from the tick task) — REMOTE-1.4's guarantee
    /// that the pairing endpoint is only reachable while a session is
    /// active. Safe to call when nothing is in progress.
    public func endPairing() async {
        sessionGeneration += 1
        let lease = admissionLease
        tickTask?.cancel()
        tickTask = nil
        if let server = pairingServer {
            // No-op when the session already reached a terminal state,
            // so a post-confirm teardown doesn't clobber `.confirmed`.
            await server.cancel()
            applyState(await server.currentState())
        }
        if let http = httpServer {
            await http.stop()
        }
        pairingServer = nil
        httpServer = nil
        if let lease {
            releaseAdmission(lease)
        }
    }

    // MARK: - Tick task

    /// Drives `HostPairingServer.tick()` every second — the designed
    /// external expiry driver — refreshes the published state, and ends
    /// the pairing (stopping the listener) once a terminal state is
    /// reached.
    private func startTicking(server: HostPairingServer) {
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                await server.tick()
                let current = await server.currentState()
                guard let self else { return }
                self.applyState(current)
                if current.isTerminal {
                    // endPairing cancels this task; teardown still runs
                    // to completion because none of its awaits are
                    // cancellation points that abort actor calls.
                    await self.endPairing()
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    private func applyState(_ newState: HostPairingSessionState) {
        state = newState
    }

    private func releaseAdmission(_ lease: HostPairingAdmission.Lease) {
        if admissionLease == lease {
            admissionLease = nil
        }
        admission.release(lease)
    }

}
