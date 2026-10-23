import Darwin
import Foundation
import Testing
@testable import GrafttyKit

@Suite(.serialized)
struct WorktreeSleepProcessTests {
    @Test("@spec SLEEP-10: When automatic sleep signals an isolated verified process, the application shall preserve its process identity and resume the same process on wake.")
    func isolatedProcessSurvives() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer {
            _ = kill(process.processIdentifier, SIGCONT)
            process.terminate()
            process.waitUntilExit()
        }
        let initial = try #require(SleepProcessReader.sample(pid: process.processIdentifier))
        #expect(!initial.isStopped)
        let coordinator = WorktreeSleepCoordinator(read: { SleepProcessReader.sample(pid: $0.pid) },
            signal: SleepProcessReader.signal, persist: { _ in true }, recoveryReady: { true })
        #expect(coordinator.suspend(path: "/isolated-test", processes: [initial], recheck: { true }))
        let deadline = Date().addingTimeInterval(2)
        while SleepProcessReader.sample(pid: process.processIdentifier)?.isStopped != true && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(SleepProcessReader.sample(pid: process.processIdentifier)?.isStopped == true)
        #expect(coordinator.wake(path: "/isolated-test"))
        #expect(SleepProcessReader.sample(pid: process.processIdentifier)?.identity == initial.identity)
        #expect(process.isRunning)
    }

    @Test("@spec SLEEP-11: While a previously observed background process remains alive after reparenting, the application shall keep its original worktree awake until that process identity exits.")
    func detachedJobTracking() {
        let tracker = WorktreeSleepJobTracker()
        let task = SleepProcessIdentity(pid: 100, startTime: 200)
        #expect(!tracker.observe(path: "/w", descendants: [task], isAlive: { _ in true }))
        #expect(!tracker.observe(path: "/w", descendants: [], isAlive: { _ in true }))
        #expect(!tracker.observe(path: "/w", descendants: [], isAlive: { _ in nil }))
        #expect(tracker.observe(path: "/w", descendants: [], isAlive: { _ in false }))
        #expect(!tracker.observe(path: "/w", descendants: nil, isAlive: { _ in false }))
    }
}
