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
        try await run(command: command, args: args, at: directory, timeout: nil)
    }

    public func run(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        let out = try await execute(command: command, args: args, at: directory, timeout: timeout)
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
        try await execute(command: command, args: args, at: directory, timeout: nil)
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
        // Force English output from every external tool so our parsers
        // (git diff --shortstat "insertion"/"deletion", gh pr checks
        // bucket names, zmx status text) keep working for Andy on
        // `LANG=de_DE.UTF-8` or any other non-English locale. LC_ALL
        // trumps LANG/LC_MESSAGES/LC_*, so one assignment suffices.
        env["LC_ALL"] = "C"
        return env
    }

    private func execute(
        command: String,
        args: [String],
        at directory: String,
        timeout: Duration?
    ) async throws -> CLIOutput {
        let timeoutSeconds = timeout.map(Self.seconds(of:))
        let captured: (String, String, Int32) = try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + args
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.environment = Self.enrichedEnvironment()

            // Allocated only when a timeout is requested — the common
            // unbounded path (every local git call) pays nothing. Holds
            // both the fired-flag and the pending SIGTERM timer under one
            // lock: the timer queue writes the flag and the termination
            // queue reads it / cancels the timer, so a `let` reference
            // type is what makes the cross-queue access safe under Swift 6.
            let timeoutState = timeoutSeconds.map { TimeoutState(seconds: $0) }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Drain pipes into in-memory buffers while the process runs.
            // If we waited until termination to read, a process that writes
            // more than the pipe buffer (~16–64 KB) would block on write and
            // never exit — leaking the continuation. `readabilityHandler`
            // fires on background queues; PipeBuffers guards shared state
            // with a lock and tracks per-stream EOF so the termination path
            // can confirm both streams fully drained before resuming.
            //
            // Mixing `readabilityHandler` with a synchronous
            // `readDataToEndOfFile()` in terminationHandler has a real
            // race: the readabilityHandler may have read a chunk but not
            // yet appended it to the buffer when terminationHandler reads
            // `buffers.stderrData`, producing empty stderr for a process
            // that did write (e.g. `/usr/bin/env totally-not-a-real-cmd`
            // emits "env: …: No such file" then exits 127, but the racey
            // path observed exit=127 with stderr=""). Solution: drain
            // exclusively via readabilityHandler, signal EOF via the
            // empty-chunk firing, and have terminationHandler block until
            // both streams have reached EOF before resuming.
            let buffers = PipeBuffers()

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    buffers.markStdoutEOF()
                    return
                }
                buffers.appendStdout(chunk)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    buffers.markStderrEOF()
                    return
                }
                buffers.appendStderr(chunk)
            }

            process.terminationHandler = { proc in
                // A natural exit beat the timeout — cancel the pending
                // SIGTERM timer so it doesn't fire against a dead (or, far
                // worse, recycled-PID) process later.
                timeoutState?.cancel()
                // Wait (bounded) for both streams to reach EOF in their
                // readabilityHandler before snapshotting the buffers. The
                // process is already dead, so the kernel has closed the
                // write side of both pipes; the readabilityHandler must
                // fire one final empty-chunk per stream. Cap the wait at
                // 5 s as a paranoid backstop — a kernel that fails to
                // deliver EOF is itself a bug, but we'd rather report the
                // partial output than hang the test runner.
                buffers.waitForBothEOFs(timeout: 5.0)

                let stdoutStr = String(data: buffers.stdoutData, encoding: .utf8) ?? ""
                let stderrStr = String(data: buffers.stderrData, encoding: .utf8) ?? ""

                // The timeout fired and we SIGTERMed the child: report it
                // as a timeout rather than as whatever exit status the
                // signal produced, so callers feed their backoff instead
                // of misreading it as a normal non-zero exit.
                if let timeoutState, timeoutState.didTimeout {
                    cont.resume(throwing: CLIError.timedOut(
                        command: command,
                        seconds: timeoutState.seconds
                    ))
                    return
                }

                // `/usr/bin/env` exits with 127 and emits "env: <cmd>: No
                // such file or directory" on stderr when the command is
                // not found. The prefix discriminates env's own error
                // from a child that exits 127 for some other reason — but
                // since `env` itself can only exit 127 on missing-command,
                // stderr matching is belt-and-braces (the exit code is
                // already conclusive).
                if proc.terminationStatus == 127,
                   stderrStr.hasPrefix("env:") && stderrStr.contains("No such file") {
                    cont.resume(throwing: CLIError.notFound(command: command))
                    return
                }
                cont.resume(returning: (stdoutStr, stderrStr, proc.terminationStatus))
            }

            do {
                try process.run()
                // Arm the timeout only once the process is actually
                // running. On fire, flag-then-SIGTERM: the flag is set
                // before `terminate()` so the resulting `terminationHandler`
                // observes it. We deliberately do NOT resume the
                // continuation from here — letting `terminate()` drive the
                // single resume through `terminationHandler` keeps the
                // exactly-once contract that the launch-failure and
                // natural-exit paths already rely on. The `isRunning`
                // guard makes a timer that fires just after a natural exit
                // a no-op.
                //
                // SIGTERM (not SIGKILL) suffices for the callers that pass
                // a timeout — `git`/`gh`/`glab` don't trap it and a fetch
                // wedged on a socket read is interrupted by it. A child
                // that somehow ignored SIGTERM would still hang this
                // continuation, but the poller's in-flight abandonment
                // (DIVERGE-4.11, 30s) re-dispatches regardless, so the
                // sidebar never freezes — only this one Task would leak.
                if let timeoutState {
                    let item = DispatchWorkItem {
                        if process.isRunning {
                            timeoutState.markTimedOut()
                            process.terminate()
                        }
                    }
                    timeoutState.arm(item)
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + timeoutState.seconds,
                        execute: item
                    )
                }
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(throwing: CLIError.launchFailed(
                    command: command,
                    message: error.localizedDescription
                ))
            }
        }
        return CLIOutput(stdout: captured.0, stderr: captured.1, exitCode: captured.2)
    }

    /// `Duration` → seconds as a `Double`, for `DispatchQueue.asyncAfter`
    /// and the `timedOut` error payload.
    private static func seconds(of duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Per-call timeout bookkeeping for `CLIRunner.execute`, allocated only
/// when a timeout is requested. One `NSLock` guards both the fired-flag
/// (written by the timer queue, read by the termination queue) and the
/// pending `DispatchWorkItem` (so a natural exit can cancel it). A `let`
/// reference type — not a captured `var` — is what lets both queues touch
/// it under Swift 6's concurrent-capture rules. `seconds` is immutable, so
/// it needs no locking and carries the value into the `timedOut` error.
private final class TimeoutState: @unchecked Sendable {
    let seconds: Double
    private let lock = NSLock()
    private var _didTimeout = false
    private var item: DispatchWorkItem?

    init(seconds: Double) {
        self.seconds = seconds
    }

    func arm(_ newItem: DispatchWorkItem) {
        lock.lock(); defer { lock.unlock() }
        item = newItem
    }

    func markTimedOut() {
        lock.lock(); defer { lock.unlock() }
        _didTimeout = true
    }

    var didTimeout: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didTimeout
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        item?.cancel()
        item = nil
    }
}

/// Thread-safe byte accumulator for pipe drain handlers, with explicit
/// per-stream EOF signalling so a synchronous waiter (the process
/// terminationHandler) can block until both readabilityHandlers have
/// flushed their last chunk. `readabilityHandler` fires on private
/// background queues, and `terminationHandler` on another, so without
/// this synchronization the terminationHandler can snapshot the buffer
/// before an in-flight readabilityHandler appends — observed empirically
/// as empty stderr for `/usr/bin/env`'s "command not found" path under
/// concurrent test load.
private final class PipeBuffers: @unchecked Sendable {
    private var _stdout = Data()
    private var _stderr = Data()
    private let lock = NSLock()
    private let condition = NSCondition()
    private var stdoutEOF = false
    private var stderrEOF = false

    var stdoutData: Data {
        lock.lock(); defer { lock.unlock() }
        return _stdout
    }

    var stderrData: Data {
        lock.lock(); defer { lock.unlock() }
        return _stderr
    }

    func appendStdout(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        _stdout.append(chunk)
    }

    func appendStderr(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        _stderr.append(chunk)
    }

    func markStdoutEOF() {
        condition.lock(); defer { condition.unlock() }
        stdoutEOF = true
        condition.broadcast()
    }

    func markStderrEOF() {
        condition.lock(); defer { condition.unlock() }
        stderrEOF = true
        condition.broadcast()
    }

    /// Block until both pipes' readabilityHandler have signalled EOF,
    /// or `timeout` elapses. Returns true on EOF, false on timeout.
    @discardableResult
    func waitForBothEOFs(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while !(stdoutEOF && stderrEOF) {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}
