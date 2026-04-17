import Foundation

public final class SocketServer: @unchecked Sendable {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.espalier.socket-server")
    public var onMessage: ((NotificationMessage) -> Void)?
    /// Request/response variant of `onMessage`. When set, the server calls
    /// this after `onMessage` and, if the handler returns a non-nil
    /// `ResponseMessage`, writes it to the client (as JSON + newline)
    /// before closing the connection. Handlers are invoked on the same
    /// dispatch queue as `onMessage`; dispatch to the main actor inside
    /// the handler if your state requires it.
    public var onRequest: ((NotificationMessage) -> ResponseMessage?)?

    /// Maximum path length for a Unix domain socket on macOS. `sockaddr_un.sun_path`
    /// is 104 bytes — accounting for the null terminator, the path must be ≤103
    /// bytes when encoded as UTF-8.
    public static let maxPathBytes = 103

    public init(socketPath: String) { self.socketPath = socketPath }
    deinit { stop() }

    public func start() throws {
        // Validate path length BEFORE touching anything. bind() would silently
        // accept a truncated path and create the socket at the wrong location,
        // which is worse than erroring out here.
        let pathBytes = socketPath.utf8.count
        guard pathBytes <= Self.maxPathBytes else {
            throw SocketServerError.socketPathTooLong(bytes: pathBytes, maxBytes: Self.maxPathBytes)
        }

        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw SocketServerError.socketCreationFailed }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindResult == 0 else { close(listenFD); throw SocketServerError.bindFailed(errno: errno) }
        guard Darwin.listen(listenFD, 5) == 0 else { close(listenFD); throw SocketServerError.listenFailed(errno: errno) }

        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptConnection() }
        src.setCancelHandler { [weak self] in if let fd = self?.listenFD, fd >= 0 { close(fd) } }
        src.resume()
        self.source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    private func acceptConnection() {
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }
        queue.async { [weak self] in self?.handleClient(fd: clientFD) }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = Darwin.read(fd, &chunk, 4096)
            if bytesRead <= 0 { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
        }
        let lines = String(data: buffer, encoding: .utf8)?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? []
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(NotificationMessage.self, from: data) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }

            // Request/response path: if a handler is registered, run it on
            // the main actor and block the socket-queue worker on the
            // result so the reply is written before we close the fd.
            if let onRequest {
                let semaphore = DispatchSemaphore(value: 0)
                var response: ResponseMessage?
                DispatchQueue.main.async {
                    response = onRequest(message)
                    semaphore.signal()
                }
                semaphore.wait()
                if let response, let encoded = try? JSONEncoder().encode(response) {
                    var payload = encoded
                    payload.append(0x0A) // '\n'
                    payload.withUnsafeBytes { buf in
                        _ = Darwin.write(fd, buf.baseAddress, buf.count)
                    }
                }
            }
        }
    }
}

public enum SocketServerError: Error {
    case socketCreationFailed
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case socketPathTooLong(bytes: Int, maxBytes: Int)
}
