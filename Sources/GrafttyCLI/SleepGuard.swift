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
        guard let initial = WorktreeSleepJournal.load(from: url), initial.ownerIsAlive,
              let identity = SleepProcessReader.sample(pid: ProcessInfo.processInfo.processIdentifier)?.identity else {
            throw ValidationError("The sleep journal has no live owner.")
        }
        defer { try? FileManager.default.removeItem(at: readyURL) }
        while let current = WorktreeSleepJournal.load(from: url) {
            guard current.owner == initial.owner else { return }
            try JSONEncoder().encode(SleepGuardReadiness(identity: identity, uptime: ProcessInfo.processInfo.systemUptime)).write(to: readyURL, options: .atomic)
            if !current.ownerIsAlive {
                var recovery = current
                recovery.recover()
                try recovery.save(to: url)
                if recovery.processes.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }
}
