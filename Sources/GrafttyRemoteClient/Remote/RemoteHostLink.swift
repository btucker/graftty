import Foundation
import GrafttyProtocol
#if canImport(WebRTC)
import WebRTC
#endif

/// The authenticated SSH surface both host transports expose once connected.
/// `RemoteHostConnection` (WebRTC) and `DirectSSHHostConnection` (TCP)
/// conform directly; the Mac-to-Mac registry and its tests depend only on
/// this protocol and the two dialing refinements below.
public protocol RemoteHostLink: PanesStateDriverMaking {
    var state: RemoteHostConnectionState { get async }
    func setOnStateChange(
        _ handler: (@Sendable (RemoteHostConnectionState) -> Void)?
    ) async
    func makePaneControlDriver() async throws -> any PaneControlChannelDriver
    func makeWorktreeManagementDriver() async throws -> any WorktreeManagementChannelDriver
    func makeTeamClient(
        handler: @escaping TeamRPCSession.Handler,
        onClose: @escaping @Sendable () async -> Void
    ) async throws -> TeamChannelClient
    func openTerminalClient(
        sessionName: String,
        preferPaged: Bool
    ) async throws -> any WebSocketClient & Sendable
    #if canImport(Network)
    func forwardLocalPort(host: String, port: Int) async throws -> LocalPortForward
    #endif
    func close() async
}

/// Optional parent-service channel on an existing authenticated link. Borrowers
/// own this channel, not the interactive link's lifetime or state observer.
public protocol MCPHostLink: RemoteHostLink {
    func makeMCPControlClient(handler: @escaping TeamRPCSession.Handler,
                              onClose: @escaping @Sendable () async -> Void) async throws -> TeamChannelClient
}

extension DirectSSHHostConnection: MCPHostLink {}
#if canImport(WebRTC)
extension RemoteHostConnection: MCPHostLink {}
#endif

/// A link dialed by exchanging a signed SDP offer and answer.
public protocol WebRTCHostLink: RemoteHostLink {
    func createOfferSDP() async throws -> String
    func applyAnswerSDP(_ sdp: String) async throws
}

/// A link dialed over a direct TCP endpoint.
public protocol DirectHostLink: RemoteHostLink {
    func connect(host: String, port: Int) async throws
}

extension RemoteHostLink {
    /// Reports only failed or closed transitions. Installs the link's single
    /// state-change handler, replacing any earlier one;
    /// `setOnStateChange(nil)` removes it.
    public func observeTerminalState(
        _ handler: @escaping @Sendable (RemoteHostConnectionState) -> Void
    ) async {
        await setOnStateChange { state in
            if state.isTerminal { handler(state) }
        }
    }

    /// Sends one request on its own worktree-management channel, closing the
    /// channel however the request ends.
    public func sendWorktreeManagement(
        _ request: WorktreeManagementRequest
    ) async throws -> WorktreeManagementResponse {
        let driver = try await makeWorktreeManagementDriver()
        defer { driver.close() }
        try await driver.open()
        return try await driver.send(request)
    }
}

extension DirectSSHHostConnection: DirectHostLink {
    public func makePaneControlDriver() throws -> any PaneControlChannelDriver {
        try makePaneControlClient()
    }

    public func makeWorktreeManagementDriver() throws -> any WorktreeManagementChannelDriver {
        try makeWorktreeManagementClient()
    }

    public func openTerminalClient(
        sessionName: String,
        preferPaged: Bool
    ) async throws -> any WebSocketClient & Sendable {
        try await openTerminalSession(sessionName: sessionName, preferPaged: preferPaged)
    }
}

#if canImport(WebRTC)
extension RemoteHostConnection: WebRTCHostLink {
    public func createOfferSDP() async throws -> String {
        try await createOffer().sdp
    }

    public func applyAnswerSDP(_ sdp: String) async throws {
        try await applyAnswer(RTCSessionDescription(type: .answer, sdp: sdp))
    }

    public func makePaneControlDriver() throws -> any PaneControlChannelDriver {
        try makePaneControlClient()
    }

    public func makeWorktreeManagementDriver() throws -> any WorktreeManagementChannelDriver {
        try makeWorktreeManagementClient()
    }

    public func openTerminalClient(
        sessionName: String,
        preferPaged: Bool
    ) async throws -> any WebSocketClient & Sendable {
        try await openTerminalSession(sessionName: sessionName, preferPaged: preferPaged)
    }
}
#endif
