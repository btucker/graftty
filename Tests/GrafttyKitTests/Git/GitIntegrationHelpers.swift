import Foundation

/// Shared fixture helpers for integration tests that need a real git
/// worktree + a bare "origin" remote on disk. Test files that reference
/// these get them for free at file scope — no @Suite-local reimpls.

func makeTempDir(prefix: String = "graftty") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
func shellInRepo(_ command: String, at dir: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
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
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

/// Seeds a bare origin with a single commit on `main`, then clones it.
/// Returns `(root, clone, upstream)` — callers that only need `clone`
/// can discard the other two.
func makeClonedRepo() throws -> (root: URL, clone: URL, upstream: URL) {
    let root = try makeTempDir(prefix: "graftty-clone")
    let upstream = root.appendingPathComponent("upstream.git")
    let clone = root.appendingPathComponent("clone")
    try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
    try shellInRepo("git init --bare -b main", at: upstream)
    let seed = root.appendingPathComponent("seed")
    try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
    try shellInRepo("""
        git init -b main && \
        printf 'alpha\\nbeta\\ngamma\\n' > file.txt && \
        git add file.txt && \
        git commit -m init && \
        git remote add origin \(upstream.path) && \
        git push -u origin main
        """, at: seed)
    try shellInRepo("git clone \(upstream.path) \(clone.path)", at: root)
    return (root, clone, upstream)
}
