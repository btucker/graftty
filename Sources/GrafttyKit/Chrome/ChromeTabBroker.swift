import Foundation
import GrafttyProtocol

public protocol ChromeTabBackend: Sendable {
    func perform(_ action: ChromeTabAction, authorize: @escaping @Sendable () async -> Bool) async throws -> ChromeTabState
    func stopCapture() async
}


/// Owns profiles independently of SSH/WebRTC viewer lifetimes.
public actor ChromeTabBroker {
    public typealias Authorize = @Sendable (_ target: String, _ authenticatedPeerID: String) async -> String?
    private let authorize: Authorize
    private let makeBackend: @Sendable (String) -> any ChromeTabBackend
    private var backends: [String: any ChromeTabBackend] = [:]
    private var busy: Set<String> = []
    private var closing: Set<String> = []
    private struct Lease {
        let viewerID: UUID
        let target: String
        let peerID: String
    }
    private var viewers: [String: Lease] = [:]

    public init(authorize: @escaping Authorize, makeBackend: @escaping @Sendable (String) -> any ChromeTabBackend) {
        self.authorize = authorize; self.makeBackend = makeBackend
    }

    /// TerminalSessionHandler appends one full UUID to the authenticated device ID.
    public nonisolated static func ownsDisplay(clientID: String?, peerID: String) -> Bool {
        guard let clientID else { return false }
        let prefix = "ssh-\(peerID)-"
        guard clientID.hasPrefix(prefix) else { return false }
        let suffix = String(clientID.dropFirst(prefix.count))
        return suffix.count == 36 && UUID(uuidString: suffix) != nil
    }

    public func handle(_ request: ChromeTabRequest, peerID: String, viewerID: UUID) async -> ChromeTabResponse {
        guard !Task.isCancelled, !request.target.isEmpty, request.target.utf8.count <= 256,
              request.action.isValid else { return .init(error: "Invalid Chrome request.") }
        guard let scope = await authorize(request.target, peerID), !Task.isCancelled else {
            await disconnect(viewerID: viewerID)
            return .init(error: "Take control of a live local pane before opening Chrome.")
        }
        guard !closing.contains(scope) else { return .init(error: "Chrome viewer is disconnecting. Try again.") }
        if let previous = viewers[scope], previous.viewerID != viewerID {
            if await authorize(previous.target, previous.peerID) != scope { await disconnect(viewerID: previous.viewerID) }
            else { return .init(error: "Another viewer controls this Chrome profile.") }
        }
        guard viewers[scope] == nil || viewers[scope]?.viewerID == viewerID else { return .init(error: "Chrome viewer changed. Try again.") }
        guard busy.insert(scope).inserted else { return .init(error: "Chrome is busy. Try again.") }
        defer { busy.remove(scope) }
        if backends[scope] == nil {
            switch request.action {
            case .launch, .launchOffer: break
            default: return .init(state: .init())
            }
            guard backends.count < 4 else { return .init(error: "The prototype supports four active Chrome profiles.") }
            backends[scope] = makeBackend(scope)
        }
        viewers[scope] = Lease(viewerID: viewerID, target: request.target, peerID: peerID)
        do {
            try Task.checkCancellation()
            guard await authorized(request, peerID: peerID, viewerID: viewerID, scope: scope) else { await disconnect(viewerID: viewerID); return .init(error: "Pane ownership changed.") }
            let state = try await backends[scope]!.perform(request.action, authorize: { [self] in
                await authorized(request, peerID: peerID, viewerID: viewerID, scope: scope)
            })
            try Task.checkCancellation()
            guard await authorized(request, peerID: peerID, viewerID: viewerID, scope: scope) else { await disconnect(viewerID: viewerID); return .init(error: "Pane ownership changed.") }
            guard state.tabs.count <= 32, state.frame?.jpeg.count ?? 0 <= ChromeTabFrame.maximumJPEGBytes else {
                return .init(error: "Chrome response exceeds prototype limits.")
            }
            return .init(state: state)
        } catch {
            if await authorize(request.target, peerID) != scope || Task.isCancelled { await disconnect(viewerID: viewerID) }
            return .init(error: String(describing: error))
        }
    }
    private func authorized(_ request: ChromeTabRequest, peerID: String, viewerID: UUID, scope: String) async -> Bool {
        guard !Task.isCancelled, !closing.contains(scope), viewers[scope]?.viewerID == viewerID,
              await authorize(request.target, peerID) == scope else { return false }
        return !Task.isCancelled && !closing.contains(scope) && viewers[scope]?.viewerID == viewerID
    }

    public func disconnect(viewerID: UUID) async {
        let scopes = viewers.filter { $0.value.viewerID == viewerID }.map(\.key)
        for scope in scopes {
            guard closing.insert(scope).inserted else { continue }
            viewers[scope] = nil
            await backends[scope]?.stopCapture()
            closing.remove(scope)
        }
    }

}
