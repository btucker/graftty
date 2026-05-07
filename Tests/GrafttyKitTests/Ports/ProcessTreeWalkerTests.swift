// Tests/GrafttyKitTests/Ports/ProcessTreeWalkerTests.swift
import Testing
import Foundation
import Darwin
@testable import GrafttyKit

@Suite("ProcessTreeWalker")
struct ProcessTreeWalkerTests {
    @Test("Includes the root PID itself")
    func includesRoot() {
        let walker = ProcessTreeWalker()
        let pids = walker.descendants(of: getpid())
        #expect(pids.contains(getpid()))
    }

    @Test("Returns just the root PID when it has no children")
    func leafPID() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }
        let walker = ProcessTreeWalker()
        let pids = walker.descendants(of: process.processIdentifier)
        #expect(pids == [process.processIdentifier])
    }

    @Test("Returns root + spawned child")
    func spawnedChildIncluded() async throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/bash")
        parent.arguments = ["-c", "sleep 5 & wait"]
        try parent.run()
        defer { parent.terminate() }
        let walker = ProcessTreeWalker()

        // `proc_listpids` + `proc_pidinfo` have a finite registration
        // latency for freshly-`fork()`ed processes: a process can be
        // alive (`kill(pid, 0)` succeeds) yet still have `proc_pidinfo`
        // return zero bytes while the kernel populates `proc_bsdinfo`.
        // A fixed sleep can't bound this on a loaded CI runner, so
        // poll until both bash and its `sleep 5 &` child are visible.
        var pids: [pid_t] = []
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            pids = walker.descendants(of: parent.processIdentifier)
            if pids.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(pids.contains(parent.processIdentifier))
        #expect(pids.count >= 2)
    }

    @Test("Unknown PID returns empty")
    func unknownPID() {
        let walker = ProcessTreeWalker()
        let pids = walker.descendants(of: 999_999)
        #expect(pids.isEmpty)
    }
}
