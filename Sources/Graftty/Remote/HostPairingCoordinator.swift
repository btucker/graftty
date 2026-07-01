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

    /// The QR payload to display; set while `.awaitingClient`, cleared
    /// once the client has introduced itself or the session ends.
    @Published public private(set) var payload: PairingPayload?

    /// Human-readable description of the most recent failure, or `nil`.
    @Published public private(set) var lastError: String?

    // MARK: Dependencies

    private let identityStore: HostIdentityStore
    private let trustedPeerStore: TrustedPeerStore
    private let deviceIDStore: HostDeviceIDStore
    private let hostDisplayName: String
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

    enum CoordinatorError: Swift.Error {
        case pairingURLConstructionFailed(host: String, port: Int)
    }

    /// The session's `pairingURLProvider` must exist before the listener
    /// (session → server → listener construction order), but the URL is
    /// only known after the listener binds. This locked box breaks the
    /// cycle: `beginPairing` fills it after `start()` returns the bound
    /// port and before `server.start()` first invokes the provider, so
    /// the placeholder never reaches a payload.
    private final class PairingURLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _url = URL(string: "http://127.0.0.1/v1/pairing")!
        var url: URL {
            get { lock.lock(); defer { lock.unlock() }; return _url }
            set { lock.lock(); defer { lock.unlock() }; _url = newValue }
        }
    }

    // MARK: Init

    public init(
        identityStore: HostIdentityStore,
        trustedPeerStore: TrustedPeerStore,
        deviceIDStore: HostDeviceIDStore,
        hostDisplayName: String,
        webBaseURLProvider: @escaping @MainActor @Sendable () -> URL?
    ) {
        self.identityStore = identityStore
        self.trustedPeerStore = trustedPeerStore
        self.deviceIDStore = deviceIDStore
        self.hostDisplayName = hostDisplayName
        self.webBaseURLProvider = webBaseURLProvider
    }

    // MARK: - UI actions

    /// Starts a pairing ceremony: brings up the LAN listener, builds a
    /// fresh session whose QR payload advertises
    /// `http://<primaryLANIPv4>:<boundPort>/v1/pairing`, publishes the
    /// payload, and starts the 1s tick task that drives expiry and
    /// terminal-state cleanup. Any previously active pairing is ended
    /// first. Failures land in `lastError`.
    public func beginPairing() async {
        await endPairing()
        lastError = nil
        do {
            let hostDeviceID = try deviceIDStore.loadOrGenerateAndPersist()
            // REMOTE-1.1: the identity key must exist before the session
            // will accept pairing requests; create it on first use.
            _ = try identityStore.loadOrGenerateAndPersist()

            let urlBox = PairingURLBox()
            let session = HostPairingSession(
                identityStore: identityStore,
                peerStore: trustedPeerStore,
                hostDeviceID: hostDeviceID,
                hostKind: .mac,
                hostDisplayName: hostDisplayName,
                webBaseURL: webBaseURLProvider(),
                pairingURLProvider: { urlBox.url }
            )
            let server = HostPairingServer(session: session)
            let http = PairingHTTPServer(pairingServer: server)
            let boundPort = try await http.start()
            do {
                // Fall back to loopback when no LAN interface is up so
                // same-machine flows (and tests) still work; a phone
                // can't reach it, but neither could any other address.
                let lanHost = LANAddress.primaryIPv4() ?? "127.0.0.1"
                var components = URLComponents()
                components.scheme = "http"
                components.host = lanHost
                components.port = boundPort
                components.path = "/v1/pairing"
                guard let pairingURL = components.url else {
                    throw CoordinatorError.pairingURLConstructionFailed(host: lanHost, port: boundPort)
                }
                urlBox.url = pairingURL

                let payload = try await server.start(validFor: 300)
                self.pairingServer = server
                self.httpServer = http
                self.payload = payload
                applyState(await server.currentState())
                startTicking(server: server)
            } catch {
                await http.stop()
                throw error
            }
        } catch {
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
        payload = nil
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
                if Self.isTerminal(current) {
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
        if case .awaitingClient = newState {
            // QR stays visible while waiting for the client.
        } else if payload != nil {
            payload = nil
        }
    }

    private static func isTerminal(_ state: HostPairingSessionState) -> Bool {
        switch state {
        case .confirmed, .denied, .cancelled, .expired, .failed:
            return true
        case .idle, .awaitingClient, .pendingConfirmation:
            return false
        }
    }
}
