import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("PanesStateHandler — emits initial snapshot on open + re-emits on each subscribe-callback fire.")
struct PanesStateHandlerTests {

    @Test
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

    @Test
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

    @Test
    func cancelsSubscriptionOnClose() async throws {
        let initial = makeWorktrees(count: 0)
        let subscription = FakeSubscription(initialSnapshot: initial)
        let handler = PanesStateHandler(subscribe: { [subscription] in await subscription.subscribe($0) })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(1), outbox: outboxSpy.outbox)
        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }

        await handler.onClose()
        try await pollUntil(timeout: .seconds(2)) { await subscription.cancelled }
        #expect(await subscription.cancelled)
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

private actor FakeSubscription {
    private(set) var cancelled = false
    private var onChange: (@Sendable ([WorktreePanes]) async -> Void)?
    private let initialSnapshot: [WorktreePanes]

    init(initialSnapshot: [WorktreePanes]) {
        self.initialSnapshot = initialSnapshot
    }

    nonisolated func subscribe(
        _ onChange: @escaping @Sendable ([WorktreePanes]) async -> Void
    ) async -> PanesStateHandler.Cancellable {
        await register(onChange)
        let initial = initialSnapshot
        await onChange(initial)
        return PanesStateHandler.Cancellable { [weak self] in
            Task { await self?.markCancelled() }
        }
    }

    private func register(_ callback: @escaping @Sendable ([WorktreePanes]) async -> Void) {
        self.onChange = callback
    }

    func fire(_ snapshot: [WorktreePanes]) async {
        await onChange?(snapshot)
    }

    func markCancelled() {
        cancelled = true
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
