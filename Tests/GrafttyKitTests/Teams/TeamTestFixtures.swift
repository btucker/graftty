import Foundation
@testable import GrafttyKit

enum TeamTestFixtures {
    /// Holds the inter-process worktree watermark lock from a child
    /// process until `release()`. A process's own `lockf` calls never
    /// conflict with each other, so tests exercising lock contention need
    /// a second process; python3's `fcntl.lockf` takes the same fcntl
    /// record lock `lockf(3)` does. The python source is deliberately
    /// built from single-line strings — a `"""` heredoc in a test file
    /// derails `scripts/generate-specs.py`'s `@spec` title extraction.
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
    static func holdWatermarkLock(
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
        // Block until the child reports the lock is held.
        let readied = stdout.fileHandleForReading.availableData
        guard String(data: readied, encoding: .utf8)?.contains("locked") == true else {
            holder.terminate()
            holder.waitUntilExit()
            throw CocoaError(.executableLoad)
        }
        return WatermarkLockHolder(process: holder)
    }

    /// Deterministic `message-N` inbox IDs for `TeamInbox(idGenerator:)`.
    final class SequentialMessageIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> String {
            lock.withLock {
                count += 1
                return "message-\(count)"
            }
        }
    }

    /// The team events a `TeamEventLog(rootDirectory: root)` appended, in
    /// order; empty when the log was never written.
    static func events(root: URL, teamID: String) throws -> [TeamEvent] {
        let url = root
            .appendingPathComponent(TeamInbox.fileComponent(teamID), isDirectory: true)
            .appendingPathComponent("events.jsonl")
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: UInt8(ascii: "\n")).map {
            try decoder.decode(TeamEvent.self, from: Data($0))
        }
    }

    static func makeRepo(
        path: String = "/r/multi",
        displayName: String = "multi-repo",
        branches: [String]
    ) -> RepoEntry {
        var repo = RepoEntry(path: path, displayName: displayName)
        for (i, b) in branches.enumerated() {
            let worktreePath = i == 0
                ? path
                : "\(path)/.worktrees/\(b.replacingOccurrences(of: "/", with: "-"))"
            repo.worktrees.append(WorktreeEntry(path: worktreePath, branch: b))
        }
        return repo
    }
}
