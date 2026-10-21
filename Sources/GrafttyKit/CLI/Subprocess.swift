import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One subprocess launch. `CLIRunner` and `LinuxHostSSHRunner` both run
/// through `Subprocess.run(_:)`, the shared `Process` wrapper for
/// run-to-completion commands.
struct SubprocessLaunch: Sendable {
    /// Where stdout and stderr go while the child runs.
    enum Capture: Sendable {
        /// Drain both pipes while the child runs.
        case pipes
        /// Write both streams to private temporary files and read them after
        /// exit, so a background job that inherits the descriptors (a login
        /// shell's profile daemons) cannot hold the capture open.
        case files
    }

    var executable: String
    var arguments: [String]
    var directory: String?
    var environment: [String: String] = CLIRunner.enrichedEnvironment()
    /// File connected to the child's stdin; nil inherits the app's stdin.
    var standardInput: URL?
    var capture: Capture = .pipes
    var timeout: Duration?
    /// Command named in `CLIError.timedOut`.
    var timeoutLabel: String
    /// Terminate the child, then throw `CancellationError`, when the awaiting
    /// task is cancelled. Off by default: most callers let commands finish.
    var terminatesOnCancellation = false
    /// How long a stopped child may ignore SIGTERM before SIGKILL (CLI-1.3).
    var killGrace: Duration = .seconds(2)
}

struct SubprocessOutput: Sendable {
    var stdout: Data
    var stderr: Data
    var status: Int32
}

enum Subprocess {
    /// Runs `launch` to exit. Throws `CLIError.timedOut` when the timeout
    /// stopped the child, `CancellationError` when cancellation did, and the
    /// underlying `Process.run()` error when the launch itself failed.
    static func run(_ launch: SubprocessLaunch) async throws -> SubprocessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.directory.map { URL(fileURLWithPath: $0) }
        process.environment = launch.environment

        var openedHandles: [FileHandle] = []
        defer { for handle in openedHandles { try? handle.close() } }
        if let input = launch.standardInput {
            let handle = try FileHandle(forReadingFrom: input)
            openedHandles.append(handle)
            process.standardInput = handle
        }

        let buffers = PipeBuffers()
        var pipes: [Pipe] = []
        var files: (directory: URL, stdout: URL, stderr: URL)?
        defer { if let files { try? FileManager.default.removeItem(at: files.directory) } }
        switch launch.capture {
        case .pipes:
            // Drain while the child runs: waiting for exit before reading
            // would leave a child that fills the ~64 KB pipe buffer blocked
            // on write forever. Drain exclusively via readability handlers
            // and have the termination handler wait for both EOFs; mixing in
            // a synchronous read raced the handlers and lost stderr.
            let stdout = Pipe()
            let stderr = Pipe()
            stdout.fileHandleForReading.readabilityHandler = { handle in
                guard let chunk = Self.drainChunk(from: handle) else {
                    handle.readabilityHandler = nil
                    buffers.markStdoutEOF()
                    return
                }
                buffers.appendStdout(chunk)
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                guard let chunk = Self.drainChunk(from: handle) else {
                    handle.readabilityHandler = nil
                    buffers.markStderrEOF()
                    return
                }
                buffers.appendStderr(chunk)
            }
            pipes = [stdout, stderr]
            process.standardOutput = stdout
            process.standardError = stderr
        case .files:
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("graftty-process-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let stdoutURL = directory.appendingPathComponent("stdout")
            let stderrURL = directory.appendingPathComponent("stderr")
            files = (directory, stdoutURL, stderrURL)
            try Data().write(to: stdoutURL)
            try Data().write(to: stderrURL)
            let stdout = try FileHandle(forWritingTo: stdoutURL)
            openedHandles.append(stdout)
            let stderr = try FileHandle(forWritingTo: stderrURL)
            openedHandles.append(stderr)
            process.standardOutput = stdout
            process.standardError = stderr
        }

        let termination = SubprocessTermination(process: process, killGrace: Subprocess.seconds(of: launch.killGrace))
        let launchedPipes = pipes
        let waitsForPipeEOF = launch.capture == .pipes
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    termination.finish()
                    if waitsForPipeEOF {
                        // The child is dead, so the kernel closed the write
                        // side of both pipes; wait (bounded) for each
                        // readability handler's final EOF before the caller
                        // snapshots the buffers.
                        buffers.waitForBothEOFs(timeout: 5.0)
                    }
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try termination.start()
                    if let timeout = launch.timeout {
                        termination.armTimeout(after: seconds(of: timeout))
                    }
                } catch {
                    termination.finish()
                    for pipe in launchedPipes { pipe.fileHandleForReading.readabilityHandler = nil }
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if launch.terminatesOnCancellation { termination.stop(timedOut: false) }
        }
        // `SubprocessTermination` holds the process weakly; keep it alive
        // until the child has been reaped.
        withExtendedLifetime(process) {}

        if launch.terminatesOnCancellation { try Task.checkCancellation() }
        if termination.didTimeout, let timeout = launch.timeout {
            throw CLIError.timedOut(command: launch.timeoutLabel, seconds: seconds(of: timeout))
        }
        if let files {
            return SubprocessOutput(
                stdout: try Data(contentsOf: files.stdout),
                stderr: try Data(contentsOf: files.stderr),
                status: status)
        }
        return SubprocessOutput(stdout: buffers.stdoutData, stderr: buffers.stderrData, status: status)
    }

    /// Crash-safe single-chunk drain of a pipe read handle. Returns the bytes
    /// read, or `nil` at EOF / when the fd has been closed out from under the
    /// readability handler during process+pipe teardown.
    ///
    /// `NSFileHandle.availableData` (and `readData(ofLength:)`) raise an
    /// *uncatchable* `NSFileHandleOperationException` ("Bad file descriptor")
    /// when the fd is already closed — under concurrent load the per-stream EOF
    /// wait in `terminationHandler` can lapse (the global queue that runs the
    /// readability handlers is starved for tens of seconds), the continuation
    /// resumes, the `Pipe` deallocates and closes the fd, and the still-queued
    /// readability handler then fires `availableData` against the freed fd —
    /// SIGABRT-ing the whole process. `read(upToCount:)` surfaces the same
    /// EBADF as a *catchable* Swift error, so a closed fd reads as EOF. CLI-1.1.
    static func drainChunk(from handle: FileHandle) -> Data? {
        guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
            return nil
        }
        return chunk
    }

    /// `Duration` → seconds as a `Double`, for `DispatchQueue.asyncAfter`
    /// and the `timedOut` error payload.
    static func seconds(of duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Stops one subprocess on timeout or cancellation: SIGTERM first, then
/// SIGKILL if the child is still running after `killGrace` (CLI-1.3). One
/// lock orders launch, stop, and reaping so a stop never signals a PID after
/// the termination handler has reaped it.
///
/// Delayed work items capture this object and the `Process` weakly.
/// `DispatchQueue.asyncAfter` retains even a canceled item until its
/// deadline, so a strong capture would keep a fast command's `Process` and
/// pipe descriptors alive for the rest of a long timeout (CLI-1.2).
final class SubprocessTermination: @unchecked Sendable {
    private let killGrace: TimeInterval

    private let lock = NSLock()
    private weak var process: Process?
    private var isFinished = false
    private var stopRequested = false
    private var _didTimeout = false
    private var timer: DispatchWorkItem?

    init(process: Process, killGrace: TimeInterval = 2) {
        self.process = process
        self.killGrace = killGrace
    }

    var didTimeout: Bool { lock.withLock { _didTimeout } }

    /// Launches the process unless a cancellation already stopped it.
    func start() throws {
        try lock.withLock {
            guard !stopRequested else { throw CancellationError() }
            try process?.run()
        }
    }

    func armTimeout(after seconds: Double) {
        let item = DispatchWorkItem { [weak self] in self?.stop(timedOut: true) }
        let armed = lock.withLock {
            guard !isFinished else { return false }
            timer = item
            return true
        }
        if armed { DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item) }
    }

    /// Called once the process has exited (or failed to launch).
    func finish() {
        lock.withLock {
            isFinished = true
            timer?.cancel()
            timer = nil
        }
    }

    func stop(timedOut: Bool) {
        lock.withLock {
            guard !isFinished else { return }
            stopRequested = true
            guard let process, process.isRunning else { return }
            if timedOut { _didTimeout = true }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { [weak self] in
                self?.killIfRunning()
            }
        }
    }

    private func killIfRunning() {
        lock.withLock {
            guard !isFinished, let process, process.isRunning else { return }
            _ = kill(process.processIdentifier, SIGKILL)
        }
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
