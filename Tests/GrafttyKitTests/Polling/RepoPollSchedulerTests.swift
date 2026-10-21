import Testing
import Foundation
@testable import GrafttyKit

/// Unit coverage for the per-key slot bookkeeping shared by the polling
/// stores. Every test drives an injected clock, so abandonment and cadence
/// windows are crossed without sleeping.
@MainActor
@Suite("RepoPollScheduler")
struct RepoPollSchedulerTests {

    private final class TestClock {
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private func makeScheduler(
        clock: TestClock,
        limiter: BackgroundProcessLimiter = BackgroundProcessLimiter(capacity: 4),
        cadence: @escaping (Int) -> Duration = { _ in .zero }
    ) -> RepoPollScheduler {
        RepoPollScheduler(limiter: limiter, cadence: cadence, now: { clock.now })
    }

    @Test func abandonmentThresholdIsThirtySeconds() {
        // DIVERGE-4.4 / PR-7.13: a hung dispatch suppresses fresh work for
        // at most this long before it is treated as abandoned.
        #expect(RepoPollScheduler.abandonmentThreshold == .seconds(30))
    }

    @Test func claimMarksKeyLiveAndBumpsGeneration() {
        let clock = TestClock()
        let scheduler = makeScheduler(clock: clock)

        #expect(!scheduler.isLive("/r"))
        let first = scheduler.claim("/r")
        let second = scheduler.claim("/r")

        #expect(second == first + 1)
        #expect(scheduler.generation("/r") == second)
        #expect(scheduler.isLive("/r"))
        #expect(scheduler.isCurrent("/r", generation: second))
        #expect(!scheduler.isCurrent("/r", generation: first))
    }

    @Test func liveSlotIsAbandonedOnceItReachesTheThreshold() {
        let clock = TestClock()
        let scheduler = makeScheduler(clock: clock)
        _ = scheduler.claim("/a")
        _ = scheduler.claim("/b")

        clock.advance(29)
        #expect(scheduler.isLive("/a"))
        #expect(scheduler.liveKeys() == ["/a", "/b"])
        #expect(scheduler.availableDispatchSlots() == 2)

        clock.advance(1)
        #expect(!scheduler.isLive("/a"))
        #expect(scheduler.isInFlight("/a"), "abandoned is still recorded as in flight")
        #expect(scheduler.liveKeys().isEmpty)
        #expect(scheduler.availableDispatchSlots() == 4)
    }

    @Test func onlyTheCurrentGenerationReleasesTheSlot() {
        let clock = TestClock()
        let scheduler = makeScheduler(clock: clock)
        let stale = scheduler.claim("/r")
        let live = scheduler.claim("/r")

        #expect(!scheduler.release("/r", generation: stale))
        #expect(scheduler.isInFlight("/r"))

        #expect(scheduler.release("/r", generation: live))
        #expect(!scheduler.isInFlight("/r"))
    }

    @Test func invalidateClearsTheSlotAndSupersedesItsWork() {
        let clock = TestClock()
        let scheduler = makeScheduler(clock: clock)
        let generation = scheduler.claim("/r")

        scheduler.invalidate("/r")

        #expect(!scheduler.isInFlight("/r"))
        #expect(!scheduler.isCurrent("/r", generation: generation))
        #expect(scheduler.generation("/r") == generation + 1)
    }

    @Test func coolingDownFollowsCadenceForTheFailureStreak() {
        let clock = TestClock()
        let scheduler = makeScheduler(clock: clock) { streak in
            .seconds(10 << streak)
        }
        #expect(!scheduler.isCoolingDown("/r"), "never-completed keys are due")

        scheduler.recordFailure("/r")
        #expect(scheduler.failureStreak("/r") == 1)
        clock.advance(19)
        #expect(scheduler.isCoolingDown("/r"))
        clock.advance(1)
        #expect(!scheduler.isCoolingDown("/r"))

        scheduler.recordSuccess("/r")
        #expect(scheduler.failureStreak("/r") == 0)
        clock.advance(9)
        #expect(scheduler.isCoolingDown("/r"))
        clock.advance(1)
        #expect(!scheduler.isCoolingDown("/r"))
    }

    @Test func recordCompletionKeepsTheFailureStreak() {
        let clock = TestClock()
        let scheduler = makeScheduler(clock: clock) { _ in .seconds(10) }
        scheduler.recordFailure("/r")

        clock.advance(100)
        scheduler.recordCompletion("/r")

        #expect(scheduler.failureStreak("/r") == 1)
        #expect(scheduler.isCoolingDown("/r"))
    }

    @Test func runSkipsWorkSupersededWhileWaitingForAPermit() async {
        let clock = TestClock()
        let limiter = BackgroundProcessLimiter(capacity: 1)
        let scheduler = makeScheduler(clock: clock, limiter: limiter)
        let gate = PermitGate()
        let occupant = Task { await limiter.run { await gate.hold() } }
        await gate.waitUntilHeld()

        let stale = scheduler.claim("/r")
        let ran = MutableBox(false)
        let queued = Task {
            await scheduler.run("/r", generation: stale) { ran.value = true }
        }
        _ = scheduler.claim("/r")
        await gate.open()
        await occupant.value

        #expect(await queued.value == nil)
        #expect(!ran.value)
    }

    @Test func runRestartsTheAbandonmentWindowWhenItObtainsAPermit() async {
        let clock = TestClock()
        let scheduler = makeScheduler(clock: clock)
        let generation = scheduler.claim("/r")
        clock.advance(100)
        #expect(!scheduler.isLive("/r"))

        let result = await scheduler.run("/r", generation: generation) { 7 }

        #expect(result == 7)
        #expect(scheduler.isLive("/r"))
    }

    @Test func pruneDropsKeysNoLongerInTheModel() {
        let clock = TestClock()
        let scheduler = makeScheduler(clock: clock)
        _ = scheduler.claim("/keep")
        _ = scheduler.claim("/drop")

        scheduler.prune(keeping: ["/keep"])

        #expect(scheduler.isInFlight("/keep"))
        #expect(!scheduler.isInFlight("/drop"))
        #expect(scheduler.generation("/drop") == 0)
    }

    @Test func nextBatchRotatesThroughCandidatesInBatchSizeSteps() {
        let clock = TestClock()
        let scheduler = makeScheduler(clock: clock)
        let paths = (1...6).map { "/r\($0)" }

        let first = scheduler.nextBatch(from: paths, path: { $0 })
        let second = scheduler.nextBatch(from: paths, path: { $0 })

        #expect(scheduler.batchSize == 4)
        #expect(first == ["/r1", "/r2", "/r3", "/r4"])
        #expect(second == ["/r5", "/r6", "/r1", "/r2"])
    }
}

/// Holds a limiter permit until the test opens it, and reports when the
/// permit is actually held so ordering is deterministic without sleeps.
private actor PermitGate {
    private var held = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    private var opened = false

    func hold() async {
        held = true
        heldWaiters.forEach { $0.resume() }
        heldWaiters.removeAll()
        guard !opened else { return }
        await withCheckedContinuation { release = $0 }
    }

    func waitUntilHeld() async {
        guard !held else { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func open() {
        opened = true
        release?.resume()
        release = nil
    }
}
