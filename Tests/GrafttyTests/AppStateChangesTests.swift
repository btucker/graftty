import Combine
import Observation
import Testing
@testable import Graftty

@Observable @MainActor
private final class ObservedStore { var value = 0 }

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppStateChangesTests {
    /// Records each refresh and lets a test hold one open while it publishes.
    @MainActor
    private final class Refreshes {
        let stream: AsyncStream<Int>
        private let continuation: AsyncStream<Int>.Continuation
        private(set) var count = 0
        private(set) var revisions: [UInt64] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdNext = false

        init() { (stream, continuation) = AsyncStream<Int>.makeStream() }

        func refresh(at revision: UInt64) async {
            count += 1
            revisions.append(revision)
            continuation.yield(count)
            if holdNext {
                holdNext = false
                await withCheckedContinuation { gate = $0 }
            }
        }

        func release() { gate?.resume(); gate = nil }
    }

    private func start(_ changes: AppStateChanges, ticks: AsyncStream<Void> = AsyncStream { _ in },
                       _ refreshes: Refreshes) -> Task<Void, Never> {
        Task { await changes.observe(settle: { _ in }, ticks: ticks) { await refreshes.refresh(at: changes.currentRevision) } }
    }

    @Test("@spec PERF-1.16: When an observer subscribes to application state changes, the application shall rebuild once immediately and then once per burst of changes published while a rebuild is in progress, instead of rebuilding on a fixed interval.")
    func firstBuildThenOneRebuildPerBurst() async {
        let changes = AppStateChanges()
        let refreshes = Refreshes()
        var events = refreshes.stream.makeAsyncIterator()
        refreshes.holdNext = true
        let task = start(changes, refreshes)
        defer { task.cancel() }

        #expect(await events.next() == 1)
        for _ in 0..<5 { changes.publish() }
        refreshes.release()
        #expect(await events.next() == 2)

        // Had the burst queued a further rebuild, the third would still see
        // revision 5 rather than the sixth publish.
        changes.publish()
        #expect(await events.next() == 3)
        #expect(refreshes.revisions == [0, 5, 6])
    }

    @Test("@spec PERF-1.17: While no application state change is published, the application shall still rebuild observed snapshots on each safety-net tick so a change source that was not wired cannot leave a viewer stale indefinitely.")
    func safetyNetTickRebuildsWithoutChanges() async {
        let changes = AppStateChanges()
        let refreshes = Refreshes()
        var events = refreshes.stream.makeAsyncIterator()
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        let task = start(changes, ticks: ticks, refreshes)
        defer { task.cancel() }

        #expect(await events.next() == 1)
        tick.yield()
        #expect(await events.next() == 2)
        tick.yield()
        #expect(await events.next() == 3)
    }

    @Test("@spec PERF-1.18: When a store that sidebar and panes-state snapshots read changes, the application shall publish an application state change.")
    func storeChangesPublish() async {
        let changes = AppStateChanges()
        let refreshes = Refreshes()
        var events = refreshes.stream.makeAsyncIterator()
        let store = ObservedStore()
        let subject = PassthroughSubject<Void, Never>()
        changes.publish(onChangeOf: { _ = store.value })
        changes.publish(on: subject)
        let task = start(changes, refreshes)
        defer { task.cancel() }

        #expect(await events.next() == 1)
        store.value += 1
        #expect(await events.next() == 2)
        // Tracking re-arms after each change.
        store.value += 1
        #expect(await events.next() == 3)
        subject.send()
        #expect(await events.next() == 4)
    }

    @Test("@spec PERF-1.19: While application state changes keep arriving, the application shall rebuild observed snapshots no more often than once per second.")
    func continuousChangesRebuildAtMostOncePerSecond() async {
        #expect(AppStateChanges.settleDelay(sinceLastRebuild: .zero) == AppStateChanges.minimumRebuildInterval)
        #expect(AppStateChanges.settleDelay(sinceLastRebuild: .milliseconds(400)) == .milliseconds(600))
        // A change after a quiet second still lands after only the settle delay.
        #expect(AppStateChanges.settleDelay(sinceLastRebuild: .seconds(5)) == AppStateChanges.settleInterval)

        // observe() holds the rebuild until settle returns.
        let changes = AppStateChanges()
        let refreshes = Refreshes()
        var events = refreshes.stream.makeAsyncIterator()
        let (settles, settleEntered) = AsyncStream<Duration>.makeStream()
        var settleCalls = settles.makeAsyncIterator()
        let (releases, release) = AsyncStream<Void>.makeStream()
        let task = Task {
            await changes.observe(settle: { elapsed in
                settleEntered.yield(elapsed)
                for await _ in releases { break }
            }, ticks: AsyncStream { _ in }) { await refreshes.refresh(at: changes.currentRevision) }
        }
        defer { task.cancel() }

        #expect(await events.next() == 1)
        changes.publish()
        #expect(await settleCalls.next() != nil)
        #expect(refreshes.count == 1)
        release.yield()
        #expect(await events.next() == 2)
    }

    @Test func cancellingTheObservingTaskEndsObservation() async {
        let changes = AppStateChanges()
        let refreshes = Refreshes()
        var events = refreshes.stream.makeAsyncIterator()
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        let (tickTeardown, tornDown) = AsyncStream<Void>.makeStream()
        tick.onTermination = { _ in tornDown.finish() }
        let task = start(changes, ticks: ticks, refreshes)

        #expect(await events.next() == 1)
        task.cancel()
        await task.value
        for await _ in tickTeardown {}
    }
}
