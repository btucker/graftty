import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("@spec REMOTE-6.12: When a client observes a changing value through a latest-value broadcast, the application shall first deliver the latest published value, then deliver only the newest value published while the observer was busy, and shall end every observation once the broadcast finishes.", .timeLimit(.minutes(1)))
// A broken broadcast ends observers early instead of hanging them: each
// observer finishes its signal stream when its loop exits.
struct LatestValueBroadcastTests {
    @Test func newObserverReceivesLatestValueFirst() async {
        let broadcast = LatestValueBroadcast<Int>()
        broadcast.publish(1)
        broadcast.publish(2)
        var updates = broadcast.updates().makeAsyncIterator()
        #expect(await updates.next() == 2)
        broadcast.publish(3)
        #expect(await updates.next() == 3)
        #expect(broadcast.latest == 3)
    }

    @Test func observerWithoutPublishedValueWaitsForFirstPublish() async {
        let broadcast = LatestValueBroadcast<Int>()
        #expect(broadcast.latest == nil)
        var updates = broadcast.updates().makeAsyncIterator()
        broadcast.publish(7)
        #expect(await updates.next() == 7)
    }

    @Test func busyObserverSkipsToNewestValue() async {
        let broadcast = LatestValueBroadcast<Int>()
        let received = AsyncStream<Int>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let observer = Task {
            defer { received.continuation.finish() }
            var seen: [Int] = []
            var gate = release.stream.makeAsyncIterator()
            for await value in broadcast.updates() {
                seen.append(value)
                received.continuation.yield(value)
                // Hold the observer busy on its first value while later
                // values are published.
                if seen.count == 1 { _ = await gate.next() }
            }
            return seen
        }
        // `Task.value` does not forward the time limit's cancellation, so a
        // broken finish() would otherwise hang past the limit.
        await withTaskCancellationHandler {
            var receivedValues = received.stream.makeAsyncIterator()
            broadcast.publish(1)
            #expect(await receivedValues.next() == 1)
            broadcast.publish(2)
            broadcast.publish(3)
            broadcast.publish(4)
            release.continuation.yield()
            #expect(await receivedValues.next() == 4)
            broadcast.finish()
            #expect(await observer.value == [1, 4])
        } onCancel: {
            observer.cancel()
        }
    }

    @Test func eachLiveObserverReceivesValuesIndependently() async {
        let broadcast = LatestValueBroadcast<Int>()
        broadcast.publish(1)
        var first = broadcast.updates().makeAsyncIterator()
        var second = broadcast.updates().makeAsyncIterator()
        #expect(broadcast.observerCount == 2)
        #expect(await first.next() == 1)
        #expect(await second.next() == 1)
        broadcast.publish(2)
        broadcast.publish(3)
        #expect(await first.next() == 3)
        #expect(await second.next() == 3)

        let cancelled = Task { for await _ in broadcast.updates() {} }
        cancelled.cancel()
        await cancelled.value
        broadcast.publish(4)
        #expect(await first.next() == 4)
        #expect(await second.next() == 4)

        broadcast.finish()
        #expect(await first.next() == nil)
        #expect(await second.next() == nil)
    }

    /// A publish that reaches `latest` before finish() must also reach every
    /// observer, or an observer ends on an older value than `latest`. A wide
    /// payload makes each delivery slow enough for a racing finish() to
    /// overtake it, and the race repeats so that it lands.
    @Test func publishRacingFinishReachesEveryObserverOrNone() async {
        var staleObservers = 0
        for _ in 0..<1_000 {
            let broadcast = LatestValueBroadcast<WideFrame>()
            broadcast.publish(WideFrame(id: 1))
            var observers: [AsyncStream<WideFrame>.AsyncIterator] = []
            for _ in 0..<64 {
                var observer = broadcast.updates().makeAsyncIterator()
                _ = await observer.next()
                observers.append(observer)
            }
            // A lock re-entry regression deadlocks synchronously, which the
            // time limit cannot interrupt, so the race runs under a bounded
            // wait. On a deadlock the observers are leaked: releasing them
            // would take the stuck lock.
            let raced = await finishes(within: 5) {
                DispatchQueue.concurrentPerform(iterations: 2) { lane in
                    if lane == 0 { broadcast.publish(WideFrame(id: 2)) } else { broadcast.finish() }
                }
            }
            guard raced else {
                Issue.record("publish racing finish deadlocked")
                _ = Unmanaged.passRetained(LeakedObservers(observers))
                return
            }
            let expected: Int? = broadcast.latest?.id == 2 ? 2 : nil
            for index in observers.indices where await observers[index].next()?.id != expected {
                staleObservers += 1
            }
        }
        #expect(staleObservers == 0)
    }

    @Test func finishEndsCurrentAndFutureObservers() async {
        let broadcast = LatestValueBroadcast<Int>()
        broadcast.publish(1)
        var current = broadcast.updates().makeAsyncIterator()
        #expect(await current.next() == 1)
        broadcast.finish()
        #expect(await current.next() == nil)

        broadcast.publish(2)
        #expect(broadcast.latest == 1)
        var late = broadcast.updates().makeAsyncIterator()
        #expect(await late.next() == nil)
    }

    @Test func cancelledObserverIsReleased() async {
        let broadcast = LatestValueBroadcast<Int>()
        let started = AsyncStream<Void>.makeStream()
        let observer = Task {
            defer { started.continuation.finish() }
            for await _ in broadcast.updates() { started.continuation.yield() }
        }
        broadcast.publish(1)
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()
        #expect(broadcast.observerCount == 1)
        observer.cancel()
        await observer.value
        #expect(broadcast.observerCount == 0)
    }

    @Test func releasedBroadcastEndsItsObservers() async {
        // An owner that drops the broadcast without finishing it (a store
        // released without unsubscribing) must not strand its observers.
        var broadcast: LatestValueBroadcast<Int>? = LatestValueBroadcast()
        broadcast?.publish(1)
        var updates = broadcast!.updates().makeAsyncIterator()
        #expect(await updates.next() == 1)
        broadcast = nil
        #expect(await updates.next() == nil)
    }

    /// A reference payload's deinit may use the broadcast: read it, publish
    /// again, or finish it, which ends its observers. Releasing a replaced
    /// payload while the broadcast holds its lock would deadlock; a
    /// synchronous deadlock cannot be cancelled, so publishing runs on a
    /// queue under a bounded wait. A stuck publisher keeps the fixture alive,
    /// so the test never releases a broadcast whose lock is held.
    @Test(arguments: [false, true], PayloadReleaseAction.allCases)
    func releasingAReplacedPayloadMayUseTheBroadcast(withObserver: Bool, action: PayloadReleaseAction) {
        let fixture = ReentrantFixture(withObserver: withObserver)
        // Proves the deinit ran and finished its re-entry, so an
        // implementation that never releases replaced payloads cannot pass.
        let used = DispatchSemaphore(value: 0)
        let usesBroadcast: @Sendable () -> Void = { [weak broadcast = fixture.broadcast] in
            guard let broadcast else { return }
            switch action {
            case .read: _ = broadcast.latest
            case .publish: broadcast.publish(Payload(onRelease: {}))
            case .finish: broadcast.finish()
            }
            used.signal()
        }
        let published = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            fixture.broadcast.publish(Payload(onRelease: usesBroadcast))
            fixture.broadcast.publish(Payload(onRelease: {}))
            published.signal()
        }
        #expect(published.wait(timeout: .now() + 5) == .success)
        #expect(used.wait(timeout: .now() + 5) == .success)
    }
}

enum PayloadReleaseAction: CaseIterable, Sendable {
    case read, publish, finish
}

private typealias Eight<T> = (T, T, T, T, T, T, T, T)

/// 4 KiB, so delivering one into an observer's buffer takes measurable time.
private struct WideFrame: Sendable {
    let id: Int
    private let padding: Eight<Eight<Eight<Int>>>

    init(id: Int) {
        self.id = id
        let words = (0, 0, 0, 0, 0, 0, 0, 0)
        let rows = (words, words, words, words, words, words, words, words)
        padding = (rows, rows, rows, rows, rows, rows, rows, rows)
    }
}

/// Runs `work` on a queue and reports whether it returned within `seconds`,
/// without blocking a cooperative thread on a work item that may deadlock.
private func finishes(within seconds: Double, _ work: @escaping @Sendable () -> Void) async -> Bool {
    let resumed = ResumeOnce()
    return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            work()
            if resumed.claim() { continuation.resume(returning: true) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
            if resumed.claim() { continuation.resume(returning: false) }
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

private final class LeakedObservers {
    let observers: [AsyncStream<WideFrame>.AsyncIterator]
    init(_ observers: [AsyncStream<WideFrame>.AsyncIterator]) { self.observers = observers }
}

private final class ReentrantFixture: Sendable {
    let broadcast = LatestValueBroadcast<Payload>()
    let observer: AsyncStream<Payload>?
    init(withObserver: Bool) { observer = withObserver ? broadcast.updates() : nil }
}

private final class Payload: Sendable {
    private let onRelease: @Sendable () -> Void
    init(onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}
