import ArgumentParser
import Foundation
import GrafttyKit

/// Separate from the GUI and pane-owned processes. It outlives a GUI crash
/// and only resumes identities recorded by that exact application instance.
struct SleepGuard: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sleep-guard", abstract: "Recover worktree suspension after the owning app exits.")

    @Option var journal: String
    @Option var ready: String

    func run() throws {
        let url = URL(fileURLWithPath: journal)
        let readyURL = URL(fileURLWithPath: ready)
        guard let lease = WorktreeSleepRecoveryLease(journal: url) else {
            throw ValidationError("The sleep journal already has a recovery owner.")
        }
        defer { withExtendedLifetime(lease) {} }
        guard let initial = WorktreeSleepJournal.load(from: url), initial.ownerIsAlive,
              let identity = SleepProcessReader.sample(pid: ProcessInfo.processInfo.processIdentifier)?.identity else {
            throw ValidationError("The sleep journal has no live owner.")
        }
        defer { try? FileManager.default.removeItem(at: readyURL) }
        var pendingRecovery: WorktreeSleepJournal?
        while let current = WorktreeSleepJournal.load(from: url) {
            guard current.owner == initial.owner else { return }
            if !current.ownerIsAlive {
                var recovery = pendingRecovery ?? current
                recovery.recover()
                pendingRecovery = recovery
                do {
                    try recovery.save(to: url)
                    if recovery.processes.isEmpty { try FileManager.default.removeItem(at: url); return }
                } catch {
                    // Resume does not depend on heartbeat or disk availability.
                    // Retain successful resumes in memory while clearing the
                    // durable journal is retried, so they are not signaled twice.
                }
            }
            try? JSONEncoder().encode(SleepGuardReadiness(identity: identity, uptime: ProcessInfo.processInfo.systemUptime)).write(to: readyURL, options: .atomic)
            Thread.sleep(forTimeInterval: 2)
        }
    }
}
