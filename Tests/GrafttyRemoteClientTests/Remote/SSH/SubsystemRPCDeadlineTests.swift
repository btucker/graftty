import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@Suite("Subsystem RPC deadlines on the WebRTC event-loop type")
struct SubsystemRPCDeadlineTests {
    @Test("@spec REMOTE-11.23: If a pane-control or worktree-management RPC response does not arrive before its deadline, then the client shall fail that RPC with a timeout using elapsed time independently of the transport event-loop clock.")
    func paneControlResponseDeadlineIgnoresTheEventLoopClock() async throws {
        let received = RequestCounter()
        let link = try await InMemorySSHLink.make(
            serverChild: ScriptedSubsystemHost.install(
                unanswered: 1,
                reply: try JSONEncoder().encode(PaneControlResponse.ok),
                received: received
            )
        )
        let clock = ManualReplyDeadline()
        let client = PaneControlChannelClient(
            parentChannel: link.client,
            parentHandler: link.clientHandler,
            responseDeadline: clock.deadline
        )
        try await client.open()

        // The in-memory link's event loops never advance their clock, so a
        // deadline scheduled on them could not fire here.
        let first = Task { try await client.send(.equalize(target: "pane")) }
        await received.waitUntil(1)
        await clock.waitUntilArmed()
        clock.fire()
        guard case .failure(PaneControlChannelClient.ClientError.timedOut) = await first.result else {
            Issue.record("expected .timedOut, got \(await first.result)")
            client.close()
            await link.close()
            return
        }
        // Pane control keeps the channel after a timeout so a wedged
        // mutator does not cost the connection its layout controls.
        let next = await Task { try await client.send(.equalize(target: "pane")) }.result
        guard case .success(.ok) = next else {
            Issue.record("expected the next RPC to succeed, got \(next)")
            client.close()
            await link.close()
            return
        }
        client.close()
        await link.close()
    }

    @Test("a worktree-management response deadline closes the channel before the caller resumes")
    func worktreeManagementDeadlinePoisonsBeforeResuming() async throws {
        let received = RequestCounter()
        let link = try await InMemorySSHLink.make(serverChild: ScriptedSubsystemHost.install(received: received))
        let clock = ManualReplyDeadline()
        let client = WorktreeManagementChannelClient(
            parentChannel: link.client,
            parentHandler: link.clientHandler,
            subsystemReplyTimeout: .seconds(30),
            responseDeadline: clock.deadline
        )
        try await client.open()

        // The second request is issued the moment the first one resumes.
        // The wire has no request IDs, so it must find the channel already
        // poisoned rather than write a mutation a late reply could answer.
        let outcomes = Task { () -> (Result<WorktreeManagementResponse, any Error>, Result<WorktreeManagementResponse, any Error>) in
            let first = await Result(catching: { try await client.send(.open(worktreeID: "/tmp/w")) })
            let second = await Result(catching: { try await client.send(.open(worktreeID: "/tmp/w")) })
            return (first, second)
        }
        await received.waitUntil(1)
        await clock.waitUntilArmed()
        clock.fire()
        let (first, second) = await outcomes.value
        guard case .failure(WorktreeManagementChannelClient.ClientError.timedOut) = first else {
            Issue.record("expected .timedOut, got \(first)")
            client.close()
            await link.close()
            return
        }
        guard case .failure(WorktreeManagementChannelClient.ClientError.channelClosed) = second else {
            Issue.record("expected .channelClosed after the timeout, got \(second)")
            client.close()
            await link.close()
            return
        }
        #expect(received.count == 1)
        await link.close()
    }
}

private extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) }
        catch { self = .failure(error) }
    }
}
