import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@Suite("Subsystem RPC deadlines on the WebRTC event-loop type")
struct SubsystemRPCDeadlineTests {
    @Test("@spec REMOTE-11.23: If a pane-control or worktree-management RPC response does not arrive before its deadline, then the client shall fail that RPC with a timeout using elapsed time independently of the transport event-loop clock.")
    func paneControlResponseDeadlineUsesElapsedTime() async throws {
        let link = try await InMemorySSHLink.make { StalledSubsystemHost() }
        let client = PaneControlChannelClient(
            parentChannel: link.client,
            parentHandler: link.clientHandler,
            rpcDeadline: .milliseconds(50)
        )
        try await client.open()

        let outcome = await Self.bounded(onExpiry: { client.close() }) {
            try await client.send(.equalize(target: "pane"))
        }
        guard case .failure(PaneControlChannelClient.ClientError.timedOut) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            client.close()
            await link.close()
            return
        }
        client.close()
        await link.close()
    }

    @Test("a worktree-management response deadline fires on the WebRTC event-loop type and closes the channel")
    func worktreeManagementResponseDeadlineUsesElapsedTime() async throws {
        let link = try await InMemorySSHLink.make { StalledSubsystemHost() }
        let client = WorktreeManagementChannelClient(
            parentChannel: link.client,
            parentHandler: link.clientHandler,
            responseTimeout: .milliseconds(50)
        )
        try await client.open()

        let outcome = await Self.bounded(onExpiry: { client.close() }) {
            try await client.send(.open(worktreeID: "/tmp/w"))
        }
        guard case .failure(WorktreeManagementChannelClient.ClientError.timedOut) = outcome else {
            Issue.record("expected .timedOut, got \(outcome)")
            client.close()
            await link.close()
            return
        }
        // Poison-on-timeout: the wire has no request IDs, so a late reply
        // must never be paired with a later request.
        let next = await Self.bounded(onExpiry: { client.close() }) {
            try await client.send(.open(worktreeID: "/tmp/w"))
        }
        guard case .failure(WorktreeManagementChannelClient.ClientError.channelClosed) = next else {
            Issue.record("expected .channelClosed after the timeout, got \(next)")
            await link.close()
            return
        }
        await link.close()
    }

    private struct Watchdog: Error {}

    /// Runs `operation`, reporting `Watchdog` if it is still pending after
    /// two seconds, so a deadline that never fires fails instead of hanging.
    /// `onExpiry` must unblock `operation` (RPCs ignore task cancellation).
    private static func bounded<Value: Sendable>(
        onExpiry: @escaping @Sendable () -> Void,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, any Error> {
        await withTaskGroup(of: Result<Value, any Error>?.self) { group in
            group.addTask {
                do { return .success(try await operation()) }
                catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { onExpiry() }
            return first ?? .failure(Watchdog())
        }
    }
}
