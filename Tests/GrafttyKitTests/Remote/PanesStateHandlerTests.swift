import Foundation
import os
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("PanesStateHandler — emits initial snapshot on open + re-emits on each subscribe-callback fire.")
struct PanesStateHandlerTests {

    @Test("""
@spec REMOTE-6.2: Immediately after accepting a `panes_state` channel, the host shall send a `{"type":"snapshot","worktrees":[…]}` frame containing the current `[WorktreePanes]` array.
""")
    func emitsInitialSnapshotOnOpen() async throws {
        let initial = makeWorktrees(count: 1)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateHandler(subscribe: { [subscription] in await subscription.subscribe($0) })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(7), outbox: outboxSpy.outbox)

        try await pollUntil(timeout: .seconds(2)) {
            await outboxSpy.framesCount == 1
        }
        let frames = await outboxSpy.frames
        guard case .payload(let meta, let body) = frames[0] else {
            Issue.record("expected payload frame, got \(frames[0])")
            return
        }
        #expect(meta.id == ChannelID(7))
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: body)
        #expect(decoded == .snapshot(initial))
    }

    @Test("""
@spec REMOTE-6.3: While a `panes_state` channel is open, on any change to the host's `AppState.repos[*].worktrees`, splittree, attention state, or PR status, the host shall send a fresh `{"type":"snapshot","worktrees":[…]}` frame.
""")
    func reemitsOnFurtherSubscribeFires() async throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateHandler(subscribe: { [subscription] in await subscription.subscribe($0) })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(11), outbox: outboxSpy.outbox)
        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }

        let next = makeWorktrees(count: 2)
        await subscription.fire(next)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 2 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let body) = frames[1] else {
            Issue.record("expected payload frame")
            return
        }
        let decoded = try JSONDecoder().decode(PanesStateMessage.self, from: body)
        #expect(decoded == .snapshot(next))
    }

    @Test("""
@spec REMOTE-6.4: When the `RemoteHostConnection` tears down (client background, host switch, network failure, peer revocation), any open `panes_state` channels shall close.
""")
    func cancelsSubscriptionOnClose() async throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateHandler(subscribe: { [subscription] in await subscription.subscribe($0) })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(1), outbox: outboxSpy.outbox)
        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }

        await handler.onClose()
        try await pollUntil(timeout: .seconds(5)) { subscription.cancelled }
        #expect(subscription.cancelled)
    }

    private func makeWorktrees(count: Int) -> [WorktreePanes] {
        (0..<count).map { idx in
            WorktreePanes(
                path: "/repo/wt-\(idx)",
                displayName: "wt-\(idx)",
                repoDisplayName: "graftty",
                displayBranch: "branch-\(idx)",
                state: .running,
                isMainCheckout: false,
                prBadge: nil,
                stats: nil,
                attentionText: nil,
                layout: .leaf(sessionName: "s\(idx)", title: "shell", attentionText: nil)
            )
        }
    }
}

private final class FakeSubscription: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (
        cancelled: false,
        onChange: Optional<@Sendable ([WorktreePanes]) async -> Void>.none
    ))
    private let initialSnapshot: [WorktreePanes]

    var cancelled: Bool {
        state.withLock { $0.cancelled }
    }

    init(initialSnapshot: [WorktreePanes]) {
        self.initialSnapshot = initialSnapshot
    }

    func subscribe(
        _ onChange: @escaping @Sendable ([WorktreePanes]) async -> Void
    ) async -> PanesStateHandler.Cancellable {
        state.withLock { $0.onChange = onChange }
        await onChange(initialSnapshot)
        return PanesStateHandler.Cancellable { [weak self] in
            self?.markCancelled()
        }
    }

    func fire(_ snapshot: [WorktreePanes]) async {
        let cb = state.withLock { $0.onChange }
        await cb?(snapshot)
    }

    private func markCancelled() {
        state.withLock { $0.cancelled = true }
    }
}

private actor OutboxSpy {
    var frames: [ChannelFrame] = []
    var framesCount: Int { frames.count }

    nonisolated var outbox: ChannelOutbox {
        ChannelOutbox { [weak self] frame in
            await self?.append(frame)
        }
    }

    func append(_ frame: ChannelFrame) {
        frames.append(frame)
    }
}

private struct PollTimeout: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "pollUntil timed out after \(timeout)" }
}

private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(20),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    throw PollTimeout(timeout: timeout)
}
