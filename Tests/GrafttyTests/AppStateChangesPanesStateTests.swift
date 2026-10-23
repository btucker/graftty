import Foundation
import GrafttyProtocol
import Testing
@testable import Graftty

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppStateChangesPanesStateTests {
    private static let a = PanesStateMessage.snapshot([])
    private static let b = PanesStateMessage.snapshot([], sidebar: SidebarSnapshot(projects: []))
    private static let c = PanesStateMessage.snapshot(
        [], sidebar: SidebarSnapshot(projects: [], supportsNavigationEditing: false)
    )

    @Test("@spec PERF-1.21: When a paired device subscribes to panes-state, the application shall send the initial snapshot before the subscription returns, and afterwards re-read the snapshot only when an application state change is published or the safety-net tick fires, sending it only when it differs from the last snapshot sent.")
    func sendsInitialThenChangedSnapshotsOnSignal() async {
        let changes = AppStateChanges()
        let source = SnapshotSource(Self.a)
        let sent = Sent()
        let settles = SettleCount()
        var reads = source.reads.makeAsyncIterator()
        var messages = sent.stream.makeAsyncIterator()
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        let (tickTeardown, tornDown) = AsyncStream<Void>.makeStream()
        tick.onTermination = { _ in tornDown.finish() }

        let subscription = await changes.subscribePanesState(
            settle: { _ in await settles.increment() }, ticks: ticks,
            snapshot: { source.next() }, onChange: { sent.append($0) })
        defer { subscription.cancel() }
        #expect(sent.messages == [Self.a])
        #expect(await messages.next() == Self.a)
        #expect(await reads.next() == 1)

        // The next read waits for a published change: only a rebuild after
        // the first one settles, so an unprompted re-read would see none.
        // That unchanged snapshot is not sent again; the next changed one
        // proves nothing was queued in between.
        changes.publish()
        #expect(await reads.next() == 2)
        #expect(settles.count == 1)
        source.current = Self.b
        changes.publish()
        #expect(await messages.next() == Self.b)

        // The safety-net tick re-reads without any published change.
        source.current = Self.c
        tick.yield()
        #expect(await messages.next() == Self.c)
        #expect(sent.messages == [Self.a, Self.b, Self.c])

        subscription.cancel()
        for await _ in tickTeardown {}
        let readsAtCancel = source.count
        changes.publish()
        source.current = Self.a
        tick.yield()
        #expect(source.count == readsAtCancel)
        #expect(sent.messages == [Self.a, Self.b, Self.c])
    }
}

@MainActor
private final class SettleCount {
    private(set) var count = 0
    func increment() { count += 1 }
}

@MainActor
private final class SnapshotSource {
    var current: PanesStateMessage
    private(set) var count = 0
    let reads: AsyncStream<Int>
    private let readContinuation: AsyncStream<Int>.Continuation

    init(_ initial: PanesStateMessage) {
        current = initial
        (reads, readContinuation) = AsyncStream<Int>.makeStream()
    }

    func next() -> PanesStateMessage {
        count += 1
        readContinuation.yield(count)
        return current
    }
}

private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [PanesStateMessage] = []
    let stream: AsyncStream<PanesStateMessage>
    private let continuation: AsyncStream<PanesStateMessage>.Continuation

    init() { (stream, continuation) = AsyncStream<PanesStateMessage>.makeStream() }

    var messages: [PanesStateMessage] { lock.withLock { sent } }

    func append(_ message: PanesStateMessage) {
        lock.withLock { sent.append(message) }
        continuation.yield(message)
    }
}
