@testable import GhosttyTerminal
import Foundation
import Testing

struct InMemoryTerminalSnapshotTests {
    @Test
    func `native history statuses distinguish discarded pages from loaded rows`() {
        #expect(InMemoryTerminalHistoryResult(status: 1, appliedRows: 42) == .applied(rows: 42))
        #expect(InMemoryTerminalHistoryResult(status: 1, appliedRows: 0) == .failed)
        #expect(InMemoryTerminalHistoryResult(status: 1, appliedRows: -1) == .failed)
        #expect(InMemoryTerminalHistoryResult(status: 2, appliedRows: 0) == .requiresRecovery)
        #expect(InMemoryTerminalHistoryResult(status: 3, appliedRows: 0) == .limitReached)
        #expect(InMemoryTerminalHistoryResult(status: 4, appliedRows: 0) == .stale)
        #expect(InMemoryTerminalHistoryResult(status: -1, appliedRows: 0) == .failed)
        #expect(InMemoryTerminalHistoryResult(status: 99, appliedRows: 5) == .failed)
    }

    @Test(arguments: ["complete", "cancel", "detach"])
    func `output flush waits for earlier writes and handles cancellation or detach`(mode: String) async {
        let writeStarted = DispatchSemaphore(value: 0)
        let finishWrite = DispatchSemaphore(value: 0)
        let flushStarted = DispatchSemaphore(value: 0)
        let flushFinished = DispatchSemaphore(value: 0)
        let session = InMemoryTerminalSession(
            write: { _ in }, resize: { _ in }, surfaceWrite: { _, _ in
                writeStarted.signal()
                finishWrite.wait()
            }
        )
        session.setSurface(UnsafeMutableRawPointer(bitPattern: 12)!)
        session.receive(Data([1]))
        #expect(await waitForSnapshotSignal(writeStarted))
        let flushing = Task.detached {
            flushStarted.signal()
            let result = await session.flushOutput()
            flushFinished.signal()
            return result
        }
        #expect(await waitForSnapshotSignal(flushStarted))
        #expect(await waitForSnapshotSignal(flushFinished, timeout: 0.1) == false)
        if mode == "cancel" { flushing.cancel() }
        if mode == "detach" {
            DispatchQueue.global().async { session.setSurface(nil) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while session.currentSurface != nil && ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(session.currentSurface == nil)
        }
        finishWrite.signal()
        #expect(await flushing.value == (mode == "complete"))
        session.setSurface(nil)
        #expect(await session.flushOutput() == false)
    }

    @Test @MainActor
    func `session forwards checkpoint generation screen and native results`() async {
        let expected = Data([1, 2, 3])
        let session = InMemoryTerminalSession(
            write: { _ in }, resize: { _ in }, surfaceWrite: { _, _ in },
            snapshotOperations: InMemoryTerminalSnapshotOperations(
                install: { _, data, generation in
                    #expect(Thread.isMainThread)
                    #expect(data == expected)
                    #expect(generation == 77)
                    return true
                },
                append: { _, data, generation, screen in
                    #expect(data == expected)
                    #expect(generation == 77)
                    #expect(screen == 1)
                    return .applied(rows: 9)
                },
                nearTop: { _, generation, screen, threshold in
                    generation == 77 && screen == 1 && threshold == 32
                },
                gridMatches: { _, columns, rows in columns == 80 && rows == 24 }
            )
        )
        session.setSurface(UnsafeMutableRawPointer(bitPattern: 10)!)
        #expect(await session.installSnapshot(expected, generation: 77))
        #expect(await session.appendHistory(expected, generation: 77, screen: 1) == .applied(rows: 9))
        #expect(session.nearHistoryTop(generation: 77, screen: 1, thresholdRows: 32))
        #expect(session.gridMatches(columns: 80, rows: 24))
        session.setSurface(nil)
        #expect(await session.installSnapshot(expected, generation: 77) == false)
        #expect(await session.appendHistory(expected, generation: 77, screen: 1) == .stale)
        #expect(session.nearHistoryTop(generation: 77, screen: 1) == false)
        #expect(session.gridMatches(columns: 80, rows: 24) == false)
    }

    @Test @MainActor
    func `canceled installation never calls native snapshot installation`() async {
        let session = InMemoryTerminalSession(
            write: { _ in }, resize: { _ in }, surfaceWrite: { _, _ in },
            snapshotOperations: InMemoryTerminalSnapshotOperations(
                install: { _, _, _ in
                    Issue.record("Canceled installation reached the native surface")
                    return true
                },
                append: { _, _, _, _ in .failed },
                nearTop: { _, _, _, _ in false },
                gridMatches: { _, _, _ in false }
            )
        )
        session.setSurface(UnsafeMutableRawPointer(bitPattern: 11)!)
        let pending = Task { await session.installSnapshot(Data([1]), generation: 1) }
        pending.cancel()
        #expect(await pending.value == false)
    }
}

private func waitForSnapshotSignal(_ signal: DispatchSemaphore, timeout: TimeInterval = 2) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: signal.wait(timeout: .now() + timeout) == .success)
        }
    }
}
