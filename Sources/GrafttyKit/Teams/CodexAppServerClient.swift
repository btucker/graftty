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
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["app-server", "proxy", "--sock", socketPath]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexAppServerClientError.subprocessLaunchFailed(String(describing: error))
        }

        let deadline = Date().addingTimeInterval(timeout)
        let stdinFD = stdin.fileHandleForWriting.fileDescriptor
        try setNoSigPipe(stdinFD)
        try makeNonBlocking(stdinFD)
        let reader = CodexAppServerJSONLineReader(fd: stdout.fileHandleForReading.fileDescriptor)
        defer {
            cleanup(process: process, stdin: stdin, stdout: stdout)
        }

        try sendRequest(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "graftty", "version": clientVersion()],
            ]],
            to: stdinFD,
            deadline: deadline
        )
        _ = try resultObject(
            from: readResponse(reader: reader, deadline: deadline, expectedID: 1, method: "initialize"),
            method: "initialize"
        )

        try sendRequest(
            ["jsonrpc": "2.0", "method": "initialized"],
            to: stdinFD,
            deadline: deadline
        )

        try sendRequest(
            ["jsonrpc": "2.0", "id": 2, "method": "thread/loaded/list", "params": ["limit": 10]],
            to: stdinFD,
            deadline: deadline
        )
        let loadedResult = try resultObject(
            from: readResponse(reader: reader, deadline: deadline, expectedID: 2, method: "thread/loaded/list"),
            method: "thread/loaded/list"
        )
        let threadID = try exactlyOneLoadedThreadID(from: loadedResult)

        try sendRequest(
            ["jsonrpc": "2.0", "id": 3, "method": "thread/read", "params": [
                "threadId": threadID,
                "includeTurns": false,
            ]],
            to: stdinFD,
            deadline: deadline
        )
        let readResult = try resultObject(
            from: readResponse(reader: reader, deadline: deadline, expectedID: 3, method: "thread/read"),
            method: "thread/read"
        )
        try requireCWD(expectedCWD, in: readResult)

        try sendRequest(
            ["jsonrpc": "2.0", "id": 4, "method": "turn/start", "params": [
                "threadId": threadID,
                "cwd": expectedCWD,
                "input": [["type": "text", "text": message]],
            ]],
            to: stdinFD,
            deadline: deadline
        )
        try requireNoRPCError(
            in: readResponse(reader: reader, deadline: deadline, expectedID: 4, method: "turn/start"),
            method: "turn/start"
        )

        try? stdin.fileHandleForWriting.close()
        return CodexAppServerDeliveryResult(threadID: threadID)
    }
    #endif

    private func sendRequest(_ object: [String: Any], to fd: Int32, deadline: Date) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try writeAll(data + Data([0x0A]), to: fd, deadline: deadline)
        } catch let error as CodexAppServerClientError {
            throw error
        } catch {
            throw CodexAppServerClientError.writeFailed(String(describing: error))
        }
    }

    private func writeAll(_ data: Data, to fd: Int32, deadline: Date) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                try waitForWritable(fd: fd, deadline: deadline)
                let pointer = baseAddress.advanced(by: offset)
                let count = Darwin.write(fd, pointer, data.count - offset)
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

    private func waitForWritable(fd: Int32, deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CodexAppServerClientError.writeTimedOut
            }
            let timeoutMilliseconds = max(1, Int32((remaining * 1000).rounded(.up)))
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
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
        reader: CodexAppServerJSONLineReader,
        deadline: Date,
        expectedID: Int,
        method: String
    ) throws -> [String: Any] {
        while true {
            let response = try parseResponseLine(try reader.readLine(deadline: deadline))
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

    private func parseResponseLine(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8) else {
            throw CodexAppServerClientError.invalidResponse("response was not UTF-8")
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let response = object as? [String: Any] else {
                throw CodexAppServerClientError.invalidResponse("response was not a JSON object")
            }
            guard response["jsonrpc"] as? String == "2.0" else {
                throw CodexAppServerClientError.invalidResponse("response missing jsonrpc 2.0")
            }
            return response
        } catch let error as CodexAppServerClientError {
            throw error
        } catch {
            throw CodexAppServerClientError.invalidResponse("response was not valid JSON: \(line)")
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

    private func exactlyOneLoadedThreadID(from result: [String: Any]) throws -> String {
        guard let data = result["data"] as? [Any] else {
            throw CodexAppServerClientError.invalidResponse("thread/loaded/list result missing data array")
        }
        let threadIDs = data.compactMap { $0 as? String }
        guard threadIDs.count == data.count else {
            throw CodexAppServerClientError.invalidResponse("thread/loaded/list data contained non-string thread ids")
        }
        guard threadIDs.count == 1, let threadID = threadIDs.first else {
            throw CodexAppServerClientError.loadedThreadCount(threadIDs.count)
        }
        return threadID
    }

    private func requireCWD(_ expectedCWD: String, in result: [String: Any]) throws {
        guard let thread = result["thread"] as? [String: Any] else {
            throw CodexAppServerClientError.missingThreadCWD
        }
        guard let actualCWD = thread["cwd"] as? String else {
            throw CodexAppServerClientError.missingThreadCWD
        }
        guard actualCWD == expectedCWD else {
            throw CodexAppServerClientError.cwdMismatch(expected: expectedCWD, actual: actualCWD)
        }
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
    case readFailed(String)
    case invalidResponse(String)
    case mismatchedResponseID(method: String, expected: Int, actual: Int)
    case jsonRPCError(method: String, message: String)
    case loadedThreadCount(Int)
    case missingThreadCWD
    case cwdMismatch(expected: String, actual: String)

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
            "Codex app-server proxy timed out waiting for a JSON-RPC response."
        case .closed:
            "Codex app-server proxy closed before sending a JSON-RPC response."
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
        }
    }
}

private final class CodexAppServerJSONLineReader {
    private let fd: Int32
    private var buffer: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
    }

    func readLine(deadline: Date) throws -> String {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineBytes = Array(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                guard let line = String(bytes: lineBytes, encoding: .utf8) else {
                    throw CodexAppServerClientError.invalidResponse("response line was not UTF-8")
                }
                return line
            }

            try waitForReadable(deadline: deadline)

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk.prefix(count))
            } else if count == 0 {
                throw CodexAppServerClientError.closed
            } else if errno != EINTR {
                throw CodexAppServerClientError.readFailed(String(cString: strerror(errno)))
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
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
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
}
