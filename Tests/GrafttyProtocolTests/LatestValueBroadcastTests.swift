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
}
