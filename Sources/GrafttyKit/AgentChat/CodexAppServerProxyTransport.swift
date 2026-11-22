#if os(macOS)
import Foundation

/// A lasting connection to a Codex tab's registered app-server socket, made
/// through `codex app-server proxy` as team delivery does. Socket paths can
/// exceed what `connect` accepts, and the proxy is Codex's supported route.
final class CodexAppServerProxyTransport: CodexChatTransport, @unchecked Sendable {
    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let connection: CodexAppServerWebSocketConnection
    private let sendQueue = DispatchQueue(label: "graftty.codex-chat.send")
    private let stream: AsyncThrowingStream<String, Error>
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private let sendTimeout: TimeInterval

    /// Launches the proxy and completes the WebSocket upgrade.
    init(binaryPath: String, socketPath: String, timeout: TimeInterval = 5) throws {
        sendTimeout = timeout
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server", "proxy", "--sock", socketPath]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        connection = CodexAppServerWebSocketConnection(
            inputFD: stdin.fileHandleForWriting.fileDescriptor,
            outputFD: stdout.fileHandleForReading.fileDescriptor
        )
        try process.run()
        // A proxy that exits must fail the send, not end this process.
        let writeFD = stdin.fileHandleForWriting.fileDescriptor
        _ = fcntl(writeFD, F_SETNOSIGPIPE, 1)
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        do {
            try connection.performHandshake(deadline: Date().addingTimeInterval(timeout))
        } catch {
            process.terminate()
            throw error
        }
        let reader = Thread { [connection, continuation] in
            do {
                while true {
                    continuation.yield(try connection.readText(deadline: .distantFuture))
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        reader.name = "graftty.codex-chat.read"
        reader.start()
    }

    func send(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            sendQueue.async { [connection, sendTimeout] in
                resume.resume(with: Result {
                    try connection.sendText(text, deadline: Date().addingTimeInterval(sendTimeout))
                })
            }
        }
    }

    func messages() -> AsyncThrowingStream<String, Error> { stream }

    /// Ends the proxy. The reader then sees end of input and finishes the stream.
    func close() async {
        if process.isRunning { process.terminate() }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }
}
#endif
