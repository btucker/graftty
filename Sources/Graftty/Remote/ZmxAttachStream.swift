import Darwin
import Foundation
import GrafttyKit
import NIOConcurrencyHelpers

/// `TerminalByteStream` conformer that wraps a `Process` running
/// `zmx attach <sessionName>`. Inbound bytes (stdout from the zmx
/// attach Process) are emitted on the AsyncStream; `send()` writes to
/// stdin; `close()` terminates the Process.
///
/// Lifecycle: the underlying user shell runs in the zmx daemon, not
/// in this Process. Killing the Process detaches the view without
/// affecting the shell. This is the same model used by
/// `GrafttyKit.WebSession`; duplication is intentional for R4 —
/// R6 consolidates after `/ws` deletion.
///
/// `resize(cols:rows:)` issues `ioctl(TIOCSWINSZ)` on the stdin pipe fd.
/// Because `zmx attach` connects to a PTY owned by the zmx daemon (not
/// this process), the ioctl lands on a pipe and silently no-ops (ENOTTY),
/// which matches the best-effort posture of `WebSession.resize`. The
/// important resize path on the SSH-over-WebRTC route is the SSH
/// `window-change` channel request issued by `TerminalSessionClient`.
final class ZmxAttachStream: TerminalByteStream, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>
    private let lock = NIOLock()
    private var closed = false
    private let attachmentRegistry: RemoteAttachmentRegistry?
    private let sessionName: String
    /// TERM-11.5: whether init's registry attach actually ran, decided
    /// under `lock` against `closed`. An instantly-dying child can drive
    /// the EOF handler's `close()` before init reaches the registry call;
    /// pairing both sides through `lock` keeps attach/detach balanced.
    private var didRegisterAttach = false

    init(
        zmxExecutable: URL,
        zmxDir: URL,
        sessionName: String,
        workingDirectory: URL?,
        attachmentRegistry: RemoteAttachmentRegistry? = nil
    ) throws {
        let process = Process()
        process.executableURL = zmxExecutable
        process.arguments = ["attach", sessionName]
        var env = ProcessInfo.processInfo.environment
        env["ZMX_DIR"] = zmxDir.path
        process.environment = env
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.sessionName = sessionName
        self.attachmentRegistry = attachmentRegistry

        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont

        stdout.fileHandleForReading.readabilityHandler = { [continuation = cont!, weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                // EOF: use Task indirection to avoid calling async close()
                // from a non-async GCD context. Yield-after-finish is a
                // no-op per AsyncStream docs, so any duplicate finish() is safe.
                Task { await self?.close() }
            } else {
                continuation.yield(data)
            }
        }

        try process.run()
        // TERM-11.5: only a successfully running attach child counts as a
        // remote client; a throwing run() leaves the registry untouched.
        // Registered under `lock` and gated on `closed`: if the child died
        // so fast that the EOF handler's close() already won, registering
        // now would leak a count no close() will ever pair. attach() takes
        // only the registry's own lock and fires no observer, so calling
        // it under `lock` is safe.
        lock.withLock {
            guard !closed else { return }
            attachmentRegistry?.attach(sessionName: sessionName)
            didRegisterAttach = true
        }
    }

    func send(_ bytes: Data) async throws {
        let proceed: Bool = lock.withLock { !closed && process.isRunning }
        guard proceed else { return }
        // On macOS 11+ FileHandle.write(contentsOf:) throws on broken pipe
        // instead of raising NSFileHandleOperationException. Deployment
        // target is macOS 14, so this modern API is always available.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: bytes)
        } catch {
            // Broken pipe means the zmx attach process exited; nothing to
            // do — close() will or has run.
        }
    }

    func resize(cols: Int, rows: Int) async {
        var ws = winsize()
        ws.ws_col = UInt16(cols)
        ws.ws_row = UInt16(rows)
        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        _ = ioctl(fd, UInt(TIOCSWINSZ), &ws)
        // Best-effort: ignore ioctl failures (process gone, fd closed, or
        // ENOTTY because fd is a pipe rather than a PTY master).
        // /ws's WebSession.resize takes the same posture.
    }

    func close() async {
        let (shouldRunCleanup, shouldDetach): (Bool, Bool) = lock.withLock {
            guard !closed else { return (false, false) }
            closed = true
            return (true, didRegisterAttach)
        }
        guard shouldRunCleanup else { return }

        // Nil the read handler BEFORE finish(); any already-dispatched GCD
        // block that fires sees yield-after-finish as a no-op per AsyncStream
        // docs. Ordering: nil handler -> finish() -> terminate process.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        continuation.finish()
        if process.isRunning {
            process.terminate()
        }
        // TERM-11.5: detach outside this stream's non-reentrant NIOLock so
        // an onLastDetach observer that re-enters the stream can't deadlock.
        // (Observer-vs-registry safety is the registry's own contract: it
        // releases its lock before invoking the observer.)
        if shouldDetach {
            attachmentRegistry?.detach(sessionName: sessionName)
        }
    }
}
