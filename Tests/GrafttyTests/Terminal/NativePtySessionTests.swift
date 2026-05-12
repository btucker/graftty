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
