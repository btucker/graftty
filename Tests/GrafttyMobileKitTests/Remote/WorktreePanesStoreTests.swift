#if canImport(UIKit)
import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("WorktreePanesStore — opens panes_state channel, applies decoded snapshot to current.")
struct WorktreePanesStoreTests {

    @Test
    func applySnapshotUpdatesCurrent() async throws {
        let pair = FakePair()
        let mobileRouter = ChannelRouter(transport: pair.aliceSide)
        let serverRouter = ChannelRouter(transport: pair.bobSide)
        await mobileRouter.start()
        await serverRouter.start()

        let initial = makeWorktrees(count: 1)
        let panes = PassThroughPanesSource(initial: initial)
        await serverRouter.register(type: "panes_state") {
            ServerSidePushHandler(source: panes)
        }

        let store = WorktreePanesStore(router: mobileRouter)
        try await store.subscribe()

        try await pollUntil(timeout: .seconds(2)) { await store.current.count == 1 }
        let current = await store.current
        #expect(current.first?.path == "/repo/wt-0")

        // Push a second snapshot from the server.
        let next = makeWorktrees(count: 3)
        await panes.fire(next)
        try await pollUntil(timeout: .seconds(2)) { await store.current.count == 3 }
    }

    @Test
    func unsubscribeCleansUp() async throws {
        let pair = FakePair()
        let mobileRouter = ChannelRouter(transport: pair.aliceSide)
        let serverRouter = ChannelRouter(transport: pair.bobSide)
        await mobileRouter.start()
        await serverRouter.start()

        let initial = makeWorktrees(count: 0)
        let panes = PassThroughPanesSource(initial: initial)
        await serverRouter.register(type: "panes_state") {
            ServerSidePushHandler(source: panes)
        }

        let store = WorktreePanesStore(router: mobileRouter)
        try await store.subscribe()
        try await pollUntil(timeout: .seconds(2)) {
            await store.current.isEmpty   // initial snapshot is empty by construction
        }

        await store.unsubscribe()
        try await pollUntil(timeout: .seconds(2)) { await panes.cancelled }
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

/// Server-side mock that sends the initial snapshot on open, then any
/// snapshot the test pushes via `fire(_:)`.
private actor PassThroughPanesSource {
    private(set) var cancelled = false
    private var emit: (@Sendable ([WorktreePanes]) async -> Void)?
    private let initial: [WorktreePanes]

    init(initial: [WorktreePanes]) {
        self.initial = initial
    }

    func register(_ emit: @escaping @Sendable ([WorktreePanes]) async -> Void) async {
        self.emit = emit
        await emit(initial)
    }

    func fire(_ snapshot: [WorktreePanes]) async {
        await emit?(snapshot)
    }

    func markCancelled() {
        cancelled = true
    }
}

private actor ServerSidePushHandler: ChannelHandler {
    nonisolated let channelType = "panes_state"
    private let source: PassThroughPanesSource

    init(source: PassThroughPanesSource) {
        self.source = source
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        await source.register { snapshot in
            let envelope = PanesStateMessage.snapshot(snapshot)
            guard let data = try? JSONEncoder().encode(envelope) else { return }
            try? await outbox.send(.payload(ChannelPayload(id: id), data))
        }
    }

    func onPayload(_ data: Data) async {}
    func onClose() async {
        await source.markCancelled()
    }
    func onError(_ code: String, message: String) async {
        await source.markCancelled()
    }
}

private final class FakePair: Sendable {
    let aliceSide: AliceTransport
    let bobSide: BobTransport
    init() {
        let aliceToBob = FakeBridge()
        let bobToAlice = FakeBridge()
        self.aliceSide = AliceTransport(out: aliceToBob, in: bobToAlice)
        self.bobSide = BobTransport(out: bobToAlice, in: aliceToBob)
    }
}

private actor FakeBridge {
    var subscriber: (@Sendable (Data) async -> Void)?
    func subscribe(_ s: @escaping @Sendable (Data) async -> Void) { subscriber = s }
    func publish(_ data: Data) async { await subscriber?(data) }
}

private struct AliceTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
    }
}

private struct BobTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
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
#endif
