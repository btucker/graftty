import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One subprocess launch. `CLIRunner` and `LinuxHostSSHRunner` both run
/// through `Subprocess.run(_:)`, the shared process wrapper for
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
    /// Optional rolling capture limit and observer, used by worktree creation.
    var captureLimit: Int?
    var onOutput: (@Sendable (Data) -> Void)?
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
    #if os(Linux)
    /// Reaps the child; tests inject a status another waiter took (CLI-1.9).
    var waitpid: @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { Glibc.waitpid($0, $1, $2) }
    #endif
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
    /// launcher's own error (`Process.run()`, or `posix_spawn` on Linux) when
    /// the launch itself failed.
    static func run(_ launch: SubprocessLaunch) async throws -> SubprocessOutput {
        #if os(Linux)
        let process = SubprocessProcess(waitpid: launch.waitpid)
        #else
        let process = SubprocessProcess()
        #endif
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

        let buffers = PipeBuffers(limit: launch.captureLimit, onOutput: launch.onOutput)
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
        // A lost exit status (CLI-1.9) is reported only after the timeout
        // and cancellation that may have stopped the child.
        let status: Result<Int32, Error> = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    termination.finish()
                    // The child is dead, so everything it wrote is already in
                    // the pipes. Read it now instead of waiting for EOF, which
                    // a background child that inherited a pipe, or a
                    // readability callback queued behind a busy dispatch pool,
                    // can hold back (CLI-1.4). A no-op for `.files` capture.
                    buffers.stdout.finish()
                    buffers.stderr.finish()
                    continuation.resume(returning: Result { try process.reapedStatus() })
                }
                do {
                    try termination.start()
                    if let timeout = launch.timeout {
                        termination.armTimeout(after: seconds(of: timeout))
                    }
                } catch {
                    termination.finish()
                    buffers.stdout.finish()
                    buffers.stderr.finish()
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
        let exitStatus = try status.get()
        if let files {
            return SubprocessOutput(
                stdout: try Data(contentsOf: files.stdout),
                stderr: try Data(contentsOf: files.stderr),
                status: exitStatus)
        }
        return SubprocessOutput(stdout: buffers.stdout.data, stderr: buffers.stderr.data, status: exitStatus)
    }

    /// Crash-safe single-chunk drain of a pipe's read descriptor. Returns the
    /// bytes one `read` returns, or `nil` at EOF, on a closed descriptor, or
    /// when a non-blocking descriptor has nothing to read yet.
    ///
    /// One POSIX `read` returns what the pipe holds now. `FileHandle`'s
    /// `read(upToCount:)` keeps reading until it fills the count or reaches
    /// EOF, so a background child holding the pipe open blocked the callback,
    /// and the output behind it, until that child exited (CLI-1.4).
    /// `FileHandle` reads raise an *uncatchable* `NSFileHandleOperationException`
    /// ("Bad file descriptor") when the fd is already closed (CLI-1.1); a raw
    /// `read` reports EBADF as -1, which reads as EOF here.
    static func drainChunk(fd: Int32, upTo limit: Int = 64 * 1024) -> Data? {
        var buffer = [UInt8](repeating: 0, count: min(limit, 64 * 1024))
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 { return Data(buffer[0..<count]) }
            if count < 0, errno == EINTR { continue }
            return nil
        }
    }

    /// Bytes waiting in a pipe right now (`FIONREAD`), or nil if unknown.
    static func pendingByteCount(_ fd: Int32) -> Int? {
        var count: Int32 = 0
        #if canImport(Darwin)
        // `FIONREAD` is `_IOR('f', 127, int)`, a macro Swift does not import.
        let request: UInt = 0x4004_667F
        #else
        let request = UInt(FIONREAD)
        #endif
        guard ioctl(fd, request, &count) >= 0, count >= 0 else { return nil }
        return Int(count)
    }

    /// What `fd` held when called, without blocking: at most the bytes
    /// `FIONREAD` reported, stopping early at EOF or when the pipe empties.
    /// A closed descriptor reads as empty.
    static func readWithoutBlocking(_ fd: Int32) -> Data {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
        // Once the child has exited, everything it wrote is already in the
        // pipe. Read only that much: a background writer refilling the pipe
        // would otherwise keep this loop, and the caller, going (CLI-1.4).
        var remaining = pendingByteCount(fd) ?? 1 << 20
        var result = Data()
        // Stops at EOF, or at EAGAIN when the pipe is empty but still open.
        while remaining > 0, let chunk = drainChunk(fd: fd, upTo: remaining) {
            result.append(chunk)
            remaining -= chunk.count
        }
        return result
    }

    /// `Duration` → seconds as a `Double`, for `DispatchQueue.asyncAfter`
    /// and the `timedOut` error payload.
    static func seconds(of duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

#if os(Linux)
/// The process `Subprocess.run(_:)` launches. swift-corelibs-foundation's
/// `Process.run()` sizes its descriptor-closing loop by reading
/// `/proc/self/fd`, copying a fixed 256-byte name out of each `readdir`
/// entry. That reads past glibc's directory buffer when an entry ends at a
/// page edge, crashing with SIGSEGV (#736; fixed upstream by
/// swift-corelibs-foundation #5472, in no Swift release through 6.4.1).
typealias SubprocessProcess = SpawnedSubprocess
#else
typealias SubprocessProcess = Process

extension Process: TerminableSubprocess {
    /// Foundation's own reaper always records the exit status.
    func reapedStatus() throws -> Int32 { terminationStatus }

    /// Foundation reaps on its own queue, so a reap between this check and
    /// the signal is not excluded here.
    func killIfRunning() {
        if isRunning { _ = kill(processIdentifier, SIGKILL) }
    }
}
#endif

/// What `SubprocessTermination` needs from the process it stops. Tests
/// substitute a process whose reaper runs at a chosen moment (CLI-1.8).
protocol TerminableSubprocess: AnyObject {
    var isRunning: Bool { get }
    func run() throws
    func terminate()
    /// SIGKILL, unless the child has already been reaped.
    func killIfRunning()
}

/// Stops one subprocess on timeout or cancellation: SIGTERM first, then
/// SIGKILL if the child is still running after `killGrace` (CLI-1.3). One
/// lock orders launch, stop, and the kill check. The process checks that its
/// child is unreaped in the same step that signals it. On Linux that step
/// holds the lock its reaper takes, so a late action cannot signal a PID the
/// reaper released (CLI-1.8); Foundation's macOS reaper is not excluded.
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
    private weak var process: (any TerminableSubprocess)?
    private var isFinished = false
    private var stopRequested = false
    private var _didTimeout = false

    init(process: any TerminableSubprocess, killGrace: TimeInterval = 2, scheduler: SubprocessScheduler = .dispatch) {
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
            guard !isFinished, let process else { return }
            process.killIfRunning()
        }
    }
}

/// Captured stdout and stderr of one piped subprocess.
private final class PipeBuffers: Sendable {
    let stdout: PipeStream
    let stderr: PipeStream

    init(limit: Int?, onOutput: (@Sendable (Data) -> Void)?) {
        stdout = PipeStream(limit: limit, onOutput: onOutput)
        stderr = PipeStream(limit: limit, onOutput: onOutput)
    }
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

    private let limit: Int?
    private let onOutput: (@Sendable (Data) -> Void)?

    init(limit: Int?, onOutput: (@Sendable (Data) -> Void)?) {
        self.limit = limit
        self.onOutput = onOutput
    }

    private func append(_ chunk: Data) {
        bytes.append(chunk)
        if let limit, bytes.count > limit { bytes = Data(bytes.suffix(limit)) }
        onOutput?(chunk)
    }

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
        let atEOF = lock.withLock { () -> FileHandle? in
            guard !finished else { return nil }
            guard let chunk = Subprocess.drainChunk(fd: fd) else { return handle }
            append(chunk)
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
            append(Subprocess.readWithoutBlocking(fd))
            self.handle = nil
            return handle
        }
        // Cleared outside the lock: a setter that synchronizes with the
        // source could otherwise wait on a callback blocked on this lock.
        drained?.readabilityHandler = nil
    }
}

#if os(Linux)
/// The subset of `Process` that `Subprocess` uses, launched through
/// `SpawnedProcessGroup` (#736). Like corelibs, the child starts in its own
/// process group and inherits only its standard streams, but the descriptors
/// are closed in the child, so the parent never scans `/proc/self/fd`. Like
/// `Process` on macOS, it starts with default signal handling, so SIGTERM
/// stops it (CLI-1.7).
///
/// Termination is reported when the child itself exits, even while a
/// background descendant still holds an inherited descriptor (CLI-1.6).
/// Corelibs instead waits until every holder of its launch socket closes it.
final class SpawnedSubprocess: TerminableSubprocess, @unchecked Sendable {
    var executableURL: URL?
    var arguments: [String]?
    var currentDirectoryURL: URL?
    var environment: [String: String]?
    /// Nil inherits the app's stdin.
    var standardInput: FileHandle?
    /// A `Pipe` or `FileHandle`; nil inherits the app's stream.
    var standardOutput: Any?
    var standardError: Any?
    var terminationHandler: (@Sendable (SpawnedSubprocess) -> Void)?

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var running = false
    /// Nil until exit, and after it when another waiter reaped the child.
    private var status: Int32?
    /// `waitpid(2)`; tests inject one whose status another waiter took (CLI-1.9).
    private let reap: @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t

    init(waitpid: @escaping @Sendable (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { Glibc.waitpid($0, $1, $2) }) {
        reap = waitpid
    }

    var processIdentifier: Int32 { lock.withLock { pid } }
    var isRunning: Bool { lock.withLock { running } }

    /// The exit status as `Process.terminationStatus` reports it. Throws
    /// ECHILD when another waiter reaped the child first, losing it (CLI-1.9).
    func reapedStatus() throws -> Int32 {
        guard let status = lock.withLock({ status }) else { throw POSIXError(.ECHILD) }
        return status
    }

    func run() throws {
        guard let executableURL else { throw POSIXError(.ENOENT) }
        let spawned = try SpawnedProcessGroup.spawn(
            executable: executableURL, args: arguments ?? [],
            env: environment ?? ProcessInfo.processInfo.environment,
            directory: currentDirectoryURL?.path, resetsSignals: true,
            standardInput: standardInput?.fileDescriptor,
            standardOutput: Self.writeDescriptor(standardOutput) ?? STDOUT_FILENO,
            standardError: Self.writeDescriptor(standardError) ?? STDERR_FILENO,
            closeDescriptors: [])
        // The child holds its own copies; the readers see EOF once it and
        // any descendants close them.
        for case let pipe as Pipe in [standardOutput, standardError] {
            try? pipe.fileHandleForWriting.close()
        }
        lock.withLock {
            pid = spawned
            running = true
        }
        // A blocking wait per child, on its own thread rather than one taken
        // from the dispatch pool.
        Thread { self.waitForExit() }.start()
    }

    /// SIGTERM, as `Process.terminate()` sends; a no-op once the child exited.
    func terminate() { signal(SIGTERM) }

    func killIfRunning() { signal(SIGKILL) }

    /// The reaper releases the PID under the same lock.
    private func signal(_ signal: Int32) {
        lock.withLock {
            guard running else { return }
            _ = kill(pid, signal)
        }
    }

    private func waitForExit() {
        let pid = processIdentifier
        // Observe the exit without reaping: until `waitpid` below, the zombie
        // keeps the PID reserved, so `terminate()` cannot signal a reused PID.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        var raw: Int32 = 0
        lock.withLock {
            running = false
            var reaped: pid_t
            repeat { reaped = reap(pid, &raw, 0) } while reaped == -1 && errno == EINTR
            guard reaped == pid else { return }
            // Exit code, or the signal number for an uncaught signal, as
            // `Process.terminationStatus` reports them.
            let signal = raw & 0x7F
            status = signal == 0 ? (raw >> 8) & 0xFF : signal
        }
        let handler = terminationHandler
        terminationHandler = nil
        handler?(self)
    }

    private static func writeDescriptor(_ stream: Any?) -> Int32? {
        switch stream {
        case let pipe as Pipe: pipe.fileHandleForWriting.fileDescriptor
        case let handle as FileHandle: handle.fileDescriptor
        default: nil
        }
    }
}
#endif
