import Darwin
import Foundation
import Testing
@testable import GrafttyKit

@Suite(.serialized)
struct WorktreeSleepRecoveryTests {
    @Test("@spec SLEEP-12: If the recovery helper is unavailable or suspension ownership cannot be verified, then the application shall keep the worktree awake without sending SIGSTOP.")
    func missingHelper() {
        var signals = 0
        let sample = SleepProcessSample(identity: .init(pid: 100, startTime: 200), cpuNanoseconds: 0, diskBytes: 0, isStopped: false)
        let coordinator = WorktreeSleepCoordinator(read: { _ in sample }, signal: { _, _ in signals += 1; return true }, persist: { _ in true }, recoveryReady: { false })
        #expect(!coordinator.suspend(path: "/w", processes: [sample], recheck: { true }))
        #expect(signals == 0)
    }

    @Test("@spec SLEEP-13: When the owning application crashes, the independent recovery helper shall resume only its journaled process identities and remove completed recovery records.")
    func watchdogRecoversAfterOwnerDies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sleep-guard-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try helper()
        let target = try helper()
        defer {
            for process in [owner, target] {
                _ = kill(process.processIdentifier, SIGCONT)
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
            }
        }
        let ownerIdentity = try #require(SleepProcessReader.sample(pid: owner.processIdentifier)?.identity)
        let targetIdentity = try #require(SleepProcessReader.sample(pid: target.processIdentifier)?.identity)
        let journalURL = directory.appendingPathComponent("journal.json")
        let readyURL = directory.appendingPathComponent("ready")
        try WorktreeSleepJournal(owner: ownerIdentity, processes: [.init(path: "/isolated-test", identity: targetIdentity)]).save(to: journalURL)
        let guardProcess = Process()
        guardProcess.executableURL = try guardExecutable()
        guardProcess.arguments = ["internal", "sleep-guard", "--journal", journalURL.path, "--ready", readyURL.path]
        guardProcess.standardOutput = FileHandle.nullDevice
        guardProcess.standardError = FileHandle.nullDevice
        try guardProcess.run()
        defer { if guardProcess.isRunning { guardProcess.terminate() }; guardProcess.waitUntilExit() }
        try wait { FileManager.default.fileExists(atPath: readyURL.path) }
        #expect(SleepProcessReader.signal(targetIdentity, stop: true))
        try wait { SleepProcessReader.sample(pid: targetIdentity.pid)?.isStopped == true }
        _ = kill(ownerIdentity.pid, SIGKILL)
        owner.waitUntilExit()
        try wait { !guardProcess.isRunning }
        #expect(target.isRunning)
        #expect(SleepProcessReader.sample(pid: targetIdentity.pid)?.isStopped == false)
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test("Recovery preserves unreadable identities and drops reused PIDs without signaling")
    func journalIdentityFailures() {
        let owner = SleepProcessIdentity(pid: 1, startTime: 1)
        let identity = SleepProcessIdentity(pid: 100, startTime: 200)
        var journal = WorktreeSleepJournal(owner: owner, processes: [.init(path: "/w", identity: identity)])
        var signals = 0
        journal.recover(identity: { _ in 200 }, read: { _ in nil }, signal: { _, _ in signals += 1; return true })
        #expect(journal.processes.count == 1)
        journal.recover(identity: { _ in 201 }, read: { _ in nil }, signal: { _, _ in signals += 1; return true })
        #expect(journal.processes.isEmpty)
        #expect(signals == 0)
    }

    private func helper() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func wait(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(6)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(condition())
    }

    private func guardExecutable() throws -> URL {
        var directory = Bundle.module.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("graftty-cli")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "SleepGuardTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "The package's graftty-cli test helper was not built."])
    }
}
