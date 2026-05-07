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

    @Test(
        "Returns root + spawned child",
        // macOS GitHub Actions runners reproducibly return a
        // truncated `proc_pidinfo` for grandchildren of the swift-
        // test binary even after seconds of polling: `descendants(of:
        // parent)` resolves the parent itself but never picks up the
        // backgrounded sleep child, regardless of shell pattern
        // (sh/bash, `& wait` vs `; sleep`, 5s vs 60s child duration).
        // The walker's tree-walking logic is already covered via the
        // `ProcessTreeWalking` protocol stub in `PortScannerTests`,
        // so this integration assertion stays for local-dev
        // confidence but is skipped where the kernel-level proc info
        // surface diverges.
        .disabled(if: ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true")
    )
    func spawnedChildIncluded() async throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "/bin/sleep 60 & wait"]
        try parent.run()
        defer { parent.terminate() }
        let walker = ProcessTreeWalker()

        // `proc_listpids` + `proc_pidinfo` have a finite registration
        // latency for freshly-`fork()`ed processes, so poll until
        // both /bin/sh and its `/bin/sleep 60 &` child are visible.
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
