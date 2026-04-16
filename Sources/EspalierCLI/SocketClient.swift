import Foundation
import EspalierKit

enum SocketClient {
    static func send(_ message: NotificationMessage) throws {
        let socketPath = resolveSocketPath()
        guard FileManager.default.fileExists(atPath: socketPath) else { throw CLIError.appNotRunning }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError.socketError("Failed to create socket") }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connectResult == 0 else {
            if errno == ECONNREFUSED || errno == ENOENT { throw CLIError.appNotRunning }
            throw CLIError.socketTimeout
        }

        let data = try JSONEncoder().encode(message)
        let jsonLine = String(data: data, encoding: .utf8)! + "\n"
        jsonLine.withCString { ptr in _ = Darwin.write(fd, ptr, strlen(ptr)) }
    }

    private static func resolveSocketPath() -> String {
        if let envPath = ProcessInfo.processInfo.environment["ESPALIER_SOCK"] { return envPath }
        return AppState.defaultDirectory.appendingPathComponent("espalier.sock").path
    }
}
