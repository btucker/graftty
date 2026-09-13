import Foundation
import Darwin
import GrafttyProtocol

/// Connects to an existing zmx daemon without creating a PTY or replaying VT history.
public final class PagedZmxAttachEngine: PagedTerminalStream, TerminalSizeReporting, TerminalSyncResizing, @unchecked Sendable {
    public typealias Config = ZmxAttachEngine.Config
    public enum Error: Swift.Error { case unsupported, alreadyStarted, closed, invalidFrame, socket(Int32) }
    public var usesHostClipboard: Bool { true }
    public let events: AsyncStream<PagedTerminalEvent>
    private let continuation: AsyncStream<PagedTerminalEvent>.Continuation
    private let config: Config
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var started = false
    private var closed = false
    private var registered = false
    private var knownSize: (UInt16, UInt16)?
    private var requestedSize: (UInt16, UInt16)?
    private var sizeCallback: ((UInt16, UInt16) -> Void)?
    public var attachmentRegistry: RemoteAttachmentRegistry?
    public var inputState: ZmxInputState?

    public var onPTYSize: ((UInt16, UInt16) -> Void)? {
        get { lock.withLock { sizeCallback } }
        set {
            let size = lock.withLock { () -> (UInt16, UInt16)? in
                sizeCallback = newValue
                return closed ? nil : knownSize
            }
            if let size { newValue?(size.0, size.1) }
        }
    }

    public init(config: Config) {
        self.config = config
        let pair = AsyncStream<PagedTerminalEvent>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = pair.stream
        continuation = pair.continuation
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { result in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try self.startBlocking(); result.resume() }
                catch { self.closeSync(); result.resume(throwing: error) }
            }
        }
    }

    private func startBlocking() throws {
        try lock.withLock {
            guard !started else { throw Error.alreadyStarted }
            guard !closed else { throw Error.closed }
            started = true
        }
        let name = config.sessionName
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw Error.unsupported
        }
        let path = config.zmxDir.appendingPathComponent(name).path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Error.unsupported }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socket(errno) }
        var handedToReader = false
        defer { if !handedToReader { Darwin.close(fd) } }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Error.unsupported }
        try lock.withLock {
            guard !closed else { throw Error.closed }
            descriptor = fd
        }
        defer {
            if !handedToReader { lock.withLock { descriptor = -1 } }
        }
        // Bit 3 alone prevents older snapshot daemons from selecting a full snapshot.
        var capabilities = Data(); capabilities.appendLE(UInt64(8))
        try sendFrame(tag: 23, payload: capabilities)
        let negotiationDeadline = Date().addingTimeInterval(2)
        var negotiated = false
        while !negotiated {
            let frame = try Self.readFrame(fd: fd, deadline: negotiationDeadline)
            if frame.tag == 23 {
                guard PagedZmxWire.supportsPaging(frame.payload) else { throw Error.unsupported }
                negotiated = true
            } else if frame.tag == 1 || frame.tag == 22 { throw Error.unsupported }
        }
        try sendFrame(tag: 26, payload: Data(PagedTerminalLimits.codec.utf8))
        let readyDeadline = Date().addingTimeInterval(5)
        while true {
            let frame = try Self.readFrame(fd: fd, deadline: readyDeadline)
            if frame.tag == 27 {
                guard let event = try PagedZmxWire.event(tag: frame.tag, payload: frame.payload) else { throw Error.unsupported }
                emit(event)
                break
            }
            if frame.tag == 1 || frame.tag == 22 { throw Error.unsupported }
        }
        try lock.withLock {
            guard !closed else { throw Error.closed }
            attachmentRegistry?.attach(sessionName: name)
            registered = true
        }
        handedToReader = true
        let reader = Thread { [weak self] in
            defer {
                self?.lock.withLock { self?.descriptor = -1 }
                Darwin.close(fd)
                self?.closeSync()
            }
            do {
                while let self, !self.lock.withLock({ self.closed }) {
                    let frame = try Self.readFrame(fd: fd, deadline: nil)
                    if frame.tag == 2 {
                        guard frame.payload.isEmpty else { throw Error.invalidFrame }
                        try self.replyToSizeRequest()
                        continue
                    }
                    if let event = try PagedZmxWire.event(tag: frame.tag, payload: frame.payload) {
                        self.emit(event)
                    }
                }
            } catch { }
        }
        reader.name = "PagedZmxAttachEngine.reader(\(name))"
        reader.start()
    }

    public func send(_ bytes: Data) async throws {
        guard !bytes.isEmpty else { return }
        try sendFrame(tag: 0, payload: bytes)
        inputState?.recordInput(bytes, forSession: config.sessionName)
    }
    public func resize(cols: UInt16, rows: UInt16) {
        guard cols > 0, rows > 0 else { return }
        var payload = Data(); payload.appendLE(rows); payload.appendLE(cols)
        try? sendFrame(tag: 2, payload: payload, requestedSize: (cols, rows))
    }
    public func resize(cols: Int, rows: Int) async {
        resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
    }
    public func requestHistory(_ request: PagedTerminalHistoryRequest) async throws {
        guard request.screen < 2 else { throw Error.invalidFrame }
        try sendFrame(tag: 28, payload: PagedZmxWire.history(request))
    }
    public func requestCheckpoint() async throws {
        try sendFrame(tag: 26, payload: Data(PagedTerminalLimits.codec.utf8))
    }
    public func close() async { closeSync() }
    public func close() { closeSync() }
    deinit { closeSync() }

    private func closeSync() {
        let detach = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            // The reader owns close(fd). shutdown interrupts read without fd reuse.
            if descriptor >= 0 { _ = shutdown(descriptor, SHUT_RDWR) }
            sizeCallback = nil
            let detach = registered
            registered = false
            return detach
        }
        if detach { attachmentRegistry?.detach(sessionName: config.sessionName) }
        inputState?.removeSession(config.sessionName)
        continuation.finish()
    }

    private func sendFrame(tag: UInt8, payload: Data, requestedSize: (UInt16, UInt16)? = nil) throws {
        let frame = PagedZmxWire.frame(tag: tag, payload: payload)
        try withWritableSocket { fd in
            if let requestedSize {
                // A daemon grid notification can prompt the ownership bridge
                // to synchronize this follower again. Echoing an unchanged
                // resize produces another grid notification indefinitely.
                if let previous = self.requestedSize, previous == requestedSize { return }
                self.requestedSize = requestedSize
            }
            try Self.write(frame, to: fd)
        }
    }

    private func replyToSizeRequest() throws {
        try withWritableSocket { fd in
            // An initial owner resize can be ignored while another zmx client
            // leads. zmx asks again after the first input transfers leadership.
            // Read and write under one lock so an older reply cannot overtake
            // a new owner resize. Passive attachments never invent a size.
            guard let (cols, rows) = requestedSize else { return }
            var payload = Data(); payload.appendLE(rows); payload.appendLE(cols)
            try Self.write(PagedZmxWire.frame(tag: 2, payload: payload), to: fd)
        }
    }

    private func withWritableSocket(_ body: (Int32) throws -> Void) throws {
        do {
            try lock.withLock {
                guard !closed, descriptor >= 0 else { throw Error.closed }
                do { try body(descriptor) }
                catch {
                    // A partial frame cannot be retried or followed by another
                    // header. Poison the descriptor before unlocking so another
                    // writer cannot append bytes to the incomplete payload.
                    _ = shutdown(descriptor, SHUT_RDWR)
                    descriptor = -1
                    throw error
                }
            }
        } catch {
            closeSync()
            throw error
        }
    }

    private static func write(_ frame: Data, to fd: Int32) throws {
        try frame.withUnsafeBytes { bytes in
            try SocketIO.writeAll(fd: fd, bytes: bytes.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count)
        }
    }

    private func emit(_ event: PagedTerminalEvent) {
        if case .checkpoint(let checkpoint) = event { updateSize(cols: checkpoint.cols, rows: checkpoint.rows) }
        if case .dropped = continuation.yield(event) { closeSync() }
    }
    private func updateSize(cols: UInt16, rows: UInt16) {
        let callback = lock.withLock { () -> ((UInt16, UInt16) -> Void)? in
            guard !closed else { return nil }
            knownSize = (cols, rows)
            return sizeCallback
        }
        callback?(cols, rows)
    }

    private static func readFrame(fd: Int32, deadline: Date?) throws -> (tag: UInt8, payload: Data) {
        let header = try readExactly(fd: fd, count: 8, deadline: deadline)
        let count = Int(header.le(1, 4))
        guard count <= PagedTerminalLimits.readyBytes + 48 else { throw Error.invalidFrame }
        return (header[0], try readExactly(fd: fd, count: count, deadline: deadline))
    }
    private static func readExactly(fd: Int32, count: Int, deadline: Date?) throws -> Data {
        var data = Data(count: count)
        var position = 0
        while position < count {
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw Error.unsupported }
                var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let result = poll(&pollFD, 1, Int32(min(remaining * 1000, Double(Int32.max))))
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw Error.unsupported }
            }
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: position), count - position) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw Error.closed }
            position += n
        }
        return data
    }
}

/// zmx's packed IPC header occupies eight bytes; its u32 length starts at byte one.
enum PagedZmxWire {
    static func frame(tag: UInt8, payload: Data) -> Data {
        var result = Data([tag]); result.appendLE(UInt32(payload.count))
        result.append(contentsOf: [0, 0, 0]); result.append(payload)
        return result
    }
    static func supportsPaging(_ payload: Data) -> Bool { payload.count == 8 && payload.le(0, 8) & 8 != 0 }
    static func history(_ request: PagedTerminalHistoryRequest) -> Data {
        var result = Data()
        result.appendLE(request.incarnation); result.appendLE(request.checkpointID)
        result.appendLE(request.requestID); result.appendLE(request.ordinal); result.appendLE(request.screen)
        result.append(contentsOf: repeatElement(UInt8(0), count: 6))
        return result
    }
    static func event(tag: UInt8, payload: Data) throws -> PagedTerminalEvent? {
        switch tag {
        case 1: return .output(payload)
        case 27:
            guard payload.count > 24, payload.count <= PagedTerminalLimits.readyBytes + 24,
                  payload.le(0, 8) != 0, payload.le(8, 8) != 0,
                  payload.le(16, 2) > 0, payload.le(18, 2) > 0 else { throw PagedZmxAttachEngine.Error.unsupported }
            return .checkpoint(.init(incarnation: payload.le(0, 8), id: payload.le(8, 8),
                cols: UInt16(payload.le(16, 2)), rows: UInt16(payload.le(18, 2)), ready: Data(payload.dropFirst(24)),
                hasPrimaryHistory: payload[20] & 1 != 0, hasAlternateHistory: payload[20] & 2 != 0))
        case 29, 30:
            guard payload.count >= 40 else { throw PagedZmxAttachEngine.Error.invalidFrame }
            let request = PagedTerminalHistoryRequest(incarnation: payload.le(0, 8), checkpointID: payload.le(8, 8),
                requestID: payload.le(16, 8), ordinal: payload.le(24, 8), screen: UInt16(payload.le(32, 2)))
            guard request.screen < 2 else { throw PagedZmxAttachEngine.Error.invalidFrame }
            if tag == 30 {
                guard payload.count == 41, payload[40] < 4 else { throw PagedZmxAttachEngine.Error.invalidFrame }
                let reasons: [PagedTerminalHistoryFailure.Reason] = [.expired, .incompatible, .limit, .unavailable]
                return .unavailable(.init(request: request, reason: reasons[Int(payload[40])]))
            }
            guard payload.count >= 48, payload.count <= PagedTerminalLimits.pageBytes + 48,
                  payload[40] <= 1 else { throw PagedZmxAttachEngine.Error.invalidFrame }
            return .page(.init(incarnation: request.incarnation, checkpointID: request.checkpointID,
                requestID: request.requestID, ordinal: request.ordinal, screen: request.screen,
                data: Data(payload.dropFirst(48)), complete: payload[40] == 1))
        case 31:
            guard payload.count == 4 else { throw PagedZmxAttachEngine.Error.invalidFrame }
            return .grid(cols: UInt16(payload.le(2, 2)), rows: UInt16(payload.le(0, 2)))
        case 32:
            guard payload.count == 4 else { throw PagedZmxAttachEngine.Error.invalidFrame }
            return .ended(Int32(bitPattern: UInt32(payload.le(0, 4))))
        default: return nil
        }
    }
}

extension Data {
    fileprivate func le(_ offset: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + offset + $1]) << (8 * $1) }
    }
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
