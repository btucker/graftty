import Foundation
import Testing
@testable import GrafttyKit

@Suite("Background zmx PID resolution")
struct ZmxPIDResolverTests {
    @Test("@spec PORTS-4.6: When the port scanner resolves a pending pane's shell PID, the application shall read and parse zmx logs off the main thread.")
    @MainActor
    func readsOffMainThread() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("session.log")
        try "pty spawned session=session pid=4242\n".write(to: log, atomically: true, encoding: .utf8)
        let resolver = ZmxPIDResolver(readLog: { url in
            #expect(!Thread.isMainThread)
            return try? String(contentsOf: url, encoding: .utf8)
        })
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == 4242)
    }

    @Test("@spec PORTS-4.7: While a zmx log remains cached and unchanged, the application shall reuse its unsuccessful PID lookup; when the log is appended, replaced, truncated, or created, the application shall retry resolution, including the rotated log fallback.")
    func retriesOnlyChangedLogs() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("session.log")
        let rotated = directory.appendingPathComponent("session.log.old")
        let reads = ReadCounts()
        let resolver = ZmxPIDResolver(readLog: { url in
            reads.record(url)
            return try? String(contentsOf: url, encoding: .utf8)
        })

        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == nil)
        try "no spawn marker\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == nil)
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == nil)
        #expect(reads.count(log) == 1)

        // A new rotated file must be considered even if the current log did not change.
        try "pty spawned session=session pid=1111\n".write(to: rotated, atomically: true, encoding: .utf8)
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == 1111)
        #expect(reads.count(log) == 1)
        #expect(reads.count(rotated) == 1)

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("pty spawned session=session pid=2222\n".utf8))
        try handle.close()
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == 2222)
        #expect(reads.count(log) == 2)

        // Atomic replacement can preserve size and mtime but changes file identity.
        let oldDate = try #require(try FileManager.default.attributesOfItem(atPath: log.path)[.modificationDate] as? Date)
        try "no spawn marker\npty spawned session=session pid=3333\n".write(to: log, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: log.path)
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == 3333)

        try "".write(to: log, atomically: false, encoding: .utf8)
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == 1111)
        #expect(reads.count(rotated) == 1)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("A transient log read failure does not suppress later resolution")
    func retriesReadFailures() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("session.log")
        try "pty spawned session=session pid=4242\n".write(to: log, atomically: true, encoding: .utf8)
        let reads = ReadCounts()
        let resolver = ZmxPIDResolver(readLog: { url in
            reads.record(url)
            guard reads.count(url) > 1 else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        })
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == nil)
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == 4242)
    }

    @Test("A log replaced during reading does not supply a stale PID")
    func rejectsPIDFromReplacedLog() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("session.log")
        try "pty spawned session=session pid=1111\n".write(to: log, atomically: true, encoding: .utf8)
        let reads = ReadCounts()
        let resolver = ZmxPIDResolver(readLog: { url in
            reads.record(url)
            let contents = try? String(contentsOf: url, encoding: .utf8)
            if reads.count(url) == 1 {
                try? "pty spawned session=session pid=2222\n".write(to: url, atomically: true, encoding: .utf8)
            }
            return contents
        })
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == nil)
        #expect(await resolver.shellPID(logFile: log, sessionName: "session") == 2222)
    }

    private final class ReadCounts: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [URL: Int] = [:]

        func record(_ url: URL) { lock.withLock { counts[url, default: 0] += 1 } }
        func count(_ url: URL) -> Int { lock.withLock { counts[url, default: 0] } }
    }
}
