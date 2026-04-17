# Worktree Divergence Indicator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a fixed-width left-gutter indicator on each sidebar worktree row showing `↑X ↓Y` commits and `+I -D` lines changed vs. the repository's origin default branch.

**Architecture:** Pure git-parsing + compute functions in `EspalierKit/Git/`. An `@Observable` app-level `WorktreeStatsStore` owns ephemeral stats keyed by worktree path. `WorktreeMonitorBridge` triggers refreshes on HEAD-change / repo-change events; a 60s timer catches external-fetch drift. A new `WorktreeRowGutter` view reads from the store and prepends itself to `WorktreeRow`.

**Tech Stack:** Swift 5.9+, Swift Testing (`@Suite`/`@Test`), SwiftUI (macOS 14+), `@Observable`. Git invoked via `Process` with `/usr/bin/git` (matches existing `GitWorktreeDiscovery` pattern).

**Spec:** `SPECS.md` §7 (DIVERGE-1.x through DIVERGE-4.4).

---

## File Structure

**Create (EspalierKit):**
- `Sources/EspalierKit/Git/GitWorktreeStats.swift` — `WorktreeStats` struct, pure parsers (`parseRevListCounts`, `parseShortStat`), `compute(worktreePath:defaultBranchRef:)`.
- `Sources/EspalierKit/Git/GitOriginDefaultBranch.swift` — `resolve(repoPath:)` with local-only symbolic-ref + show-ref fallback.
- `Tests/EspalierKitTests/Git/GitWorktreeStatsTests.swift`
- `Tests/EspalierKitTests/Git/GitOriginDefaultBranchTests.swift`

**Create (Espalier app):**
- `Sources/Espalier/Model/WorktreeStatsStore.swift` — `@Observable` class, refresh/clear/dedup.
- `Sources/Espalier/Views/WorktreeRowGutter.swift` — the two-line gutter view.

**Modify:**
- `Sources/Espalier/Views/WorktreeRow.swift` — prepend `WorktreeRowGutter`, pass stats in.
- `Sources/Espalier/Views/SidebarView.swift` — take store, pass stats to row.
- `Sources/Espalier/Views/MainWindow.swift` — thread store through to sidebar.
- `Sources/Espalier/EspalierApp.swift` — instantiate store, wire it to bridge, initial population, 60s timer.

---

## Task 1: `WorktreeStats` type + pure parsers

**Files:**
- Create: `Sources/EspalierKit/Git/GitWorktreeStats.swift`
- Create: `Tests/EspalierKitTests/Git/GitWorktreeStatsTests.swift`

Covers spec DIVERGE-3.1, DIVERGE-3.2 (parsing portion only).

- [ ] **Step 1: Write the failing tests**

Create `Tests/EspalierKitTests/Git/GitWorktreeStatsTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("GitWorktreeStats — parsers")
struct GitWorktreeStatsParserTests {

    // MARK: parseRevListCounts
    // Format is `<behind>\t<ahead>\n` because we invoke
    // `rev-list --left-right --count <default>...HEAD` — the left side
    // of A...B is "commits in A not B" (behind for us), right side is
    // "commits in B not A" (ahead).

    @Test func parsesRevListBothNonZero() throws {
        let result = GitWorktreeStats.parseRevListCounts("2\t5\n")
        #expect(result?.behind == 2)
        #expect(result?.ahead == 5)
    }

    @Test func parsesRevListAllZeros() throws {
        let result = GitWorktreeStats.parseRevListCounts("0\t0\n")
        #expect(result?.behind == 0)
        #expect(result?.ahead == 0)
    }

    @Test func parsesRevListWithTrailingWhitespace() throws {
        let result = GitWorktreeStats.parseRevListCounts("  3\t7  \n")
        #expect(result?.behind == 3)
        #expect(result?.ahead == 7)
    }

    @Test func rejectsMalformedRevListOutput() throws {
        #expect(GitWorktreeStats.parseRevListCounts("") == nil)
        #expect(GitWorktreeStats.parseRevListCounts("not a number\tnope\n") == nil)
        #expect(GitWorktreeStats.parseRevListCounts("only-one-column\n") == nil)
    }

    // MARK: parseShortStat
    // git diff --shortstat output looks like:
    //   " 3 files changed, 42 insertions(+), 7 deletions(-)"
    // Insertions or deletions may be absent if zero. Empty output
    // (no diff) returns (0, 0) rather than failing.

    @Test func parsesShortStatBoth() throws {
        let output = " 3 files changed, 42 insertions(+), 7 deletions(-)\n"
        let result = GitWorktreeStats.parseShortStat(output)
        #expect(result.insertions == 42)
        #expect(result.deletions == 7)
    }

    @Test func parsesShortStatSingularInsertion() throws {
        let output = " 1 file changed, 1 insertion(+)\n"
        let result = GitWorktreeStats.parseShortStat(output)
        #expect(result.insertions == 1)
        #expect(result.deletions == 0)
    }

    @Test func parsesShortStatOnlyDeletions() throws {
        let output = " 2 files changed, 15 deletions(-)\n"
        let result = GitWorktreeStats.parseShortStat(output)
        #expect(result.insertions == 0)
        #expect(result.deletions == 15)
    }

    @Test func parsesShortStatEmpty() throws {
        let result = GitWorktreeStats.parseShortStat("")
        #expect(result.insertions == 0)
        #expect(result.deletions == 0)
    }

    @Test func parsesShortStatBlankLineOnly() throws {
        let result = GitWorktreeStats.parseShortStat("\n")
        #expect(result.insertions == 0)
        #expect(result.deletions == 0)
    }

    // MARK: WorktreeStats.isEmpty

    @Test func isEmptyWhenAllZero() throws {
        let s = WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 0)
        #expect(s.isEmpty)
    }

    @Test func isNotEmptyWhenAnyNonZero() throws {
        #expect(!WorktreeStats(ahead: 1, behind: 0, insertions: 0, deletions: 0).isEmpty)
        #expect(!WorktreeStats(ahead: 0, behind: 1, insertions: 0, deletions: 0).isEmpty)
        #expect(!WorktreeStats(ahead: 0, behind: 0, insertions: 1, deletions: 0).isEmpty)
        #expect(!WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 1).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitWorktreeStatsParserTests`
Expected: FAIL — `WorktreeStats` and `GitWorktreeStats` are not defined.

- [ ] **Step 3: Implement the type + parsers**

Create `Sources/EspalierKit/Git/GitWorktreeStats.swift`:

```swift
import Foundation

/// Ephemeral per-worktree divergence information vs. the origin default branch.
/// Not persisted — lives in `WorktreeStatsStore` for the session only.
public struct WorktreeStats: Equatable, Sendable {
    public let ahead: Int
    public let behind: Int
    public let insertions: Int
    public let deletions: Int

    public init(ahead: Int, behind: Int, insertions: Int, deletions: Int) {
        self.ahead = ahead
        self.behind = behind
        self.insertions = insertions
        self.deletions = deletions
    }

    public var isEmpty: Bool {
        ahead == 0 && behind == 0 && insertions == 0 && deletions == 0
    }
}

public enum GitWorktreeStats {

    /// Parse output of `git rev-list --left-right --count <ref>...HEAD`.
    /// A single line of the form `<left>\t<right>\n`, where left = commits
    /// reachable from `<ref>` but not HEAD (behind), right = commits
    /// reachable from HEAD but not `<ref>` (ahead).
    public static func parseRevListCounts(_ output: String) -> (behind: Int, ahead: Int)? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let behind = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let ahead = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (behind: behind, ahead: ahead)
    }

    /// Parse output of `git diff --shortstat`. Empty output means no diff —
    /// return (0, 0) rather than failing, since "no changes" is a valid answer.
    public static func parseShortStat(_ output: String) -> (insertions: Int, deletions: Int) {
        var insertions = 0
        var deletions = 0
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (0, 0) }
        for part in trimmed.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.contains("insertion"), let n = leadingInt(token) {
                insertions = n
            } else if token.contains("deletion"), let n = leadingInt(token) {
                deletions = n
            }
        }
        return (insertions: insertions, deletions: deletions)
    }

    private static func leadingInt(_ s: String) -> Int? {
        var digits = ""
        for ch in s {
            if ch.isWholeNumber { digits.append(ch) } else if !digits.isEmpty { break }
        }
        return Int(digits)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitWorktreeStatsParserTests`
Expected: PASS — all 11 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Git/GitWorktreeStats.swift \
        Tests/EspalierKitTests/Git/GitWorktreeStatsTests.swift
git commit -m "feat(diverge): WorktreeStats type + rev-list/shortstat parsers"
```

---

## Task 2: `GitOriginDefaultBranch.resolve` + integration tests

**Files:**
- Create: `Sources/EspalierKit/Git/GitOriginDefaultBranch.swift`
- Create: `Tests/EspalierKitTests/Git/GitOriginDefaultBranchTests.swift`

Covers spec DIVERGE-2.1, DIVERGE-2.2, DIVERGE-2.3.

- [ ] **Step 1: Write the failing tests**

Create `Tests/EspalierKitTests/Git/GitOriginDefaultBranchTests.swift`:

```swift
import Testing
import Foundation
@testable import EspalierKit

@Suite("GitOriginDefaultBranch")
struct GitOriginDefaultBranchTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("espalier-origin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func shell(_ command: String, at dir: URL) throws -> Int32 {
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

    @Test func returnsNilWhenNoRemote() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try shell("git init -b main && git commit --allow-empty -m init", at: dir)

        let result = try GitOriginDefaultBranch.resolve(repoPath: dir.path)
        #expect(result == nil)
    }

    @Test func resolvesViaSymbolicRefWhenOriginHeadIsSet() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream.git")
        let clone = root.appendingPathComponent("clone")

        // A bare upstream with a 'main' branch, then clone it. The clone
        // will have refs/remotes/origin/HEAD pointing to origin/main.
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try shell("git init --bare -b main", at: upstream)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try shell("""
            git init -b main && \
            git commit --allow-empty -m init && \
            git remote add origin \(upstream.path) && \
            git push -u origin main
            """, at: seed)
        try shell("git clone \(upstream.path) \(clone.path)", at: root)

        let result = try GitOriginDefaultBranch.resolve(repoPath: clone.path)
        #expect(result == "origin/main")
    }

    @Test func fallsBackToProbingMainWhenSymbolicRefMissing() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream.git")
        let clone = root.appendingPathComponent("clone")

        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try shell("git init --bare -b main", at: upstream)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try shell("""
            git init -b main && \
            git commit --allow-empty -m init && \
            git remote add origin \(upstream.path) && \
            git push -u origin main
            """, at: seed)
        try shell("git clone \(upstream.path) \(clone.path)", at: root)

        // Remove the symbolic ref so only the probe fallback can succeed.
        try shell("git remote set-head origin --delete", at: clone)

        let result = try GitOriginDefaultBranch.resolve(repoPath: clone.path)
        #expect(result == "origin/main")
    }

    @Test func fallsBackToMasterIfNoMain() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let upstream = root.appendingPathComponent("upstream.git")
        let clone = root.appendingPathComponent("clone")

        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try shell("git init --bare -b master", at: upstream)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try shell("""
            git init -b master && \
            git commit --allow-empty -m init && \
            git remote add origin \(upstream.path) && \
            git push -u origin master
            """, at: seed)
        try shell("git clone \(upstream.path) \(clone.path)", at: root)
        try shell("git remote set-head origin --delete", at: clone)

        let result = try GitOriginDefaultBranch.resolve(repoPath: clone.path)
        #expect(result == "origin/master")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitOriginDefaultBranchTests`
Expected: FAIL — `GitOriginDefaultBranch` is not defined.

- [ ] **Step 3: Implement `GitOriginDefaultBranch`**

Create `Sources/EspalierKit/Git/GitOriginDefaultBranch.swift`:

```swift
import Foundation

public enum GitOriginDefaultBranch {

    /// Resolves the origin default branch for a repository.
    ///
    /// Returns a short ref like `"origin/main"` suitable for direct use in
    /// `git rev-list` / `git diff` arguments, or `nil` if there is no origin
    /// remote or no default branch can be identified.
    ///
    /// Local only — never hits the network. First tries `git symbolic-ref
    /// --short refs/remotes/origin/HEAD`; on failure, probes `origin/main`,
    /// `origin/master`, `origin/develop` in order via `git show-ref --verify`.
    public static func resolve(repoPath: String) throws -> String? {
        if let (out, code) = try? runGitCapturing(
            args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            at: repoPath
        ), code == 0 {
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        // Probe fallback. show-ref --verify exits 0 if the ref exists, non-zero
        // otherwise. We check `refs/remotes/origin/<name>` directly so a
        // local branch of the same name doesn't false-positive.
        for candidate in ["main", "master", "develop"] {
            guard let (_, code) = try? runGitCapturing(
                args: ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"],
                at: repoPath
            ) else { continue }
            if code == 0 { return "origin/\(candidate)" }
        }

        return nil
    }

    /// Runs git and returns `(stdout, terminationStatus)`. Never throws on
    /// non-zero exit — callers decide whether the exit code is meaningful.
    /// Throws only if the process itself fails to launch.
    private static func runGitCapturing(args: [String], at directory: String) throws -> (String, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (out, process.terminationStatus)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitOriginDefaultBranchTests`
Expected: PASS — all 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Git/GitOriginDefaultBranch.swift \
        Tests/EspalierKitTests/Git/GitOriginDefaultBranchTests.swift
git commit -m "feat(diverge): GitOriginDefaultBranch.resolve (local-only)"
```

---

## Task 3: `GitWorktreeStats.compute` + integration tests

**Files:**
- Modify: `Sources/EspalierKit/Git/GitWorktreeStats.swift` (add `compute`)
- Modify: `Tests/EspalierKitTests/Git/GitWorktreeStatsTests.swift` (add integration suite)

Covers spec DIVERGE-3.1, DIVERGE-3.2.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/EspalierKitTests/Git/GitWorktreeStatsTests.swift`:

```swift
@Suite("GitWorktreeStats — compute (integration)")
struct GitWorktreeStatsComputeTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("espalier-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    func shell(_ command: String, at dir: URL) throws -> Int32 {
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

    /// Sets up a clone with origin/main as the default branch and returns
    /// the clone path.
    func makeClonedRepo() throws -> (root: URL, clone: URL) {
        let root = try makeTempDir()
        let upstream = root.appendingPathComponent("upstream.git")
        let clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try shell("git init --bare -b main", at: upstream)
        let seed = root.appendingPathComponent("seed")
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try shell("""
            git init -b main && \
            printf 'alpha\\nbeta\\ngamma\\n' > file.txt && \
            git add file.txt && \
            git commit -m init && \
            git remote add origin \(upstream.path) && \
            git push -u origin main
            """, at: seed)
        try shell("git clone \(upstream.path) \(clone.path)", at: root)
        return (root, clone)
    }

    @Test func returnsZerosAtParity() throws {
        let (root, clone) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let stats = try GitWorktreeStats.compute(
            worktreePath: clone.path,
            defaultBranchRef: "origin/main"
        )
        #expect(stats == WorktreeStats(ahead: 0, behind: 0, insertions: 0, deletions: 0))
    }

    @Test func countsAheadAndLineChanges() throws {
        let (root, clone) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Add two commits on HEAD with a net +3 / -1.
        try shell("""
            printf 'alpha\\nbeta\\ngamma\\ndelta\\n' > file.txt && \
            git add file.txt && git commit -m 'add delta' && \
            printf 'ALPHA\\nbeta\\ngamma\\ndelta\\nepsilon\\nzeta\\n' > file.txt && \
            git add file.txt && git commit -m 'add epsilon/zeta, tweak alpha'
            """, at: clone)

        let stats = try GitWorktreeStats.compute(
            worktreePath: clone.path,
            defaultBranchRef: "origin/main"
        )
        #expect(stats.ahead == 2)
        #expect(stats.behind == 0)
        // 3 new lines (delta, epsilon, zeta) net to +3/-0, plus alpha changed
        // from 'alpha' to 'ALPHA' which is +1/-1. Final: +4/-1.
        #expect(stats.insertions == 4)
        #expect(stats.deletions == 1)
    }

    @Test func countsBehindWhenOriginAdvances() throws {
        let (root, clone) = try makeClonedRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        // Push two new commits to origin from a second clone, then fetch.
        let other = root.appendingPathComponent("other-clone")
        try shell("git clone \(root.appendingPathComponent("upstream.git").path) \(other.path)", at: root)
        try shell("""
            printf 'alpha\\nbeta\\ngamma\\nomega\\n' > file.txt && \
            git add file.txt && git commit -m 'omega' && \
            git push origin main
            """, at: other)
        try shell("git fetch origin", at: clone)

        let stats = try GitWorktreeStats.compute(
            worktreePath: clone.path,
            defaultBranchRef: "origin/main"
        )
        #expect(stats.ahead == 0)
        #expect(stats.behind == 1)
    }

    @Test func throwsWhenWorktreeMissing() throws {
        let bogus = "/nonexistent-espalier-path-\(UUID().uuidString)"
        #expect(throws: Error.self) {
            try GitWorktreeStats.compute(worktreePath: bogus, defaultBranchRef: "origin/main")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter GitWorktreeStatsComputeTests`
Expected: FAIL — `GitWorktreeStats.compute` is not defined.

- [ ] **Step 3: Implement `compute`**

Append to `Sources/EspalierKit/Git/GitWorktreeStats.swift` inside the `public enum GitWorktreeStats` namespace:

```swift
    /// Computes divergence stats for a worktree vs. an origin default branch ref.
    /// Runs two local git commands synchronously — callers should invoke this
    /// off the main thread. Throws if git fails to launch or exits non-zero.
    public static func compute(
        worktreePath: String,
        defaultBranchRef: String
    ) throws -> WorktreeStats {
        let range = "\(defaultBranchRef)...HEAD"

        let revListOutput = try runGit(
            args: ["rev-list", "--left-right", "--count", range],
            at: worktreePath
        )
        guard let counts = parseRevListCounts(revListOutput) else {
            throw GitWorktreeStatsError.unparseableRevList(revListOutput)
        }

        let diffOutput = try runGit(
            args: ["diff", "--shortstat", range],
            at: worktreePath
        )
        let diff = parseShortStat(diffOutput)

        return WorktreeStats(
            ahead: counts.ahead,
            behind: counts.behind,
            insertions: diff.insertions,
            deletions: diff.deletions
        )
    }

    private static func runGit(args: [String], at directory: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitWorktreeStatsError.gitFailed(terminationStatus: process.terminationStatus)
        }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum GitWorktreeStatsError: Error, Equatable {
    case gitFailed(terminationStatus: Int32)
    case unparseableRevList(String)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter GitWorktreeStatsComputeTests`
Expected: PASS — all 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/EspalierKit/Git/GitWorktreeStats.swift \
        Tests/EspalierKitTests/Git/GitWorktreeStatsTests.swift
git commit -m "feat(diverge): GitWorktreeStats.compute against default branch"
```

---

## Task 4: `WorktreeStatsStore` (refresh + dedup, no timer)

**Files:**
- Create: `Sources/Espalier/Model/WorktreeStatsStore.swift`

Covers spec DIVERGE-3.3, DIVERGE-3.4, DIVERGE-4.4, part of DIVERGE-2.4.

- [ ] **Step 1: Create the directory**

```bash
mkdir -p Sources/Espalier/Model
```

- [ ] **Step 2: Implement the store**

Create `Sources/Espalier/Model/WorktreeStatsStore.swift`:

```swift
import Foundation
import Observation
import EspalierKit

/// Session-scoped, @MainActor-observed store of per-worktree divergence stats.
///
/// Not persisted. All git work runs on a background Task.detached; publishing
/// back to `stats` happens on the MainActor. Concurrent refresh requests for
/// the same worktree path are deduplicated (DIVERGE-4.4).
@MainActor
@Observable
public final class WorktreeStatsStore {

    /// Keyed by worktree path. Absent key means "not computed yet or cleared".
    public private(set) var stats: [String: WorktreeStats] = [:]

    /// Cached origin default branch ref per repo path. `.some(nil)` caches a
    /// "no default branch resolvable" result so we don't retry on every poll.
    @ObservationIgnored
    private var defaultBranchByRepo: [String: String?] = [:]

    @ObservationIgnored
    private var inFlight: Set<String> = []

    public init() {}

    public func refresh(worktreePath: String, repoPath: String) {
        guard !inFlight.contains(worktreePath) else { return }
        inFlight.insert(worktreePath)

        Task.detached { [weak self] in
            let computed = await Self.computeOffMain(
                worktreePath: worktreePath,
                repoPath: repoPath,
                cachedDefault: self?.defaultBranchByRepo[repoPath] ?? nil
            )
            await self?.apply(
                worktreePath: worktreePath,
                repoPath: repoPath,
                result: computed
            )
        }
    }

    public func clear(worktreePath: String) {
        stats.removeValue(forKey: worktreePath)
    }

    public func invalidateDefaultBranch(repoPath: String) {
        defaultBranchByRepo.removeValue(forKey: repoPath)
    }

    // MARK: - Private

    /// Result of a background compute attempt. Carries the default branch
    /// discovered (so we can cache it on main) plus the stats or nil if no
    /// default branch exists for this repo.
    private struct ComputeResult: Sendable {
        let defaultBranch: String?
        let stats: WorktreeStats?
    }

    private static func computeOffMain(
        worktreePath: String,
        repoPath: String,
        cachedDefault: String?
    ) async -> ComputeResult {
        let ref: String?
        if let cached = cachedDefault {
            ref = cached
        } else {
            ref = (try? GitOriginDefaultBranch.resolve(repoPath: repoPath)) ?? nil
        }
        guard let ref else {
            return ComputeResult(defaultBranch: nil, stats: nil)
        }
        let stats = try? GitWorktreeStats.compute(
            worktreePath: worktreePath,
            defaultBranchRef: ref
        )
        return ComputeResult(defaultBranch: ref, stats: stats)
    }

    private func apply(
        worktreePath: String,
        repoPath: String,
        result: ComputeResult
    ) {
        inFlight.remove(worktreePath)
        defaultBranchByRepo[repoPath] = result.defaultBranch
        if let s = result.stats {
            stats[worktreePath] = s
        } else {
            stats.removeValue(forKey: worktreePath)
        }
    }
}
```

- [ ] **Step 3: Verify the project builds**

Run: `swift build`
Expected: build succeeds (the file compiles; nothing uses it yet).

- [ ] **Step 4: Commit**

```bash
git add Sources/Espalier/Model/WorktreeStatsStore.swift
git commit -m "feat(diverge): WorktreeStatsStore with dedup + bg compute"
```

---

## Task 5: Wire bridge to store + initial population

**Files:**
- Modify: `Sources/Espalier/EspalierApp.swift`

Covers spec DIVERGE-4.1, DIVERGE-4.2 and supports DIVERGE-1.6 (stale → clear).

- [ ] **Step 1: Add the store to `AppServices`**

Edit `Sources/Espalier/EspalierApp.swift` — change the `AppServices` class (lines 7-17):

```swift
@MainActor
final class AppServices {
    let socketServer: SocketServer
    let worktreeMonitor: WorktreeMonitor
    let statsStore: WorktreeStatsStore
    var worktreeMonitorBridge: WorktreeMonitorBridge?

    init(socketPath: String) {
        self.socketServer = SocketServer(socketPath: socketPath)
        self.worktreeMonitor = WorktreeMonitor()
        self.statsStore = WorktreeStatsStore()
    }
}
```

- [ ] **Step 2: Update `WorktreeMonitorBridge` to take the store and call it**

Edit `Sources/Espalier/EspalierApp.swift` — replace the `WorktreeMonitorBridge` class (lines 422-482) with:

```swift
@MainActor
final class WorktreeMonitorBridge: WorktreeMonitorDelegate {
    let appState: Binding<AppState>
    let statsStore: WorktreeStatsStore

    init(appState: Binding<AppState>, statsStore: WorktreeStatsStore) {
        self.appState = appState
        self.statsStore = statsStore
    }

    /// Called when `.git/worktrees/` changes (new worktree added, existing
    /// one removed externally). After reconciling appState, refresh stats
    /// for every non-stale worktree in the repo — new worktrees need their
    /// initial stats, removed ones will be marked stale (and stats cleared
    /// by `worktreeMonitorDidDetectDeletion`).
    nonisolated func worktreeMonitorDidDetectChange(_ monitor: WorktreeMonitor, repoPath: String) {
        let binding = appState
        let store = statsStore
        Task { @MainActor in
            guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { return }
            guard let repoIdx = binding.wrappedValue.repos.firstIndex(where: { $0.path == repoPath }) else { return }

            let existing = binding.wrappedValue.repos[repoIdx].worktrees
            let existingPaths = Set(existing.map(\.path))
            let discoveredPaths = Set(discovered.map(\.path))

            for d in discovered where !existingPaths.contains(d.path) {
                let entry = WorktreeEntry(path: d.path, branch: d.branch)
                binding.wrappedValue.repos[repoIdx].worktrees.append(entry)
            }

            for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = binding.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                if !discoveredPaths.contains(wt.path) && wt.state != .stale {
                    binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                }
            }

            // Refresh stats for all non-stale worktrees in this repo.
            for wt in binding.wrappedValue.repos[repoIdx].worktrees where wt.state != .stale {
                store.refresh(worktreePath: wt.path, repoPath: repoPath)
            }
        }
    }

    nonisolated func worktreeMonitorDidDetectDeletion(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        Task { @MainActor in
            for repoIdx in binding.wrappedValue.repos.indices {
                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                    }
                }
            }
            store.clear(worktreePath: worktreePath)
        }
    }

    nonisolated func worktreeMonitorDidDetectBranchChange(_ monitor: WorktreeMonitor, worktreePath: String) {
        let binding = appState
        let store = statsStore
        Task { @MainActor in
            for repoIdx in binding.wrappedValue.repos.indices {
                let repoPath = binding.wrappedValue.repos[repoIdx].path
                guard let discovered = try? GitWorktreeDiscovery.discover(repoPath: repoPath) else { continue }
                for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                    if binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path == worktreePath,
                       let match = discovered.first(where: { $0.path == worktreePath }) {
                        binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch = match.branch
                        // HEAD moved — recompute stats for this worktree.
                        store.refresh(worktreePath: worktreePath, repoPath: repoPath)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Pass the store into the bridge at startup**

Edit `Sources/Espalier/EspalierApp.swift` — change the bridge construction in `startup()` (line 141):

```swift
        let bridge = WorktreeMonitorBridge(
            appState: $appState,
            statsStore: services.statsStore
        )
```

- [ ] **Step 4: Kick off initial stats population after reconcile**

Edit `Sources/Espalier/EspalierApp.swift` — after the call to `reconcileOnLaunch()` in `startup()` (line 152), add:

```swift
        reconcileOnLaunch()
        for repo in appState.repos {
            for wt in repo.worktrees where wt.state != .stale {
                services.statsStore.refresh(worktreePath: wt.path, repoPath: repo.path)
            }
        }
        restoreRunningWorktrees()
```

- [ ] **Step 5: Verify the project builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Espalier/EspalierApp.swift
git commit -m "feat(diverge): wire WorktreeStatsStore into monitor bridge"
```

---

## Task 6: `WorktreeRowGutter` view + row/sidebar wiring

**Files:**
- Create: `Sources/Espalier/Views/WorktreeRowGutter.swift`
- Modify: `Sources/Espalier/Views/WorktreeRow.swift`
- Modify: `Sources/Espalier/Views/SidebarView.swift`
- Modify: `Sources/Espalier/Views/MainWindow.swift`
- Modify: `Sources/Espalier/EspalierApp.swift`

Covers spec DIVERGE-1.1 through DIVERGE-1.6.

- [ ] **Step 1: Create `WorktreeRowGutter`**

Create `Sources/Espalier/Views/WorktreeRowGutter.swift`:

```swift
import SwiftUI
import EspalierKit

/// Fixed-width leading block on each sidebar worktree row showing divergence
/// vs. the origin default branch. Reserves its width even when empty so
/// sibling row contents stay vertically aligned (DIVERGE-1.1, DIVERGE-1.4).
struct WorktreeRowGutter: View {
    let stats: WorktreeStats?
    let theme: GhosttyTheme

    /// Width reserved for the gutter. Sized to fit ~`↑99 ↓99` in caption2
    /// monospaced — larger numbers will still render, just tighter.
    static let width: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let stats, !stats.isEmpty {
                Text(commitsLine(stats))
                Text(linesLine(stats))
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundColor(theme.foreground.opacity(0.55))
        .frame(width: Self.width, alignment: .leading)
    }

    /// `↑X ↓Y` with zero sides omitted (DIVERGE-1.2). Returns empty string
    /// when both are zero — caller decides whether to render.
    private func commitsLine(_ s: WorktreeStats) -> String {
        var parts: [String] = []
        if s.ahead > 0 { parts.append("↑\(s.ahead)") }
        if s.behind > 0 { parts.append("↓\(s.behind)") }
        return parts.joined(separator: " ")
    }

    /// `+I -D` with zero sides omitted (DIVERGE-1.3).
    private func linesLine(_ s: WorktreeStats) -> String {
        var parts: [String] = []
        if s.insertions > 0 { parts.append("+\(s.insertions)") }
        if s.deletions > 0 { parts.append("-\(s.deletions)") }
        return parts.joined(separator: " ")
    }
}
```

- [ ] **Step 2: Prepend gutter to `WorktreeRow`**

Edit `Sources/Espalier/Views/WorktreeRow.swift` — replace the entire file with:

```swift
import SwiftUI
import EspalierKit

struct WorktreeRow: View {
    let entry: WorktreeEntry
    let isSelected: Bool
    /// Primary display label, computed by the sidebar with knowledge of
    /// the worktree's siblings so we can disambiguate same-basename
    /// worktrees.
    let displayName: String
    /// True if this is the repo's main checkout (path == repo.path).
    /// Gets a distinct leading icon to differentiate from linked worktrees.
    let isMainCheckout: Bool
    /// Theme snapshot for foreground/dim text colors, so the sidebar
    /// matches ghostty's palette rather than fighting it.
    let theme: GhosttyTheme
    /// Divergence stats for this worktree, or nil when unresolved (no
    /// origin remote, stale, not yet computed).
    let stats: WorktreeStats?

    var body: some View {
        HStack(spacing: 6) {
            // Stale worktrees get no gutter content per DIVERGE-1.6, but
            // the width stays reserved for vertical alignment.
            WorktreeRowGutter(
                stats: entry.state == .stale ? nil : stats,
                theme: theme
            )
            stateIndicator
            typeIcon
            branchLabel
            Spacer()
            attentionBadge
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? theme.foreground.opacity(0.16) : .clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var typeIcon: some View {
        Image(systemName: isMainCheckout ? "house" : "arrow.triangle.branch")
            .font(.system(size: 10))
            .foregroundColor(theme.foreground.opacity(0.6))
            .frame(width: 12)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch entry.state {
        case .closed:
            Circle()
                .strokeBorder(theme.foreground.opacity(0.5), lineWidth: 1)
                .frame(width: 8, height: 8)
        case .running:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        case .stale:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.yellow)
        }
    }

    @ViewBuilder
    private var branchLabel: some View {
        HStack(spacing: 6) {
            if entry.state == .stale {
                Text(displayName)
                    .strikethrough()
                    .foregroundColor(theme.foreground.opacity(0.5))
            } else {
                Text(displayName)
                    .foregroundColor(
                        isSelected
                            ? theme.foreground
                            : theme.foreground.opacity(0.8)
                    )
            }

            if entry.branch != displayName {
                Text(entry.branch)
                    .font(.caption)
                    .foregroundColor(theme.foreground.opacity(0.45))
            }
        }
    }

    @ViewBuilder
    private var attentionBadge: some View {
        if let attention = entry.attention {
            Text(attention.text)
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.red)
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
    }
}
```

- [ ] **Step 3: Thread the store through `SidebarView`**

Edit `Sources/Espalier/Views/SidebarView.swift` — add the store as a property and pass stats to the row:

Change the struct's properties (lines 5-11):

```swift
struct SidebarView: View {
    @Binding var appState: AppState
    let theme: GhosttyTheme
    let statsStore: WorktreeStatsStore
    let onSelect: (String) -> Void
    let onAddRepo: () -> Void
    let onAddPath: (String) -> Void
    let onStopWorktree: (String) -> Void
```

Change the `WorktreeRow` call inside `repoSection` (currently lines 65-71):

```swift
                    WorktreeRow(
                        entry: worktree,
                        isSelected: appState.selectedWorktreePath == worktree.path,
                        displayName: label(for: worktree, in: repo),
                        isMainCheckout: worktree.path == repo.path,
                        theme: theme,
                        stats: statsStore.stats[worktree.path]
                    )
```

- [ ] **Step 4: Thread the store through `MainWindow`**

Run this to find every call site that constructs `SidebarView`:

```bash
grep -n "SidebarView(" Sources/Espalier/Views/MainWindow.swift
```

At each call site, add `statsStore: statsStore` after `theme:`. And add `let statsStore: WorktreeStatsStore` to `MainWindow`'s properties. The exact existing code depends on the file; follow the pattern already used for `theme`.

Run this to find where MainWindow is constructed in EspalierApp:

```bash
grep -n "MainWindow(" Sources/Espalier/EspalierApp.swift
```

Pass `statsStore: services.statsStore` there too.

- [ ] **Step 5: Verify the project builds and run the full test suite**

Run: `swift build`
Expected: build succeeds.

Run: `swift test`
Expected: all tests pass (no regressions).

- [ ] **Step 6: Commit**

```bash
git add Sources/Espalier/Views/WorktreeRowGutter.swift \
        Sources/Espalier/Views/WorktreeRow.swift \
        Sources/Espalier/Views/SidebarView.swift \
        Sources/Espalier/Views/MainWindow.swift \
        Sources/Espalier/EspalierApp.swift
git commit -m "feat(diverge): gutter view + sidebar wiring"
```

---

## Task 7: 60-second periodic poll

**Files:**
- Modify: `Sources/Espalier/EspalierApp.swift`

Covers spec DIVERGE-4.3.

- [ ] **Step 1: Add a poll Timer to `AppServices`**

Edit `Sources/Espalier/EspalierApp.swift` — change `AppServices` to hold a timer:

```swift
@MainActor
final class AppServices {
    let socketServer: SocketServer
    let worktreeMonitor: WorktreeMonitor
    let statsStore: WorktreeStatsStore
    var worktreeMonitorBridge: WorktreeMonitorBridge?
    var statsPollTimer: Timer?

    init(socketPath: String) {
        self.socketServer = SocketServer(socketPath: socketPath)
        self.worktreeMonitor = WorktreeMonitor()
        self.statsStore = WorktreeStatsStore()
    }
}
```

- [ ] **Step 2: Start the timer in `startup()`**

Edit `Sources/Espalier/EspalierApp.swift` — after the initial stats-population block added in Task 5 Step 4, start the timer:

```swift
        reconcileOnLaunch()
        for repo in appState.repos {
            for wt in repo.worktrees where wt.state != .stale {
                services.statsStore.refresh(worktreePath: wt.path, repoPath: repo.path)
            }
        }

        // 60s poll catches origin/<default> drift from external `git fetch`
        // invocations — WorktreeMonitor's HEAD watcher only fires when this
        // worktree's HEAD moves, not when the remote ref does.
        let binding = $appState
        let store = services.statsStore
        services.statsPollTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { _ in
            MainActor.assumeIsolated {
                for repo in binding.wrappedValue.repos {
                    for wt in repo.worktrees where wt.state != .stale {
                        store.refresh(worktreePath: wt.path, repoPath: repo.path)
                    }
                }
            }
        }

        restoreRunningWorktrees()
```

- [ ] **Step 3: Verify the project builds**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Manual smoke test**

Build and run the app:

```bash
swift run Espalier
```

Expected behavior:
- Launch with an existing repo that has at least one worktree with divergence. Within a few seconds, the gutter should populate on each row (blank for parity/stale rows, `↑X ↓Y` + `+I -D` for divergent rows).
- Make a commit in one of the worktrees (via terminal or external editor). Within a second or two, that row's gutter updates.
- Leave the app running for ~60s without interacting. The poll timer should fire; if an external `git fetch` has advanced origin/main, `↓Y` updates on affected rows.

- [ ] **Step 5: Commit**

```bash
git add Sources/Espalier/EspalierApp.swift
git commit -m "feat(diverge): 60s poll for origin default branch drift"
```

---

## Self-Review

**Spec coverage (SPECS.md §7):**

| Requirement | Task(s) |
|---|---|
| DIVERGE-1.1 fixed-width gutter | Task 6 (`WorktreeRowGutter.width`, `.frame(width:...)`) |
| DIVERGE-1.2 `↑X ↓Y` line, zero sides hidden | Task 6 (`commitsLine`) |
| DIVERGE-1.3 `+I -D` line, zero sides hidden | Task 6 (`linesLine`) |
| DIVERGE-1.4 blank when all zero | Task 6 (`!stats.isEmpty` guard) |
| DIVERGE-1.5 blank when no origin | Task 4 (`stats` map absent → nil → empty block) |
| DIVERGE-1.6 blank when stale | Task 6 (`entry.state == .stale ? nil : stats`) |
| DIVERGE-2.1 symbolic-ref | Task 2 |
| DIVERGE-2.2 probe fallback | Task 2 |
| DIVERGE-2.3 no network | Task 2 (no `fetch`/`ls-remote` calls) |
| DIVERGE-2.4 cache per repo | Task 4 (`defaultBranchByRepo`) |
| DIVERGE-3.1 rev-list compute | Task 3 |
| DIVERGE-3.2 shortstat compute | Task 3 |
| DIVERGE-3.3 off main | Task 4 (`Task.detached`) |
| DIVERGE-3.4 in memory only | Task 4 (no `Codable`, not in `state.json`) |
| DIVERGE-4.1 refresh on repo add | Task 5 (`worktreeMonitorDidDetectChange` + initial population) |
| DIVERGE-4.2 refresh on HEAD change | Task 5 (`worktreeMonitorDidDetectBranchChange`) |
| DIVERGE-4.3 60s poll | Task 7 |
| DIVERGE-4.4 dedup in-flight | Task 4 (`inFlight: Set<String>`) |

All requirements covered.

**Type consistency:** `WorktreeStats(ahead, behind, insertions, deletions)` used identically in Tasks 1, 3, 4, 6. `GitOriginDefaultBranch.resolve(repoPath:) throws -> String?` used in Tasks 2 and 4. `GitWorktreeStats.compute(worktreePath:, defaultBranchRef:) throws -> WorktreeStats` used in Tasks 3 and 4. Store methods `refresh(worktreePath:, repoPath:)`, `clear(worktreePath:)`, `invalidateDefaultBranch(repoPath:)` used consistently in Tasks 4, 5, 7.

**No placeholders detected.**
