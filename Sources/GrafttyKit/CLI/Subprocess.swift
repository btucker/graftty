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
    /// Runs the delayed timeout and SIGKILL actions.
    var scheduler: SubprocessScheduler = .dispatch
}

/// Runs a delayed stop action. Production uses GCD; tests inject a manual
/// scheduler so they fire the timeout and the SIGKILL escalation themselves
/// instead of waiting on wall-clock timers (CLI-1.3).
struct SubprocessScheduler: Sendable {
    let after: @Sendable (_ seconds: TimeInterval, _ action: @escaping @Sendable () -> Void) -> Void

    static let dispatch = SubprocessScheduler { seconds, action in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
    }
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
            // on write forever. The termination handler then reads what is
            // left (CLI-1.4); each stream's reads share one lock, so the two
            // never interleave chunks.
            let stdout = Pipe()
            let stderr = Pipe()
            buffers.stdout.attach(stdout.fileHandleForReading)
            buffers.stderr.attach(stderr.fileHandleForReading)
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

        let termination = SubprocessTermination(
            process: process, killGrace: Subprocess.seconds(of: launch.killGrace), scheduler: launch.scheduler)
        let launchedPipes = pipes
        let waitsForPipeEOF = launch.capture == .pipes
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    termination.finish()
                    if waitsForPipeEOF {
                        // The child is dead, so everything it wrote is
                        // already in the pipes. Read it now instead of
                        // waiting for EOF, which a background child that
                        // inherited a pipe, or a readability callback queued
                        // behind a busy dispatch pool, can hold back (CLI-1.4).
                        buffers.stdout.finish()
                        buffers.stderr.finish()
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
        return SubprocessOutput(stdout: buffers.stdout.data, stderr: buffers.stderr.data, status: status)
    }

    /// Crash-safe single-chunk drain of a pipe's read descriptor. Returns the
    /// bytes one `read` returns, or `nil` at EOF or on a closed descriptor.
    ///
    /// One POSIX `read` returns what the pipe holds now. `FileHandle`'s
    /// `read(upToCount:)` keeps reading until it fills the count or reaches
    /// EOF, so a background child holding the pipe open blocked the callback,
    /// and the output behind it, until that child exited (CLI-1.4).
    /// `FileHandle` reads raise an *uncatchable* `NSFileHandleOperationException`
    /// ("Bad file descriptor") when the fd is already closed (CLI-1.1); a raw
    /// `read` reports EBADF as -1, which reads as EOF here.
    static func drainChunk(fd: Int32) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Data(buffer[0..<count]) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }

    /// Everything `fd` can return right now, up to EOF. The descriptor is
    /// switched to non-blocking first, so a pipe whose writer is still open
    /// ends the read instead of blocking. A closed descriptor reads as empty.
    static func readWithoutBlocking(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                result.append(contentsOf: buffer[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                // 0 is EOF; EAGAIN means the pipe is empty but still open.
                return result
            }
        }
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
/// lock orders launch, stop, and the kill check; `isRunning` is what keeps a
/// late action from signalling a reaped PID.
///
/// Delayed actions capture this object, and it holds the `Process`, weakly.
/// `DispatchQueue.asyncAfter` retains a scheduled closure until its deadline,
/// so a strong capture would keep a fast command's `Process` and pipe
/// descriptors alive for the rest of a long timeout (CLI-1.2). An action that
/// fires after the process finished is a no-op.
final class SubprocessTermination: @unchecked Sendable {
    private let killGrace: TimeInterval
    private let scheduler: SubprocessScheduler

    private let lock = NSLock()
    private weak var process: Process?
    private var isFinished = false
    private var stopRequested = false
    private var _didTimeout = false

    init(process: Process, killGrace: TimeInterval = 2, scheduler: SubprocessScheduler = .dispatch) {
        self.process = process
        self.killGrace = killGrace
        self.scheduler = scheduler
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
        guard !lock.withLock({ isFinished }) else { return }
        scheduler.after(seconds) { [weak self] in self?.stop(timedOut: true) }
    }

    /// Called once the process has exited (or failed to launch).
    func finish() {
        lock.withLock { isFinished = true }
    }

    func stop(timedOut: Bool) {
        let signalled = lock.withLock { () -> Bool in
            guard !isFinished else { return false }
            stopRequested = true
            guard let process, process.isRunning else { return false }
            if timedOut { _didTimeout = true }
            process.terminate()
            return true
        }
        if signalled {
            scheduler.after(killGrace) { [weak self] in self?.killIfRunning() }
        }
    }

    private func killIfRunning() {
        lock.withLock {
            guard !isFinished, let process, process.isRunning else { return }
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// Captured stdout and stderr of one piped subprocess.
private final class PipeBuffers: Sendable {
    let stdout = PipeStream()
    let stderr = PipeStream()
}

/// One pipe's bytes. `readabilityHandler` fires on private background queues
/// and `terminationHandler` on another; one lock orders every read of the
/// pipe, so a chunk read by a late callback can never land after, or be lost
/// behind, the exit drain. Reads use the descriptor captured while the pipe
/// was open: `FileHandle.fileDescriptor` raises an uncatchable exception once
/// teardown has closed the handle (CLI-1.1), and no read happens after
/// `finish`, before the `Pipe` can be released.
private final class PipeStream: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var fd: Int32 = -1
    private var handle: FileHandle?
    private var finished = false

    var data: Data { lock.withLock { bytes } }

    /// Drains `handle` while the child runs, one chunk per callback.
    func attach(_ handle: FileHandle) {
        lock.withLock {
            self.handle = handle
            fd = handle.fileDescriptor
        }
        handle.readabilityHandler = { [weak self] _ in self?.drainAvailable() }
    }

    private func drainAvailable() {
        // The handler is cleared outside the lock: a platform's setter may
        // wait for an in-flight callback, which could be waiting for it.
        let atEOF = lock.withLock { () -> FileHandle? in
            guard !finished else { return nil }
            guard let chunk = Subprocess.drainChunk(fd: fd) else { return handle }
            bytes.append(chunk)
            return nil
        }
        atEOF?.readabilityHandler = nil
    }

    /// After the child exits: stop the callback and read whatever the pipe
    /// still holds without blocking. A background child that inherited the
    /// pipe may keep it open; its later writes are not this command's output.
    func finish() {
        let drained = lock.withLock { () -> FileHandle? in
            guard !finished, let handle else { return nil }
            finished = true
            bytes.append(Subprocess.readWithoutBlocking(fd))
            self.handle = nil
            return handle
        }
        drained?.readabilityHandler = nil
    }
}
