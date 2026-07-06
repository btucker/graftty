import Darwin
import Dispatch
import Foundation

public struct CodexAppServerDeliveryResult: Sendable, Equatable {
    public let threadID: String

    public init(threadID: String) {
        self.threadID = threadID
    }
}

public protocol CodexAppServerClienting: Sendable {
    func deliver(
        binaryPath: String,
        socketPath: String,
        expectedCWD: String,
        message: String
    ) async throws -> CodexAppServerDeliveryResult
}

public struct CodexAppServerClient: CodexAppServerClienting, Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 5.0) {
        self.timeout = timeout
    }

    public func deliver(
        binaryPath: String,
        socketPath: String,
        expectedCWD: String,
        message: String
    ) async throws -> CodexAppServerDeliveryResult {
        #if os(macOS)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try deliverOnMacOS(
                        binaryPath: binaryPath,
                        socketPath: socketPath,
                        expectedCWD: expectedCWD,
                        message: message
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        #else
        throw CodexAppServerClientError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
    private func deliverOnMacOS(
        binaryPath: String,
        socketPath: String,
        expectedCWD: String,
        message: String
    ) throws -> CodexAppServerDeliveryResult {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderrCapture = CodexAppServerProxyStderrCapture.make()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server", "proxy", "--sock", socketPath]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderrCapture?.fileHandle ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            stderrCapture?.closeAndRemove()
            throw CodexAppServerClientError.subprocessLaunchFailed(String(describing: error))
        }
        defer {
            cleanup(process: process, stdin: stdin, stdout: stdout)
            stderrCapture?.closeAndRemove()
        }

        let deadline = Date().addingTimeInterval(timeout)
        let stdinFD = stdin.fileHandleForWriting.fileDescriptor
        try setNoSigPipe(stdinFD)
        try makeNonBlocking(stdinFD)
        let connection = CodexAppServerWebSocketConnection(
            inputFD: stdinFD,
            outputFD: stdout.fileHandleForReading.fileDescriptor
        )
        do {
            try connection.performHandshake(deadline: deadline)

            try sendRequest(
                ["id": 1, "method": "initialize", "params": [
                    "clientInfo": ["name": "graftty", "version": clientVersion()],
                ]],
                to: connection,
                deadline: deadline
            )
            _ = try resultObject(
                from: readResponse(connection: connection, deadline: deadline, expectedID: 1, method: "initialize"),
                method: "initialize"
            )

            try sendRequest(
                ["method": "initialized"],
                to: connection,
                deadline: deadline
            )

            var nextRequestID = 2
            let threadIDs = try loadedThreadIDs(
                connection: connection,
                deadline: deadline,
                nextRequestID: &nextRequestID
            )
            let threadID = try matchingLoadedThreadID(
                from: threadIDs,
                expectedCWD: expectedCWD,
                connection: connection,
                deadline: deadline,
                nextRequestID: &nextRequestID
            )

            try sendRequest(
                ["id": nextRequestID, "method": "turn/start", "params": [
                    "threadId": threadID,
                    "cwd": expectedCWD,
                    "input": [["type": "text", "text": message]],
                ]],
                to: connection,
                deadline: deadline
            )
            try requireNoRPCError(
                in: readResponse(connection: connection, deadline: deadline, expectedID: nextRequestID, method: "turn/start"),
                method: "turn/start"
            )

            return CodexAppServerDeliveryResult(threadID: threadID)
        } catch let error as CodexAppServerClientError {
            throw error.appendingProxyStderr(stderrCapture?.contents())
        }
    }
    #endif

    private func sendRequest(
        _ object: [String: Any],
        to connection: CodexAppServerWebSocketConnection,
        deadline: Date
    ) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let text = String(data: data, encoding: .utf8) else {
                throw CodexAppServerClientError.writeFailed("request was not UTF-8")
            }
            try connection.sendText(text, deadline: deadline)
        } catch let error as CodexAppServerClientError {
            throw error
        } catch {
            throw CodexAppServerClientError.writeFailed(String(describing: error))
        }
    }

    #if os(macOS)
    private func setNoSigPipe(_ fd: Int32) throws {
        guard fcntl(fd, F_SETNOSIGPIPE, 1) >= 0 else {
            throw CodexAppServerClientError.writeFailed(String(cString: strerror(errno)))
        }
    }
    #endif

    private func makeNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw CodexAppServerClientError.writeFailed(String(cString: strerror(errno)))
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw CodexAppServerClientError.writeFailed(String(cString: strerror(errno)))
        }
    }

    private func readResponse(
        connection: CodexAppServerWebSocketConnection,
        deadline: Date,
        expectedID: Int,
        method: String
    ) throws -> [String: Any] {
        while true {
            let response = try parseResponseText(try connection.readText(deadline: deadline))
            guard let id = responseID(response) else {
                if response["method"] is String {
                    continue
                }
                throw CodexAppServerClientError.invalidResponse("\(method) response missing id")
            }
            guard id == expectedID else {
                throw CodexAppServerClientError.mismatchedResponseID(method: method, expected: expectedID, actual: id)
            }
            return response
        }
    }

    private func parseResponseText(_ text: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8) else {
            throw CodexAppServerClientError.invalidResponse("response was not UTF-8")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let response = object as? [String: Any] else {
                throw CodexAppServerClientError.invalidResponse("response was not a JSON object")
            }
            return response
        } catch let error as CodexAppServerClientError {
            throw error
        } catch {
            throw CodexAppServerClientError.invalidResponse("response was not valid JSON: \(text)")
        }
    }

    private func responseID(_ response: [String: Any]) -> Int? {
        if let id = response["id"] as? Int {
            return id
        }
        if let id = response["id"] as? NSNumber {
            return id.intValue
        }
        return nil
    }

    private func resultObject(from response: [String: Any], method: String) throws -> [String: Any] {
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(describing: error)
            throw CodexAppServerClientError.jsonRPCError(method: method, message: message)
        }
        guard let result = response["result"] as? [String: Any] else {
            throw CodexAppServerClientError.invalidResponse("\(method) response missing result object")
        }
        return result
    }

    private func requireNoRPCError(in response: [String: Any], method: String) throws {
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? String(describing: error)
            throw CodexAppServerClientError.jsonRPCError(method: method, message: message)
        }
        guard response.keys.contains("result") else {
            throw CodexAppServerClientError.invalidResponse("\(method) response missing result")
        }
    }

    private func loadedThreadIDs(
        connection: CodexAppServerWebSocketConnection,
        deadline: Date,
        nextRequestID: inout Int
    ) throws -> [String] {
        var cursor: String?
        var threadIDs: [String] = []
        repeat {
            let requestID = nextRequestID
            nextRequestID += 1
            var params: [String: Any] = ["limit": 100]
            if let cursor {
                params["cursor"] = cursor
            }
            try sendRequest(
                ["id": requestID, "method": "thread/loaded/list", "params": params],
                to: connection,
                deadline: deadline
            )
            let result = try resultObject(
                from: readResponse(
                    connection: connection,
                    deadline: deadline,
                    expectedID: requestID,
                    method: "thread/loaded/list"
                ),
                method: "thread/loaded/list"
            )
            threadIDs.append(contentsOf: try loadedThreadIDs(from: result))
            cursor = nextCursor(from: result)
        } while cursor != nil

        guard !threadIDs.isEmpty else {
            throw CodexAppServerClientError.loadedThreadCount(0)
        }
        return threadIDs
    }

    private func loadedThreadIDs(from result: [String: Any]) throws -> [String] {
        guard let data = result["data"] as? [Any] else {
            throw CodexAppServerClientError.invalidResponse("thread/loaded/list result missing data array")
        }
        let threadIDs = data.compactMap { $0 as? String }
        guard threadIDs.count == data.count else {
            throw CodexAppServerClientError.invalidResponse("thread/loaded/list data contained non-string thread ids")
        }
        return threadIDs
    }

    private func nextCursor(from result: [String: Any]) -> String? {
        for key in ["nextCursor", "next_cursor"] {
            if let cursor = result[key] as? String, !cursor.isEmpty {
                return cursor
            }
        }
        return nil
    }

    private func matchingLoadedThreadID(
        from threadIDs: [String],
        expectedCWD: String,
        connection: CodexAppServerWebSocketConnection,
        deadline: Date,
        nextRequestID: inout Int
    ) throws -> String {
        var actualCWDs: [String] = []
        var matchingThreadIDs: [String] = []
        for threadID in threadIDs {
            let requestID = nextRequestID
            nextRequestID += 1
            try sendRequest(
                ["id": requestID, "method": "thread/read", "params": [
                    "threadId": threadID,
                    "includeTurns": false,
                ]],
                to: connection,
                deadline: deadline
            )
            let readResult = try resultObject(
                from: readResponse(
                    connection: connection,
                    deadline: deadline,
                    expectedID: requestID,
                    method: "thread/read"
                ),
                method: "thread/read"
            )
            let actualCWD = try threadCWD(in: readResult)
            if actualCWD == expectedCWD {
                matchingThreadIDs.append(threadID)
            } else {
                actualCWDs.append(actualCWD)
            }
        }
        if matchingThreadIDs.count == 1 {
            return matchingThreadIDs[0]
        }
        if matchingThreadIDs.count > 1 {
            throw CodexAppServerClientError.multipleLoadedThreadsMatchingCWD(
                expected: expectedCWD,
                count: matchingThreadIDs.count
            )
        }
        if threadIDs.count == 1, let actual = actualCWDs.first {
            throw CodexAppServerClientError.cwdMismatch(expected: expectedCWD, actual: actual)
        }
        throw CodexAppServerClientError.noLoadedThreadMatchingCWD(
            expected: expectedCWD,
            count: threadIDs.count
        )
    }

    private func threadCWD(in result: [String: Any]) throws -> String {
        guard let thread = result["thread"] as? [String: Any] else {
            throw CodexAppServerClientError.missingThreadCWD
        }
        guard let actualCWD = thread["cwd"] as? String else {
            throw CodexAppServerClientError.missingThreadCWD
        }
        return actualCWD
    }

    private func clientVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    #if os(macOS)
    private func cleanup(process: Process, stdin: Pipe, stdout: Pipe) {
        try? stdin.fileHandleForWriting.close()
        try? stdout.fileHandleForReading.close()
        guard process.isRunning else { return }

        process.terminate()
        if waitForExit(process: process, timeout: 0.2) {
            return
        }

        kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(process: process, timeout: 0.5)
    }

    private func waitForExit(process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(10_000)
        }
        return !process.isRunning
    }
    #endif
}

private enum CodexAppServerClientError: Error, Equatable, CustomStringConvertible {
    case unsupportedPlatform
    case subprocessLaunchFailed(String)
    case writeFailed(String)
    case writeTimedOut
    case timeout
    case closed
    case closedWithStderr(String)
    case readFailed(String)
    case invalidResponse(String)
    case mismatchedResponseID(method: String, expected: Int, actual: Int)
    case jsonRPCError(method: String, message: String)
    case loadedThreadCount(Int)
    case missingThreadCWD
    case cwdMismatch(expected: String, actual: String)
    case noLoadedThreadMatchingCWD(expected: String, count: Int)
    case multipleLoadedThreadsMatchingCWD(expected: String, count: Int)

    var description: String {
        switch self {
        case .unsupportedPlatform:
            "Codex app-server delivery is only supported on macOS."
        case .subprocessLaunchFailed(let detail):
            "Codex app-server proxy failed to launch: \(detail)"
        case .writeFailed(let detail):
            "Codex app-server proxy write failed: \(detail)"
        case .writeTimedOut:
            "Codex app-server proxy write timed out."
        case .timeout:
            "Codex app-server proxy timed out waiting for a response."
        case .closed:
            "Codex app-server proxy closed before sending a response."
        case .closedWithStderr(let detail):
            "Codex app-server proxy closed before sending a response: \(detail)"
        case .readFailed(let detail):
            "Codex app-server proxy read failed: \(detail)"
        case .invalidResponse(let detail):
            "Codex app-server proxy returned an invalid response: \(detail)"
        case .mismatchedResponseID(let method, let expected, let actual):
            "Codex app-server \(method) response id mismatch: expected id \(expected), got \(actual)."
        case .jsonRPCError(let method, let message):
            "Codex app-server \(method) JSON-RPC error: \(message)"
        case .loadedThreadCount(let count):
            "Codex app-server expected exactly one loaded thread, got \(count)."
        case .missingThreadCWD:
            "Codex app-server thread/read response missing thread cwd."
        case .cwdMismatch(let expected, let actual):
            "Codex app-server thread cwd mismatch: expected \(expected), got \(actual)."
        case .noLoadedThreadMatchingCWD(let expected, let count):
            "Codex app-server found no loaded thread for cwd \(expected) among \(count) loaded threads."
        case .multipleLoadedThreadsMatchingCWD(let expected, let count):
            "Codex app-server found \(count) loaded threads for cwd \(expected); refusing ambiguous delivery."
        }
    }

    func appendingProxyStderr(_ stderr: String?) -> CodexAppServerClientError {
        guard case .closed = self,
              let stderr,
              !stderr.isEmpty
        else {
            return self
        }
        return .closedWithStderr(stderr)
    }
}

private final class CodexAppServerProxyStderrCapture {
    let fileHandle: FileHandle
    private let url: URL

    private init(fileHandle: FileHandle, url: URL) {
        self.fileHandle = fileHandle
        self.url = url
    }

    static func make() -> CodexAppServerProxyStderrCapture? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-proxy-stderr-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return CodexAppServerProxyStderrCapture(fileHandle: fileHandle, url: url)
    }

    func contents() -> String? {
        try? fileHandle.synchronize()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return nil
        }
        let capped = data.count > 4096 ? Data(data.suffix(4096)) : data
        let text = String(decoding: capped, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func closeAndRemove() {
        try? fileHandle.close()
        try? FileManager.default.removeItem(at: url)
    }
}

private final class CodexAppServerWebSocketConnection {
    private let inputFD: Int32
    private let outputFD: Int32
    private var buffer: [UInt8] = []

    init(inputFD: Int32, outputFD: Int32) {
        self.inputFD = inputFD
        self.outputFD = outputFD
    }

    func performHandshake(deadline: Date) throws {
        let request = """
        GET /rpc HTTP/1.1\r
        Host: localhost\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(Self.webSocketKey())\r
        Sec-WebSocket-Version: 13\r
        \r

        """
        try writeAll(Data(request.utf8), deadline: deadline)
        let response = try readHTTPHeader(deadline: deadline)
        guard response.hasPrefix("HTTP/1.1 101 ") || response.hasPrefix("HTTP/1.0 101 ") else {
            throw CodexAppServerClientError.invalidResponse("websocket upgrade failed: \(response)")
        }
    }

    func sendText(_ text: String, deadline: Date) throws {
        try sendFrame(opcode: 0x1, payload: [UInt8](text.utf8), deadline: deadline)
    }

    func readText(deadline: Date) throws -> String {
        try readMessageText(deadline: deadline)
    }

    private func readMessageText(deadline: Date) throws -> String {
        var fragments: [UInt8]?
        while true {
            let frame = try readFrame(deadline: deadline)
            switch frame.opcode {
            case 0x0:
                guard fragments != nil else {
                    throw CodexAppServerClientError.invalidResponse("websocket continuation frame without text frame")
                }
                fragments?.append(contentsOf: frame.payload)
                if frame.fin {
                    return try decodeText(fragments ?? [])
                }
            case 0x1:
                guard fragments == nil else {
                    throw CodexAppServerClientError.invalidResponse("websocket text frame interrupted fragmented message")
                }
                if frame.fin {
                    return try decodeText(frame.payload)
                }
                fragments = frame.payload
            case 0x8:
                throw CodexAppServerClientError.closed
            case 0x9:
                try sendFrame(opcode: 0xA, payload: frame.payload, deadline: deadline)
            case 0xA:
                continue
            default:
                continue
            }
        }
    }

    private func decodeText(_ payload: [UInt8]) throws -> String {
        guard let text = String(bytes: payload, encoding: .utf8) else {
            throw CodexAppServerClientError.invalidResponse("websocket text frame was not UTF-8")
        }
        return text
    }

    private func readHTTPHeader(deadline: Date) throws -> String {
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        while true {
            if let end = buffer.firstRange(of: terminator)?.upperBound {
                let headerBytes = Array(buffer[..<end])
                buffer.removeSubrange(..<end)
                guard let header = String(bytes: headerBytes, encoding: .utf8) else {
                    throw CodexAppServerClientError.invalidResponse("websocket upgrade response was not UTF-8")
                }
                return header
            }
            try readMore(deadline: deadline)
        }
    }

    private func readFrame(deadline: Date) throws -> WebSocketFrame {
        let header = try readExact(2, deadline: deadline)
        let fin = header[0] & 0x80 != 0
        let opcode = header[0] & 0x0F
        let isMasked = header[1] & 0x80 != 0
        var length = UInt64(header[1] & 0x7F)
        if length == 126 {
            length = UInt64(Self.bigEndianUInt16(try readExact(2, deadline: deadline)))
        } else if length == 127 {
            length = Self.bigEndianUInt64(try readExact(8, deadline: deadline))
        }
        guard length <= UInt64(Int.max) else {
            throw CodexAppServerClientError.invalidResponse("websocket frame was too large")
        }
        let mask = isMasked ? try readExact(4, deadline: deadline) : []
        var payload = try readExact(Int(length), deadline: deadline)
        if isMasked {
            payload = payload.enumerated().map { index, byte in
                byte ^ mask[index % mask.count]
            }
        }
        return WebSocketFrame(fin: fin, opcode: opcode, payload: payload)
    }

    private func readExact(_ count: Int, deadline: Date) throws -> [UInt8] {
        while buffer.count < count {
            try readMore(deadline: deadline)
        }
        let bytes = Array(buffer.prefix(count))
        buffer.removeSubrange(..<count)
        return bytes
    }

    private func readMore(deadline: Date) throws {
        try waitForReadable(deadline: deadline)
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(outputFD, &chunk, chunk.count)
        if count > 0 {
            buffer.append(contentsOf: chunk.prefix(count))
        } else if count == 0 {
            throw CodexAppServerClientError.closed
        } else if errno != EINTR {
            throw CodexAppServerClientError.readFailed(String(cString: strerror(errno)))
        }
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8], deadline: Date) throws {
        var frame: [UInt8] = [0x80 | opcode]
        appendClientPayloadLength(payload.count, to: &frame)
        var mask = [UInt8](repeating: 0, count: 4)
        arc4random_buf(&mask, mask.count)
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { index, byte in
            byte ^ mask[index % mask.count]
        })
        try writeAll(Data(frame), deadline: deadline)
    }

    private func appendClientPayloadLength(_ length: Int, to frame: inout [UInt8]) {
        if length < 126 {
            frame.append(0x80 | UInt8(length))
        } else if length <= 65_535 {
            frame.append(0x80 | 126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(0x80 | 127)
            let value = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
    }

    private func writeAll(_ data: Data, deadline: Date) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                try waitForWritable(deadline: deadline)
                let pointer = baseAddress.advanced(by: offset)
                let count = Darwin.write(inputFD, pointer, data.count - offset)
                if count > 0 {
                    offset += count
                } else if count == 0 {
                    throw CodexAppServerClientError.writeTimedOut
                } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                    continue
                } else if errno == EPIPE {
                    throw CodexAppServerClientError.writeFailed("stdin pipe closed")
                } else {
                    throw CodexAppServerClientError.writeFailed(String(cString: strerror(errno)))
                }
            }
        }
    }

    private func waitForWritable(deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CodexAppServerClientError.writeTimedOut
            }
            let timeoutMilliseconds = max(1, Int32((remaining * 1000).rounded(.up)))
            var descriptor = pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0)
            let result = poll(&descriptor, 1, timeoutMilliseconds)
            if result > 0 {
                if descriptor.revents & Int16(POLLOUT) != 0 {
                    return
                }
                throw CodexAppServerClientError.writeFailed("stdin pipe is no longer writable")
            }
            if result == 0 {
                throw CodexAppServerClientError.writeTimedOut
            }
            if errno != EINTR {
                throw CodexAppServerClientError.writeFailed(String(cString: strerror(errno)))
            }
        }
    }

    private func waitForReadable(deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CodexAppServerClientError.timeout
            }
            let timeoutMilliseconds = max(1, Int32((remaining * 1000).rounded(.up)))
            var descriptor = pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, timeoutMilliseconds)
            if result > 0 {
                return
            }
            if result == 0 {
                throw CodexAppServerClientError.timeout
            }
            if errno != EINTR {
                throw CodexAppServerClientError.readFailed(String(cString: strerror(errno)))
            }
        }
    }

    private static func webSocketKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        return Data(bytes).base64EncodedString()
    }

    private static func bigEndianUInt16(_ bytes: [UInt8]) -> UInt16 {
        (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    private static func bigEndianUInt64(_ bytes: [UInt8]) -> UInt64 {
        bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private struct WebSocketFrame {
        let fin: Bool
        let opcode: UInt8
        let payload: [UInt8]
    }
}
