import Foundation
import GrafttyProtocol
import GrafttyHostAgent
import Testing
@testable import Graftty

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppStateChangesPanesStateTests {
    nonisolated private static let a = PanesStateMessage.snapshot([])
    nonisolated private static let b = PanesStateMessage.snapshot([], sidebar: SidebarSnapshot(projects: []))
    nonisolated private static let c = PanesStateMessage.snapshot(
        [], sidebar: SidebarSnapshot(projects: [], supportsNavigationEditing: false)
    )

    @Test("@spec PERF-1.23: While multiple paired viewers subscribe to the same panes-state projection, the host shall build and encode each changed snapshot once, share it among those viewers, and stop observing when the last viewer leaves.")
    func sharesSnapshotWorkAndRestartsAfterLastSubscriberLeaves() async throws {
        let changes = AppStateChanges()
        let source = SnapshotSource(Self.a)
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        let (stopped, stop) = AsyncStream<Void>.makeStream()
        tick.onTermination = { _ in stop.finish() }
        let feed = SharedPanesStateFeed(changes: changes, settle: { _ in }, ticks: { ticks }, snapshot: { source.next() })
        let first = Publications()
        let second = Publications()
        let a = await feed.subscribe { first.append($0) }
        let b = await feed.subscribe { second.append($0) }
        #expect(source.count == 1)
        #expect(first.values.count == 1 && second.values.count == 1)
        #expect(first.values.first === second.values.first)
        let publication = try #require(first.values.first)
        #expect(try JSONDecoder().decode(PanesStateMessage.self, from: #require(publication.encoded)) == Self.a)
        a.cancel()
        b.cancel()
        for await _ in stopped {}
        source.current = Self.b
        let third = Publications()
        let c = await feed.subscribe { third.append($0) }
        defer { c.cancel() }
        #expect(source.count == 2)
        #expect(third.values.first?.message == Self.b)
    }

    @Test func droppingCancelledFeedStopsObservationBeforeQueuedCleanup() async {
        let changes = AppStateChanges()
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        let (terminated, terminate) = AsyncStream<Void>.makeStream()
        tick.onTermination = { _ in terminate.finish() }
        weak var released: SharedPanesStateFeed?
        do {
            let feed = SharedPanesStateFeed(changes: changes, ticks: { ticks }, snapshot: { Self.a })
            released = feed
            let token = await feed.subscribe { _ in }
            token.cancel()
        }
        #expect(released == nil)
        let stopped = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in terminated {}; return true }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return false }
            let stopped = await group.next() ?? false
            group.cancelAll()
            return stopped
        }
        #expect(stopped)
    }

    @Test("@spec PERF-1.24: While a panes-state viewer is stalled sending a snapshot, the host shall retain only its newest pending snapshot and let other viewers receive updates independently.")
    func stalledViewerReceivesLatestWithoutHoldingUpItsSibling() async throws {
        let changes = AppStateChanges()
        let source = SnapshotSource(Self.a)
        let feed = SharedPanesStateFeed(changes: changes, settle: { _ in }, ticks: { AsyncStream { _ in } }, snapshot: { source.next() })
        let fast = Publications()
        let slow = Publications()
        let (blocked, block) = AsyncStream<Void>.makeStream()
        let (releases, release) = AsyncStream<Void>.makeStream()
        let a = await feed.subscribe { fast.append($0) }
        let b = await feed.subscribe {
            slow.append($0)
            if $0.message == Self.b {
                block.finish()
                for await _ in releases {}
            }
        }
        defer { a.cancel(); b.cancel(); release.finish() }
        var sent = fast.stream.makeAsyncIterator()
        _ = await sent.next()
        source.current = Self.b
        changes.publish()
        #expect(await sent.next()?.message == Self.b)
        for await _ in blocked {}
        for value in [Self.c, Self.a, Self.c] {
            source.current = value
            changes.publish()
            #expect(await sent.next()?.message == value)
        }
        #expect(source.count == 5)
        #expect(slow.values.map(\.message) == [Self.a, Self.b])
        var caughtUp = slow.stream.makeAsyncIterator()
        _ = await caughtUp.next()
        _ = await caughtUp.next()
        release.finish()
        #expect(await caughtUp.next()?.message == Self.c)
        #expect(slow.values.map(\.message) == [Self.a, Self.b, Self.c])
    }

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

        let feed = SharedPanesStateFeed(changes: changes,
            settle: { _ in await settles.increment() }, ticks: { ticks },
            snapshot: { source.next() })
        let subscription = await feed.subscribe { sent.append($0.message) }
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

private final class Publications: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PanesStatePublication] = []
    let stream: AsyncStream<PanesStatePublication>
    private let continuation: AsyncStream<PanesStatePublication>.Continuation
    init() { (stream, continuation) = AsyncStream<PanesStatePublication>.makeStream() }
    var values: [PanesStatePublication] { lock.withLock { stored } }
    func append(_ value: PanesStatePublication) {
        lock.withLock { stored.append(value) }
        continuation.yield(value)
    }
}
