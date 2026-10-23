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
            at: NSTemporaryDirectory(),
            timeout: .seconds(10)
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

    @Test func runWithExceededTimeoutTerminatesProcessPromptly() async throws {
        // A wedged fetch is the production case: `git`/`gh` block on a
        // dead socket forever. The bounded `run` must SIGTERM the child
        // and throw `timedOut` rather than waiting out the subprocess.
        //
        // The real assertion is that `timedOut` is THROWN against a child
        // that cannot finish on its own within the test's patience: the
        // child sleeps 120s, so a `timedOut` result can only mean the
        // timeout fired and killed it. The 500ms target normally fires
        // sub-second, but the GCD timer rides the global queue, which is
        // starved for *tens of seconds* under 300+ parallel CI suites (the
        // same artifact `PollingHeart` documents — observed ~29s once). So
        // the long sleep keeps the timer winning the race regardless of
        // slip, and the `elapsed` check is only a loose hang-guard, not a
        // latency assertion. In production a slipped timer is backstopped
        // by the 30s in-flight abandonment (DIVERGE-4.11) anyway.
        let start = Date()
        do {
            _ = try await runner.run(
                command: "sleep",
                args: ["120"],
                at: NSTemporaryDirectory(),
                timeout: .milliseconds(500)
            )
            Issue.record("should have thrown timedOut")
        } catch CLIError.timedOut(let cmd, _) {
            #expect(cmd == "sleep")
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 90.0, "timed-out run must not wait out the full 120s sleep")
    }

    @Test("@spec CLI-1.3: If a stopped subprocess, timed out or cancelled, is still running when its kill grace (two seconds by default) elapses after SIGTERM, then the application shall send SIGKILL so the caller is released instead of waiting for a child that ignores SIGTERM.")
    func timeoutEscalatesToKillForChildIgnoringTerminate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-kill-escalation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        try #require(mkfifo(ready.path, 0o600) == 0)

        // The manual scheduler drives both delays, so no wall-clock timer
        // decides the outcome. The child reports its PID through the FIFO
        // only after installing the TERM trap, so SIGTERM cannot win a race
        // against the trap and pass the test without escalation.
        let scheduler = ManualSubprocessScheduler()
        var launch = SubprocessLaunch(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; exec sleep 120", "sh", ready.path],
            directory: directory.path,
            timeout: .seconds(30),
            timeoutLabel: "sh"
        )
        launch.scheduler = scheduler.scheduler
        let run = Task { try await Subprocess.run(launch) }

        let reported = await Self.readFIFO(ready).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(reported))
        defer { kill(pid, SIGKILL) } // releases `run` if escalation is broken

        let timeout = await scheduler.nextAction()
        #expect(timeout.seconds == 30)
        timeout.run() // SIGTERM, which the child ignores
        let escalation = try #require(scheduler.pendingAction(), "no SIGKILL was scheduled after SIGTERM")
        #expect(escalation.seconds == 2)
        escalation.run()

        do {
            _ = try await run.value
            Issue.record("should have thrown timedOut")
        } catch CLIError.timedOut(let cmd, _) {
            #expect(cmd == "sh")
        }
    }

    private static func readFIFO(_ url: URL) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                // Opening a FIFO blocks until the child opens it for writing;
                // reading to EOF then returns everything the child wrote.
                let data = FileHandle(forReadingAtPath: url.path)?.readDataToEndOfFile() ?? Data()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    @Test func runWithGenerousTimeoutReturnsNormally() async throws {
        // A timeout that the command finishes well within must not
        // interfere with the normal success path.
        let output = try await runner.run(
            command: "echo",
            args: ["hi"],
            at: NSTemporaryDirectory(),
            timeout: .seconds(10)
        )
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hi")
        #expect(output.exitCode == 0)
    }

    @Test("""
    @spec CLI-1.2: When a timeout-enabled subprocess exits before its deadline, the application shall allow its Process and pipe descriptors to be released immediately rather than retain them in the delayed timeout work item until the original deadline.
    """)
    func delayedTimeoutWorkItemDoesNotRetainCompletedProcess() {
        weak var weakProcess: Process?
        weak var weakTermination: SubprocessTermination?

        do {
            // A 60-second timer stays queued long after this scope ends;
            // neither the process nor its termination state may ride on it.
            let process = Process()
            let termination = SubprocessTermination(process: process)
            termination.armTimeout(after: 60)
            weakProcess = process
            weakTermination = termination
        }

        #expect(weakProcess == nil)
        #expect(weakTermination == nil)
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

    /// @spec CLI-1.1: When a subprocess pipe's read fd is closed out from
    /// under the in-flight readability handler during process/pipe teardown,
    /// the application shall treat the read as EOF rather than crash.
    /// `FileHandle` reads raise an *uncatchable*
    /// `NSFileHandleOperationException` ("Bad file descriptor") on a closed fd,
    /// SIGABRT-ing the whole process; the drain's raw `read` reports EBADF,
    /// which it returns as `nil`.
    @Test func drainChunkReturnsNilOnClosedFDInsteadOfCrashing() throws {
        // A descriptor torn down under the handler reads as EOF. -1 stands in
        // for it: a just-closed number could be reused by a parallel test.
        #expect(Subprocess.drainChunk(fd: -1) == nil)
    }

    @Test func drainChunkReturnsBytesThenNilAtEOF() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("hello".utf8))
        try pipe.fileHandleForWriting.close() // signal EOF after the payload
        let reader = pipe.fileHandleForReading

        let first = Subprocess.drainChunk(fd: reader.fileDescriptor)
        #expect(first.map { String(decoding: $0, as: UTF8.self) } == "hello")
        // Write end closed + payload consumed → next drain is EOF (nil).
        #expect(Subprocess.drainChunk(fd: reader.fileDescriptor) == nil)
    }

    @Test func pathEnrichmentIncludesHomebrewLocalAndBun() {
        let env = CLIRunner.enrichedEnvironment(base: ["PATH": "/usr/bin"])
        let path = env["PATH"] ?? ""
        let parts = path.split(separator: ":").map(String.init)
        #expect(parts.contains("/opt/homebrew/bin"))
        #expect(parts.contains("/usr/local/bin"))
        #expect(parts.contains("\(NSHomeDirectory())/.local/bin"))
        #expect(parts.contains("\(NSHomeDirectory())/.bun/bin"))
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

    // All external tool output that we parse (git diff --shortstat,
    // gh pr checks, zmx list, etc.) has English word markers baked in
    // at call sites ("insertion", "deletion", "pass"). On a user with
    // `LANG=de_DE.UTF-8` (or any non-English locale) those tools may
    // emit localized messages that our parsers won't match. Force
    // LC_ALL=C on every invocation so output stays English regardless
    // of the user's shell settings.

    @Test func enrichedEnvironmentForcesCLocaleEvenWhenBaseIsLocalized() {
        let env = CLIRunner.enrichedEnvironment(base: [
            "PATH": "/usr/bin",
            "LANG": "de_DE.UTF-8",
            "LC_MESSAGES": "fr_FR.UTF-8",
            "LC_ALL": "ja_JP.UTF-8",
        ])
        #expect(env["LC_ALL"] == "C")
    }

    @Test func enrichedEnvironmentAddsCLocaleWhenUnset() {
        let env = CLIRunner.enrichedEnvironment(base: ["PATH": "/usr/bin"])
        #expect(env["LC_ALL"] == "C")
    }

    /// Regression guard for the pipe buffer deadlock: if we read stdout only
    /// after the process exits, a child that writes more than the pipe
    /// capacity (~16–64 KB on macOS) blocks on write and never terminates.
    /// Emits exactly 262144 bytes ("1\n" × 131072) and asserts the full
    /// payload comes through. Without `readabilityHandler` draining, this
    /// test hangs forever.
    @Test func largeStdoutDoesNotDeadlock() async throws {
        let lineCount = 131072 // 131072 × 2 bytes = 262144 bytes (256 KiB)
        let output = try await runner.run(
            command: "sh",
            args: ["-c", "yes 1 | head -n \(lineCount)"],
            at: NSTemporaryDirectory()
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout.utf8.count == lineCount * 2)
        // Spot-check content integrity: all lines should be "1".
        let lines = output.stdout.split(separator: "\n", omittingEmptySubsequences: false)
        // split produces lineCount + 1 elements because of the trailing newline.
        #expect(lines.count == lineCount + 1)
        #expect(lines.first == "1")
        #expect(lines[lineCount - 1] == "1")
    }
}

/// Records each delayed stop action instead of arming a timer, so a test can
/// fire the timeout and the SIGKILL escalation itself.
private final class ManualSubprocessScheduler: @unchecked Sendable {
    struct Action {
        let seconds: TimeInterval
        let run: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var pending: [Action] = []
    private var waiter: CheckedContinuation<Action, Never>?

    var scheduler: SubprocessScheduler {
        SubprocessScheduler { [self] seconds, action in add(Action(seconds: seconds, run: action)) }
    }

    /// Waits for the next scheduled action.
    func nextAction() async -> Action {
        await withCheckedContinuation { continuation in
            let ready: Action? = lock.withLock {
                if !pending.isEmpty { return pending.removeFirst() }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Returns an action already scheduled, without waiting.
    func pendingAction() -> Action? {
        lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
    }

    private func add(_ action: Action) {
        let waiting: CheckedContinuation<Action, Never>? = lock.withLock {
            if let waiter {
                self.waiter = nil
                return waiter
            }
            pending.append(action)
            return nil
        }
        waiting?.resume(returning: action)
    }
}
