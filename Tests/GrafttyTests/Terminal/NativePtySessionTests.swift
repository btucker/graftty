import Darwin
import Foundation
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("NativePtySession — PTY bridge")
struct NativePtySessionTests {
    @Test func forwardsChildOutputToSurfaceSink() throws {
        let recorder = LockedRecorder<Data>()
        let session = NativePtySession(
            argv: ["/bin/sh", "-c", "echo hello; sleep 0.2"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { recorder.append($0) },
            processExited: { _, _ in },
            spawnFailed: { _ in }
        )

        try session.start()
        defer { session.close() }

        try Self.waitUntil {
            String(data: recorder.values().reduce(Data(), +), encoding: .utf8)?.contains("hello") == true
        }
    }

    @Test func writeReachesChildStdin() throws {
        let recorder = LockedRecorder<Data>()
        let session = NativePtySession(
            argv: ["/bin/cat"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { recorder.append($0) },
            processExited: { _, _ in },
            spawnFailed: { _ in }
        )

        try session.start()
        defer { session.close() }

        try session.write(Data("from-stdin\n".utf8))

        try Self.waitUntil {
            String(data: recorder.values().reduce(Data(), +), encoding: .utf8)?.contains("from-stdin") == true
        }
    }

    @Test func concurrentWritesAreSerialized() throws {
        let activeWriters = LockedCounter()
        let maxActiveWriters = LockedCounter()
        let session = NativePtySession(
            argv: ["/bin/sh", "-c", "sleep 2"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { _ in },
            processExited: { _, _ in },
            spawnFailed: { _ in },
            writer: { _, _, _ in
                let active = activeWriters.increment()
                maxActiveWriters.recordMax(active)
                Thread.sleep(forTimeInterval: 0.1)
                _ = activeWriters.decrement()
            }
        )

        try session.start()
        defer { session.close() }

        let group = DispatchGroup()
        for byte in ["a", "b"] {
            group.enter()
            DispatchQueue.global().async {
                try? session.write(Data(byte.utf8))
                group.leave()
            }
        }

        #expect(group.wait(timeout: .now() + 2) == .success)
        #expect(maxActiveWriters.value() == 1)
    }

    @Test func concurrentStartSpawnsAtMostOnceAndOnlyOneCallerSucceeds() throws {
        let spawnAttempts = LockedCounter()
        let startedSpawning = DispatchSemaphore(value: 0)
        let releaseSpawner = DispatchSemaphore(value: 0)
        let session = NativePtySession(
            argv: ["/bin/sh", "-c", "sleep 2"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { _ in },
            processExited: { _, _ in },
            spawnFailed: { _ in },
            spawner: { argv, env, currentDirectory, initialSize in
                _ = spawnAttempts.increment()
                startedSpawning.signal()
                _ = releaseSpawner.wait(timeout: .now() + 2)
                return try PtyProcess.spawn(
                    argv: argv,
                    env: env,
                    currentDirectory: currentDirectory,
                    initialSize: initialSize
                )
            }
        )

        let outcomes = LockedRecorder<Bool>()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outcomes.append((try? session.start()) != nil)
            group.leave()
        }

        #expect(startedSpawning.wait(timeout: .now() + 2) == .success)

        group.enter()
        DispatchQueue.global().async {
            outcomes.append((try? session.start()) != nil)
            group.leave()
        }

        Thread.sleep(forTimeInterval: 0.1)
        releaseSpawner.signal()

        #expect(group.wait(timeout: .now() + 5) == .success)
        defer { session.close() }

        #expect(spawnAttempts.value() == 1)
        #expect(outcomes.values().filter { $0 }.count == 1)
        #expect(outcomes.values().filter { !$0 }.count == 1)
    }

    @Test func closeImmediatelyAfterStartDoesNotCloseFDBeforeReaderOwnsIt() throws {
        let allowReaderToStart = DispatchSemaphore(value: 0)
        let readerObservedOpenFD = LockedRecorder<Bool>()
        let fdCloses = LockedCounter()
        let session = NativePtySession(
            argv: ["/bin/sh", "-c", "sleep 2"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { _ in },
            processExited: { _, _ in },
            spawnFailed: { _ in },
            closer: { spawned in
                Self.terminateChildOnly(spawned)
            },
            fdCloser: { fd in
                _ = fdCloses.increment()
                close(fd)
            },
            readerWillStart: { fd in
                _ = allowReaderToStart.wait(timeout: .now() + 2)
                readerObservedOpenFD.append(fcntl(fd, F_GETFD) != -1)
            }
        )

        try session.start()
        session.close()
        #expect(fdCloses.value() == 0)
        allowReaderToStart.signal()

        try Self.waitUntil {
            readerObservedOpenFD.values().isEmpty == false
        }
        #expect(readerObservedOpenFD.values() == [true])
        try Self.waitUntil {
            fdCloses.value() == 1
        }
    }

    @Test func closeWaitsForInFlightWriteBeforeClosingFD() throws {
        let writerEntered = DispatchSemaphore(value: 0)
        let allowWriterToFinish = DispatchSemaphore(value: 0)
        let closeStartedDuringWrite = LockedCounter()
        let session = NativePtySession(
            argv: ["/bin/sh", "-c", "sleep 2"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { _ in },
            processExited: { _, _ in },
            spawnFailed: { _ in },
            writer: { _, _, _ in
                writerEntered.signal()
                _ = allowWriterToFinish.wait(timeout: .now() + 2)
            },
            closer: { spawned in
                _ = closeStartedDuringWrite.increment()
                Self.terminateChildOnly(spawned)
            }
        )

        try session.start()

        let writeGroup = DispatchGroup()
        writeGroup.enter()
        DispatchQueue.global().async {
            try? session.write(Data("x".utf8))
            writeGroup.leave()
        }

        #expect(writerEntered.wait(timeout: .now() + 2) == .success)

        let closeGroup = DispatchGroup()
        closeGroup.enter()
        DispatchQueue.global().async {
            session.close()
            closeGroup.leave()
        }

        Thread.sleep(forTimeInterval: 0.1)
        #expect(closeStartedDuringWrite.value() == 0)
        allowWriterToFinish.signal()

        #expect(writeGroup.wait(timeout: .now() + 2) == .success)
        #expect(closeGroup.wait(timeout: .now() + 2) == .success)
    }

    @Test func closeWaitsForInFlightResizeBeforeClosingFD() throws {
        let resizeEntered = DispatchSemaphore(value: 0)
        let allowResizeToFinish = DispatchSemaphore(value: 0)
        let closeStartedDuringResize = LockedCounter()
        let session = NativePtySession(
            argv: ["/bin/sh", "-c", "sleep 2"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { _ in },
            processExited: { _, _ in },
            spawnFailed: { _ in },
            resizer: { _, _, _ in
                resizeEntered.signal()
                _ = allowResizeToFinish.wait(timeout: .now() + 2)
            },
            closer: { spawned in
                _ = closeStartedDuringResize.increment()
                Self.terminateChildOnly(spawned)
            }
        )

        try session.start()

        let resizeGroup = DispatchGroup()
        resizeGroup.enter()
        DispatchQueue.global().async {
            try? session.resize(cols: 80, rows: 24)
            resizeGroup.leave()
        }

        #expect(resizeEntered.wait(timeout: .now() + 2) == .success)

        let closeGroup = DispatchGroup()
        closeGroup.enter()
        DispatchQueue.global().async {
            session.close()
            closeGroup.leave()
        }

        Thread.sleep(forTimeInterval: 0.1)
        #expect(closeStartedDuringResize.value() == 0)
        allowResizeToFinish.signal()

        #expect(resizeGroup.wait(timeout: .now() + 2) == .success)
        #expect(closeGroup.wait(timeout: .now() + 2) == .success)
    }

    @Test func resizeChangesSttySize() throws {
        let recorder = LockedRecorder<Data>()
        let session = NativePtySession(
            argv: ["/bin/sh", "-c", "sleep 0.2; stty size; sleep 0.2"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { recorder.append($0) },
            processExited: { _, _ in },
            spawnFailed: { _ in }
        )

        try session.start()
        defer { session.close() }

        try session.resize(cols: 42, rows: 13)

        try Self.waitUntil {
            String(data: recorder.values().reduce(Data(), +), encoding: .utf8)?.contains("13 42") == true
        }
    }

    @Test func closeIsIdempotent() throws {
        let session = NativePtySession(
            argv: ["/bin/sh", "-c", "sleep 2"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { _ in },
            processExited: { _, _ in },
            spawnFailed: { _ in }
        )

        try session.start()

        session.close()
        session.close()
    }

    @Test func processExitCallbackFiresExactlyOnce() throws {
        let exits = LockedRecorder<pid_t>()
        let session = NativePtySession(
            argv: ["/bin/sh", "-c", "echo done"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { _ in },
            processExited: { pid, _ in exits.append(pid) },
            spawnFailed: { _ in }
        )

        try session.start()
        defer { session.close() }

        try Self.waitUntil { exits.values().count == 1 }
        Thread.sleep(forTimeInterval: 0.2)
        #expect(exits.values().count == 1)
    }

    @Test func spawnFailureCallsFailurePathOnceAndLeavesNoLiveFD() throws {
        struct ForcedFailure: Error {}

        let failures = LockedRecorder<String>()
        let session = NativePtySession(
            argv: ["/bin/sh"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { _ in },
            processExited: { _, _ in },
            spawnFailed: { _ in failures.append("failed") },
            spawner: { _, _, _, _ in throw ForcedFailure() }
        )

        #expect(throws: Error.self) {
            try session.start()
        }
        #expect(failures.values().count == 1)
        #expect(session.activeMasterFDForTesting == nil)
        session.close()
        #expect(failures.values().count == 1)
    }

    @Test func spawnFailureIsTerminalAndDoesNotRetryOrRecallFailureCallback() throws {
        struct ForcedFailure: Error {}

        let failures = LockedRecorder<String>()
        let attempts = LockedCounter()
        let session = NativePtySession(
            argv: ["/bin/sh"],
            env: [:],
            workingDirectory: nil,
            writeToSurface: { _ in },
            processExited: { _, _ in },
            spawnFailed: { _ in failures.append("failed") },
            spawner: { _, _, _, _ in
                _ = attempts.increment()
                throw ForcedFailure()
            }
        )

        #expect(throws: Error.self) {
            try session.start()
        }
        #expect(throws: Error.self) {
            try session.start()
        }

        #expect(attempts.value() == 1)
        #expect(failures.values().count == 1)
        #expect(session.activeMasterFDForTesting == nil)
    }

    @Test func ghosttySurfaceInitializerIsAvailableAtCompileTime() {
        func makeSession(surface: ghostty_surface_t) -> NativePtySession {
            NativePtySession(
                surface: surface,
                argv: ["/bin/sh"],
                env: [:],
                workingDirectory: nil,
                spawnFailed: { _ in }
            )
        }

        _ = makeSession
    }

    private static func waitUntil(
        timeout: TimeInterval = 5,
        condition: @escaping () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(condition(), "waitUntil timed out")
    }

    private static func terminateChildOnly(_ spawned: PtyProcess.Spawned) {
        _ = kill(spawned.pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<10 {
            if waitpid(spawned.pid, &status, WNOHANG) != 0 { break }
            usleep(50_000)
        }
    }
}

private final class LockedRecorder<Value> {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    func values() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var stored = 0

    func increment() -> Int {
        lock.lock()
        stored += 1
        let value = stored
        lock.unlock()
        return value
    }

    func decrement() -> Int {
        lock.lock()
        stored -= 1
        let value = stored
        lock.unlock()
        return value
    }

    func recordMax(_ candidate: Int) {
        lock.lock()
        stored = max(stored, candidate)
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
