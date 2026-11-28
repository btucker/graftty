import CTailcat
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Numeric errors deliberately exclude upstream text, which can contain secrets.
public enum TailcatFailure: Error, Sendable {
    case status(Int32)
    case incompatibleABI
    case invalidInfo
}

private enum Runtime {
    static let workers = DispatchQueue.global(qos: .userInitiated)

    static func check(_ status: Int32) throws {
        guard status == TC_OK else { throw TailcatFailure.status(status) }
    }

    // The token exists before cancellation can run. Its close is nonblocking.
    // Buffers and handle owners stay alive until the original C call returns.
    static func perform<T: Sendable>(timeout: Int64 = 30_000_000_000, _ body: @escaping @Sendable (tc_token) throws -> T) async throws -> T {
        var allocated: tc_token = 0
        try check(tc_token_new(timeout, &allocated, nil))
        let token = allocated
        defer { _ = tc_close(token, nil) }
        return try await withTaskCancellationHandler {
            do {
                let value = try await withCheckedThrowingContinuation { continuation in
                    workers.async {
                        do { continuation.resume(returning: try body(token)) }
                        catch { continuation.resume(throwing: error) }
                    }
                }
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            _ = tc_token_cancel(token, nil)
        }
    }
}

private final class Resource: @unchecked Sendable {
    let handle: tc_handle
    init(_ handle: tc_handle) { self.handle = handle }
    func close() async {
        await withCheckedContinuation { continuation in
            Runtime.workers.async { [self] in
                _ = tc_close(handle, nil)
                continuation.resume()
            }
        }
    }
    deinit {
        let handle = handle
        Runtime.workers.async { _ = tc_close(handle, nil) }
    }
}

/// Encoded identities contain both secrets. Store them as credentials.
public struct TailcatServerIdentity: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    fileprivate let private_key: String
    fileprivate let preshared_key: String
    public var description: String { "TailcatServerIdentity(redacted)" }
    public var debugDescription: String { description }

    public static func generate() throws -> Self {
        guard tc_abi_version() == 1 else { throw TailcatFailure.incompatibleABI }
        var output: UnsafeMutablePointer<CChar>?
        try Runtime.check(tc_key_generate(&output, nil))
        defer { tc_free(output) }
        guard let output else { throw TailcatFailure.invalidInfo }
        return try JSONDecoder().decode(Self.self, from: Data(String(cString: output).utf8))
    }
}

public final class TailcatPeer: @unchecked Sendable {
    private let resource: Resource
    private init(_ handle: tc_handle) { resource = Resource(handle) }

    public static func server() throws -> TailcatPeer {
        try server(configuration: "{}")
    }

    public static func server(identity: TailcatServerIdentity, previousAddress: String? = nil) throws -> TailcatPeer {
        guard tc_abi_version() == 1 else { throw TailcatFailure.incompatibleABI }
        guard !identity.private_key.isEmpty, !identity.preshared_key.isEmpty else {
            throw TailcatFailure.invalidInfo
        }
        var configuration: [String: Any] = ["key": identity.private_key, "preshared_key": identity.preshared_key]
        if let previousAddress {
            var address = Array(previousAddress.utf8CString)
            var output: UnsafeMutablePointer<CChar>?
            try Runtime.check(address.withUnsafeMutableBufferPointer { tc_address_parse($0.baseAddress, &output, nil) })
            defer { tc_free(output) }
            guard let output, let metadata = try JSONSerialization.jsonObject(with: Data(String(cString: output).utf8)) as? [String: Any]
            else { throw TailcatFailure.invalidInfo }
            if let region = (metadata["regions"] as? [[String: Any]])?.first {
                configuration["region"] = region
            } else if let id = metadata["region_id"] as? Int, id > 0 {
                configuration["region_id"] = id
            } else { throw TailcatFailure.invalidInfo }
        }
        return try server(configuration: String(decoding: JSONSerialization.data(withJSONObject: configuration), as: UTF8.self))
    }

    private static func server(configuration: String) throws -> TailcatPeer {
        guard tc_abi_version() == 1 else { throw TailcatFailure.incompatibleABI }
        var handle: tc_handle = 0
        var json = Array(configuration.utf8CString)
        try Runtime.check(json.withUnsafeMutableBufferPointer { tc_server_new($0.baseAddress, &handle, nil) })
        return TailcatPeer(handle)
    }

    public static func client(address: String) throws -> TailcatPeer {
        guard tc_abi_version() == 1 else { throw TailcatFailure.incompatibleABI }
        let encoded = try JSONEncoder().encode(["address": address])
        var json = Array(String(decoding: encoded, as: UTF8.self).utf8CString)
        var handle: tc_handle = 0
        try Runtime.check(json.withUnsafeMutableBufferPointer { tc_client_new($0.baseAddress, &handle, nil) })
        return TailcatPeer(handle)
    }

    public func listen(port: UInt16) async throws -> TailcatListener {
        try await Runtime.perform { [self] token in
            var handle: tc_handle = 0
            try Runtime.check(tc_server_listen(resource.handle, token, port, Int32(TC_TCP), &handle, nil))
            return TailcatListener(handle)
        }
    }

    /// Secret connection capability. Never include the returned value in logs.
    public func address() async throws -> String {
        try await Runtime.perform { [self] token in
            var output: UnsafeMutablePointer<CChar>?
            try Runtime.check(tc_info(resource.handle, token, &output, nil))
            defer { tc_free(output) }
            guard let output else { throw TailcatFailure.invalidInfo }
            struct Info: Decodable { let address: String }
            return try JSONDecoder().decode(Info.self, from: Data(String(cString: output).utf8)).address
        }
    }

    public func dial(port: UInt16) async throws -> TailcatPipe {
        try await Runtime.perform { [self] token in
            var handle: tc_handle = 0
            try Runtime.check(tc_client_dial(resource.handle, token, port, Int32(TC_TCP), &handle, nil))
            return try TailcatPipe(handle)
        }
    }

    /// Only the route category is returned, never addresses or keys.
    public func routeKind() async throws -> String {
        try await Runtime.perform { [self] token in
            var output: UnsafeMutablePointer<CChar>?
            try Runtime.check(tc_client_disco_ping(resource.handle, token, &output, nil))
            defer { tc_free(output) }
            guard let output else { throw TailcatFailure.invalidInfo }
            struct Info: Decodable { let endpoint: String? }
            let info = try JSONDecoder().decode(Info.self, from: Data(String(cString: output).utf8))
            return info.endpoint?.isEmpty == false ? "direct" : "relay"
        }
    }

    public func close() async { await resource.close() }
}

/// Keep the owning TailcatPeer alive while using this listener or its streams.
/// Closing or releasing the peer closes the C library's complete resource tree.
public final class TailcatListener: @unchecked Sendable {
    private let resource: Resource
    fileprivate init(_ handle: tc_handle) { resource = Resource(handle) }
    public func accept() async throws -> TailcatPipe {
        try await Runtime.perform(timeout: -1) { [self] token in
            var handle: tc_handle = 0
            try Runtime.check(tc_listener_accept(resource.handle, token, &handle, nil))
            return try TailcatPipe(handle)
        }
    }
}

/// Owns the Swift end of an internal socket pair, not a listening TCP port.
/// The SSH client duplicates this file descriptor and owns its duplicates.
/// After handing duplicates to NIO, close `file` so local SSH closure reaches
/// the bridge. Retain the owning peer until the stream is finished.
public final class TailcatPipe: @unchecked Sendable {
    public let file: FileHandle
    private let bridge: SocketBridge

    fileprivate init(_ handle: tc_handle) throws {
        let resource = Resource(handle)
        var sockets: [Int32] = [-1, -1]
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        #else
        // Atomic close-on-exec: the runner spawns panes constantly, and a
        // child forked before fcntl below could hold a bridge socket open.
        let streamType = Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue)
        #endif
        guard socketpair(AF_UNIX, streamType, 0, &sockets) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for socket in sockets {
            // Linux has no SO_NOSIGPIPE: the bridge sends with MSG_NOSIGNAL
            // instead, and the process ignores SIGPIPE for the SSH side.
            #if canImport(Darwin)
            var enabled: Int32 = 1
            _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            #endif
            _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        }
        file = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
        bridge = SocketBridge(resource: resource, socket: sockets[1])
        bridge.start()
    }

    public func close() async {
        bridge.stop()
        await bridge.join()
        try? file.close()
    }
    deinit { bridge.stop() }
}

// Fixed 32 KiB staging in each direction. Blocking socket I/O applies
// backpressure without growing a Swift queue. This prototype closes the whole
// SSH connection on either EOF; arbitrary TCP half-close is not supported.
private final class SocketBridge: @unchecked Sendable {
    private let resource: Resource
    private let socket: Int32
    private let lock = NSLock()
    private var stopped = false
    private let pumps = DispatchGroup()

    init(resource: Resource, socket: Int32) { self.resource = resource; self.socket = socket }
    func start() {
        pumps.enter()
        pumps.enter()
        Runtime.workers.async { [self] in readTailcat(); stop(); pumps.leave() }
        Runtime.workers.async { [self] in writeTailcat(); stop(); pumps.leave() }
        pumps.notify(queue: Runtime.workers) { [socket] in _ = closeSocket(socket) }
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        // shutdown interrupts both local I/O calls. Close the descriptor only
        // after both workers exit, so a recycled descriptor cannot be touched.
        _ = shutdown(socket, Int32(SHUT_RDWR))
        lock.unlock()
        let handle = resource.handle
        Runtime.workers.async { _ = tc_close(handle, nil) }
    }
    func join() async {
        await withCheckedContinuation { continuation in
            pumps.notify(queue: Runtime.workers) { continuation.resume() }
        }
    }
    private func readTailcat() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            var count = 0
            let status = buffer.withUnsafeMutableBytes {
                tc_conn_read(resource.handle, 0, $0.baseAddress, $0.count, &count, nil)
            }
            // The C ABI can return final bytes together with EOF or an error.
            let delivered = buffer.withUnsafeBytes { bytes -> Bool in
                var sent = 0
                while sent < count {
                    let result = sendSocket(socket, bytes.baseAddress!.advanced(by: sent), count - sent)
                    if result < 0 && errno == EINTR { continue }
                    guard result > 0 else { return false }
                    sent += result
                }
                return true
            }
            if !delivered || status != TC_OK || count == 0 { return }
        }
    }
    private func writeTailcat() {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { readSocket(socket, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            let delivered = buffer.withUnsafeMutableBytes { bytes -> Bool in
                var sent = 0
                while sent < count {
                    var written = 0
                    let status = tc_conn_write(resource.handle, 0, bytes.baseAddress!.advanced(by: sent), count - sent, &written, nil)
                    sent += written
                    guard status == TC_OK, written > 0 else { return false }
                }
                return true
            }
            if !delivered { return }
        }
    }
}

#if canImport(Darwin)
private func closeSocket(_ socket: Int32) -> Int32 { Darwin.close(socket) }
private func readSocket(_ socket: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Darwin.read(socket, buffer, count) }
private func sendSocket(_ socket: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int { Darwin.write(socket, buffer, count) }
#else
private func closeSocket(_ socket: Int32) -> Int32 { Glibc.close(socket) }
private func readSocket(_ socket: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Glibc.read(socket, buffer, count) }
private func sendSocket(_ socket: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    Glibc.send(socket, buffer, count, Int32(MSG_NOSIGNAL))
}
#endif
