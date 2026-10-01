import CryptoKit
import Foundation
import GrafttyKit
import GrafttyProtocol
import Testing
@testable import GrafttyHostAgent
@testable import GrafttyRemoteClient

@Suite("Negotiated WebRTC bulk transport", .serialized)
struct WebRTCBulkTransportTests {
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
            if case .text(let checkpoint) = try await foreground.receive() {
                guard case .checkpoint = try PagedTerminalEnvelope.parse(checkpoint).event else {
                    Issue.record("expected checkpoint"); throw BulkTestError.unexpected
                }
            } else { Issue.record("expected checkpoint text") }
            if enabled {
                let boundDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !foreground.hasHistoryChannelForTesting, ContinuousClock.now < boundDeadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                #expect(foreground.hasHistoryChannelForTesting)
            }
            let request = PagedTerminalHistoryRequest(incarnation: 1, checkpointID: 2, requestID: 3, ordinal: 0, screen: 0)
            try await foreground.send(.text(try PagedTerminalEnvelope(request: .history(request)).encoded()))
            if case .text(let page) = try await foreground.receive() {
                guard case .page(let value) = try PagedTerminalEnvelope.parse(page).event else {
                    Issue.record("expected history page"); throw BulkTestError.unexpected
                }
                #expect(value.data == Data([1, 2, 3]))
            } else { Issue.record("expected history text") }
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
