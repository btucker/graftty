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
        try await Task.sleep(for: .milliseconds(150))
        let walker = ProcessTreeWalker()
        let pids = walker.descendants(of: parent.processIdentifier)
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
