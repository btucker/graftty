import Foundation
import Darwin
@testable import GrafttyKit

/// Holds the inter-process worktree watermark lock from a child process
/// until `release()`. A process's own `lockf` calls never conflict with
/// each other, so tests exercising lock contention need a second process;
/// python3's `fcntl.lockf` takes the same fcntl record lock `lockf(3)`
/// does. Mirrors `TeamTestFixtures.holdWatermarkLock` in GrafttyKitTests
/// (test targets cannot share helpers). The python source is built from
/// single-line strings — a `"""` heredoc in a test file derails
/// `scripts/generate-specs.py`'s `@spec` title extraction.
final class WatermarkLockHolder {
    private let process: Process
    private var released = false

    fileprivate init(process: Process) {
        self.process = process
    }

    func release() {
        guard !released else { return }
        released = true
        process.terminate()
        process.waitUntilExit()
    }

    deinit { release() }
}

/// Spawns the lock-holder child for `worktree`'s watermark lock under
/// `root` and returns once the child confirms it holds the lock.
func holdWatermarkLock(
    root: URL,
    teamID: String,
    worktree: String
) throws -> WatermarkLockHolder {
    let lockURL = root
        .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
        .appendingPathComponent("worktrees", isDirectory: true)
        .appendingPathComponent(TeamInbox.fileComponent(worktree) + ".lock")
    try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    let script = [
        "import fcntl, sys, time",
        "f = open(sys.argv[1], \"w\")",
        "fcntl.lockf(f, fcntl.LOCK_EX)",
        "print(\"locked\", flush=True)",
        "time.sleep(30)",
    ].joined(separator: "\n")
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    holder.arguments = ["python3", "-c", script, lockURL.path]
    let stdout = Pipe()
    holder.standardOutput = stdout
    try holder.run()
    // A child blocked before acquiring the lock must fail this test promptly,
    // not leave the entire CI job parked in availableData indefinitely.
    var descriptor = pollfd(fd: stdout.fileHandleForReading.fileDescriptor,
                            events: Int16(POLLIN | POLLHUP), revents: 0)
    let pollResult = poll(&descriptor, 1, 5_000)
    guard pollResult > 0 else {
        holder.terminate()
        holder.waitUntilExit()
        throw CocoaError(.fileReadUnknown)
    }
    let readied = stdout.fileHandleForReading.availableData
    guard String(data: readied, encoding: .utf8)?.contains("locked") == true else {
        holder.terminate()
        holder.waitUntilExit()
        throw CocoaError(.executableLoad)
    }
    return WatermarkLockHolder(process: holder)
}
