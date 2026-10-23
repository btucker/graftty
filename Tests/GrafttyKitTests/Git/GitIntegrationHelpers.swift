import Foundation
import GrafttyTestSupport

/// Shared fixture helpers for integration tests that need a real git
/// worktree + a bare "origin" remote on disk. Test files that reference
/// these get them for free at file scope — no @Suite-local reimpls.

@discardableResult
func shellInRepo(_ command: String, at dir: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = dir
    process.environment = [
        "PATH": "/usr/bin:/bin:/usr/local/bin",
        "HOME": NSHomeDirectory(),
        "GIT_AUTHOR_NAME": "Test",
        "GIT_AUTHOR_EMAIL": "test@test.com",
        "GIT_COMMITTER_NAME": "Test",
        "GIT_COMMITTER_EMAIL": "test@test.com",
    ]
    // One pipe for both streams, drained before waiting: a child that fills
    // the pipe buffer would otherwise block on write while we wait for it.
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let captured = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        // Callers see only the status; keep git's own message in the log.
        FileHandle.standardError.write(
            Data("shellInRepo exited \(process.terminationStatus): \(command)\n".utf8) + captured
        )
    }
    return process.terminationStatus
}

/// Seeds a bare origin with a single commit on `defaultBranch`, then clones
/// it. Returns `(root, clone, upstream)` — callers that only need `clone`
/// can discard the other two.
func makeClonedRepo(defaultBranch: String = "main") throws -> (root: URL, clone: URL, upstream: URL) {
    let root = try makeTempDir(prefix: "graftty-clone")
    let upstream = root.appendingPathComponent("upstream.git")
    let clone = root.appendingPathComponent("clone")
    try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
    try shellInRepo("git init --bare -b \(defaultBranch)", at: upstream)
    let seed = root.appendingPathComponent("seed")
    try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
    try shellInRepo("""
        git init -b \(defaultBranch) && \
        printf 'alpha\\nbeta\\ngamma\\n' > file.txt && \
        git add file.txt && \
        git commit -m init && \
        git remote add origin \(upstream.path) && \
        git push -u origin \(defaultBranch)
        """, at: seed)
    try shellInRepo("git clone \(upstream.path) \(clone.path)", at: root)
    return (root, clone, upstream)
}
