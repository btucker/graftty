import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@Suite("@spec REMOTE-13.31: When a client sends a worktree-management request over a remote host link, it shall open a dedicated worktree-management channel for that request and close the channel whether the open, the send, or neither fails.")
struct RemoteHostLinkWorktreeManagementTests {
    @Test func successfulRequestClosesItsChannel() async throws {
        let driver = ScriptedManagementDriver()
        let response = try await ManagementOnlyLink(driver: driver)
            .sendWorktreeManagement(.hostPresentation)
        #expect(response == .ok)
        #expect(driver.events == ["open", "send", "close"])
    }

    @Test func failedOpenStillClosesItsChannel() async throws {
        let driver = ScriptedManagementDriver(openError: WorktreeManagementChannelClient.ClientError.subsystemRejected)
        await #expect(throws: WorktreeManagementChannelClient.ClientError.self) {
            _ = try await ManagementOnlyLink(driver: driver).sendWorktreeManagement(.hostPresentation)
        }
        #expect(driver.events == ["open", "close"])
    }

    @Test func failedSendClosesItsChannel() async throws {
        let driver = ScriptedManagementDriver(sendError: WorktreeManagementChannelClient.ClientError.timedOut)
        await #expect(throws: WorktreeManagementChannelClient.ClientError.self) {
            _ = try await ManagementOnlyLink(driver: driver).sendWorktreeManagement(.hostPresentation)
        }
        #expect(driver.events == ["open", "send", "close"])
    }
}

private struct LinkUnused: Error {}

/// Implements only the management channel; every other channel is unused here.
private struct ManagementOnlyLink: RemoteHostLink {
    let driver: ScriptedManagementDriver

    var state: RemoteHostConnectionState { .connected }
    func setOnStateChange(_ handler: (@Sendable (RemoteHostConnectionState) -> Void)?) {}
    func makePanesStateDriver(originAware: Bool) throws -> any PanesStateSubscriptionDriver { throw LinkUnused() }
    func makePaneControlDriver() throws -> any PaneControlChannelDriver { throw LinkUnused() }
    func makeWorktreeManagementDriver() -> any WorktreeManagementChannelDriver { driver }
    func makeTeamClient(
        handler: @escaping TeamRPCSession.Handler,
        onClose: @escaping @Sendable () async -> Void
    ) throws -> TeamChannelClient { throw LinkUnused() }
    func openTerminalClient(sessionName: String, preferPaged: Bool) throws -> any WebSocketClient & Sendable {
        throw LinkUnused()
    }
    func forwardLocalPort(host: String, port: Int) throws -> LocalPortForward { throw LinkUnused() }
    func close() {}
}

private final class ScriptedManagementDriver: WorktreeManagementChannelDriver, @unchecked Sendable {
    private let lock = NSLock()
    private let openError: (any Error)?
    private let sendError: (any Error)?
    private var recorded: [String] = []

    init(openError: (any Error)? = nil, sendError: (any Error)? = nil) {
        self.openError = openError
        self.sendError = sendError
    }

    var events: [String] { lock.withLock { recorded } }

    func open() async throws {
        lock.withLock { recorded.append("open") }
        if let openError { throw openError }
    }

    func send(_ request: WorktreeManagementRequest) async throws -> WorktreeManagementResponse {
        lock.withLock { recorded.append("send") }
        if let sendError { throw sendError }
        return .ok
    }

    func close() {
        lock.withLock { recorded.append("close") }
    }
}
