import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("Worktree creation progress")
struct WorktreeCreationProgressTests {
    @Test("@spec GIT-5.25: While Git and its worktree hooks are running, the application shall publish bounded stdout and stderr before Git exits, without waiting for a CLI connection.")
    @MainActor func hookOutputArrivesBeforeCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await GitRunner.run(args: ["init", "-b", "main"], at: root.path)
        _ = try await GitRunner.run(args: ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial"], at: root.path)
        let gate = root.appendingPathComponent("release")
        let hook = root.appendingPathComponent(".git/hooks/post-checkout")
        try """
        #!/bin/sh
        echo 'hook stdout: waiting for setup lock'
        echo 'hook stderr: still running' >&2
        while [ ! -f '\(gate.path)' ]; do sleep 0.02; done
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        // A broken streaming implementation must fail rather than hang the test.
        let fallback = Task {
            try await Task.sleep(for: .seconds(10))
            try Data().write(to: gate)
        }
        defer { fallback.cancel() }
        var receivedBeforeExit = false
        try await GitWorktreeAdd.add(repoPath: root.path, worktreePath: root.appendingPathComponent("child").path,
            branch: .createNew(name: "feature"), startPoint: nil) { output in
                if !receivedBeforeExit, output.text.contains("hook stdout"), output.text.contains("hook stderr") {
                    receivedBeforeExit = !FileManager.default.fileExists(atPath: gate.path)
                    try? Data().write(to: gate)
                }
            }
        #expect(receivedBeforeExit)
    }

    @Test("@spec GIT-5.26: While creation is pending, discovery shall preserve the creating row and its progress whether Git has registered the worktree yet or not.", arguments: [false, true])
    func reconciliationPreservesProgress(discovered: Bool) throws {
        var state = AppState()
        state.repos = [RepoEntry(path: "/repo", displayName: "repo")]
        let path = try state.insertCreatingWorktree(repoPath: "/repo", worktreeName: "feature", branch: .createNew(name: "feature")).get()
        let progress = try #require(state.worktree(forPath: path)?.creationProgress)
        let result = WorktreeReconciler.reconcile(existing: state.repos[0].worktrees,
            discovered: discovered ? [DiscoveredWorktree(path: path, branch: "feature")] : [])
        #expect(result.merged.first?.state == .creating)
        #expect(result.merged.first?.creationProgress == progress)
    }

    @Test("@spec GIT-5.27: When creation moves from Git and hooks to pane startup and then finishes or fails, the application shall retain the bounded output with a fixed completion time and the terminal outcome.")
    func completionAndFailureRetainOutput() {
        let start = Date(timeIntervalSince1970: 100)
        var progress = WorktreeCreationProgress(startedAt: start)
        progress.output = "waiting for lock"
        progress.transition(to: .startingPane, now: start.addingTimeInterval(10))
        #expect(progress.isPending)
        #expect(progress.phase == .startingPane)
        progress.transition(to: .failed, error: "pane failed", now: start.addingTimeInterval(12))
        #expect(!progress.isPending)
        #expect(progress.elapsed(at: start.addingTimeInterval(100)) == 12)
        #expect(progress.output == "waiting for lock")
        #expect(progress.error == "pane failed")
        var success = WorktreeCreationProgress(startedAt: start)
        success.transition(to: .ready, now: start.addingTimeInterval(20))
        #expect(success.elapsed(at: start.addingTimeInterval(100)) == 20)
    }

    @Test("@spec GIT-5.28: When saved creation progress was pending at host shutdown, the application shall restore it as interrupted, retain its output, and state that Git or hooks may still run without automatic pane launch.")
    func restartMarksInterruptedWithoutChangingWireProgress() throws {
        var entry = WorktreeEntry(path: "/repo/feature", branch: "feature", state: .creating)
        entry.creationProgress = WorktreeCreationProgress()
        entry.creationProgress?.output = "hook running"
        let restored = try JSONDecoder().decode(WorktreeEntry.self, from: JSONEncoder().encode(entry))
        #expect(restored.state == .closed)
        #expect(restored.creationProgress?.phase == .interrupted)
        #expect(restored.creationProgress?.output == "hook running")
        let wire = WorktreePanes(entry: entry, repo: RepoEntry(path: "/repo", displayName: "repo"),
            inputs: WorktreeRowInputs(origin: nil, projectID: "repo", displayName: "feature"))
        let decoded = try JSONDecoder().decode(WorktreePanes.self, from: JSONEncoder().encode(wire))
        #expect(decoded.creationProgress?.phase == .preparing)
        #expect(wire.with(path: "relay").creationProgress == wire.creationProgress)
    }

    @Test func terminalControlsAndInvalidUTF8StayBounded() {
        #expect(WorktreeCreationProgress.plainText("\u{1B}[31merror\u{1B}[0m\u{1B}]0;title\u{07}\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\") == "errorlink")
        #expect(WorktreeCreationProgress.plainText("safe\u{202E}text\u{2066}") == "safetext")
        let buffer = WorktreeCreationOutputBuffer()
        buffer.append(Data(repeating: 0xFF, count: 100_000))
        #expect(buffer.snapshot.text.utf8.count <= WorktreeCreationProgress.maximumOutputBytes)
        #expect(buffer.snapshot.truncated)
    }

    @Test func outputIsBoundedAndIsolated() {
        let first = WorktreeCreationOutputBuffer()
        let second = WorktreeCreationOutputBuffer()
        first.append(Data(String(repeating: "x", count: 100_000).utf8))
        first.append(Data("tail".utf8))
        #expect(first.snapshot.text.utf8.count <= WorktreeCreationProgress.maximumOutputBytes)
        #expect(first.snapshot.text.hasSuffix("tail"))
        #expect(first.snapshot.truncated)
        #expect(second.snapshot.text.isEmpty)
    }
}
