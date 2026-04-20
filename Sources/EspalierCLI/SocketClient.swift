import Foundation
import EspalierKit

enum SocketClient {
    /// Fire-and-forget: write the message and close. Used by `notify`.
    static func send(_ message: NotificationMessage) throws {
        let fd = try openConnectedSocket()
        defer { close(fd) }
        try writeMessage(message, to: fd)
    }

    /// Request/response: write the message, half-close the write side so
    /// the server knows the request is complete, then read the reply.
    /// Used by `pane list`, `pane add`, `pane close`.
    static func sendExpectingResponse(_ message: NotificationMessage) throws -> ResponseMessage {
        let fd = try openConnectedSocket()
        defer { close(fd) }
        try writeMessage(message, to: fd)

        // Half-close so the server's read-until-EOF loop terminates and
        // it proceeds to compute + write the response. Without this the
        // server would block indefinitely waiting for more bytes.
        _ = Darwin.shutdown(fd, Int32(SHUT_WR))

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &chunk, 4096)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        switch SocketResponseDecoder.decode(buffer) {
        case .success(let msg):
            return msg
        case .failure(.timeout):
            // Pre-cycle-138 this was `socketError("Empty response
            // from app")` — misleading when the actual cause is a
            // timeout (client SO_RCVTIMEO elapsed, or server closed
            // fd without a response per `ATTN-2.10`). `.socketTimeout`
            // mirrors the ATTN-3.3 error shape so the user gets the
            // same "try again / wait for the app" cue regardless of
            // which end of the timeout fired.
            throw CLIError.socketTimeout
        case .failure(.unparseable):
            throw CLIError.socketError("Unparseable response from app")
        }
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

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

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

    private static func writeMessage(_ message: NotificationMessage, to fd: Int32) throws {
        let data = try JSONEncoder().encode(message)
        let jsonLine = String(data: data, encoding: .utf8)! + "\n"
        // Pre-cycle-139 this did `_ = Darwin.write(fd, ptr, strlen(ptr))`,
        // silently dropping partial writes AND errors. `espalier notify
        // "done"` against a just-crashed server would report success
        // even though the server never received the message. See
        // `SocketIO.writeAll` for the loop + errno-surfacing.
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
