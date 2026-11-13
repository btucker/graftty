import CryptoKit
import CTailcat
import Darwin
import Foundation
import GrafttyProtocol
import GrafttyRemoteClient

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
    static func perform<T: Sendable>(_ body: @escaping @Sendable (tc_token) throws -> T) async throws -> T {
        var allocated: tc_token = 0
        try check(tc_token_new(30_000_000_000, &allocated, nil))
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

public final class TailcatPeer: @unchecked Sendable {
    private let resource: Resource
    private init(_ handle: tc_handle) { resource = Resource(handle) }

    public static func server() throws -> TailcatPeer {
        guard tc_abi_version() == 1 else { throw TailcatFailure.incompatibleABI }
        var handle: tc_handle = 0
        var json = Array("{}".utf8CString)
        try Runtime.check(json.withUnsafeMutableBufferPointer { tc_server_new($0.baseAddress, &handle, nil) })
        return TailcatPeer(handle)
    }

    fileprivate static func client(address: String) throws -> TailcatPeer {
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

    fileprivate func dial(port: UInt16) async throws -> TailcatPipe {
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
        try await Runtime.perform { [self] token in
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
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var enabled: Int32 = 1
        for socket in sockets {
            _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
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
        pumps.notify(queue: Runtime.workers) { [socket] in Darwin.close(socket) }
    }
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        // shutdown interrupts both local I/O calls. Close the descriptor only
        // after both workers exit, so a recycled descriptor cannot be touched.
        _ = shutdown(socket, SHUT_RDWR)
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
                    let result = Darwin.write(socket, bytes.baseAddress!.advanced(by: sent), count - sent)
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
            let count = buffer.withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) }
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

public final class TailcatSSHConnection: @unchecked Sendable {
    public let ssh: DirectSSHHostConnection
    private let peer: TailcatPeer
    private let pipe: TailcatPipe
    private init(ssh: DirectSSHHostConnection, peer: TailcatPeer, pipe: TailcatPipe) {
        self.ssh = ssh; self.peer = peer; self.pipe = pipe
    }
    public static func connect(address: String, port: UInt16, key: Curve25519.Signing.PrivateKey,
                               fingerprint: RemoteIdentityFingerprint) async throws -> TailcatSSHConnection {
        let peer = try TailcatPeer.client(address: address)
        let pipe: TailcatPipe
        do { pipe = try await peer.dial(port: port) }
        catch { await peer.close(); throw error }
        let ssh = DirectSSHHostConnection(clientKey: key, expectedHostFingerprint: fingerprint)
        do {
            try await ssh.connect(input: pipe.file, output: pipe.file)
            try pipe.file.close()
            try Task.checkCancellation()
            return TailcatSSHConnection(ssh: ssh, peer: peer, pipe: pipe)
        } catch {
            await ssh.close(); await pipe.close(); await peer.close()
            throw error
        }
    }
    public func routeKind() async throws -> String { try await peer.routeKind() }
    public func close() async {
        await ssh.close(); await pipe.close(); await peer.close()
    }
}
