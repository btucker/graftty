import Darwin
import Foundation
import GrafttyKit

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

    init(
        zmxExecutable: URL,
        zmxDir: URL,
        sessionName: String,
        workingDirectory: URL?
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

        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont

        stdout.fileHandleForReading.readabilityHandler = { [continuation = cont!] handle in
            let data = handle.availableData
            if data.isEmpty {
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }

        try process.run()
    }

    func send(_ bytes: Data) async throws {
        try stdinPipe.fileHandleForWriting.write(contentsOf: bytes)
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
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        continuation.finish()
    }
}
