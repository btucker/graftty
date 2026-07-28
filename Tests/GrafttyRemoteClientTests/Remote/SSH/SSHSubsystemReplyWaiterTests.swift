import Foundation
import Testing
@testable import GrafttyRemoteClient

@Suite("SSH subsystem reply waiter")
struct SSHSubsystemReplyWaiterTests {
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
