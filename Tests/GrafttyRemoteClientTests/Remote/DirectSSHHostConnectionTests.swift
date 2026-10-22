#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GrafttyProtocol
import NIOCore
import NIOPosix
import Testing
@testable import GrafttyRemoteClient

struct DirectSSHHostConnectionTests {
    @Test("@spec REMOTE-20.15: When a direct SSH connection dials its host, the application shall run the connection on NIO's shared event loop group rather than starting an event-loop thread per connection.", .timeLimit(.minutes(1)))
    func dialsOnSharedEventLoopGroup() async throws {
        let host = try await SilentSSHHost.start()
        let (connection, dial) = host.dial()
        let loop = await connection.awaitTransportEventLoop()

        let sharedLoops = Array(MultiThreadedEventLoopGroup.singleton.makeIterator())
        #expect(sharedLoops.contains { $0 === loop })

        await connection.close()
        _ = await dial.result
        try await host.stop()
    }

    @Test("@spec REMOTE-20.16: If a direct SSH connection is closed while it is still waiting for authentication, then the pending connect shall fail and return rather than wait forever.", .timeLimit(.minutes(1)))
    func closeDuringAuthenticationEndsConnect() async throws {
        let host = try await SilentSSHHost.start()
        let (connection, dial) = host.dial()
        #expect(await connection.awaitTransportEventLoop() != nil)

        await connection.close()

        // A regression parks `connect` on a future that never completes; fail
        // instead of hanging the run. The bound only elapses on that failure.
        let result = try #require(await outcome(of: dial, within: .seconds(5)), "connect never returned after close")
        #expect(throws: (any Error).self) { try result.get() }
        #expect(await connection.state == .closed)
        try await host.stop()
    }
}

/// Accepts TCP but never answers the SSH handshake, parking a client between
/// TCP connect and authentication.
private struct SilentSSHHost {
    let server: any Channel

    static func start() async throws -> SilentSSHHost {
        SilentSSHHost(server: try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get())
    }

    func dial() -> (DirectSSHHostConnection, Task<Void, any Error>) {
        let hostKey = try! RemoteIdentityPublicKey(
            rawRepresentation: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        )
        let connection = DirectSSHHostConnection(
            clientKey: Curve25519.Signing.PrivateKey(),
            expectedHostFingerprint: RemoteIdentityFingerprint(of: hostKey)
        )
        let port = server.localAddress!.port!
        return (connection, Task { try await connection.connect(host: "127.0.0.1", port: port) })
    }

    func stop() async throws { try await server.close() }
}

private extension DirectSSHHostConnection {
    /// Suspends until TCP is connected (or the dial has already failed).
    func awaitTransportEventLoop() async -> (any EventLoop)? {
        while transportEventLoopForTesting == nil, !state.isTerminal { await Task.yield() }
        return transportEventLoopForTesting
    }
}

/// The task's result, or nil if it is still running after `limit`. The task
/// is left running: a NIO future it awaits ignores cancellation.
private func outcome<Success>(
    of task: Task<Success, any Error>, within limit: Duration
) async -> Result<Success, any Error>? {
    let gate = FirstResume<Result<Success, any Error>?>()
    return await withCheckedContinuation { (continuation: CheckedContinuation<Result<Success, any Error>?, Never>) in
        gate.install(continuation)
        let timer = Task<Void, Never> {
            try? await Task<Never, Never>.sleep(for: limit)
            gate.resume(nil)
        }
        Task<Void, Never> {
            gate.resume(await task.result)
            timer.cancel()
        }
    }
}

/// Resumes a continuation with whichever value arrives first.
private final class FirstResume<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    func install(_ continuation: CheckedContinuation<Value, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: Value) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}
