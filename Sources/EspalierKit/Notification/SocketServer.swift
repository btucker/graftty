import Foundation

public final class SocketServer: @unchecked Sendable {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.espalier.socket-server")
    public var onMessage: ((NotificationMessage) -> Void)?
    /// The last error thrown from `start()`, or `nil` if the most
    /// recent call succeeded (or none has been made). Exists so the
    /// app shell can introspect a failed startup without catching
    /// the error itself — `EspalierApp.startup` historically wrapped
    /// `start()` in `try?` and silently ran without a notify surface
    /// (ATTN-2.7).
    public private(set) var lastStartError: SocketServerError?
    /// Request/response variant of `onMessage`. When set, the server calls
    /// this after `onMessage` and, if the handler returns a non-nil
    /// `ResponseMessage`, writes it to the client (as JSON + newline)
    /// before closing the connection. Handlers are invoked on the same
    /// dispatch queue as `onMessage`; dispatch to the main actor inside
    /// the handler if your state requires it.
    public var onRequest: ((NotificationMessage) -> ResponseMessage?)?

    /// Upper bound on how long the socket worker waits for an `onRequest`
    /// handler (which runs on the main queue) to return. If the main
    /// queue stalls — modal dialog, long synchronous work, reentrancy
    /// bug — the previous unbounded `semaphore.wait()` pinned the
    /// socket queue and every subsequent client behind it. Capping at
    /// 5s means the server closes the fd without a response on stall;
    /// the CLI's 2s client-side timeout (`ATTN-3.3`) then surfaces that
    /// as a clean `socketTimeout` to the user instead of hanging
    /// forever. Tests can override; production takes the default.
    public var onRequestTimeout: DispatchTimeInterval = .seconds(5)

    /// Per-client read cap. `SO_RCVTIMEO` only fires on idle pipes,
    /// so a continuously-writing peer needs an explicit byte bound.
    /// `ATTN-2.11`. Tests can shrink.
    public var maxPerClientBytes: Int = 1 * 1024 * 1024

    /// Maximum path length for a Unix domain socket on macOS. `sockaddr_un.sun_path`
    /// is 104 bytes — accounting for the null terminator, the path must be ≤103
    /// bytes when encoded as UTF-8.
    public static let maxPathBytes = 103

    public init(socketPath: String) { self.socketPath = socketPath }
    deinit { stop() }

    public func start() throws {
        do {
            try _start()
            lastStartError = nil
        } catch let error as SocketServerError {
            lastStartError = error
            throw error
        }
    }

    private func _start() throws {
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
        // Listen backlog of 64 (ATTN-2.8): small enough to not over-commit
        // kernel resources, large enough that a user running parallel
        // `espalier notify` invocations from several shell scripts won't
        // start hitting ECONNREFUSED under burst load. The prior backlog
        // of 5 was the historical `listen(2)` default and had effectively
        // no headroom.
        guard Darwin.listen(listenFD, 64) == 0 else { close(listenFD); throw SocketServerError.listenFailed(errno: errno) }

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
        // Bound each client's read phase with SO_RCVTIMEO so a silent or
        // hung peer can't pin this serial dispatch queue indefinitely —
        // which would block acceptConnection from running and DoS every
        // subsequent `espalier notify`. Matches the CLI's client-side
        // 2s timeout (ATTN-3.3); JSON messages are ≤~1 KB over a local
        // Unix socket, so 2s is ample for any well-behaved client.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let cap = maxPerClientBytes
        while buffer.count < cap {
            let remaining = cap - buffer.count
            let toRead = min(chunk.count, remaining)
            let bytesRead = Darwin.read(fd, &chunk, toRead)
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
                let responseBox = ResponseBox()
                DispatchQueue.main.async {
                    responseBox.value = onRequest(message)
                    semaphore.signal()
                }
                // Cap the wait at onRequestTimeout so a stalled main
                // queue can't pin this serial socket queue and block
                // every subsequent client behind it. On timeout, we
                // drop the response (the closure may still complete
                // later — its signal() goes into the retained
                // semaphore harmlessly).
                let waitResult = semaphore.wait(timeout: .now() + onRequestTimeout)
                if waitResult == .success,
                   let response = responseBox.value,
                   let encoded = try? JSONEncoder().encode(response) {
                    var payload = encoded
                    payload.append(0x0A) // '\n'
                    // Errors are logged-and-dropped: the socket worker
                    // queue has no useful escalation path for a per-
                    // client write failure past this point.
                    payload.withUnsafeBytes { buf in
                        guard let base = buf.baseAddress?
                            .assumingMemoryBound(to: UInt8.self) else { return }
                        try? SocketIO.writeAll(fd: fd, bytes: base, count: buf.count)
                    }
                }
            }
        }
    }
}

/// Heap-allocated box for the onRequest response. Necessary because the
/// closure dispatched to main needs to write the response where the
/// socket worker can read it AFTER the semaphore signals success. A
/// plain `var response: ResponseMessage?` captured by the closure would
/// race the worker's read against the closure's write on timeout
/// reclaim; a class gives us a known reference the closure writes
/// under a happens-before edge with `signal() → wait() == .success`.
private final class ResponseBox: @unchecked Sendable {
    var value: ResponseMessage?
}

public enum SocketServerError: Error {
    case socketCreationFailed
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case socketPathTooLong(bytes: Int, maxBytes: Int)
}
