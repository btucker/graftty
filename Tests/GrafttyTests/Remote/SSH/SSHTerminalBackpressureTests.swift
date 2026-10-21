import CryptoKit
import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

@Suite("SSH terminal backpressure over encrypted channels", .timeLimit(.minutes(1)))
struct SSHTerminalBackpressureTests {
    enum AttachmentAbort: CaseIterable, Sendable { case close, cancellation }
    enum AttachmentPhase: CaseIterable, Sendable, Equatable { case childConfirmation, shellFactory }

    @Test("@spec REMOTE-9.15: When an SSH terminal attachment closes or is canceled before shell acknowledgement, the application shall fail the pending connection and close its child channel without disconnecting the shared transport.", arguments: AttachmentAbort.allCases, AttachmentPhase.allCases)
    func attachmentAbortCompletesBeforeShellAcknowledgement(abort: AttachmentAbort, phase: AttachmentPhase) async throws {
        let fixture = try await SSHBackpressureFixture.make(stalling: phase)
        do {
            switch abort {
            case .close: fixture.client.close()
            case .cancellation: fixture.cancelConnection()
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while (fixture.probe.connection.value == nil || (phase == .shellFactory && !fixture.probe.childClosed)),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            // Inspect before releasing the factory. Releasing it during cleanup
            // lets the old acknowledgement-only implementation finish safely.
            #expect(fixture.probe.connection.value != nil)
            if phase == .shellFactory { #expect(fixture.probe.childClosed) }
            #expect(fixture.clientParent.isActive)
            #expect(fixture.serverParent.isActive)
            fixture.releaseAttach()
            try await fixture.wait(for: "aborted connection completion") {
                fixture.probe.connection.value != nil
            }
            switch try #require(fixture.probe.connection.value) {
            case .success: Issue.record("An aborted terminal attachment connected successfully")
            case .failure(let error):
                if case .cancellation = abort { #expect(error is CancellationError) }
            }
            fixture.client.close()
            // Before OPEN_CONFIRMATION, the client cannot address the server's
            // channel ID. The late confirmed child must close after release.
            try await fixture.wait(for: "aborted server child cleanup") { fixture.probe.childClosed }
            if phase == .shellFactory {
                try await fixture.wait(for: "deferred factory cleanup") { fixture.stream.wasClosed }
            }
            #expect(fixture.clientParent.isActive)
            #expect(fixture.serverParent.isActive)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func stalledViewerOverflowClosesOnlyItsTerminalChannel() async throws {
        let fixture = try await SSHBackpressureFixture.make()
        do {
            // One bounded producer frame becomes 513 SSH output slices. The
            // viewer does not receive until its 8 MiB budget has overflowed.
            try fixture.stream.emit(Data(repeating: 0x61, count: 8 * 1024 * 1024 + 16 * 1024))
            try await fixture.wait(for: "overflow channel cleanup") {
                fixture.probe.childClosed && fixture.stream.wasClosed
            }
            let received = SSHBackpressureResult<Void>()
            let receiver = Task {
                do {
                    _ = try await fixture.client.receive()
                    received.complete(.success(()))
                }
                catch { received.complete(.failure(error)) }
            }
            defer { receiver.cancel() }
            try await fixture.wait(for: "overflow receive failure") { received.value != nil }
            switch try #require(received.value) {
            case .failure(TerminalSessionClient.ClientError.receiveBufferOverflow): break
            case .failure(let error): Issue.record("Expected receiveBufferOverflow, got \(error)")
            case .success: Issue.record("A stalled viewer received output after overflow")
            }
            await receiver.value
            #expect(fixture.clientParent.isActive)
            #expect(fixture.serverParent.isActive)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }

    @Test func terminalEOFDrainsFinalBytesBeforeExitStatus() async throws {
        let fixture = try await SSHBackpressureFixture.make()
        do {
            // Cross several SSH writes and the receive batch boundary, using
            // a changing pattern so missing or reordered slices are visible.
            let expected = Data((0..<(256 * 1024 + 3)).map {
                UInt8(truncatingIfNeeded: ($0 / 16384) ^ ($0 % 251))
            })
            try fixture.stream.emit(expected)
            fixture.stream.finish()
            try await fixture.wait(for: "EOF channel cleanup") {
                fixture.probe.childClosed && fixture.stream.wasClosed
            }

            let received = SSHBackpressureResult<(Data, Int)>()
            let receiver = Task {
                var bytes = Data()
                do {
                    while true {
                        switch try await fixture.client.receive() {
                        case .binary(let chunk):
                            guard bytes.count + chunk.count <= expected.count else {
                                throw SSHBackpressureFailure("unexpected extra terminal output")
                            }
                            bytes.append(chunk)
                        case .text:
                            throw SSHBackpressureFailure("unexpected terminal control frame")
                        }
                    }
                } catch TerminalSessionClient.ClientError.sessionEnded(let status) {
                    received.complete(.success((bytes, status)))
                } catch {
                    received.complete(.failure(error))
                }
            }
            defer { receiver.cancel() }
            try await fixture.wait(for: "final bytes and exit status") { received.value != nil }
            let (bytes, status) = try #require(received.value).get()
            await receiver.value
            #expect(bytes == expected)
            #expect(status == 0)
            #expect(fixture.clientParent.isActive)
            #expect(fixture.serverParent.isActive)
        } catch {
            await fixture.close()
            throw error
        }
        await fixture.close()
    }
}

private final class SSHBackpressureFixture: @unchecked Sendable {
    let clientParent = NIOAsyncTestingChannel()
    let serverParent = NIOAsyncTestingChannel()
    let stream = SSHBackpressureStream()
    let probe = SSHBackpressureProbe()
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ssh-terminal-backpressure-\(UUID().uuidString)")
    private let deadline = ContinuousClock.now + .seconds(25)
    private let attachGate: SSHBackpressureAttachGate?
    private let childConfirmationGate: SSHBackpressureChildGate?
    private var pump: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var connecting: Task<Void, Never>?
    private(set) var client: TerminalSessionClient!

    private init(stalling phase: SSHTerminalBackpressureTests.AttachmentPhase?) {
        attachGate = phase == .shellFactory ? SSHBackpressureAttachGate() : nil
        childConfirmationGate = phase == .childConfirmation ? SSHBackpressureChildGate() : nil
    }

    static func make(stalling phase: SSHTerminalBackpressureTests.AttachmentPhase? = nil) async throws -> SSHBackpressureFixture {
        let fixture = SSHBackpressureFixture(stalling: phase)
        do {
            try await fixture.start()
            return fixture
        } catch {
            await fixture.close()
            throw error
        }
    }

    private func start() async throws {
        let serverKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let store = TrustedPeerStore(directory: directory)
        let peer = SSHUserAuthTestSupport.makePeer(key: clientKey, kind: .mac)
        try store.add(peer)
        let stream = self.stream
        let probe = self.probe
        let attachGate = self.attachGate
        let childConfirmationGate = self.childConfirmationGate
        let serverHandler = SSHBackpressureHandlerBox(handler: SSHServerSetup.makeHandler(
            hostKey: serverKey, trustedPeerStore: store, allocator: serverParent.allocator,
            inboundChildChannelInitializer: { child, type in
                guard case .session = type else {
                    return child.eventLoop.makeFailedFuture(SSHBackpressureFailure("unexpected SSH channel type"))
                }
                child.closeFuture.whenComplete { _ in probe.markChildClosed() }
                let installed = child.pipeline.addHandler(TerminalSessionHandler(
                    streamFactory: { _ in
                        await attachGate?.wait()
                        return stream
                    },
                    ownershipStore: SessionDisplayOwnershipStore(),
                    ownershipBroadcaster: DisplayOwnershipBroadcaster(), deviceID: peer.id
                ))
                guard let childConfirmationGate else { return installed }
                let ready = child.eventLoop.makePromise(of: Void.self)
                childConfirmationGate.hold(ready)
                return installed.flatMap { ready.futureResult }
            }
        ))
        let clientHandler = SSHBackpressureHandlerBox(handler: SSHClientSetup.makeHandler(
            clientKey: clientKey,
            expectedHostFingerprint: .init(of: try RemoteIdentityPublicKey(rawRepresentation: serverKey.publicKey.rawRepresentation)),
            allocator: clientParent.allocator
        ))
        try await serverParent.testingEventLoop.executeInContext {
            try self.serverParent.pipeline.syncOperations.addHandler(serverHandler.handler)
        }
        try await clientParent.testingEventLoop.executeInContext {
            try self.clientParent.pipeline.syncOperations.addHandler(clientHandler.handler)
            try self.clientParent.pipeline.syncOperations.addHandler(SSHBackpressureAuthenticationRelay(probe: probe))
        }
        try await serverParent.connect(to: .init(unixDomainSocketPath: "/tmp/ssh-backpressure-server")).get()
        try await clientParent.connect(to: .init(unixDomainSocketPath: "/tmp/ssh-backpressure-client")).get()
        let clientParent = self.clientParent
        let serverParent = self.serverParent
        pump = Task {
            do {
                while !Task.isCancelled {
                    await clientParent.testingEventLoop.run()
                    await serverParent.testingEventLoop.run()
                    while let bytes = try await clientParent.readOutbound(as: IOData.self) {
                        try Task.checkCancellation()
                        try await serverParent.writeInbound(bytes)
                    }
                    while let bytes = try await serverParent.readOutbound(as: IOData.self) {
                        try Task.checkCancellation()
                        try await clientParent.writeInbound(bytes)
                    }
                    try await Task.sleep(for: .milliseconds(1))
                }
            } catch {
                if !Task.isCancelled { probe.fail(error) }
            }
        }
        let deadline = self.deadline
        watchdog = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            probe.fail(SSHBackpressureFailure("SSH loopback watchdog expired"))
            clientParent.close(promise: nil)
            serverParent.close(promise: nil)
        }
        try await wait(for: "authentication") { probe.authenticated }
        let client = TerminalSessionClient(parentChannel: clientParent,
            parentHandler: clientHandler.handler, sessionName: "backpressure")
        self.client = client
        connecting = Task {
            do { try await client.connect(); probe.connection.complete(.success(())) }
            catch { probe.connection.complete(.failure(error)) }
        }
        // Shell acknowledgement has no production timeout. Poll its result so
        // an acknowledgement regression cannot hold this test open forever.
        if let childConfirmationGate {
            try await wait(for: "SSH child initializer entry") { childConfirmationGate.entered }
        } else if let attachGate {
            try await wait(for: "terminal factory entry") { attachGate.entered }
        } else {
            try await wait(for: "terminal shell acknowledgement") { probe.connection.value != nil }
            try #require(probe.connection.value).get()
        }
    }

    func cancelConnection() { connecting?.cancel() }
    func releaseAttach() {
        attachGate?.release()
        childConfirmationGate?.release()
    }

    func wait(for phase: String, until condition: () -> Bool) async throws {
        while !condition() {
            if let error = probe.failure { throw error }
            guard ContinuousClock.now < deadline else {
                throw SSHBackpressureFailure("Timed out waiting for \(phase)")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        if let error = probe.failure { throw error }
    }

    func close() async {
        watchdog?.cancel()
        releaseAttach()
        client?.close()
        stream.finish()
        connecting?.cancel()
        clientParent.close(promise: nil)
        serverParent.close(promise: nil)
        await clientParent.testingEventLoop.run()
        await serverParent.testingEventLoop.run()
        pump?.cancel()
        await pump?.value
        _ = try? await clientParent.finish()
        _ = try? await serverParent.finish()
        // A completed setup task can be joined. An unacknowledged shell task
        // may ignore cancellation, so cleanup must not await it indefinitely.
        if probe.connection.value != nil { await connecting?.value }
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class SSHBackpressureStream: GrafttyKit.TerminalByteStream, @unchecked Sendable {
    let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closed = false
    var wasClosed: Bool { lock.withLock { closed } }

    init() {
        let pair = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(1))
        inboundBytes = pair.stream
        continuation = pair.continuation
    }

    func emit(_ data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 + 16 * 1024,
              case .enqueued = continuation.yield(data) else {
            throw SSHBackpressureFailure("bounded terminal fixture rejected output")
        }
    }

    func send(_ bytes: Data) async throws {}
    func finish() { continuation.finish() }
    func close() async {
        lock.withLock { closed = true }
        continuation.finish()
    }
}

private final class SSHBackpressureAttachGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                didEnter = true
                if released { continuation.resume() }
                else { waiter = continuation }
            }
        }
    }

    func release() {
        let waiter = lock.withLock {
            released = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }
}

private final class SSHBackpressureChildGate: @unchecked Sendable {
    private let lock = NSLock()
    private var promise: EventLoopPromise<Void>?
    private var released = false
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }

    func hold(_ promise: EventLoopPromise<Void>) {
        let releaseImmediately = lock.withLock {
            didEnter = true
            guard !released else { return true }
            self.promise = promise
            return false
        }
        if releaseImmediately { promise.succeed(()) }
    }

    func release() {
        let promise = lock.withLock {
            released = true
            defer { self.promise = nil }
            return self.promise
        }
        promise?.succeed(())
    }
}

private final class SSHBackpressureResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    var value: Result<Value, Error>? { lock.withLock { result } }
    func complete(_ result: Result<Value, Error>) { lock.withLock { self.result = result } }
}

private final class SSHBackpressureProbe: @unchecked Sendable {
    let connection = SSHBackpressureResult<Void>()
    private let lock = NSLock()
    private var didAuthenticate = false
    private var didCloseChild = false
    private var error: Error?
    var authenticated: Bool { lock.withLock { didAuthenticate } }
    var childClosed: Bool { lock.withLock { didCloseChild } }
    var failure: Error? { lock.withLock { error } }
    func markAuthenticated() { lock.withLock { didAuthenticate = true } }
    func markChildClosed() { lock.withLock { didCloseChild = true } }
    func fail(_ error: Error) { lock.withLock { if self.error == nil { self.error = error } } }
}

private final class SSHBackpressureAuthenticationRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let probe: SSHBackpressureProbe
    init(probe: SSHBackpressureProbe) { self.probe = probe }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { probe.markAuthenticated() }
        context.fireUserInboundEventTriggered(event)
    }
}

private struct SSHBackpressureHandlerBox: @unchecked Sendable {
    let handler: NIOSSHHandler
}

private struct SSHBackpressureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
