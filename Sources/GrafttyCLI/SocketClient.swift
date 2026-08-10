import Foundation
import GrafttyKit

enum SocketClient {
    static let maxResponseBytes = 16 * 1024 * 1024
    static let socketTimeoutSeconds = 2
    static let serverBusyRetryDelays: [TimeInterval] = [0.05, 0.1, 0.2, 0.4]

    /// One-way command with a transport-level admission acknowledgement.
    /// A normal accepted notification completes when the server closes with
    /// no payload; a pre-dispatch capacity rejection is retried safely.
    static func send(
        _ message: NotificationMessage,
        delays: [TimeInterval] = serverBusyRetryDelays,
        sleep: (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        },
        operation: ((NotificationMessage) throws -> ResponseMessage)? = nil
    ) throws {
        let sendOnce = operation ?? { try sendOneWayOnce($0) }
        let response = try retryingServerBusy(
            delays: delays,
            sleep: sleep
        ) {
            try sendOnce(message)
        }
        switch response {
        case .ok:
            return
        case .error(let message):
            throw CLIError.socketError(message)
        case .serverBusy:
            throw CLIError.socketBusy
        default:
            throw CLIError.socketError(
                "Unexpected response to one-way command"
            )
        }
    }

    /// Request/response: write the message, half-close the write side so
    /// the server knows the request is complete, then read the reply.
    /// Used by `pane list`, `pane add`, `pane close`.
    static func sendExpectingResponse(
        _ message: NotificationMessage,
        delays: [TimeInterval] = serverBusyRetryDelays,
        sleep: (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        },
        operation: ((NotificationMessage) throws -> ResponseMessage)? = nil
    ) throws -> ResponseMessage {
        let sendOnce = operation ?? { try sendExpectingResponseOnce($0) }
        let response = try retryingServerBusy(
            delays: delays,
            sleep: sleep
        ) {
            try sendOnce(message)
        }
        guard response != .serverBusy else {
            throw CLIError.socketBusy
        }
        return response
    }

    /// Capacity rejection is safe to retry: the server returns its busy
    /// response before handing the request to a handler, so even mutating
    /// commands cannot have partially executed. Keep the backoff bounded so
    /// a genuinely saturated app still returns an actionable error promptly.
    static func retryingServerBusy(
        delays: [TimeInterval] = serverBusyRetryDelays,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        operation: () throws -> ResponseMessage
    ) rethrows -> ResponseMessage {
        for delay in delays {
            let response = try operation()
            guard response == .serverBusy else {
                return response
            }
            sleep(delay)
        }
        return try operation()
    }

    private static func sendOneWayOnce(
        _ message: NotificationMessage
    ) throws -> ResponseMessage {
        let fd = try openConnectedSocket()
        defer { close(fd) }

        let writeFailure: Error?
        do {
            try writeMessage(message, to: fd)
            writeFailure = nil
        } catch {
            writeFailure = error
        }
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))
        let read = SocketIO.readCapped(fd: fd, cap: maxResponseBytes)

        if let writeFailure {
            if let busy = busyResponseIfPresent(read) {
                return busy
            }
            throw writeFailure
        }
        if read.data.isEmpty, !read.exceededCap {
            if let readError = read.readError {
                throw readFailure(readError)
            }
            return .ok
        }
        return try decodeResponse(read)
    }

    private static func sendExpectingResponseOnce(
        _ message: NotificationMessage
    ) throws -> ResponseMessage {
        let fd = try openConnectedSocket()
        defer { close(fd) }
        let writeFailure: Error?
        do {
            try writeMessage(message, to: fd)
            writeFailure = nil
        } catch {
            writeFailure = error
        }

        // Half-close so the server's read-until-EOF loop terminates and
        // it proceeds to compute + write the response. Without this the
        // server would block indefinitely waiting for more bytes.
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))

        // `ATTN-3.6`: cap the read at 16 MiB so a misbehaving or
        // compromised server can't OOM the CLI by flooding faster
        // than `SO_RCVTIMEO` fires. This is independent of the server's
        // incoming-request cap; legitimate bulk responses paginate well
        // below this last-resort boundary.
        let read = SocketIO.readCapped(fd: fd, cap: maxResponseBytes)
        if let writeFailure {
            if let busy = busyResponseIfPresent(read) {
                return busy
            }
            throw writeFailure
        }
        return try decodeResponse(read)
    }

    private static func busyResponseIfPresent(
        _ read: SocketIO.CappedRead
    ) -> ResponseMessage? {
        guard !read.exceededCap,
              !read.data.isEmpty,
              let response = try? decodeResponse(read),
              response == .serverBusy else {
            return nil
        }
        return response
    }

    static func decodeResponse(_ read: SocketIO.CappedRead) throws -> ResponseMessage {
        guard !read.exceededCap else {
            throw CLIError.responseTooLarge(maxBytes: maxResponseBytes)
        }
        switch SocketResponseDecoder.decode(read.data) {
        case .success(let msg):
            return msg
        case .failure(.timeout):
            throw readFailure(read.readError)
        case .failure(.unparseable):
            if let readError = read.readError {
                throw readFailure(readError)
            }
            throw CLIError.socketError("Unparseable response from app")
        }
    }

    private static func readFailure(_ readError: Int32?) -> CLIError {
        guard let readError else {
            return .socketClosedWithoutResponse
        }
        if readError == EAGAIN || readError == EWOULDBLOCK {
            return .socketTimeout
        }
        return .socketError("Failed to read response (errno \(readError))")
    }

    // MARK: - Internals

    private static func openConnectedSocket() throws -> Int32 {
        let socketPath = resolveSocketPath()
        let pathBytes = socketPath.utf8.count
        guard pathBytes <= SocketServer.maxPathBytes else {
            throw CLIError.socketPathTooLong(bytes: pathBytes, maxBytes: SocketServer.maxPathBytes)
        }
        // Defer the existence check until connect() fails so we can
        // distinguish "no socket file" from "file exists but no listener"
        // per ATTN-3.4. A bare fileExists gate would throw .appNotRunning
        // on the missing-file case and never reach the diagnosis.

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.socketError("Failed to create socket") }

        guard configureSocket(fd) else {
            let savedErrno = errno
            close(fd)
            throw CLIError.socketError(
                "Failed to configure socket deadlines (errno \(savedErrno))"
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            let savedErrno = errno
            close(fd)
            let reason = ControlSocketDiagnosis.classifyConnectFailure(
                errno: savedErrno,
                socketExists: FileManager.default.fileExists(atPath: socketPath),
                path: socketPath
            )
            switch reason {
            case .notRunning: throw CLIError.appNotRunning
            case .staleSocket(let path): throw CLIError.staleControlSocket(path: path)
            case .timeout: throw CLIError.socketTimeout
            }
        }
        return fd
    }

    @discardableResult
    static func configureSocket(
        _ fd: Int32,
        timeoutSeconds: Int = socketTimeoutSeconds
    ) -> Bool {
        var noSigPipe: Int32 = 1
        let noSigPipeResult = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var sendTimeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let sendResult = setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var receiveTimeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let receiveResult = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        return noSigPipeResult == 0
            && sendResult == 0
            && receiveResult == 0
    }

    private static func writeMessage(_ message: NotificationMessage, to fd: Int32) throws {
        let data = try JSONEncoder().encode(message)
        let jsonLine = String(data: data, encoding: .utf8)! + "\n"
        do {
            try SocketIO.writeAll(fd: fd, string: jsonLine)
        } catch let error as SocketIO.WriteError {
            switch error {
            case .writeFailed(let errno):
                throw CLIError.socketError("Failed to send message (errno \(errno))")
            }
        }
    }

    private static func resolveSocketPath() -> String {
        SocketPathResolver.resolve()
    }
}
