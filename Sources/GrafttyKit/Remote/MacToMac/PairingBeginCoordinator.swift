import Foundation
import GrafttyProtocol

/// Serializes LAN pairing begin requests before they reach
/// `HostPairingServer.start(validFor:)`, which otherwise restarts an
/// active pairing session.
public actor PairingBeginCoordinator {
    public typealias RoutesProvider =
        @Sendable (URL) async -> [RemoteConnectionRoute]

    private let server: HostPairingServer
    private let routesProvider: RoutesProvider
    private var startInFlight = false

    public init(
        server: HostPairingServer,
        routesProvider: @escaping RoutesProvider = {
            await RemoteAccessRouteDiscovery.routes(lanBaseURL: $0)
        }
    ) {
        self.server = server
        self.routesProvider = routesProvider
    }

    public func startIfIdle(
        validFor: TimeInterval,
        lanBaseURL: URL
    ) async -> Result<PairingPayload, PairingErrorResponse> {
        guard !startInFlight else {
            return .failure(Self.busyError())
        }
        startInFlight = true
        defer { startInFlight = false }

        await server.tick()
        let state = await server.currentState()
        guard !Self.isActivePairingState(state) else {
            return .failure(Self.busyError())
        }

        do {
            let routes = await routesProvider(Self.baseURL(fromPairingURL: lanBaseURL))
            let payload = try await server.start(
                validFor: validFor,
                pairingURL: lanBaseURL,
                connectionRoutes: routes
            )
            return .success(payload)
        } catch {
            return .failure(PairingErrorResponse(
                code: .internalError,
                error: "failed to begin pairing: \(error)"
            ))
        }
    }

    private static func isActivePairingState(_ state: HostPairingSessionState) -> Bool {
        switch state {
        case .awaitingClient, .pendingConfirmation:
            return true
        case .idle, .confirmed, .denied, .cancelled, .expired, .failed:
            return false
        }
    }

    private static func baseURL(fromPairingURL pairingURL: URL) -> URL {
        guard
            var components = URLComponents(
                url: pairingURL,
                resolvingAgainstBaseURL: false
            )
        else {
            return pairingURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? pairingURL
    }

    private static func busyError() -> PairingErrorResponse {
        PairingErrorResponse(
            code: .pairingBusy,
            error: "pairing session already active"
        )
    }
}
