# PR/MR Status Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface GitHub PR / GitLab MR status (number, title, CI rollup) in the breadcrumb for each worktree's branch, clickable to open the PR/MR in a browser. Along the way: migrate all git/CLI invocation to async + PATH-agnostic execution, and add polling (with `git fetch`) to `WorktreeStatsStore` so divergence stats stay live.

**Architecture:** Three phases. (1) New async `CLIRunner` replaces the synchronous `Process` pattern; `GitRunner` is rewritten on top of it and every existing caller migrates. (2) New `GrafttyKit/Hosting/` subsystem parses origin URLs, models PR/MR info, and shells out to `gh`/`glab`. (3) New `PRStatusStore` (with a shared `PollingTicker` helper) and polling extension on `WorktreeStatsStore` drive live updates into UI that renders `{repo} / {worktree-name} ({branch})` with a trailing PR button.

**Tech Stack:** Swift 5.10, SwiftUI, `@Observable` (Observation framework), Swift Testing (`@Test`/`#expect`), `Process` + `withCheckedThrowingContinuation` for async shell-outs. External CLIs: `gh`, `glab`.

**Spec reference:** `docs/superpowers/specs/2026-04-17-pr-mr-status-display-design.md`

**File structure being created/modified:**

```
Sources/GrafttyKit/CLI/                  ← new directory
  CLIExecutor.swift                       ← new: protocol + value types
  CLIRunner.swift                         ← new: production implementation

Sources/GrafttyKit/Hosting/              ← new directory
  HostingProvider.swift                   ← new
  HostingOrigin.swift                     ← new
  GitOriginHost.swift                     ← new
  PRInfo.swift                            ← new
  PRFetcher.swift                         ← new: protocol
  GitHubPRFetcher.swift                   ← new
  GitLabPRFetcher.swift                   ← new

Sources/GrafttyKit/Git/
  GitRunner.swift                         ← rewritten as async on top of CLIRunner
  GitRepoDetector.swift                   ← migrated to async
  GitWorktreeDiscovery.swift              ← migrated to async
  GitWorktreeStats.swift                  ← migrated to async
  GitOriginDefaultBranch.swift            ← migrated to async
  GitWorktreeAdd.swift                    ← migrated to async

Sources/Graftty/Model/
  PollingTicker.swift                     ← new
  PRStatusStore.swift                     ← new
  WorktreeStatsStore.swift                ← extended with polling + git fetch

Sources/Graftty/Views/
  BreadcrumbBar.swift                     ← rewritten
  PRButton.swift                          ← new
  WorktreeRow.swift                       ← edited (italic "root" for home)
  MainWindow.swift                        ← wires PRStatusStore
  GrafttyApp.swift                       ← instantiates PRStatusStore, removes old 60s Timer

Tests/GrafttyKitTests/
  CLI/                                    ← new
    CLIRunnerTests.swift                  ← new
    FakeCLIExecutor.swift                 ← new: shared test helper
  Hosting/                                ← new
    GitOriginHostTests.swift
    GitHubPRFetcherTests.swift
    GitLabPRFetcherTests.swift
    Fixtures/hosting/                     ← sample gh/glab JSON
  Git/                                    ← existing tests updated for async + FakeCLIExecutor

Tests/GrafttyKitTests/ — already exists; tests for:
  PollingTickerTests.swift                ← new (under a new Model/ dir)
  PRStatusStoreTests.swift                ← new
```

---

## Phase A — CLI Infrastructure

### Task A1: Create `CLIExecutor` protocol + value types

**Files:**
- Create: `Sources/GrafttyKit/CLI/CLIExecutor.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

public struct CLIOutput: Sendable, Equatable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CLIError: Error, Equatable {
    /// The executable couldn't be found on the PATH.
    case notFound(command: String)
    /// The process ran but exited non-zero. Callers that use `run(...)` see this;
    /// `capture(...)` returns the CLIOutput instead.
    case nonZeroExit(command: String, exitCode: Int32, stderr: String)
    /// Process launch itself failed (permission denied, bad cwd, etc.).
    case launchFailed(command: String, message: String)
}

public protocol CLIExecutor: Sendable {
    /// Run a command. Throws `CLIError.nonZeroExit` if the process exits non-zero.
    /// Use when non-zero exit means the call failed.
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput

    /// Run a command. Returns the `CLIOutput` regardless of exit code.
    /// Use when exit code is diagnostic (e.g. `git show-ref --verify`).
    /// Still throws on launch failure.
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput
}
```

- [ ] **Step 2: Confirm the package compiles**

Run: `swift build`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/CLI/CLIExecutor.swift
git commit -m "feat(cli): add CLIExecutor protocol and value types"
```

---

### Task A2: Implement `CLIRunner`

**Files:**
- Create: `Sources/GrafttyKit/CLI/CLIRunner.swift`

- [ ] **Step 1: Write the implementation**

```swift
import Foundation

/// Production `CLIExecutor` that invokes external commands via `/usr/bin/env`
/// so PATH is searched (rather than hardcoding `/usr/bin/git` or similar).
/// Prepends common install directories so Finder-launched apps can find
/// Homebrew-installed tools like `gh` and `glab`.
public struct CLIRunner: CLIExecutor {
    public init() {}

    public func run(
        command: String,
        args: [String],
        at directory: String
    ) async throws -> CLIOutput {
        let out = try await execute(command: command, args: args, at: directory)
        guard out.exitCode == 0 else {
            throw CLIError.nonZeroExit(
                command: command,
                exitCode: out.exitCode,
                stderr: out.stderr
            )
        }
        return out
    }

    public func capture(
        command: String,
        args: [String],
        at directory: String
    ) async throws -> CLIOutput {
        try await execute(command: command, args: args, at: directory)
    }

    /// Augmented PATH that includes common install locations. Finder-launched
    /// apps inherit a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin), which
    /// misses Homebrew-installed tools. Prepending keeps user overrides
    /// winning when the app is launched from the terminal.
    static func enrichedEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        let extras = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.local/bin"
        ]
        let existing = env["PATH"] ?? ""
        let existingParts = existing.split(separator: ":").map(String.init)
        let combined = (extras + existingParts).reduce(into: [String]()) { acc, p in
            if !p.isEmpty && !acc.contains(p) { acc.append(p) }
        }
        env["PATH"] = combined.joined(separator: ":")
        return env
    }

    private func execute(
        command: String,
        args: [String],
        at directory: String
    ) async throws -> CLIOutput {
        let captured: (String, String, Int32) = try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.environment = Self.enrichedEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
                let stderrStr = String(data: errData, encoding: .utf8) ?? ""

                // `/usr/bin/env` exits with 127 when the command is not found.
                if proc.terminationStatus == 127 && stderrStr.contains("No such file") {
                    cont.resume(throwing: CLIError.notFound(command: command))
                    return
                }
                cont.resume(returning: (stdoutStr, stderrStr, proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                cont.resume(throwing: CLIError.launchFailed(
                    command: command,
                    message: error.localizedDescription
                ))
            }
        }
        return CLIOutput(stdout: captured.0, stderr: captured.1, exitCode: captured.2)
    }
}
```

- [ ] **Step 2: Compile**

Run: `swift build`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/CLI/CLIRunner.swift
git commit -m "feat(cli): add async CLIRunner with PATH enrichment"
```

---

### Task A3: `FakeCLIExecutor` test helper

**Files:**
- Create: `Tests/GrafttyKitTests/CLI/FakeCLIExecutor.swift`

- [ ] **Step 1: Write the helper**

```swift
import Foundation
@testable import GrafttyKit

/// Test double for `CLIExecutor`. Returns canned `CLIOutput` for matching
/// `(command, args)` tuples. Asserts on unexpected invocations so tests
/// don't silently drift.
final class FakeCLIExecutor: CLIExecutor, @unchecked Sendable {
    struct Key: Hashable { let command: String; let args: [String] }
    enum Response { case output(CLIOutput); case error(CLIError) }

    private var responses: [Key: Response] = [:]
    private(set) var invocations: [(command: String, args: [String], directory: String)] = []
    private let lock = NSLock()

    func stub(command: String, args: [String], output: CLIOutput) {
        lock.lock(); defer { lock.unlock() }
        responses[Key(command: command, args: args)] = .output(output)
    }

    func stub(command: String, args: [String], error: CLIError) {
        lock.lock(); defer { lock.unlock() }
        responses[Key(command: command, args: args)] = .error(error)
    }

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        let out = try lookup(command: command, args: args, directory: directory)
        guard out.exitCode == 0 else {
            throw CLIError.nonZeroExit(
                command: command,
                exitCode: out.exitCode,
                stderr: out.stderr
            )
        }
        return out
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try lookup(command: command, args: args, directory: directory)
    }

    private func lookup(command: String, args: [String], directory: String) throws -> CLIOutput {
        lock.lock()
        invocations.append((command, args, directory))
        let resp = responses[Key(command: command, args: args)]
        lock.unlock()
        switch resp {
        case .output(let o): return o
        case .error(let e): throw e
        case .none:
            throw CLIError.launchFailed(
                command: command,
                message: "FakeCLIExecutor: no stub for \(command) \(args)"
            )
        }
    }
}
```

- [ ] **Step 2: Compile tests**

Run: `swift test --no-build 2>&1 | head -20` then `swift build --target GrafttyKitTests`
Expected: no errors; helper class available to other test files.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyKitTests/CLI/FakeCLIExecutor.swift
git commit -m "test(cli): add FakeCLIExecutor for stubbed shell-outs"
```

---

### Task A4: `CLIRunner` integration tests

**Files:**
- Create: `Tests/GrafttyKitTests/CLI/CLIRunnerTests.swift`

- [ ] **Step 1: Write the tests**

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("CLIRunner Tests")
struct CLIRunnerTests {
    let runner = CLIRunner()

    @Test func echoesStdout() async throws {
        let output = try await runner.run(command: "echo", args: ["hello"], at: NSTemporaryDirectory())
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(output.exitCode == 0)
    }

    @Test func capturesStderrAndExitCode() async throws {
        // `sh -c 'echo oops 1>&2; exit 3'` — capture, don't throw.
        let output = try await runner.capture(
            command: "sh",
            args: ["-c", "echo oops 1>&2; exit 3"],
            at: NSTemporaryDirectory()
        )
        #expect(output.stderr.contains("oops"))
        #expect(output.exitCode == 3)
    }

    @Test func runThrowsOnNonZeroExit() async throws {
        do {
            _ = try await runner.run(
                command: "sh",
                args: ["-c", "exit 5"],
                at: NSTemporaryDirectory()
            )
            Issue.record("should have thrown")
        } catch CLIError.nonZeroExit(_, let code, _) {
            #expect(code == 5)
        }
    }

    @Test func notFoundForMissingCommand() async throws {
        do {
            _ = try await runner.run(
                command: "totally-not-a-real-command-zzzzz",
                args: [],
                at: NSTemporaryDirectory()
            )
            Issue.record("should have thrown")
        } catch CLIError.notFound(let cmd) {
            #expect(cmd == "totally-not-a-real-command-zzzzz")
        }
    }

    @Test func pathEnrichmentIncludesHomebrewAndLocal() {
        let env = CLIRunner.enrichedEnvironment(base: ["PATH": "/usr/bin"])
        let path = env["PATH"] ?? ""
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.contains("/opt/homebrew/bin"))
        #expect(parts.contains("/usr/local/bin"))
        #expect(parts.contains("/usr/bin"))
        // Homebrew should come before /usr/bin so brewed git beats Xcode's.
        let homebrewIdx = parts.firstIndex(of: "/opt/homebrew/bin") ?? Int.max
        let usrBinIdx = parts.firstIndex(of: "/usr/bin") ?? -1
        #expect(homebrewIdx < usrBinIdx)
    }

    @Test func pathEnrichmentDoesNotDuplicate() {
        let env = CLIRunner.enrichedEnvironment(base: [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin"
        ])
        let path = env["PATH"] ?? ""
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.filter { $0 == "/opt/homebrew/bin" }.count == 1)
        #expect(parts.filter { $0 == "/usr/local/bin" }.count == 1)
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --filter CLIRunnerTests`
Expected: all 6 tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyKitTests/CLI/CLIRunnerTests.swift
git commit -m "test(cli): CLIRunner integration tests for PATH, stdout/stderr, exit codes"
```

---

## Phase B — `GitRunner` async migration

This phase migrates every existing git caller to async. **Run `swift build && swift test` after every task** to catch drift — all existing tests should continue to pass.

### Task B1: Rewrite `GitRunner` as async wrapper over `CLIRunner`

**Files:**
- Modify: `Sources/GrafttyKit/Git/GitRunner.swift` (full rewrite)

- [ ] **Step 1: Replace the file contents**

```swift
import Foundation

/// Shared async wrapper around `git` invocations. Delegates to `CLIRunner`
/// so all the PATH enrichment and launch-failure handling lives in one place.
/// Retained as a distinct type so call sites read as "git-specific" and so
/// we have an obvious seam for future git-only helpers.
public enum GitRunner {

    public typealias Error = CLIError

    /// Injected in tests via `configure`. Defaults to a fresh `CLIRunner`.
    private static var executor: CLIExecutor = CLIRunner()

    /// Test seam. Restore to `CLIRunner()` at the end of a test suite.
    public static func configure(executor: CLIExecutor) {
        self.executor = executor
    }

    public static func resetForTests() {
        self.executor = CLIRunner()
    }

    /// Runs `git <args>` and returns stdout. Throws `CLIError.nonZeroExit`
    /// on non-zero exit. Use when non-zero means "the call failed."
    public static func run(args: [String], at directory: String) async throws -> String {
        let out = try await executor.run(command: "git", args: args, at: directory)
        return out.stdout
    }

    /// Runs `git <args>` and returns `(stdout, exitCode)` without throwing on
    /// non-zero exit. Use when exit code is diagnostic.
    public static func capture(
        args: [String],
        at directory: String
    ) async throws -> (stdout: String, exitCode: Int32) {
        let out = try await executor.capture(command: "git", args: args, at: directory)
        return (stdout: out.stdout, exitCode: out.exitCode)
    }

    /// Runs `git <args>` and returns the full `CLIOutput` (stdout/stderr/exit).
    /// Use for mutation commands where stderr carries the user-visible error.
    public static func captureAll(
        args: [String],
        at directory: String
    ) async throws -> CLIOutput {
        try await executor.capture(command: "git", args: args, at: directory)
    }
}
```

- [ ] **Step 2: Verify build fails expectedly**

Run: `swift build 2>&1 | head -40`
Expected: errors pointing at existing call sites that use the old sync API. That's the migration cue — the remaining B tasks fix each caller.

---

### Task B2: Migrate `GitRepoDetector` to async

**Files:**
- Modify: `Sources/GrafttyKit/Git/GitRepoDetector.swift`
- Modify: `Tests/GrafttyKitTests/Git/GitRepoDetectorTests.swift`

- [ ] **Step 1: Update GitRepoDetector**

`GitRepoDetector.detect(path:)` currently doesn't use `GitRunner`; it reads files directly. No change needed to the detector itself. Verify by reading the file — no `GitRunner` calls exist.

- [ ] **Step 2: Verify no changes needed**

Run: `grep GitRunner Sources/GrafttyKit/Git/GitRepoDetector.swift`
Expected: no matches.

Skip this task's "modify source" step — the file is already fine.

- [ ] **Step 3: Confirm tests still compile**

Run: `swift test --filter GitRepoDetectorTests`
Expected: tests pass (they never touched GitRunner).

- [ ] **Step 4: No commit**

Nothing changed for this task. Move on.

---

### Task B3: Migrate `GitWorktreeDiscovery` to async

**Files:**
- Modify: `Sources/GrafttyKit/Git/GitWorktreeDiscovery.swift`
- Modify: `Tests/GrafttyKitTests/Git/GitWorktreeDiscoveryTests.swift`

- [ ] **Step 1: Make `discover` async throws**

Replace the `discover` function with:

```swift
public static func discover(repoPath: String) async throws -> [DiscoveredWorktree] {
    do {
        let output = try await GitRunner.run(args: ["worktree", "list", "--porcelain"], at: repoPath)
        return parsePorcelain(output)
    } catch let CLIError.nonZeroExit(_, code, _) {
        throw GitDiscoveryError.gitFailed(terminationStatus: code)
    }
}
```

- [ ] **Step 2: Update tests**

The existing tests use a real `git` via `/bin/zsh`. They keep working because `GitRunner` still calls real `git` by default. Add `async` to test functions that call `discover`:

```swift
@Test func listsRepoRootAndLinkedWorktrees() async throws {
    // ... existing body, with `try await GitWorktreeDiscovery.discover(...)`
}
```

Apply this `async` + `await` change to every test in the file that calls `GitWorktreeDiscovery.discover`.

- [ ] **Step 3: Run tests**

Run: `swift test --filter GitWorktreeDiscoveryTests`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyKit/Git/GitWorktreeDiscovery.swift Tests/GrafttyKitTests/Git/GitWorktreeDiscoveryTests.swift
git commit -m "refactor(git): migrate GitWorktreeDiscovery to async"
```

---

### Task B4: Migrate `GitWorktreeStats` to async

**Files:**
- Modify: `Sources/GrafttyKit/Git/GitWorktreeStats.swift`
- Modify: `Tests/GrafttyKitTests/Git/GitWorktreeStatsTests.swift`

- [ ] **Step 1: Make `compute` async throws**

Replace the `compute` function with:

```swift
public static func compute(
    worktreePath: String,
    defaultBranchRef: String
) async throws -> WorktreeStats {
    let range = "\(defaultBranchRef)...HEAD"

    let revListOutput: String
    do {
        revListOutput = try await GitRunner.run(
            args: ["rev-list", "--left-right", "--count", range],
            at: worktreePath
        )
    } catch let CLIError.nonZeroExit(_, status, _) {
        throw GitWorktreeStatsError.gitFailed(terminationStatus: status)
    }

    guard let counts = parseRevListCounts(revListOutput) else {
        throw GitWorktreeStatsError.unparseableRevList(revListOutput)
    }

    let diffOutput: String
    do {
        diffOutput = try await GitRunner.run(
            args: ["diff", "--shortstat", range],
            at: worktreePath
        )
    } catch let CLIError.nonZeroExit(_, status, _) {
        throw GitWorktreeStatsError.gitFailed(terminationStatus: status)
    }
    let diff = parseShortStat(diffOutput)

    let statusOutput: String
    do {
        statusOutput = try await GitRunner.run(
            args: ["status", "--porcelain"],
            at: worktreePath
        )
    } catch let CLIError.nonZeroExit(_, status, _) {
        throw GitWorktreeStatsError.gitFailed(terminationStatus: status)
    }
    let dirty = !statusOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    return WorktreeStats(
        ahead: counts.ahead,
        behind: counts.behind,
        insertions: diff.insertions,
        deletions: diff.deletions,
        hasUncommittedChanges: dirty
    )
}
```

- [ ] **Step 2: Update tests**

Add `async` + `await` at every call site of `GitWorktreeStats.compute` in the test file.

- [ ] **Step 3: Run tests**

Run: `swift test --filter GitWorktreeStatsTests`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyKit/Git/GitWorktreeStats.swift Tests/GrafttyKitTests/Git/GitWorktreeStatsTests.swift
git commit -m "refactor(git): migrate GitWorktreeStats to async"
```

---

### Task B5: Migrate `GitOriginDefaultBranch` to async

**Files:**
- Modify: `Sources/GrafttyKit/Git/GitOriginDefaultBranch.swift`
- Modify: `Tests/GrafttyKitTests/Git/GitOriginDefaultBranchTests.swift`

- [ ] **Step 1: Make `resolve` async throws**

Replace the `resolve` function with:

```swift
public static func resolve(repoPath: String) async throws -> String? {
    if let captured = try? await GitRunner.capture(
        args: ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
        at: repoPath
    ), captured.exitCode == 0 {
        let trimmed = captured.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("origin/") {
            let name = String(trimmed.dropFirst("origin/".count))
            if !name.isEmpty { return name }
        } else if !trimmed.isEmpty {
            return trimmed
        }
    }

    for candidate in ["main", "master", "develop"] {
        guard let captured = try? await GitRunner.capture(
            args: ["show-ref", "--verify", "--quiet", "refs/remotes/origin/\(candidate)"],
            at: repoPath
        ) else { continue }
        if captured.exitCode == 0 { return candidate }
    }

    return nil
}
```

- [ ] **Step 2: Update tests**

Add `async` + `await` at every `GitOriginDefaultBranch.resolve` call site in the test file.

- [ ] **Step 3: Run tests**

Run: `swift test --filter GitOriginDefaultBranchTests`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyKit/Git/GitOriginDefaultBranch.swift Tests/GrafttyKitTests/Git/GitOriginDefaultBranchTests.swift
git commit -m "refactor(git): migrate GitOriginDefaultBranch to async"
```

---

### Task B6: Migrate `GitWorktreeAdd` to async

**Files:**
- Modify: `Sources/GrafttyKit/Git/GitWorktreeAdd.swift`

- [ ] **Step 1: Rewrite `add` as async throws**

```swift
import Foundation

public enum GitWorktreeAdd {

    public enum Error: Swift.Error, Equatable {
        case gitFailed(exitCode: Int32, stderr: String)
    }

    public static func add(
        repoPath: String,
        worktreePath: String,
        branchName: String,
        startPoint: String?
    ) async throws {
        var args: [String] = ["worktree", "add", "-b", branchName, worktreePath]
        if let startPoint, !startPoint.isEmpty {
            args.append(startPoint)
        }
        let result = try await GitRunner.captureAll(args: args, at: repoPath)
        guard result.exitCode == 0 else {
            throw Error.gitFailed(
                exitCode: result.exitCode,
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
```

- [ ] **Step 2: Compile the package**

Run: `swift build`
Expected: `MainWindow.swift` will fail where it calls `GitWorktreeAdd.add` inside `Task.detached`. That's expected; Task B7 fixes it.

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Git/GitWorktreeAdd.swift
git commit -m "refactor(git): migrate GitWorktreeAdd to async"
```

---

### Task B7: Migrate app-layer callers

**Files:**
- Modify: `Sources/Graftty/Model/WorktreeStatsStore.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`
- Modify: `Sources/Graftty/GrafttyApp.swift` (`reconcileOnLaunch` + `WorktreeMonitorBridge`)

- [ ] **Step 1: `WorktreeStatsStore.computeOffMain` becomes async-naïve**

In `Sources/Graftty/Model/WorktreeStatsStore.swift`, change `computeOffMain` to use `async` and drop the sync-over-async wrapping. Replace the existing `computeOffMain` and the `Task.detached` call in `refresh` with:

```swift
public func refresh(worktreePath: String, repoPath: String) {
    guard !inFlight.contains(worktreePath) else { return }
    inFlight.insert(worktreePath)
    let cached = defaultBranchByRepo[repoPath] ?? nil

    Task {
        let computed = await Self.computeOffMain(
            worktreePath: worktreePath,
            repoPath: repoPath,
            cachedDefault: cached
        )
        await MainActor.run {
            self.apply(
                worktreePath: worktreePath,
                repoPath: repoPath,
                result: computed
            )
        }
    }
}

private static func computeOffMain(
    worktreePath: String,
    repoPath: String,
    cachedDefault: String?
) async -> ComputeResult {
    let name: String?
    if let cached = cachedDefault {
        name = cached
    } else {
        name = (try? await GitOriginDefaultBranch.resolve(repoPath: repoPath)) ?? nil
    }
    guard let name else {
        return ComputeResult(defaultBranch: nil, stats: nil)
    }
    let isHomeWorktree = (worktreePath == repoPath)
    let baseRef = isHomeWorktree ? "origin/\(name)" : name
    let stats = try? await GitWorktreeStats.compute(
        worktreePath: worktreePath,
        defaultBranchRef: baseRef
    )
    return ComputeResult(defaultBranch: name, stats: stats)
}
```

Note: `Task { ... }` without `.detached` runs at the current actor's priority; since the inner work awaits async I/O, it doesn't block MainActor.

- [ ] **Step 2: Update `MainWindow.addWorktree`**

In `MainWindow.swift`, the `addWorktree` function currently does `Task.detached { ... GitWorktreeAdd.add(...) ... }`. Replace it with direct `await`:

```swift
private func addWorktree(
    repo: RepoEntry,
    worktreeName: String,
    branchName: String
) async -> String? {
    let repoPath = repo.path
    let worktreePath = repoPath + "/.worktrees/" + worktreeName

    let startPoint: String?
    do {
        startPoint = try await GitOriginDefaultBranch.resolve(repoPath: repoPath)
    } catch {
        startPoint = nil
    }

    let gitError: String?
    do {
        try await GitWorktreeAdd.add(
            repoPath: repoPath,
            worktreePath: worktreePath,
            branchName: branchName,
            startPoint: startPoint
        )
        gitError = nil
    } catch GitWorktreeAdd.Error.gitFailed(_, let stderr) {
        gitError = stderr.isEmpty ? "git worktree add failed" : stderr
    } catch {
        gitError = "\(error)"
    }
    if let gitError { return gitError }

    if let discovered = try? await GitWorktreeDiscovery.discover(repoPath: repoPath),
       let repoIdx = appState.repos.firstIndex(where: { $0.path == repoPath }) {
        let existingPaths = Set(appState.repos[repoIdx].worktrees.map(\.path))
        for d in discovered where !existingPaths.contains(d.path) {
            let entry = WorktreeEntry(path: d.path, branch: d.branch)
            appState.repos[repoIdx].worktrees.append(entry)
            worktreeMonitor.watchWorktreePath(entry.path)
            worktreeMonitor.watchHeadRef(worktreePath: entry.path, repoPath: repoPath)
            statsStore.refresh(worktreePath: entry.path, repoPath: repoPath)
        }
    }

    selectWorktree(worktreePath)
    return nil
}
```

Also update `addRepoFromPath(_:selectWorktree:)` where it calls `GitWorktreeDiscovery.discover`:

```swift
private func addRepoFromPath(_ repoPath: String, selectWorktree: String?) {
    guard !appState.repos.contains(where: { $0.path == repoPath }) else {
        if let wt = selectWorktree {
            appState.selectedWorktreePath = wt
        }
        return
    }

    Task {
        guard let discovered = try? await GitWorktreeDiscovery.discover(repoPath: repoPath) else { return }
        let worktrees = discovered.map { WorktreeEntry(path: $0.path, branch: $0.branch) }
        let displayName = URL(fileURLWithPath: repoPath).lastPathComponent
        let repo = RepoEntry(path: repoPath, displayName: displayName, worktrees: worktrees)
        appState.addRepo(repo)

        if let wt = selectWorktree {
            self.selectWorktree(wt)
        } else if let first = worktrees.first {
            self.selectWorktree(first.path)
        }
    }
}
```

- [ ] **Step 3: Update `GrafttyApp.reconcileOnLaunch`**

`reconcileOnLaunch` currently calls `GitWorktreeDiscovery.discover` synchronously. Change to a `Task`:

```swift
private func reconcileOnLaunch() {
    let binding = $appState
    Task {
        for repoIdx in binding.wrappedValue.repos.indices {
            let repoPath = binding.wrappedValue.repos[repoIdx].path
            guard let discovered = try? await GitWorktreeDiscovery.discover(repoPath: repoPath) else { continue }
            let discoveredPaths = Set(discovered.map(\.path))

            let existingPaths = Set(binding.wrappedValue.repos[repoIdx].worktrees.map(\.path))
            for d in discovered where !existingPaths.contains(d.path) {
                binding.wrappedValue.repos[repoIdx].worktrees.append(
                    WorktreeEntry(path: d.path, branch: d.branch)
                )
            }

            for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                let wt = binding.wrappedValue.repos[repoIdx].worktrees[wtIdx]
                if !discoveredPaths.contains(wt.path) && wt.state != .stale {
                    binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].state = .stale
                }
            }

            for wtIdx in binding.wrappedValue.repos[repoIdx].worktrees.indices {
                if let match = discovered.first(where: {
                    $0.path == binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].path
                }) {
                    binding.wrappedValue.repos[repoIdx].worktrees[wtIdx].branch = match.branch
                }
            }
        }
    }
}
```

- [ ] **Step 4: Update `WorktreeMonitorBridge`**

`WorktreeMonitorBridge.worktreeMonitorDidDetectChange` and `.worktreeMonitorDidDetectBranchChange` currently call `GitWorktreeDiscovery.discover` synchronously inside `Task { @MainActor in ... }`. Change to `try? await`:

In `worktreeMonitorDidDetectChange`:
```swift
Task { @MainActor in
    guard let discovered = try? await GitWorktreeDiscovery.discover(repoPath: repoPath) else { return }
    // ... rest of body unchanged
}
```

Same change in `worktreeMonitorDidDetectBranchChange`.

- [ ] **Step 5: Build and test**

Run: `swift build && swift test`
Expected: all tests pass, no warnings about unhandled async.

- [ ] **Step 6: Commit**

```bash
git add Sources/Graftty Sources/GrafttyKit
git commit -m "refactor: migrate app-layer callers to async git API"
```

---

### Task B8: End-to-end build sanity check

- [ ] **Step 1: Full clean rebuild**

Run: `swift package clean && swift build`
Expected: no errors, no warnings about deprecated sync API.

- [ ] **Step 2: Full test run**

Run: `swift test`
Expected: all pre-existing tests pass. Phase B is complete.

- [ ] **Step 3: No commit** (already committed per-task)

---

## Phase C — Hosting detection

### Task C1: `HostingProvider` + `HostingOrigin` types

**Files:**
- Create: `Sources/GrafttyKit/Hosting/HostingProvider.swift`
- Create: `Sources/GrafttyKit/Hosting/HostingOrigin.swift`

- [ ] **Step 1: Write `HostingProvider`**

```swift
import Foundation

public enum HostingProvider: String, Codable, Sendable, Equatable {
    case github
    case gitlab
    case unsupported
}
```

- [ ] **Step 2: Write `HostingOrigin`**

```swift
import Foundation

public struct HostingOrigin: Codable, Sendable, Equatable {
    public let provider: HostingProvider
    public let host: String
    public let owner: String
    public let repo: String

    public init(provider: HostingProvider, host: String, owner: String, repo: String) {
        self.provider = provider
        self.host = host
        self.owner = owner
        self.repo = repo
    }

    public var slug: String { "\(owner)/\(repo)" }
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyKit/Hosting/
git commit -m "feat(hosting): add HostingProvider and HostingOrigin types"
```

---

### Task C2: `GitOriginHost.parse` + tests

**Files:**
- Create: `Sources/GrafttyKit/Hosting/GitOriginHost.swift`
- Create: `Tests/GrafttyKitTests/Hosting/GitOriginHostTests.swift`

- [ ] **Step 1: Write a failing test first**

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitOriginHost.parse")
struct GitOriginHostParseTests {
    @Test func parsesGitHubSSHURL() {
        let origin = GitOriginHost.parse(remoteURL: "git@github.com:btucker/graftty.git")
        #expect(origin == HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "graftty"))
    }

    @Test func parsesGitHubHTTPSURL() {
        let origin = GitOriginHost.parse(remoteURL: "https://github.com/btucker/graftty.git")
        #expect(origin == HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "graftty"))
    }

    @Test func parsesGitHubHTTPSWithoutDotGit() {
        let origin = GitOriginHost.parse(remoteURL: "https://github.com/btucker/graftty")
        #expect(origin == HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "graftty"))
    }

    @Test func parsesGitLabSSHURL() {
        let origin = GitOriginHost.parse(remoteURL: "git@gitlab.com:foo/bar.git")
        #expect(origin == HostingOrigin(provider: .gitlab, host: "gitlab.com", owner: "foo", repo: "bar"))
    }

    @Test func enterpriseGitHubMatchesByHostSubstring() {
        let origin = GitOriginHost.parse(remoteURL: "git@github.acme.com:team/proj.git")
        #expect(origin == HostingOrigin(provider: .github, host: "github.acme.com", owner: "team", repo: "proj"))
    }

    @Test func enterpriseGitLabMatchesByHostSubstring() {
        let origin = GitOriginHost.parse(remoteURL: "git@gitlab.acme.com:team/proj.git")
        #expect(origin == HostingOrigin(provider: .gitlab, host: "gitlab.acme.com", owner: "team", repo: "proj"))
    }

    @Test func unrecognizedHostIsUnsupported() {
        let origin = GitOriginHost.parse(remoteURL: "git@bitbucket.org:foo/bar.git")
        #expect(origin?.provider == .unsupported)
    }

    @Test func localPathReturnsNil() {
        #expect(GitOriginHost.parse(remoteURL: "/some/local/path") == nil)
        #expect(GitOriginHost.parse(remoteURL: "file:///some/path") == nil)
    }

    @Test func emptyReturnsNil() {
        #expect(GitOriginHost.parse(remoteURL: "") == nil)
    }

    @Test func gitProtocolReturnsNil() {
        // git://host/... — rarely used; treat as unsupported rather than misparsing
        #expect(GitOriginHost.parse(remoteURL: "git://example.com/foo/bar.git") == nil)
    }
}
```

- [ ] **Step 2: Run; expect compile error (parse undefined)**

Run: `swift test --filter GitOriginHostParseTests`
Expected: compile error.

- [ ] **Step 3: Implement `GitOriginHost.parse`**

```swift
import Foundation

public enum GitOriginHost {
    /// Parse a git remote URL into a `HostingOrigin`.
    /// Returns nil for local paths, `file://`, `git://`, or empty strings.
    /// Returns `HostingOrigin` with `.unsupported` provider for recognized-but-
    /// unsupported hosts (like bitbucket).
    public static func parse(remoteURL: String) -> HostingOrigin? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Reject schemes we can't infer a provider from.
        if trimmed.hasPrefix("file://") || trimmed.hasPrefix("git://") || trimmed.hasPrefix("/") {
            return nil
        }

        let (host, path): (String, String)

        if trimmed.hasPrefix("git@") || trimmed.hasPrefix("ssh://") {
            // SSH: `git@host:owner/repo.git` or `ssh://git@host/owner/repo.git`
            let stripped: String
            if trimmed.hasPrefix("ssh://") {
                stripped = String(trimmed.dropFirst("ssh://".count))
            } else {
                stripped = String(trimmed.dropFirst("git@".count))
            }
            // Separate host from path using first ':' (scp-style) or '/' (ssh://)
            let separatorIdx: String.Index?
            if let colon = stripped.firstIndex(of: ":") {
                separatorIdx = colon
            } else if let slash = stripped.firstIndex(of: "/") {
                separatorIdx = slash
            } else {
                return nil
            }
            guard let sep = separatorIdx else { return nil }
            var rawHost = String(stripped[..<sep])
            // Strip optional `user@` if ssh://user@host/...
            if let at = rawHost.lastIndex(of: "@") {
                rawHost = String(rawHost[rawHost.index(after: at)...])
            }
            host = rawHost
            path = String(stripped[stripped.index(after: sep)...])
        } else if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            guard let url = URL(string: trimmed), let urlHost = url.host else { return nil }
            host = urlHost
            // Drop leading slash.
            path = String(url.path.drop(while: { $0 == "/" }))
        } else {
            return nil
        }

        // Split owner/repo from the first '/'. Strip trailing `.git` from repo.
        guard let slash = path.firstIndex(of: "/") else { return nil }
        let owner = String(path[..<slash])
        var repo = String(path[path.index(after: slash)...])
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(".git".count)) }
        // Also strip any trailing slash.
        while repo.hasSuffix("/") { repo = String(repo.dropLast()) }

        guard !owner.isEmpty, !repo.isEmpty, !host.isEmpty else { return nil }

        let provider: HostingProvider
        if host.contains("github") {
            provider = .github
        } else if host.contains("gitlab") {
            provider = .gitlab
        } else {
            provider = .unsupported
        }

        return HostingOrigin(provider: provider, host: host, owner: owner, repo: repo)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter GitOriginHostParseTests`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Hosting/GitOriginHost.swift Tests/GrafttyKitTests/Hosting/GitOriginHostTests.swift
git commit -m "feat(hosting): parse origin remote URLs into HostingOrigin"
```

---

### Task C3: `GitOriginHost.detect` + test

**Files:**
- Modify: `Sources/GrafttyKit/Hosting/GitOriginHost.swift`
- Modify: `Tests/GrafttyKitTests/Hosting/GitOriginHostTests.swift`

- [ ] **Step 1: Add a failing test (using FakeCLIExecutor via GitRunner.configure)**

Append to `GitOriginHostTests.swift`:

```swift
@Suite("GitOriginHost.detect")
struct GitOriginHostDetectTests {
    @Test func detectsGitHubOrigin() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["remote", "get-url", "origin"],
            output: CLIOutput(stdout: "git@github.com:btucker/graftty.git\n", stderr: "", exitCode: 0)
        )
        GitRunner.configure(executor: fake)
        defer { GitRunner.resetForTests() }

        let origin = try await GitOriginHost.detect(repoPath: "/tmp/repo")
        #expect(origin?.provider == .github)
        #expect(origin?.slug == "btucker/graftty")
    }

    @Test func returnsNilWhenRemoteMissing() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["remote", "get-url", "origin"],
            error: .nonZeroExit(command: "git", exitCode: 128, stderr: "no such remote")
        )
        GitRunner.configure(executor: fake)
        defer { GitRunner.resetForTests() }

        let origin = try await GitOriginHost.detect(repoPath: "/tmp/repo")
        #expect(origin == nil)
    }
}
```

- [ ] **Step 2: Add `detect` to `GitOriginHost`**

Append to `GitOriginHost.swift`:

```swift
extension GitOriginHost {
    /// Resolves the repo's `origin` remote URL and parses it.
    /// Returns nil if there's no origin remote or the URL is unparseable.
    public static func detect(repoPath: String) async throws -> HostingOrigin? {
        let output: String
        do {
            output = try await GitRunner.run(args: ["remote", "get-url", "origin"], at: repoPath)
        } catch CLIError.nonZeroExit {
            return nil
        }
        return parse(remoteURL: output)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `swift test --filter GitOriginHostDetectTests`
Expected: both tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/GrafttyKit/Hosting/GitOriginHost.swift Tests/GrafttyKitTests/Hosting/GitOriginHostTests.swift
git commit -m "feat(hosting): detect origin remote via GitRunner"
```

---

## Phase D — PR fetchers

### Task D1: `PRInfo` value type

**Files:**
- Create: `Sources/GrafttyKit/Hosting/PRInfo.swift`

- [ ] **Step 1: Write the type**

```swift
import Foundation

public struct PRInfo: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, Equatable {
        case open
        case merged
    }

    public enum Checks: String, Codable, Sendable, Equatable {
        case pending
        case success
        case failure
        case none
    }

    public let number: Int
    public let title: String
    public let url: URL
    public let state: State
    public let checks: Checks
    public let fetchedAt: Date

    public var id: Int { number }

    public init(
        number: Int,
        title: String,
        url: URL,
        state: State,
        checks: Checks,
        fetchedAt: Date
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.checks = checks
        self.fetchedAt = fetchedAt
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Hosting/PRInfo.swift
git commit -m "feat(hosting): add PRInfo value type"
```

---

### Task D2: `PRFetcher` protocol

**Files:**
- Create: `Sources/GrafttyKit/Hosting/PRFetcher.swift`

- [ ] **Step 1: Write the protocol**

```swift
import Foundation

public protocol PRFetcher: Sendable {
    /// Returns the PR/MR for `branch`. Prefers open; falls back to
    /// most-recent merged. Never returns closed-unmerged.
    /// Returns nil if no matching PR/MR exists.
    /// Throws `CLIError` on CLI failure (including auth / network / rate limit).
    func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo?
}
```

- [ ] **Step 2: Build**

Run: `swift build`

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Hosting/PRFetcher.swift
git commit -m "feat(hosting): PRFetcher protocol"
```

---

### Task D3: `GitHubPRFetcher` + fixtures + tests

**Files:**
- Create: `Sources/GrafttyKit/Hosting/GitHubPRFetcher.swift`
- Create: `Tests/GrafttyKitTests/Hosting/GitHubPRFetcherTests.swift`
- Create: `Tests/GrafttyKitTests/Hosting/Fixtures/gh-pr-open-passing.json`
- Create: `Tests/GrafttyKitTests/Hosting/Fixtures/gh-pr-open-pending.json`
- Create: `Tests/GrafttyKitTests/Hosting/Fixtures/gh-pr-open-failing.json`
- Create: `Tests/GrafttyKitTests/Hosting/Fixtures/gh-pr-empty.json`
- Create: `Tests/GrafttyKitTests/Hosting/Fixtures/gh-pr-merged.json`
- Create: `Tests/GrafttyKitTests/Hosting/Fixtures/gh-pr-checks-passing.json`
- Create: `Tests/GrafttyKitTests/Hosting/Fixtures/gh-pr-checks-pending.json`
- Create: `Tests/GrafttyKitTests/Hosting/Fixtures/gh-pr-checks-failing.json`
- Create: `Tests/GrafttyKitTests/Hosting/Fixtures/gh-pr-checks-none.json`

- [ ] **Step 1: Write the fixtures**

`gh-pr-open-passing.json`:
```json
[{"number":412,"title":"Add PR/MR status button to breadcrumb","url":"https://github.com/btucker/graftty/pull/412","state":"OPEN","headRefName":"feature/git-improvements"}]
```

`gh-pr-merged.json`:
```json
[{"number":398,"title":"GitHub integration scaffold","url":"https://github.com/btucker/graftty/pull/398","state":"MERGED","headRefName":"feature/github-integration","mergedAt":"2026-04-15T10:00:00Z"}]
```

`gh-pr-empty.json`:
```json
[]
```

`gh-pr-checks-passing.json`:
```json
[{"name":"build","state":"COMPLETED","conclusion":"SUCCESS"},{"name":"test","state":"COMPLETED","conclusion":"SUCCESS"}]
```

`gh-pr-checks-pending.json`:
```json
[{"name":"build","state":"COMPLETED","conclusion":"SUCCESS"},{"name":"test","state":"IN_PROGRESS","conclusion":""}]
```

`gh-pr-checks-failing.json`:
```json
[{"name":"build","state":"COMPLETED","conclusion":"SUCCESS"},{"name":"test","state":"COMPLETED","conclusion":"FAILURE"}]
```

`gh-pr-checks-none.json`:
```json
[]
```

Register fixtures in `Package.swift` — update the `GrafttyKitTests` target:

```swift
.testTarget(
    name: "GrafttyKitTests",
    dependencies: ["GrafttyKit"],
    resources: [.process("Hosting/Fixtures")]
)
```

- [ ] **Step 2: Write a failing test**

Create `GitHubPRFetcherTests.swift`:

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitHubPRFetcher")
struct GitHubPRFetcherTests {
    let origin = HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "graftty")
    let branch = "feature/git-improvements"

    func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Hosting/Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    @Test func returnsOpenPRWithPassingChecks() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: [
                "pr", "list",
                "--repo", "btucker/graftty",
                "--head", branch,
                "--state", "open",
                "--limit", "1",
                "--json", "number,title,url,state,headRefName"
            ],
            output: CLIOutput(stdout: loadFixture("gh-pr-open-passing"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "412", "--repo", "btucker/graftty", "--json", "name,state,conclusion"],
            output: CLIOutput(stdout: loadFixture("gh-pr-checks-passing"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date(timeIntervalSince1970: 100) })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)

        #expect(pr?.number == 412)
        #expect(pr?.state == .open)
        #expect(pr?.checks == .success)
        #expect(pr?.title == "Add PR/MR status button to breadcrumb")
        #expect(pr?.url.absoluteString == "https://github.com/btucker/graftty/pull/412")
    }

    @Test func returnsMergedPRWhenNoOpen() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "btucker/graftty",
                "--head", branch, "--state", "open", "--limit", "1",
                "--json", "number,title,url,state,headRefName"
            ],
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "btucker/graftty",
                "--head", branch, "--state", "merged", "--limit", "1",
                "--json", "number,title,url,state,headRefName,mergedAt"
            ],
            output: CLIOutput(stdout: loadFixture("gh-pr-merged"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)

        #expect(pr?.number == 398)
        #expect(pr?.state == .merged)
        #expect(pr?.checks == PRInfo.Checks.none)
    }

    @Test func returnsNilWhenNoOpenOrMerged() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "btucker/graftty",
                "--head", branch, "--state", "open", "--limit", "1",
                "--json", "number,title,url,state,headRefName"
            ],
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "btucker/graftty",
                "--head", branch, "--state", "merged", "--limit", "1",
                "--json", "number,title,url,state,headRefName,mergedAt"
            ],
            output: CLIOutput(stdout: loadFixture("gh-pr-empty"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(pr == nil)
    }

    @Test func checksPendingRollup() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "btucker/graftty",
                "--head", branch, "--state", "open", "--limit", "1",
                "--json", "number,title,url,state,headRefName"
            ],
            output: CLIOutput(stdout: loadFixture("gh-pr-open-passing"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "412", "--repo", "btucker/graftty", "--json", "name,state,conclusion"],
            output: CLIOutput(stdout: loadFixture("gh-pr-checks-pending"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(pr?.checks == .pending)
    }

    @Test func checksFailingRollup() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "btucker/graftty",
                "--head", branch, "--state", "open", "--limit", "1",
                "--json", "number,title,url,state,headRefName"
            ],
            output: CLIOutput(stdout: loadFixture("gh-pr-open-passing"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "412", "--repo", "btucker/graftty", "--json", "name,state,conclusion"],
            output: CLIOutput(stdout: loadFixture("gh-pr-checks-failing"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(pr?.checks == .failure)
    }

    @Test func checksNoneRollup() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "btucker/graftty",
                "--head", branch, "--state", "open", "--limit", "1",
                "--json", "number,title,url,state,headRefName"
            ],
            output: CLIOutput(stdout: loadFixture("gh-pr-open-passing"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "412", "--repo", "btucker/graftty", "--json", "name,state,conclusion"],
            output: CLIOutput(stdout: loadFixture("gh-pr-checks-none"), stderr: "", exitCode: 0)
        )

        let fetcher = GitHubPRFetcher(executor: fake, now: { Date() })
        let pr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(pr?.checks == PRInfo.Checks.none)
    }
}
```

- [ ] **Step 3: Run tests; expect compile error**

Run: `swift test --filter GitHubPRFetcherTests`
Expected: compile error — `GitHubPRFetcher` not defined.

- [ ] **Step 4: Implement `GitHubPRFetcher`**

```swift
import Foundation

public struct GitHubPRFetcher: PRFetcher {
    private let executor: CLIExecutor
    private let now: @Sendable () -> Date

    public init(executor: CLIExecutor = CLIRunner(), now: @Sendable @escaping () -> Date = Date.init) {
        self.executor = executor
        self.now = now
    }

    public func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
        if let open = try await fetchOne(origin: origin, branch: branch, state: "open") {
            let checks = try await fetchChecks(origin: origin, number: open.number)
            return PRInfo(
                number: open.number,
                title: open.title,
                url: open.url,
                state: .open,
                checks: checks,
                fetchedAt: now()
            )
        }
        if let merged = try await fetchOne(origin: origin, branch: branch, state: "merged") {
            return PRInfo(
                number: merged.number,
                title: merged.title,
                url: merged.url,
                state: .merged,
                checks: .none,
                fetchedAt: now()
            )
        }
        return nil
    }

    // MARK: - Internals

    private struct RawPR: Decodable {
        let number: Int
        let title: String
        let url: URL
        let state: String
        let headRefName: String
    }

    private struct RawCheck: Decodable {
        let name: String
        let state: String
        let conclusion: String?
    }

    private func fetchOne(origin: HostingOrigin, branch: String, state: String) async throws -> RawPR? {
        var args = [
            "pr", "list",
            "--repo", origin.slug,
            "--head", branch,
            "--state", state,
            "--limit", "1",
            "--json", "number,title,url,state,headRefName"
        ]
        if state == "merged" {
            // Minor additional field for the merged path, to keep the stubs
            // distinguishable in tests; the JSON decoder ignores extras.
            if let idx = args.firstIndex(of: "number,title,url,state,headRefName") {
                args[idx] = "number,title,url,state,headRefName,mergedAt"
            }
        }
        let output = try await executor.run(command: "gh", args: args, at: NSHomeDirectory())
        let data = Data(output.stdout.utf8)
        let prs = try JSONDecoder().decode([RawPR].self, from: data)
        return prs.first
    }

    private func fetchChecks(origin: HostingOrigin, number: Int) async throws -> PRInfo.Checks {
        let args = [
            "pr", "checks", String(number),
            "--repo", origin.slug,
            "--json", "name,state,conclusion"
        ]
        let output = try await executor.run(command: "gh", args: args, at: NSHomeDirectory())
        let data = Data(output.stdout.utf8)
        let checks = try JSONDecoder().decode([RawCheck].self, from: data)
        return rollup(checks)
    }

    static func rollup(_ checks: [RawCheck]) -> PRInfo.Checks {
        if checks.isEmpty { return .none }
        if checks.contains(where: { ($0.conclusion ?? "").uppercased() == "FAILURE" }) {
            return .failure
        }
        if checks.contains(where: {
            let s = $0.state.uppercased()
            return s == "IN_PROGRESS" || s == "QUEUED" || s == "PENDING"
        }) {
            return .pending
        }
        if checks.allSatisfy({ ($0.conclusion ?? "").uppercased() == "SUCCESS" }) {
            return .success
        }
        return .none
    }
}

extension GitHubPRFetcher {
    fileprivate struct RawCheckForTest: Decodable { let name: String; let state: String; let conclusion: String? }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter GitHubPRFetcherTests`
Expected: all 6 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Hosting/GitHubPRFetcher.swift Tests/GrafttyKitTests/Hosting Package.swift
git commit -m "feat(hosting): GitHubPRFetcher with CI rollup"
```

---

### Task D4: `GitLabPRFetcher` + fixtures + tests

**Files:**
- Create: `Sources/GrafttyKit/Hosting/GitLabPRFetcher.swift`
- Create: `Tests/GrafttyKitTests/Hosting/GitLabPRFetcherTests.swift`
- Create fixtures:
  - `Tests/GrafttyKitTests/Hosting/Fixtures/glab-mr-opened.json`
  - `Tests/GrafttyKitTests/Hosting/Fixtures/glab-mr-merged.json`
  - `Tests/GrafttyKitTests/Hosting/Fixtures/glab-mr-empty.json`
  - `Tests/GrafttyKitTests/Hosting/Fixtures/glab-pipeline-success.json`
  - `Tests/GrafttyKitTests/Hosting/Fixtures/glab-pipeline-running.json`
  - `Tests/GrafttyKitTests/Hosting/Fixtures/glab-pipeline-failed.json`

- [ ] **Step 1: Write fixtures**

`glab-mr-opened.json`:
```json
[{"iid":512,"title":"Blindspots experiment plumbing","web_url":"https://gitlab.com/foo/bar/-/merge_requests/512","state":"opened","source_branch":"feature/blindspots","head_pipeline":{"id":9001,"status":"success"}}]
```

`glab-mr-merged.json`:
```json
[{"iid":498,"title":"GitHub integration scaffold","web_url":"https://gitlab.com/foo/bar/-/merge_requests/498","state":"merged","source_branch":"feature/gh-integration"}]
```

`glab-mr-empty.json`:
```json
[]
```

`glab-pipeline-success.json`:
```json
{"id":9001,"status":"success","web_url":"https://gitlab.com/foo/bar/-/pipelines/9001"}
```

`glab-pipeline-running.json`:
```json
{"id":9001,"status":"running","web_url":"https://gitlab.com/foo/bar/-/pipelines/9001"}
```

`glab-pipeline-failed.json`:
```json
{"id":9001,"status":"failed","web_url":"https://gitlab.com/foo/bar/-/pipelines/9001"}
```

- [ ] **Step 2: Write failing tests**

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("GitLabPRFetcher")
struct GitLabPRFetcherTests {
    let origin = HostingOrigin(provider: .gitlab, host: "gitlab.com", owner: "foo", repo: "bar")
    let branch = "feature/blindspots"

    func loadFixture(_ name: String) -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Hosting/Fixtures")!
        return try! String(contentsOf: url, encoding: .utf8)
    }

    @Test func returnsOpenMRWithSuccessChecks() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: [
                "mr", "list",
                "--repo", "foo/bar",
                "--source-branch", branch,
                "--state", "opened",
                "--per-page", "1",
                "-F", "json"
            ],
            output: CLIOutput(stdout: loadFixture("glab-mr-opened"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: ["ci", "get", "--repo", "foo/bar", "--pipeline-id", "9001", "-F", "json"],
            output: CLIOutput(stdout: loadFixture("glab-pipeline-success"), stderr: "", exitCode: 0)
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let mr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(mr?.number == 512)
        #expect(mr?.state == .open)
        #expect(mr?.checks == .success)
    }

    @Test func returnsMergedWhenNoOpen() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "glab",
            args: [
                "mr", "list",
                "--repo", "foo/bar",
                "--source-branch", branch,
                "--state", "opened",
                "--per-page", "1",
                "-F", "json"
            ],
            output: CLIOutput(stdout: loadFixture("glab-mr-empty"), stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "glab",
            args: [
                "mr", "list",
                "--repo", "foo/bar",
                "--source-branch", branch,
                "--state", "merged",
                "--per-page", "1",
                "-F", "json"
            ],
            output: CLIOutput(stdout: loadFixture("glab-mr-merged"), stderr: "", exitCode: 0)
        )

        let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
        let mr = try await fetcher.fetch(origin: origin, branch: branch)
        #expect(mr?.number == 498)
        #expect(mr?.state == .merged)
        #expect(mr?.checks == PRInfo.Checks.none)
    }

    @Test func pipelineStatusMapping() async throws {
        func tryStatus(_ fixture: String) async throws -> PRInfo.Checks? {
            let fake = FakeCLIExecutor()
            fake.stub(
                command: "glab",
                args: [
                    "mr", "list",
                    "--repo", "foo/bar",
                    "--source-branch", branch,
                    "--state", "opened",
                    "--per-page", "1",
                    "-F", "json"
                ],
                output: CLIOutput(stdout: loadFixture("glab-mr-opened"), stderr: "", exitCode: 0)
            )
            fake.stub(
                command: "glab",
                args: ["ci", "get", "--repo", "foo/bar", "--pipeline-id", "9001", "-F", "json"],
                output: CLIOutput(stdout: loadFixture(fixture), stderr: "", exitCode: 0)
            )
            let fetcher = GitLabPRFetcher(executor: fake, now: { Date() })
            return try await fetcher.fetch(origin: origin, branch: branch)?.checks
        }

        #expect(try await tryStatus("glab-pipeline-running") == .pending)
        #expect(try await tryStatus("glab-pipeline-failed") == .failure)
        #expect(try await tryStatus("glab-pipeline-success") == .success)
    }
}
```

- [ ] **Step 3: Implement `GitLabPRFetcher`**

```swift
import Foundation

public struct GitLabPRFetcher: PRFetcher {
    private let executor: CLIExecutor
    private let now: @Sendable () -> Date

    public init(executor: CLIExecutor = CLIRunner(), now: @Sendable @escaping () -> Date = Date.init) {
        self.executor = executor
        self.now = now
    }

    public func fetch(origin: HostingOrigin, branch: String) async throws -> PRInfo? {
        if let opened = try await fetchOne(origin: origin, branch: branch, state: "opened") {
            let checks = try await fetchChecks(origin: origin, pipelineId: opened.head_pipeline?.id)
            return PRInfo(
                number: opened.iid,
                title: opened.title,
                url: opened.web_url,
                state: .open,
                checks: checks,
                fetchedAt: now()
            )
        }
        if let merged = try await fetchOne(origin: origin, branch: branch, state: "merged") {
            return PRInfo(
                number: merged.iid,
                title: merged.title,
                url: merged.web_url,
                state: .merged,
                checks: .none,
                fetchedAt: now()
            )
        }
        return nil
    }

    // MARK: - Internals

    private struct RawMR: Decodable {
        let iid: Int
        let title: String
        let web_url: URL
        let state: String
        let source_branch: String
        let head_pipeline: RawPipeline?
    }

    private struct RawPipeline: Decodable {
        let id: Int
        let status: String
    }

    private func fetchOne(origin: HostingOrigin, branch: String, state: String) async throws -> RawMR? {
        let args = [
            "mr", "list",
            "--repo", origin.slug,
            "--source-branch", branch,
            "--state", state,
            "--per-page", "1",
            "-F", "json"
        ]
        let output = try await executor.run(command: "glab", args: args, at: NSHomeDirectory())
        let data = Data(output.stdout.utf8)
        let mrs = try JSONDecoder().decode([RawMR].self, from: data)
        return mrs.first
    }

    private func fetchChecks(origin: HostingOrigin, pipelineId: Int?) async throws -> PRInfo.Checks {
        guard let pipelineId else { return .none }
        let args = ["ci", "get", "--repo", origin.slug, "--pipeline-id", String(pipelineId), "-F", "json"]
        let output = try await executor.run(command: "glab", args: args, at: NSHomeDirectory())
        let data = Data(output.stdout.utf8)
        let pipeline = try JSONDecoder().decode(RawPipeline.self, from: data)
        return Self.mapStatus(pipeline.status)
    }

    static func mapStatus(_ status: String) -> PRInfo.Checks {
        switch status.lowercased() {
        case "success": return .success
        case "failed", "canceled": return .failure
        case "running", "pending", "waiting_for_resource", "preparing", "scheduled": return .pending
        default: return .none
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter GitLabPRFetcherTests`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Hosting/GitLabPRFetcher.swift Tests/GrafttyKitTests/Hosting
git commit -m "feat(hosting): GitLabPRFetcher with pipeline status mapping"
```

---

## Phase E — `PollingTicker`

### Task E1: Implement `PollingTicker` + tests

**Files:**
- Create: `Sources/Graftty/Model/PollingTicker.swift`
- Create: `Tests/GrafttyKitTests/Model/PollingTickerTests.swift`

Note: `PollingTicker` lives in the `Graftty` target (app-level), not `GrafttyKit`, because it depends on `AppKit` for active/inactive notifications. Tests exist in `GrafttyKitTests` only if they don't require AppKit. Since `PollingTicker` uses `NSApplication`, tests exercise only the interval + pulse logic via a test-only init that skips NSApplication observation.

Revise: keep `PollingTicker` in `Sources/Graftty/Model/` but provide a test-only `init(interval:pauseWhenInactive:observeAppActivity:)` that lets tests skip AppKit. Tests go in `Tests/GrafttyTests` — but Graftty has no test target today. **Skip automated tests for this class**; validate via integration tests of `PRStatusStore` that use `PollingTicker` with a very short interval.

- [ ] **Step 1: Write `PollingTicker`**

```swift
import Foundation
import AppKit

/// Drives a single long-lived Task that fires `onTick` on a cadence.
/// Reacts to app active/inactive notifications (optionally pausing when
/// inactive), and exposes `pulse()` to wake early for user-triggered
/// refreshes.
@MainActor
final class PollingTicker {
    private let interval: Duration
    private let pauseWhenInactive: @MainActor () -> Bool
    private var task: Task<Void, Never>?
    private var pulseContinuation: AsyncStream<Void>.Continuation?
    private var pulseStream: AsyncStream<Void>?
    private var paused = false
    private var activeObserver: NSObjectProtocol?
    private var inactiveObserver: NSObjectProtocol?

    init(
        interval: Duration,
        pauseWhenInactive: @MainActor @escaping () -> Bool = { true }
    ) {
        self.interval = interval
        self.pauseWhenInactive = pauseWhenInactive
    }

    func start(onTick: @MainActor @escaping () async -> Void) {
        guard task == nil else { return }
        let (stream, cont) = AsyncStream<Void>.makeStream()
        pulseStream = stream
        pulseContinuation = cont

        installObservers()

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.paused {
                    await onTick()
                }
                await self.sleepOrPulse()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        pulseContinuation?.finish()
        pulseContinuation = nil
        pulseStream = nil
        removeObservers()
    }

    func pulse() {
        pulseContinuation?.yield(())
    }

    // MARK: - Private

    private func sleepOrPulse() async {
        let sleepTask = Task<Void, Never> { [interval] in
            try? await Task.sleep(for: interval)
        }
        let pulseTask: Task<Void, Never>
        if let pulseStream {
            pulseTask = Task {
                for await _ in pulseStream {
                    return
                }
            }
        } else {
            pulseTask = Task {}
        }
        // Await whichever finishes first.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sleepTask.value }
            group.addTask { await pulseTask.value }
            await group.next()
            group.cancelAll()
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        activeObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.paused = false }
        }
        inactiveObserver = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.pauseWhenInactive() {
                    self.paused = true
                }
            }
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        if let o = activeObserver { center.removeObserver(o); activeObserver = nil }
        if let o = inactiveObserver { center.removeObserver(o); inactiveObserver = nil }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Model/PollingTicker.swift
git commit -m "feat(polling): add PollingTicker shared helper"
```

---

## Phase F — `PRStatusStore`

### Task F1: `PRStatusStore` shape + manual refresh

**Files:**
- Create: `Sources/Graftty/Model/PRStatusStore.swift`

- [ ] **Step 1: Write the initial store**

```swift
import Foundation
import Observation
import SwiftUI
import GrafttyKit
import os

@MainActor
@Observable
public final class PRStatusStore {

    public private(set) var infos: [String: PRInfo] = [:]
    public private(set) var absent: Set<String> = []

    @ObservationIgnored private let executor: CLIExecutor
    @ObservationIgnored private let fetcherFor: (HostingProvider) -> PRFetcher?
    @ObservationIgnored private var hostByRepo: [String: HostingOrigin?] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var failureStreak: [String: Int] = [:]
    @ObservationIgnored private var ticker: PollingTicker?
    @ObservationIgnored private var getRepos: () -> [RepoEntry] = { [] }
    @ObservationIgnored private let logger = Logger(subsystem: "com.btucker.graftty", category: "PRStatusStore")

    public init(
        executor: CLIExecutor = CLIRunner(),
        fetcherFor: ((HostingProvider) -> PRFetcher?)? = nil
    ) {
        self.executor = executor
        if let fetcherFor {
            self.fetcherFor = fetcherFor
        } else {
            let cap = executor
            self.fetcherFor = { provider in
                switch provider {
                case .github: return GitHubPRFetcher(executor: cap)
                case .gitlab: return GitLabPRFetcher(executor: cap)
                case .unsupported: return nil
                }
            }
        }
    }

    /// Force a fetch for one worktree, regardless of cadence. Skips if already
    /// in flight.
    public func refresh(worktreePath: String, repoPath: String, branch: String) {
        guard !inFlight.contains(worktreePath) else { return }
        inFlight.insert(worktreePath)

        Task { [weak self] in
            await self?.performFetch(
                worktreePath: worktreePath,
                repoPath: repoPath,
                branch: branch
            )
        }
    }

    public func clear(worktreePath: String) {
        infos.removeValue(forKey: worktreePath)
        absent.remove(worktreePath)
        lastFetch.removeValue(forKey: worktreePath)
        failureStreak.removeValue(forKey: worktreePath)
    }

    // MARK: - Fetch

    private func performFetch(worktreePath: String, repoPath: String, branch: String) async {
        defer { inFlight.remove(worktreePath) }

        // Resolve host (cached per repo).
        let origin: HostingOrigin?
        if let cached = hostByRepo[repoPath] {
            origin = cached
        } else {
            origin = (try? await GitOriginHost.detect(repoPath: repoPath)) ?? nil
            hostByRepo[repoPath] = origin
        }
        guard let origin, origin.provider != .unsupported,
              let fetcher = fetcherFor(origin.provider) else {
            absent.insert(worktreePath)
            lastFetch[worktreePath] = Date()
            return
        }

        do {
            let pr = try await fetcher.fetch(origin: origin, branch: branch)
            lastFetch[worktreePath] = Date()
            failureStreak[worktreePath] = 0
            if let pr {
                infos[worktreePath] = pr
                absent.remove(worktreePath)
            } else {
                infos.removeValue(forKey: worktreePath)
                absent.insert(worktreePath)
            }
        } catch {
            logger.info("PR fetch failed for \(worktreePath): \(String(describing: error))")
            failureStreak[worktreePath, default: 0] += 1
            lastFetch[worktreePath] = Date()
            infos.removeValue(forKey: worktreePath)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Model/PRStatusStore.swift
git commit -m "feat(pr-status): PRStatusStore with manual refresh"
```

---

### Task F2: Polling with tiered cadence

**Files:**
- Modify: `Sources/Graftty/Model/PRStatusStore.swift`

- [ ] **Step 1: Add cadence calculation and polling loop**

Append to `PRStatusStore`:

```swift
extension PRStatusStore {

    /// Decide the poll interval for a worktree based on its current state.
    func cadence(for worktreePath: String) -> Duration {
        let base: Duration
        if let info = infos[worktreePath] {
            switch (info.state, info.checks) {
            case (.open, .pending): base = .seconds(25)
            case (.open, _):        base = .seconds(5 * 60)
            case (.merged, _):      base = .seconds(15 * 60)
            }
        } else if absent.contains(worktreePath) {
            base = .seconds(15 * 60)
        } else {
            base = .zero // unknown — fetch immediately
        }

        let streak = failureStreak[worktreePath] ?? 0
        if streak == 0 { return base }
        let multiplier = 1 << min(streak, 5) // 2^streak, capped
        let multiplied = base * Int(multiplier)
        let cap: Duration = .seconds(30 * 60)
        return multiplied > cap ? cap : multiplied
    }

    public func start(appState: AppState) {
        stop()
        // Snapshot appState.repos; re-read each tick to catch newly-added worktrees.
        let binding = Binding<AppState>(
            get: { appState },
            set: { _ in }
        )
        self.getRepos = { binding.wrappedValue.repos }

        let ticker = PollingTicker(
            interval: .seconds(5),
            pauseWhenInactive: { [weak self] in
                guard let self else { return true }
                // Keep running when any tracked PR is pending.
                let hasPending = self.infos.values.contains { $0.checks == .pending }
                return !hasPending
            }
        )
        self.ticker = ticker
        ticker.start { [weak self] in
            await self?.tick()
        }
    }

    public func stop() {
        ticker?.stop()
        ticker = nil
    }

    private func tick() async {
        let repos = getRepos()
        let now = Date()

        struct Candidate { let path, repoPath, branch: String }
        var candidates: [Candidate] = []

        for repo in repos {
            // Skip repos whose host is cached as unsupported / nil.
            if let cached = hostByRepo[repo.path], cached?.provider != .github && cached?.provider != .gitlab {
                continue
            }
            for wt in repo.worktrees where wt.state != .stale {
                if inFlight.contains(wt.path) { continue }
                let interval = cadence(for: wt.path)
                let last = lastFetch[wt.path]
                if let last, now.timeIntervalSince(last) < Double(interval.components.seconds) {
                    continue
                }
                candidates.append(Candidate(path: wt.path, repoPath: repo.path, branch: wt.branch))
            }
        }

        // Bound concurrency.
        let maxParallel = 4
        await withTaskGroup(of: Void.self) { group in
            var inflight = 0
            for c in candidates {
                if inflight >= maxParallel {
                    await group.next()
                    inflight -= 1
                }
                inFlight.insert(c.path)
                group.addTask { [weak self] in
                    await self?.performFetch(
                        worktreePath: c.path,
                        repoPath: c.repoPath,
                        branch: c.branch
                    )
                }
                inflight += 1
            }
        }
    }
}
```

(The `SwiftUI` import was added at the top of the file in Task F1 so `Binding` is available.)

- [ ] **Step 2: Re-verify the file compiles**

Run: `swift build`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Model/PRStatusStore.swift
git commit -m "feat(pr-status): polling with tiered cadence and backoff"
```

---

### Task F3: Minimal tests for cadence logic

**Files:**
- Create: `Tests/GrafttyKitTests/Model/PRStatusStoreCadenceTests.swift`

Note: `PRStatusStore` lives in the `Graftty` target (app-level), not `GrafttyKit`, so the tests need to be in a target that can import `Graftty`. Since Graftty has no test target, we validate cadence logic by extracting the pure function into an internal helper inside `GrafttyKit`, OR we add a minimal Graftty test target. Simplest: extract cadence logic.

Actually — cadence only depends on `infos` and `failureStreak` snapshots. Create a free function in the store's file that's pure and testable:

- [ ] **Step 1: Extract `cadenceFor` as a static pure function**

Edit `Sources/Graftty/Model/PRStatusStore.swift`: replace the `cadence(for:)` method body with a call to a static function that also lives in the file:

```swift
static func cadenceFor(
    info: PRInfo?,
    isAbsent: Bool,
    failureStreak: Int
) -> Duration {
    let base: Duration
    if let info {
        switch (info.state, info.checks) {
        case (.open, .pending): base = .seconds(25)
        case (.open, _):        base = .seconds(5 * 60)
        case (.merged, _):      base = .seconds(15 * 60)
        }
    } else if isAbsent {
        base = .seconds(15 * 60)
    } else {
        base = .zero
    }
    if failureStreak == 0 { return base }
    let multiplier = 1 << min(failureStreak, 5)
    let multiplied = base * Int(multiplier)
    let cap: Duration = .seconds(30 * 60)
    return multiplied > cap ? cap : multiplied
}

func cadence(for worktreePath: String) -> Duration {
    Self.cadenceFor(
        info: infos[worktreePath],
        isAbsent: absent.contains(worktreePath),
        failureStreak: failureStreak[worktreePath] ?? 0
    )
}
```

- [ ] **Step 2: Since PRStatusStore is in the Graftty target, we can't test it from GrafttyKitTests**

Two options: (a) add an Graftty test target, (b) move PRStatusStore to GrafttyKit.

Move it. `PRStatusStore` is pure model logic — it belongs in GrafttyKit. The only app-coupling is `PollingTicker` (AppKit), which can be abstracted behind a protocol.

Edit Package.swift — no change needed. But:

- Move `Sources/Graftty/Model/PRStatusStore.swift` → `Sources/GrafttyKit/PRStatus/PRStatusStore.swift`
- Move `Sources/Graftty/Model/PollingTicker.swift` → keep in `Graftty/Model/` (uses AppKit)
- In PRStatusStore, change the `PollingTicker` dependency to a protocol:

```swift
public protocol PollingTickerLike: AnyObject {
    func start(onTick: @MainActor @escaping () async -> Void)
    func stop()
    func pulse()
}
```

And `PollingTicker` (in Graftty) conforms to `PollingTickerLike`. `PRStatusStore.start(appState:ticker:)` accepts a `PollingTickerLike`.

Commit the reorganization:

```bash
git mv Sources/Graftty/Model/PRStatusStore.swift Sources/GrafttyKit/PRStatus/PRStatusStore.swift
# hand-edit imports and add PollingTickerLike
git add -A
git commit -m "refactor(pr-status): move PRStatusStore to GrafttyKit for testability"
```

- [ ] **Step 3: Make `PollingTicker` conform**

Edit `Sources/Graftty/Model/PollingTicker.swift`, add `: PollingTickerLike` to the class declaration (all methods already match).

- [ ] **Step 4: Write cadence tests**

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("PRStatusStore cadence")
struct PRStatusStoreCadenceTests {
    let url = URL(string: "https://github.com/x/y/pull/1")!

    @Test func pendingOpenIs25s() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .pending, fetchedAt: Date())
        let d = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 0)
        #expect(d == .seconds(25))
    }

    @Test func stableOpenIs5min() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .success, fetchedAt: Date())
        let d = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 0)
        #expect(d == .seconds(300))
    }

    @Test func mergedIs15min() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .merged, checks: .none, fetchedAt: Date())
        let d = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 0)
        #expect(d == .seconds(900))
    }

    @Test func absentIs15min() {
        let d = PRStatusStore.cadenceFor(info: nil, isAbsent: true, failureStreak: 0)
        #expect(d == .seconds(900))
    }

    @Test func unknownIsImmediate() {
        let d = PRStatusStore.cadenceFor(info: nil, isAbsent: false, failureStreak: 0)
        #expect(d == .zero)
    }

    @Test func backoffDoublesCadence() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .success, fetchedAt: Date())
        let d1 = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 1)
        #expect(d1 == .seconds(600)) // 5min * 2
        let d3 = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 3)
        #expect(d3 == .seconds(300 * 8))
    }

    @Test func backoffCapsAt30min() {
        let info = PRInfo(number: 1, title: "x", url: url, state: .open, checks: .success, fetchedAt: Date())
        let d = PRStatusStore.cadenceFor(info: info, isAbsent: false, failureStreak: 20)
        #expect(d == .seconds(30 * 60))
    }
}
```

- [ ] **Step 5: Run**

Run: `swift test --filter PRStatusStoreCadenceTests`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Tests/GrafttyKitTests/Model/PRStatusStoreCadenceTests.swift
git commit -m "test(pr-status): cadence function tests"
```

---

### Task F4: End-to-end fetch integration test

**Files:**
- Create: `Tests/GrafttyKitTests/Model/PRStatusStoreIntegrationTests.swift`

- [ ] **Step 1: Write integration test using FakeCLIExecutor**

```swift
import Testing
import Foundation
@testable import GrafttyKit

@Suite("PRStatusStore integration")
struct PRStatusStoreIntegrationTests {

    @Test func fetchesAndPublishesPRInfo() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["remote", "get-url", "origin"],
            output: CLIOutput(stdout: "git@github.com:foo/bar.git\n", stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "foo/bar",
                "--head", "feature/x", "--state", "open", "--limit", "1",
                "--json", "number,title,url,state,headRefName"
            ],
            output: CLIOutput(
                stdout: #"[{"number":10,"title":"hello","url":"https://github.com/foo/bar/pull/10","state":"OPEN","headRefName":"feature/x"}]"#,
                stderr: "",
                exitCode: 0
            )
        )
        fake.stub(
            command: "gh",
            args: ["pr", "checks", "10", "--repo", "foo/bar", "--json", "name,state,conclusion"],
            output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0)
        )

        let store = await PRStatusStore(executor: fake)
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature/x")

        // Wait for the Task to complete — poll the published state.
        for _ in 0..<50 {
            if await store.infos["/wt"] != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let info = await store.infos["/wt"]
        #expect(info?.number == 10)
        #expect(info?.state == .open)
        #expect(info?.checks == PRInfo.Checks.none)
    }

    @Test func absentWhenNoPR() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["remote", "get-url", "origin"],
            output: CLIOutput(stdout: "git@github.com:foo/bar.git\n", stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "foo/bar",
                "--head", "feature/x", "--state", "open", "--limit", "1",
                "--json", "number,title,url,state,headRefName"
            ],
            output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0)
        )
        fake.stub(
            command: "gh",
            args: [
                "pr", "list", "--repo", "foo/bar",
                "--head", "feature/x", "--state", "merged", "--limit", "1",
                "--json", "number,title,url,state,headRefName,mergedAt"
            ],
            output: CLIOutput(stdout: "[]", stderr: "", exitCode: 0)
        )

        let store = await PRStatusStore(executor: fake)
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "feature/x")

        for _ in 0..<50 {
            if await store.absent.contains("/wt") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await store.infos["/wt"] == nil)
        #expect(await store.absent.contains("/wt"))
    }

    @Test func unsupportedHostMarksAbsent() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["remote", "get-url", "origin"],
            output: CLIOutput(stdout: "git@bitbucket.org:foo/bar.git\n", stderr: "", exitCode: 0)
        )

        let store = await PRStatusStore(executor: fake)
        await store.refresh(worktreePath: "/wt", repoPath: "/repo", branch: "main")

        for _ in 0..<50 {
            if await store.absent.contains("/wt") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await store.absent.contains("/wt"))
    }
}
```

- [ ] **Step 2: Run**

Run: `swift test --filter PRStatusStoreIntegrationTests`
Expected: all three tests pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/GrafttyKitTests/Model/PRStatusStoreIntegrationTests.swift
git commit -m "test(pr-status): end-to-end integration with FakeCLIExecutor"
```

---

## Phase G — `WorktreeStatsStore` polling extension

### Task G1: Add `startPolling` / `stopPolling`

**Files:**
- Modify: `Sources/Graftty/Model/WorktreeStatsStore.swift`

- [ ] **Step 1: Add polling ticker and methods**

Import `AppKit` at the top of the file. Add:

```swift
@ObservationIgnored private var ticker: PollingTicker?

public func startPolling(appState: AppState) {
    stopPolling()
    let getRepos: () -> [RepoEntry] = { appState.repos }
    let ticker = PollingTicker(interval: .seconds(5))
    self.ticker = ticker
    ticker.start { [weak self] in
        await self?.pollTick(repos: getRepos())
    }
}

public func stopPolling() {
    ticker?.stop()
    ticker = nil
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: no errors.

- [ ] **Step 3: No commit yet** (will commit with Task G2)

---

### Task G2: `git fetch` + recompute in poll tick

**Files:**
- Modify: `Sources/Graftty/Model/WorktreeStatsStore.swift`

- [ ] **Step 1: Add repo-level fetch state and tick implementation**

Append:

```swift
@ObservationIgnored private var lastRepoFetch: [String: Date] = [:]
@ObservationIgnored private var repoFailureStreak: [String: Int] = [:]
@ObservationIgnored private var inFlightRepos: Set<String> = []

static func repoFetchCadence(failureStreak: Int) -> Duration {
    let base: Duration = .seconds(5 * 60)
    if failureStreak == 0 { return base }
    let multiplier = 1 << min(failureStreak, 5)
    let multiplied = base * Int(multiplier)
    let cap: Duration = .seconds(30 * 60)
    return multiplied > cap ? cap : multiplied
}

private func pollTick(repos: [RepoEntry]) async {
    let now = Date()
    for repo in repos {
        if inFlightRepos.contains(repo.path) { continue }
        let streak = repoFailureStreak[repo.path] ?? 0
        let interval = Self.repoFetchCadence(failureStreak: streak)
        if let last = lastRepoFetch[repo.path],
           now.timeIntervalSince(last) < Double(interval.components.seconds) {
            continue
        }
        inFlightRepos.insert(repo.path)
        let repoPath = repo.path
        let worktreePaths = repo.worktrees
            .filter { $0.state != .stale }
            .map(\.path)

        Task { [weak self] in
            await self?.performRepoFetch(
                repoPath: repoPath,
                worktreePaths: worktreePaths
            )
        }
    }
}

private func performRepoFetch(repoPath: String, worktreePaths: [String]) async {
    defer {
        Task { @MainActor in self.inFlightRepos.remove(repoPath) }
    }

    let defaultBranchResult: String?
    if let cached = defaultBranchByRepo[repoPath] ?? nil {
        defaultBranchResult = cached
    } else {
        defaultBranchResult = (try? await GitOriginDefaultBranch.resolve(repoPath: repoPath)) ?? nil
    }
    await MainActor.run { self.defaultBranchByRepo[repoPath] = defaultBranchResult }
    guard let defaultBranch = defaultBranchResult else {
        await MainActor.run {
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath] = 0
        }
        return
    }

    do {
        _ = try await GitRunner.captureAll(
            args: ["fetch", "--no-tags", "--prune", "origin", defaultBranch],
            at: repoPath
        )
        await MainActor.run {
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath] = 0
        }
    } catch {
        await MainActor.run {
            self.lastRepoFetch[repoPath] = Date()
            self.repoFailureStreak[repoPath, default: 0] += 1
        }
        return
    }

    // Recompute stats for each worktree.
    for wtPath in worktreePaths {
        await MainActor.run { self.refresh(worktreePath: wtPath, repoPath: repoPath) }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Model/WorktreeStatsStore.swift
git commit -m "feat(stats): add polling with periodic git fetch for WorktreeStatsStore"
```

---

### Task G3: Remove legacy 60s Timer from `GrafttyApp`

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Remove `statsPollTimer`**

In `AppServices`, delete:
```swift
var statsPollTimer: Timer?
```

In `startup()`, delete the entire `Timer.scheduledTimer(...)` block (the 60s poll) and replace with:

```swift
services.statsStore.startPolling(appState: appState)
```

Place this line where the Timer was.

- [ ] **Step 2: Build and run manually**

Run: `swift build`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "refactor(stats): replace 60s Timer with WorktreeStatsStore polling"
```

---

## Phase H — UI

### Task H1: `PRButton` view

**Files:**
- Create: `Sources/Graftty/Views/PRButton.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI
import AppKit
import GrafttyKit

struct PRButton: View {
    let info: PRInfo
    let theme: GhosttyTheme
    let onRefresh: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(dotColor.opacity(0.5), lineWidth: info.checks == .pending ? 2 : 0)
                )
                .modifier(PulseIfPending(isPending: info.checks == .pending))

            Text("#\(info.number)\(info.state == .merged ? " ✓ merged" : "")")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(info.state == .merged ? mergedText : theme.foreground)

            Text(info.title)
                .font(.caption)
                .foregroundColor(theme.foreground.opacity(0.55))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(theme.foreground.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("Open #\(info.number) on \(info.url.host ?? "")")
        .accessibilityLabel(
            "Pull request \(info.number), \(accessibilityChecks), \(info.title). Click to open in browser."
        )
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(info.url) }
        .contextMenu {
            Button("Refresh now") { onRefresh() }
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(info.url.absoluteString, forType: .string)
            }
        }
    }

    private var background: Color {
        info.state == .merged
            ? Color(red: 0.64, green: 0.44, blue: 0.97, opacity: 0.15)
            : theme.foreground.opacity(0.08)
    }

    private var mergedText: Color {
        Color(red: 0.82, green: 0.66, blue: 1.0)
    }

    private var dotColor: Color {
        switch info.checks {
        case .success: return Color(red: 0.25, green: 0.73, blue: 0.31)
        case .failure: return Color(red: 0.97, green: 0.32, blue: 0.29)
        case .pending: return Color(red: 0.82, green: 0.60, blue: 0.13)
        case .none:    return Color(red: 0.43, green: 0.46, blue: 0.51)
        }
    }

    private var accessibilityChecks: String {
        switch info.checks {
        case .success: return "CI passing"
        case .failure: return "CI failing"
        case .pending: return "CI running"
        case .none:    return "no CI checks"
        }
    }
}

/// Ease the pending dot in/out so the motion is subtle, not jarring.
private struct PulseIfPending: ViewModifier {
    let isPending: Bool
    @State private var phase = 0.0

    func body(content: Content) -> some View {
        content
            .opacity(isPending ? (0.5 + 0.5 * abs(cos(phase))) : 1.0)
            .task(id: isPending) {
                guard isPending else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(33))
                    phase += .pi / 36
                }
            }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Views/PRButton.swift
git commit -m "feat(ui): PRButton pill view with CI dot and states"
```

---

### Task H2: Rewrite `BreadcrumbBar`

**Files:**
- Modify: `Sources/Graftty/Views/BreadcrumbBar.swift`

- [ ] **Step 1: Rewrite the view**

```swift
import SwiftUI
import GrafttyKit

/// The row that sits at the very top of the detail column. Shows:
/// `{repo} / {worktree-display-name} ({branch})` on the left and, when
/// available, a PR button on the trailing edge. Home checkout renders
/// as italic "root". The worktree-name carries a tooltip with the full
/// filesystem path.
struct BreadcrumbBar: View {
    let repoName: String?
    let worktreeDisplayName: String?
    let worktreePath: String?
    let branchName: String?
    let isHomeCheckout: Bool
    let prInfo: PRInfo?
    let theme: GhosttyTheme
    let onRefreshPR: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let repoName {
                Text(repoName)
                    .foregroundColor(theme.foreground.opacity(0.6))
            }
            if worktreeDisplayName != nil {
                Text("/")
                    .foregroundColor(theme.foreground.opacity(0.3))
            }
            if let worktreeDisplayName {
                worktreeLabel(worktreeDisplayName)
            }
            if let branchName {
                Text("(\(branchName))")
                    .font(.caption)
                    .foregroundColor(theme.foreground.opacity(0.55))
                    .padding(.leading, 2)
            }

            Spacer()

            if let prInfo {
                PRButton(info: prInfo, theme: theme, onRefresh: onRefreshPR)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.background)
    }

    @ViewBuilder
    private func worktreeLabel(_ name: String) -> some View {
        if isHomeCheckout {
            Text("root")
                .italic()
                .foregroundColor(theme.foreground)
                .help(worktreePath ?? "")
                .overlay(underline, alignment: .bottom)
        } else {
            Text(name)
                .foregroundColor(theme.foreground)
                .fontWeight(.medium)
                .help(worktreePath ?? "")
                .overlay(underline, alignment: .bottom)
        }
    }

    private var underline: some View {
        Rectangle()
            .fill(theme.foreground.opacity(0.3))
            .frame(height: 0.5)
            .offset(y: 1)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: error — `MainWindow` still instantiates `BreadcrumbBar` with the old parameters. Task H4 fixes that.

- [ ] **Step 3: No commit yet** (will commit with Task H4)

---

### Task H3: Italic "root" in `WorktreeRow`

**Files:**
- Modify: `Sources/Graftty/Views/WorktreeRow.swift`

- [ ] **Step 1: Modify `branchLabel`**

Find the `branchLabel` property. Replace:

```swift
if entry.state == .stale {
    Text(displayName)
        .strikethrough()
        .foregroundColor(theme.foreground.opacity(0.5))
} else {
    Text(displayName)
        .foregroundColor(
            isActive
                ? theme.foreground
                : theme.foreground.opacity(0.8)
        )
}
```

with:

```swift
if entry.state == .stale {
    Text(displayName)
        .strikethrough()
        .foregroundColor(theme.foreground.opacity(0.5))
} else if isMainCheckout {
    Text("root")
        .italic()
        .foregroundColor(
            isActive
                ? theme.foreground
                : theme.foreground.opacity(0.8)
        )
} else {
    Text(displayName)
        .foregroundColor(
            isActive
                ? theme.foreground
                : theme.foreground.opacity(0.8)
        )
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: no errors (this is a leaf change).

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Views/WorktreeRow.swift
git commit -m "feat(ui): render home checkout as italic 'root' in sidebar"
```

---

### Task H4: Wire `PRStatusStore` into app and `MainWindow`

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`
- Modify: `Sources/Graftty/Views/MainWindow.swift`

- [ ] **Step 1: Instantiate `PRStatusStore` in `AppServices`**

In `GrafttyApp.swift`:

```swift
@MainActor
final class AppServices {
    let socketServer: SocketServer
    let worktreeMonitor: WorktreeMonitor
    let statsStore: WorktreeStatsStore
    let prStatusStore: PRStatusStore
    var worktreeMonitorBridge: WorktreeMonitorBridge?

    init(socketPath: String) {
        self.socketServer = SocketServer(socketPath: socketPath)
        self.worktreeMonitor = WorktreeMonitor()
        self.statsStore = WorktreeStatsStore()
        self.prStatusStore = PRStatusStore()
    }
}
```

In `startup()`, after `services.statsStore.startPolling(...)`:

```swift
services.prStatusStore.start(appState: appState)
```

- [ ] **Step 2: Pass `prStatusStore` into `MainWindow`**

Update the `MainWindow(...)` instantiation in the `WindowGroup { ... }`:

```swift
MainWindow(
    appState: $appState,
    terminalManager: terminalManager,
    statsStore: services.statsStore,
    prStatusStore: services.prStatusStore,
    worktreeMonitor: services.worktreeMonitor
)
```

- [ ] **Step 3: `MainWindow` accepts and uses the store**

Add the stored property:

```swift
let prStatusStore: PRStatusStore
```

Update `BreadcrumbBar` instantiation inside `detail`:

```swift
BreadcrumbBar(
    repoName: selectedRepo?.displayName,
    worktreeDisplayName: worktreeDisplayName,
    worktreePath: selectedWorktree?.path,
    branchName: selectedWorktree?.branch,
    isHomeCheckout: isHomeCheckout,
    prInfo: prInfo,
    theme: terminalManager.theme,
    onRefreshPR: refreshPR
)
```

Add computed helpers:

```swift
private var isHomeCheckout: Bool {
    guard let repo = selectedRepo, let wt = selectedWorktree else { return false }
    return wt.path == repo.path
}

private var worktreeDisplayName: String? {
    guard let repo = selectedRepo, let wt = selectedWorktree else { return nil }
    return wt.displayName(amongSiblingPaths: repo.worktrees.map(\.path))
}

private var prInfo: PRInfo? {
    guard let path = selectedWorktree?.path else { return nil }
    return prStatusStore.infos[path]
}

private func refreshPR() {
    guard let wt = selectedWorktree, let repo = selectedRepo else { return }
    prStatusStore.refresh(worktreePath: wt.path, repoPath: repo.path, branch: wt.branch)
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift Sources/Graftty/Views/MainWindow.swift Sources/Graftty/Views/BreadcrumbBar.swift
git commit -m "feat(ui): wire PRStatusStore through MainWindow to BreadcrumbBar"
```

---

### Task H5: Manual smoke test checklist

- [ ] **Step 1: Launch the app from Xcode or `swift run Graftty` against a GitHub repo**

Verify: with `gh` installed and authenticated, the PR button appears for a worktree whose branch has an open PR. Click opens the PR in the default browser. Title truncates cleanly.

- [ ] **Step 2: Verify CI rollup transitions**

Push a commit to trigger CI. Observe: dot transitions from pending (yellow, pulsing) → success/failure within ~30s.

- [ ] **Step 3: Verify no button when there's no PR**

On a branch with no open or merged PR: no button appears.

- [ ] **Step 4: Verify "root" rendering**

Home checkout: breadcrumb and sidebar both show italic "root". Linked worktrees show their display name.

- [ ] **Step 5: Verify `gh` absence is silent**

`mv /opt/homebrew/bin/gh /tmp/gh-backup` (or uninstall). Relaunch. No button anywhere; no crash. Restore `gh` and relaunch — buttons return.

- [ ] **Step 6: Verify graceful divergence refresh**

In a terminal outside Graftty, push a commit to `origin/main`. Wait ≤5 min. The sidebar divergence "behind" count should update without the user doing anything.

- [ ] **Step 7: (Optional) Test GitLab**

Install `glab`, add a GitLab-hosted repo. Verify MR button renders.

- [ ] **Step 8: No commit** — manual verification only. If issues, file as followups.

---

## Self-review notes (written by planner)

**Spec coverage check:**

- §3.1 CLIRunner → Task A2 ✓
- §3.2 GitRunner migration → Tasks B1–B8 ✓
- §3.3 test injection → Task A3 + tests throughout ✓
- §4 hosting detection → Tasks C1–C3 ✓
- §5 PR fetchers → Tasks D1–D4 ✓
- §6.1 PollingTicker → Task E1 ✓
- §6.2 PRStatusStore → Tasks F1–F4 ✓
- §6.3 WorktreeStatsStore polling → Tasks G1–G3 ✓
- §7.1 BreadcrumbBar → Task H2 ✓
- §7.2 PRButton → Task H1 ✓
- §7.3 WorktreeRow → Task H3 ✓
- §7.4 MainWindow wiring → Task H4 ✓
- §8 error handling (silent) → covered by PRStatusStore `catch { logger.info(...); infos.remove }` in F1 and UI hide-when-nil in H2 ✓
- §9 testing → per-task tests ✓
- §10 migration notes → Phase B ✓

**Known caveats:**

- Task F3's reorganization (moving `PRStatusStore` to `GrafttyKit`) keeps pure logic testable. The store's polling loop runs on `MainActor`, which is still valid in `GrafttyKit` (it's Swift concurrency, not AppKit).
- `PollingTicker` remains in `Graftty` (app) because of AppKit notifications; `PRStatusStore` receives a `PollingTickerLike` at start time.
- Cadence uses `Duration.components.seconds` — verify this yields Int64 seconds (it does on macOS 14).
