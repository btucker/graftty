import Testing
import Foundation
#if os(macOS)
import CoreServices
@testable import GrafttyKit

@Suite("""
@spec GIT-3.24: When an FSEvents subscription is cancelled, the application shall keep its callback context alive until the native stream finishes all callbacks and releases the context, and shall release the subscription's stream at most once.
""", .serialized)
struct WorktreeMonitorFSEventsLifetimeTests {
    @Test func cancellationBeforeContextAcquisitionKeepsContextAlive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CallbackGate()
        CallbackGate.install(gate)
        defer { CallbackGate.install(nil) }
        let queue = DispatchQueue(label: "test.fsevents.entry")
        let subscription = try #require(makeSubscription(directory, queue: queue, gate: gate, callback: gatedCallback))
        // Always unblock the native queue, including on assertion failures.
        defer {
            gate.resume.signal()
            DispatchQueue.global().async { subscription.cancel() }
        }

        try triggerCallback(directory, entered: gate.entered)
        try cancelWithDeadline(subscription)

        // The callback has not read info or retained the context yet. Checking a
        // weak capture lets the old implementation fail without dereferencing
        // the dangling pointer and crashing the test process.
        #expect(gate.payload != nil, "Cancellation freed the context before callback acquisition")
        gate.resume.signal()
        #expect(gate.exited.wait(timeout: .now() + 3) == .success)
        try drainWithDeadline(queue)
        #expect(gate.changed.wait(timeout: .now() + 1) == .success)
        #expect(gate.released.wait(timeout: .now() + 3) == .success)
        #expect(gate.payload == nil)
    }

    @Test func repeatedConcurrentCancellationReleasesContext() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CallbackGate()
        let queue = DispatchQueue(label: "test.fsevents.concurrent-cancel")
        let subscription = try #require(makeSubscription(directory, queue: queue, gate: gate))
        let cancelled = DispatchGroup()
        for _ in 0..<16 {
            cancelled.enter()
            DispatchQueue.global().async {
                subscription.cancel()
                cancelled.leave()
            }
        }
        try #require(cancelled.wait(timeout: .now() + 3) == .success)
        try drainWithDeadline(queue)
        #expect(gate.released.wait(timeout: .now() + 3) == .success)
        #expect(gate.payload == nil)
        try cancelWithDeadline(subscription)
    }

    @Test func subscriptionDeinitCancelsStream() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CallbackGate()
        let queue = DispatchQueue(label: "test.fsevents.deinit")
        let dropped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            dropSubscription(directory, queue: queue, gate: gate)
            dropped.signal()
        }
        try #require(dropped.wait(timeout: .now() + 3) == .success)
        try drainWithDeadline(queue)
        #expect(gate.released.wait(timeout: .now() + 3) == .success)
        #expect(gate.payload == nil)
    }

    @Test func failedStartReleasesContext() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CallbackGate()
        let subscription = makeSubscription(
            directory, queue: DispatchQueue(label: "test.fsevents.start-failure"),
            gate: gate, startStream: { _ in false }
        )
        #expect(subscription == nil)
        #expect(gate.released.wait(timeout: .now() + 3) == .success)
        #expect(gate.payload == nil)
    }

    @Test(arguments: [true, false])
    func cancellationFromCallbackCompletes(cancelInPredicate: Bool) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = CallbackGate()
        let target = CancellationTarget()
        defer { DispatchQueue.global().async { target.cancel() } }
        let queue = DispatchQueue(label: "test.fsevents.reentrant")
        queue.suspend()
        do {
            defer { queue.resume() }
            let subscription = try #require(makeReentrantSubscription(
                directory, queue: queue, gate: gate,
                target: target, cancelInPredicate: cancelInPredicate
            ))
            target.install(subscription)
        }
        try triggerCallback(directory, entered: gate.changed)
        try drainWithDeadline(queue)
        #expect(gate.released.wait(timeout: .now() + 3) == .success)
        #expect(gate.payload == nil)
    }

    private func dropSubscription(_ directory: URL, queue: DispatchQueue, gate: CallbackGate) {
        let subscription = makeSubscription(directory, queue: queue, gate: gate)
        #expect(subscription != nil)
        #expect(gate.payload != nil)
        withExtendedLifetime(subscription) {}
        // The final release, and thus deinit's native teardown, runs here on
        // the background thread rather than blocking the test runner.
    }

    private func cancelWithDeadline(_ subscription: FSEventsSubscription) throws {
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            subscription.cancel()
            cancelled.signal()
        }
        try #require(cancelled.wait(timeout: .now() + 3) == .success)
    }

    private func drainWithDeadline(_ queue: DispatchQueue) throws {
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        try #require(drained.wait(timeout: .now() + 3) == .success)
    }

    private func makeReentrantSubscription(
        _ directory: URL, queue: DispatchQueue, gate: CallbackGate,
        target: CancellationTarget, cancelInPredicate: Bool
    ) -> FSEventsSubscription? {
        let payload = CallbackPayload(changed: gate.changed, released: gate.released)
        gate.payload = payload
        return FSEventsSubscription.make(
            paths: [directory.path], queue: queue, latency: 0.01,
            shouldIgnore: { _ in
                if cancelInPredicate { target.cancel() }
                return false
            },
            onChange: {
                if !cancelInPredicate { target.cancel() }
                payload.didChange()
            }
        )
    }

    private func makeSubscription(
        _ directory: URL, queue: DispatchQueue, gate: CallbackGate,
        callback: FSEventStreamCallback = fileEventsCallback,
        startStream: (FSEventStreamRef) -> Bool = FSEventStreamStart
    ) -> FSEventsSubscription? {
        let payload = CallbackPayload(changed: gate.changed, released: gate.released)
        gate.payload = payload
        return FSEventsSubscription.make(
            paths: [directory.path], queue: queue, latency: 0.01,
            shouldIgnore: { _ in false }, onChange: { payload.didChange() },
            callback: callback, startStream: startStream
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-fsevents-lifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }

    private func triggerCallback(_ directory: URL, entered: DispatchSemaphore) throws {
        // Retry writes while the native stream arms. Every wait has a deadline.
        let deadline = Date().addingTimeInterval(3)
        repeat {
            try Data([1]).write(to: directory.appendingPathComponent("event"))
            if entered.wait(timeout: .now() + 0.05) == .success { return }
        } while Date() < deadline
        throw NativeCallbackTimeout()
    }
}

private struct NativeCallbackTimeout: Error {}

private final class CancellationTarget {
    private let lock = NSLock()
    private var stored: FSEventsSubscription?

    func install(_ subscription: FSEventsSubscription) {
        lock.lock()
        defer { lock.unlock() }
        stored = subscription
    }

    func cancel() {
        lock.lock()
        let subscription = stored
        stored = nil
        lock.unlock()
        subscription?.cancel()
    }
}

private final class CallbackPayload {
    let changed: DispatchSemaphore
    let released: DispatchSemaphore

    init(changed: DispatchSemaphore, released: DispatchSemaphore) {
        self.changed = changed
        self.released = released
    }

    func didChange() { changed.signal() }
    deinit { released.signal() }
}

private final class CallbackGate {
    private static let lock = NSLock()
    private static var installed: CallbackGate?

    static func install(_ gate: CallbackGate?) {
        lock.lock()
        defer { lock.unlock() }
        installed = gate
    }

    static func current() -> CallbackGate? {
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let exited = DispatchSemaphore(value: 0)
    let changed = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    weak var payload: CallbackPayload?
}

private let gatedCallback: FSEventStreamCallback = { stream, info, count, paths, flags, ids in
    // Deliberately do not touch info until cancellation has returned. Fetching
    // the gate must not acquire the production context on the callback's behalf.
    guard let gate = CallbackGate.current() else { return }
    defer { gate.exited.signal() }
    gate.entered.signal()
    guard gate.resume.wait(timeout: .now() + 5) == .success,
          gate.payload != nil else { return }
    fileEventsCallback(stream, info, count, paths, flags, ids)
}
#endif
