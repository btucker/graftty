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
/// `resize(cols:rows:)` uses the default no-op protocol implementation
/// for R4. R6 (or a follow-up) wires `ioctl(TIOCSWINSZ)` on the master
/// PTY — see the equivalent path in `WebSession`. R4 ships without
/// this because libghostty client-side resize plus the next attach's
/// env defaults are enough to keep dimensions roughly correct.
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

    func close() async {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        continuation.finish()
    }
}
