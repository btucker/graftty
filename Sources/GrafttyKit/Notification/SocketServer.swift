import Foundation

public final class SocketServer: @unchecked Sendable {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var isRunning = false
    private var generation: UInt64 = 0
    private var nextClientID: UInt64 = 0
    private var clientFDs: [Int32: ClientLease] = [:]
    private var requestWaiters: [Int32: RequestWaiter] = [:]
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(
        label: "com.graftty.socket-server.accept"
    )
    private let clientQueue = DispatchQueue(
        label: "com.graftty.socket-server.client",
        attributes: .concurrent
    )
    public var onMessage: ((NotificationMessage) -> Void)?
    /// The last error thrown from `start()`, or `nil` if the most
    /// recent call succeeded (or none has been made). Exists so the
    /// app shell can introspect a failed startup without catching
    /// the error itself — `GrafttyApp.startup` historically wrapped
    /// `start()` in `try?` and silently ran without a notify surface
    /// (ATTN-2.7).
    public private(set) var lastStartError: SocketServerError?
    /// Request/response variant of `onMessage`. When set, the server calls
    /// this after `onMessage` and, if the handler returns a non-nil
    /// `ResponseMessage`, writes it to the client (as JSON + newline)
    /// before closing the connection. Handlers are invoked on the main
    /// queue; each connection worker waits for its own handler result.
    public var onRequest: ((NotificationMessage) -> ResponseMessage?)?
    /// Async request variant used when a handler needs to await work without
    /// blocking the main actor (for example a bounded zmx subprocess). When
    /// present it takes precedence over `onRequest`.
    public var onAsyncRequest:
        (@MainActor @Sendable (NotificationMessage) async -> ResponseMessage?)?
    var clientAdmissionObserver: (@Sendable (Int32) -> Void)?

    /// Upper bound on how long a connection worker waits for an `onRequest`
    /// handler (which runs on the main queue) to return. If the main
    /// queue stalls — modal dialog, long synchronous work, reentrancy
    /// bug — the previous unbounded `semaphore.wait()` pinned the socket
    /// server. Capping at 5s means the server closes the fd without a
    /// response on stall. The CLI has its own shorter client-side deadline
    /// (`ATTN-3.3`), so neither endpoint can hang forever. Tests can override;
    /// production takes the default.
    public var onRequestTimeout: DispatchTimeInterval = .seconds(5)

    /// Per-client read cap. `SO_RCVTIMEO` only fires on idle pipes,
    /// so a continuously-writing peer needs an explicit byte bound.
    /// `ATTN-2.11`. Tests can shrink.
    public var maxPerClientBytes: Int = 1 * 1024 * 1024

    /// Idle read deadline applied independently to each accepted client.
    /// Tests can shorten it; production keeps the two-second ATTN-2.9 value.
    public var clientReadTimeoutSeconds: Int = 2

    /// Send deadline applied independently to each accepted client. Without
    /// this, a peer that never reads a large response can retain a client
    /// slot forever. Tests can shorten the production two-second value.
    public var clientSendTimeoutSeconds: Int = 2

    /// Maximum number of accepted clients allowed to occupy connection
    /// workers at once. Excess clients receive an immediate structured busy
    /// response and close. Tests can shrink the production limit to exercise
    /// admission behavior.
    public var maxConcurrentClients: Int = 64

    /// Maximum path length for a Unix domain socket on macOS. `sockaddr_un.sun_path`
    /// is 104 bytes — accounting for the null terminator, the path must be ≤103
    /// bytes when encoded as UTF-8.
    public static let maxPathBytes = 103
    public static let listenBacklog: Int32 = 64

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
        try stateLock.withLock {
            try startLocked()
        }
    }

    /// Creates and publishes the listening socket while `stateLock` is held,
    /// so `stop()` cannot race a partially-started server.
    private func startLocked() throws {
        guard !isRunning else { return }

        // Validate path length BEFORE touching anything. bind() would silently
        // accept a truncated path and create the socket at the wrong location,
        // which is worse than erroring out here.
        let pathBytes = socketPath.utf8.count
        guard pathBytes <= Self.maxPathBytes else {
            throw SocketServerError.socketPathTooLong(bytes: pathBytes, maxBytes: Self.maxPathBytes)
        }

        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketServerError.socketCreationFailed }
        var sourceOwnsFD = false
        var boundPath = false
        defer {
            if !sourceOwnsFD {
                close(fd)
                if boundPath {
                    unlink(socketPath)
                }
            }
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                pathPtr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in _ = strlcpy(dest, ptr, 104) }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindResult == 0 else {
            throw SocketServerError.bindFailed(errno: errno)
        }
        boundPath = true
        // Listen backlog of 64 (ATTN-2.8): small enough to not over-commit
        // kernel resources, large enough that a user running parallel
        // `graftty notify` invocations from several shell scripts won't
        // start hitting ECONNREFUSED under burst load. The prior backlog
        // of 5 was the historical `listen(2)` default and had effectively
        // no headroom.
        guard Darwin.listen(fd, Self.listenBacklog) == 0 else {
            throw SocketServerError.listenFailed(errno: errno)
        }

        let src = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: acceptQueue
        )
        src.setEventHandler { [weak self] in
            self?.acceptConnection(listenFD: fd)
        }
        // The source owns the listening descriptor after start succeeds.
        // Capturing the exact fd avoids a late cancel handler closing a newer
        // descriptor if the same SocketServer instance is restarted.
        src.setCancelHandler {
            close(fd)
        }
        generation &+= 1
        listenFD = fd
        isRunning = true
        self.source = src
        src.resume()
        sourceOwnsFD = true
    }

    public func stop() {
        let (sourceToCancel, waiters) = stateLock.withLock {
            () -> (DispatchSourceRead?, [DispatchSemaphore]) in
            let ownedSocketPath = source != nil
            isRunning = false
            listenFD = -1
            let sourceToCancel = source
            source = nil

            // Each connection worker owns its close(2). shutdown(2) wakes a
            // worker blocked in read/write without introducing a close/reuse
            // race with that worker's eventual cleanup.
            for fd in clientFDs.keys {
                _ = Darwin.shutdown(fd, Int32(SHUT_RDWR))
            }
            // Wake workers waiting for MainActor results as well as workers
            // blocked in socket I/O. A handler that completes later may signal
            // again harmlessly, but cannot keep the server alive after stop.
            let waiters = requestWaiters.values.map(\.semaphore)
            requestWaiters.removeAll()
            // Keep prior-generation descriptors in the admission count until
            // their workers actually close them. Otherwise rapid stop/start
            // cycles could admit another full generation while old workers
            // were still unwinding, defeating the process-wide client cap.
            if ownedSocketPath {
                unlink(socketPath)
            }
            return (sourceToCancel, waiters)
        }
        for waiter in waiters {
            waiter.signal()
        }
        sourceToCancel?.cancel()
    }

    private func acceptConnection(listenFD: Int32) {
        let clientFD = Darwin.accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        let configured = Self.configureAcceptedSocket(
            clientFD,
            receiveTimeoutSeconds: clientReadTimeoutSeconds,
            sendTimeoutSeconds: clientSendTimeoutSeconds
        )
        if !configured {
            guard configureBufferedOneWayFallback(clientFD) else {
                close(clientFD)
                return
            }
        }

        let admission = stateLock.withLock { () -> ClientAdmission in
            guard isRunning, self.listenFD == listenFD else {
                return .inactive
            }
            guard clientFDs.count < maxConcurrentClients else {
                return .busy
            }
            nextClientID &+= 1
            let lease = ClientLease(
                serverGeneration: generation,
                clientID: nextClientID
            )
            clientFDs[clientFD] = lease
            return .admitted(lease: lease)
        }
        switch admission {
        case .admitted(let lease):
            clientAdmissionObserver?(clientFD)
            // A dedicated concurrent queue prevents one connection's read or
            // request-handler wait from occupying the accept source or delaying
            // unrelated clients. Each connection still runs on one work item,
            // so its request lines and responses remain strictly ordered.
            clientQueue.async { [weak self] in
                guard let self else {
                    close(clientFD)
                    return
                }
                self.handleClient(fd: clientFD, lease: lease)
            }
        case .busy:
            // The compatibility fallback exists only for legacy one-way
            // clients whose peer has already closed. Its SO_NOSIGPIPE setup
            // failed, so never write a busy response on that descriptor.
            // A configured request client can safely receive the structured
            // response and retry.
            if configured {
                writeImmediateResponse(.serverBusy, to: clientFD)
            }
            close(clientFD)
        case .inactive:
            close(clientFD)
        }
    }

    private func writeImmediateResponse(
        _ response: ResponseMessage,
        to fd: Int32
    ) {
        guard var payload = try? JSONEncoder().encode(response) else { return }
        payload.append(0x0A)
        payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?
                .assumingMemoryBound(to: UInt8.self) else { return }
            try? SocketIO.writeAll(fd: fd, bytes: base, count: buffer.count)
        }
    }

    private func handleClient(fd: Int32, lease: ClientLease) {
        defer { finishClient(fd: fd, lease: lease) }
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
            guard isConnectionActive(fd: fd, lease: lease) else {
                return
            }
            guard let data = line.data(using: .utf8),
                  let message = try? JSONDecoder().decode(NotificationMessage.self, from: data) else { continue }
            DispatchQueue.main.async { [weak self] in
                self?.deliverMessage(
                    message,
                    generation: lease.serverGeneration
                )
            }

            // notify/clear clients close as soon as their one-way write
            // completes. Waiting on the app's response dispatcher for those
            // messages cannot produce a useful reply and, during hook bursts,
            // can needlessly occupy every bounded request slot.
            guard message.expectsResponse else { continue }

            // Request/response path: if a handler is registered, run it on
            // the main actor and block only this connection's worker on the
            // result so the reply is written before we close the fd.
            if let onAsyncRequest {
                let semaphore = DispatchSemaphore(value: 0)
                guard registerRequestWaiter(
                    semaphore,
                    fd: fd,
                    lease: lease
                ) else { return }
                let responseBox = ResponseBox()
                Task { @MainActor [weak self] in
                    guard self?.isConnectionActive(
                        fd: fd,
                        lease: lease
                    ) == true else {
                        semaphore.signal()
                        return
                    }
                    responseBox.value = await onAsyncRequest(message)
                    semaphore.signal()
                }
                guard writeResponseAfterWaiting(
                    fd: fd,
                    lease: lease,
                    semaphore: semaphore,
                    responseBox: responseBox
                ) else { return }
            } else if let onRequest {
                let semaphore = DispatchSemaphore(value: 0)
                guard registerRequestWaiter(
                    semaphore,
                    fd: fd,
                    lease: lease
                ) else { return }
                let responseBox = ResponseBox()
                DispatchQueue.main.async { [weak self] in
                    guard self?.isConnectionActive(
                        fd: fd,
                        lease: lease
                    ) == true else {
                        semaphore.signal()
                        return
                    }
                    responseBox.value = onRequest(message)
                    semaphore.signal()
                }
                guard writeResponseAfterWaiting(
                    fd: fd,
                    lease: lease,
                    semaphore: semaphore,
                    responseBox: responseBox
                ) else { return }
            }
        }
    }

    /// @spec ATTN-2.21: When the application accepts a control-socket client, it shall bound both receive and send I/O so a silent or non-reading peer cannot retain client capacity indefinitely.
    @discardableResult
    static func configureAcceptedSocket(
        _ fd: Int32,
        receiveTimeoutSeconds: Int,
        sendTimeoutSeconds: Int
    ) -> Bool {
        // A handler may finish after the CLI's shorter read timeout closed its
        // peer. Convert that late response into EPIPE instead of letting the
        // process receive SIGPIPE while SocketIO.writeAll reports the error.
        var noSigPipe: Int32 = 1
        let noSigPipeResult = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var receiveTimeout = timeval(
            tv_sec: receiveTimeoutSeconds,
            tv_usec: 0
        )
        let receiveResult = setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        var sendTimeout = timeval(tv_sec: sendTimeoutSeconds, tv_usec: 0)
        let sendResult = setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &sendTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        return noSigPipeResult == 0 && receiveResult == 0 && sendResult == 0
    }

    /// A legacy fire-and-forget client can write and fully close before the
    /// accept queue configures its socket. Darwin then rejects setsockopt with
    /// EINVAL even though the complete notification remains readable. Admit
    /// only complete one-way messages in that state, and make the descriptor
    /// nonblocking so configuration failure can never create an unbounded
    /// worker. Request messages still fail closed because replying without a
    /// working SO_NOSIGPIPE would risk SIGPIPE.
    private func configureBufferedOneWayFallback(_ fd: Int32) -> Bool {
        var bytes = [UInt8](repeating: 0, count: maxPerClientBytes)
        let count = Darwin.recv(
            fd,
            &bytes,
            bytes.count,
            Int32(MSG_PEEK | MSG_DONTWAIT)
        )
        guard count > 0,
              let text = String(
                data: Data(bytes.prefix(Int(count))),
                encoding: .utf8
              ),
              text.hasSuffix("\n") else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty,
              lines.allSatisfy({ line in
                  guard let data = String(line).data(using: .utf8),
                        let message = try? JSONDecoder().decode(
                            NotificationMessage.self,
                            from: data
                        ) else { return false }
                  return !message.expectsResponse
              }) else { return false }

        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private func deliverMessage(
        _ message: NotificationMessage,
        generation: UInt64
    ) {
        let shouldDeliver = stateLock.withLock {
            isRunning && self.generation == generation
        }
        guard shouldDeliver else { return }
        // A callback that already passed the lifecycle check may overlap a
        // concurrent stop. Waiting for arbitrary public callback code here
        // would let callback/stop dependencies deadlock clean shutdown; queued
        // callbacks and request handlers remain generation-gated instead.
        onMessage?(message)
    }

    private func isConnectionActive(fd: Int32, lease: ClientLease) -> Bool {
        stateLock.withLock {
            isRunning
                && generation == lease.serverGeneration
                && clientFDs[fd] == lease
        }
    }

    private func finishClient(fd: Int32, lease: ClientLease) {
        stateLock.withLock {
            if requestWaiters[fd]?.lease == lease {
                requestWaiters.removeValue(forKey: fd)
            }
            guard clientFDs[fd] == lease else { return }
            clientFDs.removeValue(forKey: fd)
            close(fd)
        }
    }

    private func registerRequestWaiter(
        _ semaphore: DispatchSemaphore,
        fd: Int32,
        lease: ClientLease
    ) -> Bool {
        stateLock.withLock {
            guard isRunning,
                  generation == lease.serverGeneration,
                  clientFDs[fd] == lease else { return false }
            requestWaiters[fd] = RequestWaiter(
                lease: lease,
                semaphore: semaphore
            )
            return true
        }
    }

    private func unregisterRequestWaiter(
        _ semaphore: DispatchSemaphore,
        fd: Int32,
        lease: ClientLease
    ) {
        stateLock.withLock {
            guard requestWaiters[fd]?.lease == lease,
                  requestWaiters[fd]?.semaphore === semaphore else { return }
            requestWaiters.removeValue(forKey: fd)
        }
    }

    private func writeResponseAfterWaiting(
        fd: Int32,
        lease: ClientLease,
        semaphore: DispatchSemaphore,
        responseBox: ResponseBox
    ) -> Bool {
        defer {
            unregisterRequestWaiter(
                semaphore,
                fd: fd,
                lease: lease
            )
        }
        // Cap the wait so a stalled handler cannot retain even its own
        // connection indefinitely. A late task writes only to the retained
        // box and signals a semaphore nobody is waiting on.
        let waitResult = semaphore.wait(timeout: .now() + onRequestTimeout)
        let shouldWrite = stateLock.withLock {
            isRunning
                && generation == lease.serverGeneration
                && clientFDs[fd] == lease
                && requestWaiters[fd]?.lease == lease
                && requestWaiters[fd]?.semaphore === semaphore
        }
        guard shouldWrite, waitResult == .success else { return false }
        guard let response = responseBox.value else { return true }
        guard let encoded = try? JSONEncoder().encode(response) else {
            return false
        }
        var payload = encoded
        payload.append(0x0A) // '\n'
        return payload.withUnsafeBytes { buf in
            guard let base = buf.baseAddress?
                .assumingMemoryBound(to: UInt8.self) else { return false }
            do {
                try SocketIO.writeAll(fd: fd, bytes: base, count: buf.count)
                return true
            } catch {
                return false
            }
        }
    }
}

private enum ClientAdmission {
    case admitted(lease: ClientLease)
    case busy
    case inactive
}

/// @spec ATTN-2.23: When a timed-out control-socket request's descriptor number is reused by a new client, the application shall reject the stale handler task unless its unique client lease still owns that descriptor.
private struct ClientLease: Sendable, Equatable {
    let serverGeneration: UInt64
    let clientID: UInt64
}

private struct RequestWaiter {
    let lease: ClientLease
    let semaphore: DispatchSemaphore
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
