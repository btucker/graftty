import CryptoKit
import Foundation
import GrafttyKit
import GrafttyProtocol
import NIOCore
import NIOSSH
import Testing
@testable import GrafttyHostAgent
@testable import GrafttyRemoteClient

@Suite("Negotiated WebRTC bulk transport", .serialized)
struct WebRTCBulkTransportTests {
    @Test("@spec REMOTE-11.28: When a remote connection closes, the client shall finish closing its SSH transports before closing the peer connection, and concurrent close callers shall await the same teardown.", .timeLimit(.minutes(1)))
    func closeWaitsForTransportTeardown() async throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrustedPeerStore(directory: dir)
        let peer = TrustedPeer(id: .init(value: "ordered-close"), kind: .mac,
            publicKey: try .init(rawRepresentation: clientKey.publicKey.rawRepresentation),
            displayName: "test", capabilities: .defaultsAfterPairing, pairedAt: Date(), lastSeenAt: nil)
        try store.add(peer)
        let host = WebRTCHostAgent(hostKey: hostKey, trustedPeerStore: store,
            streamFactory: { _ in LegacyBulkEchoStream() }, pagedFactory: { _ in BulkEchoStream() },
            panesStateSubscribe: { _ in .init(cancel: {}) }, paneControlMutator: { _ in fatalError("not used") },
            displayOwnershipStore: SessionDisplayOwnershipStore())
        let client = RemoteHostConnection(clientKey: clientKey, expectedHostFingerprint: .init(
            of: try .init(rawRepresentation: hostKey.publicKey.rawRepresentation)))
        do {
            let offer = try await client.createOffer()
            let answer = try await host.acceptOffer(offer, clientDeviceID: peer.id)
            try await client.applyAnswer(answer)
            let deadline = ContinuousClock.now + .seconds(5)
            while await !client.hasBulkTransportForTesting, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let bulk = try #require(await client.bulkTransportForTesting)
            let primary = try #require(await client.sshTransportForTesting)
            let gate = TransportCloseGate()
            defer { gate.release() }
            bulk.eventLoop.execute { gate.wait() }
            let enteredDeadline = ContinuousClock.now + .seconds(1)
            while !gate.hasEntered, ContinuousClock.now < enteredDeadline { await Task.yield() }
            #expect(gate.hasEntered)
            let first = Task { await client.close(); gate.recordReturn() }
            let second = Task { await client.close(); gate.recordReturn() }
            let observationDeadline = ContinuousClock.now + .milliseconds(150)
            while !gate.hasReturned, ContinuousClock.now < observationDeadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(!gate.hasReturned, "Close must wait while a transport's event loop is still busy")
            #expect(await client.state == .closed, "Logical close must precede asynchronous teardown")
            first.cancel()
            gate.release()
            await first.value
            await second.value
            #expect(!bulk.channel.isActive)
            #expect(!primary.channel.isActive)
            #expect(await client.state == .closed)
            await host.close()
        } catch {
            await client.close()
            await host.close()
            throw error
        }
    }

    @Test("@spec REMOTE-11.27: If an optional history channel cannot open before its deadline, then the application shall preserve the active terminal and deliver history over its primary channel.", .timeLimit(.minutes(1)))
    func stalledHistoryOpenPreservesTerminal() async throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrustedPeerStore(directory: dir)
        let peer = TrustedPeer(id: .init(value: "stalled-history"), kind: .mac,
            publicKey: try .init(rawRepresentation: clientKey.publicKey.rawRepresentation),
            displayName: "test", capabilities: .defaultsAfterPairing, pairedAt: Date(), lastSeenAt: nil)
        try store.add(peer)
        let host = WebRTCHostAgent(hostKey: hostKey, trustedPeerStore: store,
            streamFactory: { _ in LegacyBulkEchoStream() }, pagedFactory: { _ in BulkEchoStream() },
            panesStateSubscribe: { _ in .init(cancel: {}) },
            paneControlMutator: { _ in fatalError("not used") },
            displayOwnershipStore: SessionDisplayOwnershipStore())
        let client = RemoteHostConnection(clientKey: clientKey, expectedHostFingerprint: .init(
            of: try .init(rawRepresentation: hostKey.publicKey.rawRepresentation)))
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            historyFallbackStage("[history-fallback] watchdog closing client")
            await client.close()
            historyFallbackStage("[history-fallback] watchdog closing host")
            await host.close()
        }
        defer { deadline.cancel() }
        do {
            let offer = try await client.createOffer()
            let answer = try await host.acceptOffer(offer, clientDeviceID: peer.id)
            try await client.applyAnswer(answer)
            let readyDeadline = ContinuousClock.now + .seconds(5)
            while await !client.hasBulkTransportForTesting, ContinuousClock.now < readyDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            let bulk = try #require(await client.bulkTransportForTesting)
            try await bulk.channel.eventLoop.submit {
                let pipeline = bulk.channel.pipeline.syncOperations
                let ssh = try pipeline.handler(type: NIOSSHHandler.self)
                try pipeline.addHandler(HistoryOpenBlackhole(), position: .before(ssh))
            }.get()
            let terminal = try await client.openTerminalSession(sessionName: "foreground", preferPaged: true)
            historyFallbackStage("[history-fallback] opened terminal")
            defer { terminal.close() }
            _ = try await terminal.receive() // Initial checkpoint uses the primary channel.
            historyFallbackStage("[history-fallback] received checkpoint")
            // Exercise the real five-second open deadline, then verify the
            // same terminal still carries both output and history.
            try await Task.sleep(for: .seconds(6))
            try await terminal.send(.binary(Data("still-live".utf8)))
            #expect(try await terminal.receive() == .binary(Data("still-live".utf8)))
            historyFallbackStage("[history-fallback] received live echo")
            let request = PagedTerminalHistoryRequest(incarnation: 1, checkpointID: 2,
                requestID: 3, ordinal: 0, screen: 0)
            try await terminal.send(.text(try PagedTerminalEnvelope(request: .history(request)).encoded()))
            guard case .paged(.page(let page)) = try await terminal.receive() else {
                throw BulkTestError.unexpected
            }
            #expect(page.data == Data([1, 2, 3]))
            historyFallbackStage("[history-fallback] received history")
            #expect(await client.state == .connected)
            historyFallbackStage("[history-fallback] closing client")
            await client.close()
            historyFallbackStage("[history-fallback] closed client; closing host")
            await host.close()
            historyFallbackStage("[history-fallback] closed host")
        } catch {
            await client.close()
            await host.close()
            throw error
        }
    }

    @Test("@spec REMOTE-11.17: When both peers support bulk transport, the client shall authenticate a second ordered WebRTC channel for background traffic; if the host rejects negotiation, the client shall retain the legacy transport.",
          .timeLimit(.minutes(1)), arguments: [true, false])
    func negotiatesAndFallsBack(enabled: Bool) async throws {
        let hostKey = Curve25519.Signing.PrivateKey()
        let clientKey = Curve25519.Signing.PrivateKey()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TrustedPeerStore(directory: dir)
        let peer = TrustedPeer(
            id: RemoteDeviceID(value: "bulk-test"), kind: .ipad,
            publicKey: try RemoteIdentityPublicKey(rawRepresentation: clientKey.publicKey.rawRepresentation),
            displayName: "test", capabilities: .defaultsAfterPairing, pairedAt: Date(), lastSeenAt: nil
        )
        try store.add(peer)
        let host = WebRTCHostAgent(
            hostKey: hostKey, trustedPeerStore: store, streamFactory: { _ in LegacyBulkEchoStream() }, pagedFactory: { _ in BulkEchoStream() },
            panesStateSubscribe: { _ in .init(cancel: {}) },
            paneControlMutator: { _ in fatalError("not used") },
            displayOwnershipStore: SessionDisplayOwnershipStore()
        )
        await host.setBulkTransportEnabledForTesting(enabled)
        let client = RemoteHostConnection(clientKey: clientKey, expectedHostFingerprint: .init(
            of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation)))
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await client.close()
            await host.close()
        }
        defer { deadline.cancel() }
        do {
            let offer = try await client.createOffer()
            let answer = try await host.acceptOffer(offer, clientDeviceID: peer.id)
            try await client.applyAnswer(answer)
            let foreground = try await client.openTerminalSession(sessionName: "foreground", preferPaged: true)
            let background = try await client.openTerminalSession(sessionName: "preview", background: true)
            guard case .paged(.checkpoint) = try await foreground.receive() else {
                throw BulkTestError.unexpected
            }
            if enabled {
                let boundDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !foreground.hasHistoryChannelForTesting, ContinuousClock.now < boundDeadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(foreground.hasHistoryChannelForTesting)
            }
            let request = PagedTerminalHistoryRequest(incarnation: 1, checkpointID: 2, requestID: 3, ordinal: 0, screen: 0)
            try await foreground.send(.text(try PagedTerminalEnvelope(request: .history(request)).encoded()))
            guard case .paged(.page(let value)) = try await foreground.receive() else {
                throw BulkTestError.unexpected
            }
            #expect(value.data == Data([1, 2, 3]))
            #expect(await client.hasBulkTransportForTesting == enabled)
            #expect(host.activeRemotePeers.entries.count == (enabled ? 2 : 1))
            for terminal in [foreground, background] {
                try await terminal.send(.binary(Data("hello".utf8)))
                #expect(try await terminal.receive() == .binary(Data("hello".utf8)))
                terminal.close()
            }
            if enabled {
                let bulk = try #require(await client.bulkTransportForTesting)
                await bulk.close()
                let closedDeadline = ContinuousClock.now.advanced(by: .seconds(1))
                while await client.hasBulkTransportForTesting, ContinuousClock.now < closedDeadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let surviving = try await client.openTerminalSession(sessionName: "after-bulk-close")
                try await surviving.send(.binary(Data("still-live".utf8)))
                #expect(try await surviving.receive() == .binary(Data("still-live".utf8)))
                surviving.close()
            }
            await host.close()
            await client.close()
            #expect(await client.hasBulkTransportForTesting == false)
        } catch {
            await client.close()
            await host.close()
            throw error
        }
    }
}

private final class HistoryOpenBlackhole: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        promise?.succeed(())
    }
}
private enum BulkTestError: Error { case unexpected }
private final class BulkEchoStream: GrafttyKit.TerminalByteStream, PagedTerminalStream, @unchecked Sendable {
    let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    let events: AsyncStream<PagedTerminalEvent>
    private let paged: AsyncStream<PagedTerminalEvent>.Continuation
    init() {
        (inboundBytes, continuation) = AsyncStream.makeStream()
        (events, paged) = AsyncStream.makeStream()
        paged.yield(.checkpoint(.init(incarnation: 1, id: 2, cols: 80, rows: 24,
            ready: Data([1]), hasPrimaryHistory: true, hasAlternateHistory: false)))
    }
    func send(_ bytes: Data) async throws { continuation.yield(bytes); paged.yield(.output(bytes)) }
    func close() async { continuation.finish(); paged.finish() }
    func requestCheckpoint() async throws {}
    func requestHistory(_ request: PagedTerminalHistoryRequest) async throws {
        paged.yield(.page(.init(incarnation: request.incarnation, checkpointID: request.checkpointID,
            requestID: request.requestID, ordinal: request.ordinal, screen: request.screen,
            data: Data([1, 2, 3]), complete: true)))
    }
}

private final class LegacyBulkEchoStream: GrafttyKit.TerminalByteStream, @unchecked Sendable {
    let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    init() { (inboundBytes, continuation) = AsyncStream.makeStream() }
    func send(_ bytes: Data) async throws { continuation.yield(bytes) }
    func close() async { continuation.finish() }
}

private func historyFallbackStage(_ message: String) {
    // Keep the last completed phase even if native shutdown blocks forever.
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private final class TransportCloseGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    private var returned = false
    var hasEntered: Bool { lock.withLock { entered } }
    var hasReturned: Bool { lock.withLock { returned } }
    func recordReturn() { lock.withLock { returned = true } }
    func wait() {
        lock.withLock { entered = true }
        _ = semaphore.wait(timeout: .now() + 2)
    }
    func release() { semaphore.signal() }
}
