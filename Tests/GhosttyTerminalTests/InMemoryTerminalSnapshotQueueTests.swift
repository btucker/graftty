@testable import GhosttyTerminal
import Foundation
import GhosttyKit
import Testing

struct InMemoryTerminalSnapshotQueueTests {
    @Test @MainActor
    func `snapshot stays between earlier and later bytes across drain batches`() async {
        let events = SnapshotLockedValues<Int>()
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let access = InMemoryTerminalSurfaceAccess(
            write: { _, data in
                let value = Int(String(decoding: data, as: UTF8.self))!
                if value == 0 {
                    started.signal()
                    finish.wait()
                }
                events.append(value)
            }, processExit: { _, _, _ in }
        )
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 1)!)
        access.enqueueWrite(Data("0".utf8))
        #expect(snapshotQueueSignal(started))
        for value in 1..<130 { access.enqueueWrite(Data("\(value)".utf8)) }
        let installed: Bool? = await withCheckedContinuation { continuation in
            access.enqueueOperation(onMainThread: true, operation: { _ in
                events.append(130)
                return true
            }, completion: { continuation.resume(returning: $0) })
            access.enqueueWrite(Data("131".utf8))
            finish.signal()
        }
        await drainSnapshotQueue(access)
        #expect(installed == true)
        #expect(events.values == Array(0...131))
    }

    @Test @MainActor
    func `main-thread output barriers execute scheduled snapshot work once`() {
        let mainScheduled = DispatchSemaphore(value: 0)
        let pendingMain = SnapshotLockedValues<@Sendable () -> Void>()
        let events = SnapshotLockedValues<String>()
        let access = InMemoryTerminalSurfaceAccess(
            write: { _, _ in }, processExit: { _, _, _ in },
            scheduleOnMain: { operation in
                pendingMain.append(operation)
                mainScheduled.signal()
            }
        )
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 1)!)
        access.enqueueOperation(onMainThread: true, operation: { _ in
            #expect(Thread.isMainThread)
            events.append("installed")
            return true
        }, completion: { _ in events.append("completed") })
        #expect(mainScheduled.wait(timeout: .now() + 2) == .success)
        #expect(access.waitForPendingOutput())
        pendingMain.values.first?()
        #expect(events.values == ["installed", "completed"])
    }

    @Test @MainActor
    func `snapshot installation runs on main and orders history with live writes`() async {
        let events = SnapshotLockedValues<String>()
        let access = InMemoryTerminalSurfaceAccess(
            write: { _, data in events.append(String(decoding: data, as: UTF8.self)) },
            processExit: { _, _, _ in }
        )
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 1)!)
        access.enqueueWrite(Data("before".utf8))
        let installed: Bool? = await withCheckedContinuation { continuation in
            access.enqueueOperation(onMainThread: true, operation: { _ in
                #expect(Thread.isMainThread)
                events.append("ready")
                return true
            }, completion: { continuation.resume(returning: $0) })
            access.enqueueOperation(operation: { _ in
                events.append("page")
                return true
            }, completion: { _ in })
            access.enqueueWrite(Data("after".utf8))
        }
        await drainSnapshotQueue(access)
        #expect(installed == true)
        #expect(events.values == ["before", "ready", "page", "after"])
    }

    @Test @MainActor
    func `surface detach does not wait for an installation dispatched to main`() async {
        let mainScheduled = DispatchSemaphore(value: 0)
        let pendingMain = SnapshotLockedValues<@Sendable () -> Void>()
        let operations = SnapshotLockedValues<String>()
        let access = InMemoryTerminalSurfaceAccess(
            write: { _, _ in },
            processExit: { _, _, _ in },
            scheduleOnMain: { operation in
                pendingMain.append(operation)
                mainScheduled.signal()
            }
        )
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 2)!)
        let result: Bool? = await withCheckedContinuation { continuation in
            access.enqueueOperation(onMainThread: true, operation: { _ in
                operations.append("stale install")
                return true
            }, completion: { continuation.resume(returning: $0) })
            #expect(mainScheduled.wait(timeout: .now() + 2) == .success)
            // This runs on main while the queue is waiting for its main
            // callback. Counting that pending callback as active deadlocks.
            access.setSurface(nil)
            access.setSurface(UnsafeMutableRawPointer(bitPattern: 3)!)
            pendingMain.values.first?()
        }
        #expect(result == nil)
        #expect(operations.values.isEmpty)
        await drainSnapshotQueue(access)
    }

    @Test
    func `missing surfaces complete queued operation callbacks immediately`() async {
        let access = InMemoryTerminalSurfaceAccess(write: { _, _ in }, processExit: { _, _, _ in })
        let result: Bool? = await withCheckedContinuation { continuation in
            access.enqueueOperation(onMainThread: true, operation: { _ in
                Issue.record("Detached surface must not execute a C operation")
                return true
            }, completion: { continuation.resume(returning: $0) })
        }
        #expect(result == nil)
    }

    @Test @MainActor
    func `queued history rejects a replaced surface and releases its continuation`() async {
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let access = InMemoryTerminalSurfaceAccess(write: { _, _ in
            started.signal()
            finish.wait()
        }, processExit: { _, _, _ in })
        access.setSurface(UnsafeMutableRawPointer(bitPattern: 4)!)
        access.enqueueWrite(Data([1]))
        let result: Int? = await withCheckedContinuation { continuation in
            #expect(snapshotQueueSignal(started))
            access.enqueueOperation(operation: { _ in
                Issue.record("History must not reach a replacement surface")
                return 1
            }, completion: { continuation.resume(returning: $0) })
            access.setSurface(nil, whileWaiting: {
                // Retirement publishes nil before asking the host to drain
                // the blocked writer. Do not spin while a global queue waits
                // for CPU to begin replacement.
                #expect(access.currentSurface == nil)
                finish.signal()
            })
            access.setSurface(UnsafeMutableRawPointer(bitPattern: 5)!)
        }
        #expect(result == nil)
        await drainSnapshotQueue(access)
    }
}

private func drainSnapshotQueue(_ access: InMemoryTerminalSurfaceAccess) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            access.waitForPendingOutput()
            continuation.resume()
        }
    }
}

private final class SnapshotLockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private func snapshotQueueSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 2) == .success
}
