import Foundation
import Testing
@testable import GrafttyKit

@Suite("Automatic worktree suspension")
struct WorktreeSleepTests {
    @Test("@spec SLEEP-1: If automatic sleep is disabled, a worktree is viewed, Keep Awake is enabled, or any activity evidence is unknown, then the application shall keep the worktree awake.")
    func eligibility() {
        var evidence = WorktreeSleepEvidence()
        #expect(!evidence.allowsSleep)
        evidence.enabled = true
        evidence.allPanesInactive = true
        evidence.providerActivityKnownIdle = true
        evidence.processActivityKnownIdle = true
        #expect(evidence.allowsSleep)
        evidence.hasViewer = true
        #expect(!evidence.allowsSleep)
        evidence.hasViewer = false
        evidence.keepAwake = true
        #expect(!evidence.allowsSleep)
        evidence.keepAwake = false
        evidence.providerActivityKnownIdle = false
        #expect(!evidence.allowsSleep)
    }

    @Test("@spec SLEEP-2: While a pane has unverified descendants, changed process identity, missing counters, or sustained CPU or disk activity, the application shall reset its automatic sleep inactivity window.")
    func activityWindow() {
        var window = WorktreeSleepActivityWindow()
        let p = SleepProcessIdentity(pid: 100, startTime: 200)
        let sample = SleepProcessSample(identity: p, cpuNanoseconds: 5, diskBytes: 5, isStopped: false)
        let first = window.observe([sample], at: 0, duration: 10)
        #expect(!first)
        let beforeDeadline = window.observe([sample], at: 9, duration: 10)
        #expect(!beforeDeadline)
        let atDeadline = window.observe([sample], at: 10, duration: 10)
        #expect(atDeadline)
        let missing = window.observe(nil, at: 11, duration: 10)
        #expect(!missing)
        let afterMissing = window.observe([sample], at: 20, duration: 10)
        #expect(!afterMissing)
        let changed = SleepProcessSample(identity: p, cpuNanoseconds: 50_000_005, diskBytes: 5, isStopped: false)
        let cpuActivity = window.observe([changed], at: 21, duration: 10)
        #expect(!cpuActivity)
        let afterCPUActivity = window.observe([changed], at: 30, duration: 10)
        #expect(!afterCPUActivity)
        let reused = SleepProcessSample(identity: .init(pid: 100, startTime: 201), cpuNanoseconds: 5, diskBytes: 5, isStopped: false)
        let afterPIDReuse = window.observe([reused], at: 40, duration: 10)
        #expect(!afterPIDReuse)
    }

    @Test("@spec SLEEP-3: When automatic suspension fails or eligibility changes during suspension, the application shall resume only the processes it suspended and retain failed resumes for recovery.")
    func rollback() throws {
        let fake = SleepFake()
        let coordinator = fake.coordinator()
        fake.failStopPID = 101
        #expect(!coordinator.suspend(path: "/w", processes: fake.samples, recheck: { true }))
        #expect(fake.signals == ["stop:100", "stop:101", "continue:100"])
        #expect(!coordinator.isSleeping(path: "/w"))
        #expect(fake.journal.isEmpty)
    }

    @Test("@spec SLEEP-4: When a sleeping worktree receives an interaction, the application shall serialize resume with suspension and verify process identity before sending SIGCONT.")
    func wakeAndPIDReuse() {
        let fake = SleepFake()
        let coordinator = fake.coordinator()
        #expect(coordinator.suspend(path: "/w", processes: fake.samples, recheck: { true }))
        #expect(coordinator.isSleeping(path: "/w"))
        fake.samples[0] = .init(identity: .init(pid: 100, startTime: 999), cpuNanoseconds: 0, diskBytes: 0, isStopped: false)
        #expect(coordinator.wake(path: "/w"))
        #expect(fake.signals == ["stop:100", "stop:101", "continue:101"])
        #expect(fake.journal.isEmpty)
    }

    @Test("@spec SLEEP-5: If a process was already stopped, ownership changed, or recovery tracking cannot be persisted, then the application shall refuse automatic suspension.")
    func refusal() {
        let fake = SleepFake()
        let coordinator = fake.coordinator()
        fake.canPersist = false
        #expect(!coordinator.suspend(path: "/w", processes: fake.samples, recheck: { true }))
        #expect(fake.signals.isEmpty)
        fake.canPersist = true
        fake.samples[0].isStopped = true
        #expect(!coordinator.suspend(path: "/w", processes: fake.samples, recheck: { true }))
        #expect(fake.signals.isEmpty)
    }

    @Test("@spec SLEEP-6: When Graftty exits or recovery detects its recorded owner is gone, the application shall resume its identity-matching suspended processes without restarting terminal sessions.")
    func recovery() {
        let fake = SleepFake()
        let coordinator = fake.coordinator()
        #expect(coordinator.suspend(path: "/w", processes: fake.samples, recheck: { true }))
        fake.failContinuePID = 100
        #expect(!coordinator.wake(path: "/w"))
        #expect(fake.journal.map(\.identity.pid) == [100])
        fake.failContinuePID = nil
        #expect(coordinator.wakeAll())
        #expect(fake.journal.isEmpty)
    }

    @Test("@spec SLEEP-9: If a wake or interaction arrives during eligibility rechecking, then the application shall cancel suspension before sending a stop signal.")
    func wakeDuringRecheck() {
        let fake = SleepFake()
        let coordinator = fake.coordinator()
        #expect(!coordinator.suspend(path: "/w", processes: fake.samples, recheck: {
            _ = coordinator.wake(path: "/w")
            return true
        }))
        #expect(fake.signals.isEmpty)
    }

    @Test("Eligibility changing after the first stop rolls back its journal and signals")
    func activityDuringPartialStop() {
        let fake = SleepFake()
        let coordinator = fake.coordinator()
        #expect(!coordinator.suspend(path: "/w", processes: fake.samples, recheck: { fake.signals.isEmpty }))
        #expect(fake.signals == ["stop:100", "continue:100"])
        #expect(fake.journal.isEmpty)
    }
}

private final class SleepFake {
    var samples = [100, 101].map { SleepProcessSample(identity: .init(pid: Int32($0), startTime: 200), cpuNanoseconds: 0, diskBytes: 0, isStopped: false) }
    var signals: [String] = []
    var journal: [SuspendedSleepProcess] = []
    var canPersist = true
    var failStopPID: Int32?
    var failContinuePID: Int32?

    func coordinator() -> WorktreeSleepCoordinator {
        WorktreeSleepCoordinator(
            read: { [self] identity in samples.first { $0.identity.pid == identity.pid } },
            signal: { [self] identity, stop in
                signals.append("\(stop ? "stop" : "continue"):\(identity.pid)")
                if stop && failStopPID == identity.pid { return false }
                if !stop && failContinuePID == identity.pid { return false }
                if let index = samples.firstIndex(where: { $0.identity == identity }) { samples[index].isStopped = stop }
                return true
            },
            persist: { [self] records in
                guard canPersist else { return false }
                journal = records
                return true
            },
            recoveryReady: { true }
        )
    }
}
