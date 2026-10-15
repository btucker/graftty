import ArgumentParser
import Foundation
import GrafttyKit

struct WorktreeKeepAwake: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "keep-awake", abstract: "Keep this pane's worktree awake for a verified process lifetime.")
    @Option(help: "PID of a task currently owned by this pane") var pid: Int32

    func run() throws {
        let path = try CLIEnv.resolveWorktree()
        guard let session = ProcessInfo.processInfo.environment["ZMX_SESSION"],
              let worktree = try AppState.load(from: AppState.defaultDirectory).worktree(forPath: path),
              worktree.paneSlot(forSessionName: session) != nil else {
            throw ValidationError("Run this command inside the task's Graftty pane.")
        }
        let launcher = ZmxLauncher(executable: URL(fileURLWithPath: "/unused"))
        guard let shellPID = ZmxPIDLookup.shellPID(logFile: launcher.logFile(forSession: session), sessionName: session),
              let root = SleepProcessReader.sample(pid: shellPID)?.identity,
              ProcessTreeWalker().descendants(of: shellPID).contains(pid),
              let task = SleepProcessReader.sample(pid: pid)?.identity else {
            throw ValidationError("The task must be a live process in this pane's process tree.")
        }
        try SleepKeepAwakeRegistration(path: path, root: root, task: task).save()
        print("Keeping worktree awake until pid \(pid) exits.")
    }
}
