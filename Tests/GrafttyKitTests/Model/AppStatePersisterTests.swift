import Foundation
import Testing
@testable import GrafttyKit

/// Timer seam: `fire()` runs the armed action; nothing fires on its own.
@MainActor
final class ManualPersistTimer {
    private(set) var armedDelays: [Duration] = []
    private var action: (@MainActor () -> Void)?

    var isArmed: Bool { action != nil }

    var schedule: AppStatePersister.Schedule {
        { [weak self] delay, action in
            self?.armedDelays.append(delay)
            self?.action = action
            return { [weak self] in self?.action = nil }
        }
    }

    func fire() {
        let action = self.action
        self.action = nil
        action?()
    }
}

/// Records every write in order. `holdNextWrite()` parks the next write on
/// the persister queue until `releaseHeldWrite()`, simulating a slow disk.
final class RecordingStateWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [AppState] = []
    private var hold: DispatchSemaphore?
    /// The gate a write is parked on, kept so `releaseHeldWrite()` can find
    /// it after `write` has taken it out of `hold`.
    private var held: DispatchSemaphore?
    private var failure: (any Error)?
    private var failNext: (any Error)?
    private var started = 0
    private var inFlight = 0
    private var overlapped = false

    var written: [AppState] { lock.withLock { states } }
    /// True if a write ever began while another was still in progress.
    var sawOverlappingWrites: Bool { lock.withLock { overlapped } }

    func holdNextWrite() { lock.withLock { hold = DispatchSemaphore(value: 0) } }
    func releaseHeldWrite() { lock.withLock { held ?? hold }?.signal() }
    func failWrites(with error: (any Error)?) { lock.withLock { failure = error } }
    /// Fails only the next write; later writes succeed.
    func failNextWrite(with error: any Error) { lock.withLock { failNext = error } }

    /// Gives a write that should NOT start yet a bounded window to start
    /// anyway; returns early if it does.
    func waitBrieflyForWrite(number: Int) async {
        let deadline = ContinuousClock.now + .milliseconds(200)
        while lock.withLock({ started < number }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Waits (bounded) until a write is parked on the held gate, so the test
    /// knows that write is in flight before queuing the next one.
    func waitUntilAWriteIsParked() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while lock.withLock({ held == nil }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func write(_ state: AppState) throws {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            started += 1
            inFlight += 1
            if inFlight > 1 { overlapped = true }
            held = hold
            hold = nil
            return held
        }
        _ = gate?.wait(timeout: .now() + 2)
        defer { lock.withLock { inFlight -= 1 } }
        lock.withLock { held = nil }
        let error = lock.withLock { () -> (any Error)? in
            defer { failNext = nil }
            return failNext ?? failure
        }
        if let error { throw error }
        lock.withLock { states.append(state) }
    }
}

private func state(selecting path: String) -> AppState {
    var state = AppState()
    state.selectedWorktreePath = path
    return state
}

@MainActor
private func makePersister(
    _ writer: RecordingStateWriter,
    _ timer: ManualPersistTimer
) -> AppStatePersister {
    AppStatePersister(write: { try writer.write($0) }, schedule: timer.schedule)
}

@Suite("@spec PERSIST-2.3: When `AppState` changes, the application shall coalesce the changes into one `state.json` write that runs off the main thread no later than the save delay after the first unsaved change.")
@MainActor
struct AppStatePersisterCoalescingTests {

    @Test func rapidMarksCoalesceIntoOneWriteOfTheNewestState() async throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)

        persister.markDirty(state(selecting: "/a"))
        persister.markDirty(state(selecting: "/b"))
        persister.markDirty(state(selecting: "/c"))

        #expect(writer.written.isEmpty, "a mark wrote synchronously instead of deferring")
        #expect(timer.armedDelays == [AppStatePersister.defaultDelay])

        timer.fire()
        try await persister.flushNow()

        #expect(writer.written.map(\.selectedWorktreePath) == ["/c"])
    }

    @Test func laterMarksDoNotPostponeAnArmedSave() {
        let timer = ManualPersistTimer()
        let persister = makePersister(RecordingStateWriter(), timer)

        persister.markDirty(state(selecting: "/a"))
        persister.markDirty(state(selecting: "/b"))

        // One arm for the burst: a reset-per-mark debounce would let a
        // steady stream of attention ticks starve the save forever.
        #expect(timer.armedDelays.count == 1)
    }

    @Test func aMarkAfterTheTimerFiresArmsANewSave() async throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)

        persister.markDirty(state(selecting: "/a"))
        timer.fire()
        persister.markDirty(state(selecting: "/b"))
        #expect(timer.isArmed)
        timer.fire()
        try await persister.flushNow()

        #expect(writer.written.map(\.selectedWorktreePath) == ["/a", "/b"])
    }

    @Test func remarkingTheLastWrittenStateSkipsTheRedundantWrite() async throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)

        persister.markDirty(state(selecting: "/a"))
        try await persister.flushNow()
        // The window's `.onChange` re-marks the state a CLI path just flushed.
        persister.markDirty(state(selecting: "/a"))
        timer.fire()
        try await persister.flushNow()

        #expect(writer.written.count == 1)
    }

    @Test func aFailedWriteIsRetriedByTheNextMarkOfTheSameState() async throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)
        struct DiskFull: Error {}

        writer.failWrites(with: DiskFull())
        persister.markDirty(state(selecting: "/a"))
        await #expect(throws: DiskFull.self) { try await persister.flushNow() }

        writer.failWrites(with: nil)
        persister.markDirty(state(selecting: "/a"))
        try await persister.flushNow()

        #expect(writer.written.map(\.selectedWorktreePath) == ["/a"])
    }

    @Test func flushNowReportsAFailedInFlightWriteOfTheSameState() async throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)
        struct DiskFull: Error {}

        writer.failWrites(with: DiskFull())
        persister.markDirty(state(selecting: "/a"))
        timer.fire()  // queues the write of "/a", which fails
        // A launch path re-marks the unchanged state, then flushes before replying.
        persister.markDirty(state(selecting: "/a"))

        await #expect(throws: DiskFull.self, "the flush reported success although state.json was never written") {
            try await persister.flushNow()
        }
    }

    @Test func writesLandInStateJSON() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-state-persister-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persister = AppStatePersister(directory: directory)

        persister.markDirty(state(selecting: "/on-disk"))
        try await persister.flushNow()

        #expect(try AppState.load(from: directory).selectedWorktreePath == "/on-disk")
    }
}

@Suite("@spec PERSIST-2.4: The application shall write `state.json` snapshots in the order they were taken, so a write already in flight can never land after a newer snapshot.")
@MainActor
struct AppStatePersisterOrderingTests {

    @Test func flushNowQueuesBehindAnInFlightTimerWrite() async throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)

        writer.holdNextWrite()
        persister.markDirty(state(selecting: "/older"))
        timer.fire()
        await writer.waitUntilAWriteIsParked()  // "/older" is in flight
        persister.markDirty(state(selecting: "/newer"))
        let flush = Task { try await persister.flushNow() }
        await writer.waitBrieflyForWrite(number: 2)
        writer.releaseHeldWrite()
        try await flush.value

        #expect(!writer.sawOverlappingWrites, "the flush wrote while an older snapshot was still in flight")
        #expect(writer.written.map(\.selectedWorktreePath) == ["/older", "/newer"])
    }

    @Test func terminationFlushQueuesBehindAnInFlightTimerWrite() async throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)

        writer.holdNextWrite()
        persister.markDirty(state(selecting: "/older"))
        timer.fire()
        await writer.waitUntilAWriteIsParked()
        persister.markDirty(state(selecting: "/newer"))
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
            writer.releaseHeldWrite()
        }
        try persister.flushSynchronously()

        #expect(writer.written.map(\.selectedWorktreePath) == ["/older", "/newer"])
    }
}

@Suite("@spec PERSIST-2.6: When the application terminates, it shall synchronously write the newest state after any in-flight write completes, so quitting never loses the last change.")
@MainActor
struct AppStatePersisterTerminationTests {

    @Test func terminationWritesThePendingStateBeforeReturning() throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)

        persister.markDirty(state(selecting: "/last-change"))
        try persister.flushSynchronously()

        #expect(writer.written.map(\.selectedWorktreePath) == ["/last-change"])
        #expect(!timer.isArmed, "the armed timer would write a second time after exit began")
    }

    @Test func terminationRetriesAFailedWriteOfTheSameState() throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)
        struct DiskFull: Error {}

        writer.failNextWrite(with: DiskFull())
        persister.markDirty(state(selecting: "/last"))
        timer.fire()  // this write fails
        // applicationWillTerminate re-marks the unchanged state.
        persister.markDirty(state(selecting: "/last"))
        try persister.flushSynchronously()

        #expect(writer.written.map(\.selectedWorktreePath) == ["/last"], "quit after a failed save left state.json stale")
    }

    @Test func terminationWithNothingPendingWritesNothing() throws {
        let writer = RecordingStateWriter()
        let timer = ManualPersistTimer()
        let persister = makePersister(writer, timer)

        try persister.flushSynchronously()

        #expect(writer.written.isEmpty)
    }
}

@Suite("@spec PERSIST-2.8: When `AppState` is marked for saving, the application shall notify the registered change observer on every mark, whether or not a window is open.")
@MainActor
struct AppStatePersisterChangeHookTests {

    @Test func everyMarkNotifiesTheObserverEvenWhileASaveIsArmed() {
        let timer = ManualPersistTimer()
        let persister = makePersister(RecordingStateWriter(), timer)
        var notified = 0
        persister.onMarkDirty = { notified += 1 }

        persister.markDirty(state(selecting: "/a"))
        persister.markDirty(state(selecting: "/b"))

        #expect(notified == 2)
    }
}
