import Foundation
import Testing
@testable import GrafttyRemoteClient

@Suite("SSH subsystem reply waiter")
struct SSHSubsystemReplyWaiterTests {
    @Test("@spec REMOTE-11.9: If an SSH subsystem reply does not arrive before its deadline, then the client shall abort the wait using elapsed time independently of the transport event-loop clock.")
    func elapsedTimeAbortsWait() async throws {
        let events = WaiterEvents()
        let waiter = SSHSubsystemReplyWaiter()
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(2)) }
            catch { return }
            waiter.finish(.failure(TestError.channelClosed))
        }
        defer { watchdog.cancel() }

        await #expect(throws: TestError.timedOut) {
            try await waiter.wait(
                timeout: .milliseconds(25),
                timeoutError: TestError.timedOut,
                onAbort: { events.recordAbort() },
                start: { events.recordStart() }
            )
        }
        // The abort action completes before the waiter resumes (REMOTE-11.24).
        #expect(events.abortCount == 1)
        #expect(events.startCount == 1)
    }

    @Test("a close before wait registration is observed immediately")
    func completionBeforeWaitRegistration() async {
        let deadline = ManualDeadline()
        let events = WaiterEvents()
        let waiter = SSHSubsystemReplyWaiter()

        waiter.finish(.failure(TestError.channelClosed))

        await #expect(throws: TestError.channelClosed) {
            try await waiter.wait(
                scheduleTimeout: { callback in
                    deadline.schedule(callback)
                },
                timeoutError: TestError.timedOut,
                onAbort: { events.recordAbort() },
                start: { events.recordStart() }
            )
        }
        #expect(events.startCount == 0)
        #expect(events.abortCount == 0)
    }

    @Test("cancelling a registered wait aborts and resumes it")
    func cancellationAbortsWait() async throws {
        let deadline = ManualDeadline()
        let events = WaiterEvents()
        let waiter = SSHSubsystemReplyWaiter()
        let task = Task {
            try await waiter.wait(
                scheduleTimeout: { callback in
                    deadline.schedule(callback)
                },
                timeoutError: TestError.timedOut,
                onAbort: { events.recordAbort() },
                start: { events.recordStart() }
            )
        }
        await events.waitUntilStarted()

        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(events.abortCount == 1)
        #expect(deadline.cancelCount == 1)
    }

    @Test("deadline aborts and resumes a subsystem reply wait")
    func deadlineAbortsWait() async throws {
        let deadline = ManualDeadline()
        let events = WaiterEvents()
        let waiter = SSHSubsystemReplyWaiter()
        let task = Task {
            try await waiter.wait(
                scheduleTimeout: { callback in
                    deadline.schedule(callback)
                },
                timeoutError: TestError.timedOut,
                onAbort: { events.recordAbort() },
                start: { events.recordStart() }
            )
        }
        await events.waitUntilStarted()

        deadline.fire()

        await #expect(throws: TestError.timedOut) {
            try await task.value
        }
        #expect(events.abortCount == 1)
    }

    enum AbortTrigger: CaseIterable, Sendable {
        case deadline, cancellation
    }

    @Test("@spec REMOTE-11.24: When an SSH reply deadline or cancellation wins, the client shall run its abort action before resuming the waiting caller, so a caller can never act on a channel that is about to be torn down.", arguments: AbortTrigger.allCases)
    @available(macOS 15.0, iOS 18.0, *)
    func abortRunsBeforeTheCallerResumes(trigger: AbortTrigger) async throws {
        let deadline = ManualDeadline()
        let events = WaiterEvents()
        let order = OrderLog()
        let waiter = SSHSubsystemReplyWaiter()
        // The caller prefers an executor this test drains by hand, so resuming
        // its continuation enqueues a job there synchronously. `onAbort` can
        // then see, with no spinning and no clock, whether the caller was
        // already resumed.
        let executor = ManualTaskExecutor()
        let task = Task(executorPreference: executor) {
            do {
                try await waiter.wait(
                    scheduleTimeout: { callback in deadline.schedule(callback) },
                    timeoutError: TestError.timedOut,
                    onAbort: {
                        order.append(executor.pendingJobCount == 0 ? "aborted" : "aborted-after-resume")
                    },
                    start: { events.recordStart() }
                )
            } catch {
                order.append("resumed")
            }
        }
        executor.runUntilQueueIsEmpty()
        try #require(events.startCount == 1)

        switch trigger {
        case .deadline: deadline.fire()
        case .cancellation: task.cancel()
        }
        // The resume must route through `executor`, or `onAbort` could not
        // tell whether the caller was already resumed.
        #expect(executor.pendingJobCount == 1)
        executor.runUntilQueueIsEmpty()

        #expect(order.entries == ["aborted", "resumed"])
        // A caller that never resumed would hang `task.value`.
        try #require(order.entries.last == "resumed")
        await task.value
    }

    @Test("a reply cancels its deadline and ignores a late timeout")
    func replyWinsTimeoutRace() async throws {
        let deadline = ManualDeadline()
        let events = WaiterEvents()
        let waiter = SSHSubsystemReplyWaiter()
        let task = Task {
            try await waiter.wait(
                scheduleTimeout: { callback in
                    deadline.schedule(callback)
                },
                timeoutError: TestError.timedOut,
                onAbort: { events.recordAbort() },
                start: { events.recordStart() }
            )
        }
        await events.waitUntilStarted()

        waiter.finish(.success(()))
        try await task.value
        deadline.fire()

        #expect(events.abortCount == 0)
        #expect(deadline.cancelCount == 1)
    }
}

private enum TestError: Error {
    case channelClosed
    case timedOut
}

private final class ManualDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private var cancellations = 0

    var cancelCount: Int {
        lock.withLock { cancellations }
    }

    func schedule(
        _ callback: @escaping @Sendable () -> Void
    ) -> @Sendable () -> Void {
        lock.withLock { self.callback = callback }
        return { [weak self] in
            self?.lock.withLock {
                self?.cancellations += 1
            }
        }
    }

    func fire() {
        let callback = lock.withLock { self.callback }
        callback?()
    }
}

/// A task executor whose jobs run only when the test drains them, mirroring
/// NIOTestUtils' package-scoped `ManualTaskExecutor`.
@available(macOS 15.0, iOS 18.0, *)
private final class ManualTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [UnownedJob] = []

    var pendingJobCount: Int { lock.withLock { jobs.count } }

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        lock.withLock { jobs.append(unownedJob) }
    }

    /// Synchronously runs queued jobs, including any they enqueue, until none
    /// remain. Each task preferring this executor is then suspended or done.
    func runUntilQueueIsEmpty() {
        while let job = lock.withLock({ jobs.isEmpty ? nil : jobs.removeFirst() }) {
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var entries: [String] { lock.withLock { log } }
    func append(_ entry: String) { lock.withLock { log.append(entry) } }
}

private final class WaiterEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var aborts = 0

    var abortCount: Int {
        lock.withLock { aborts }
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    func recordStart() {
        lock.withLock { starts += 1 }
    }

    func recordAbort() {
        lock.withLock { aborts += 1 }
    }

    func waitUntilStarted() async {
        while lock.withLock({ starts == 0 }) {
            await Task.yield()
        }
    }
}
