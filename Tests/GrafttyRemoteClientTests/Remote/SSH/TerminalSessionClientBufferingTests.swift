import CryptoKit
import Foundation
import GrafttyProtocol
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing
@testable import GrafttyRemoteClient

@Suite("@spec REMOTE-9.14: When an SSH terminal receiver cancels or disconnects, the application shall release its pending receive work and discarded output, reject output after closure, and preserve final output before a deliberate remote exit.", .timeLimit(.minutes(1)))
struct TerminalSessionClientBufferingTests {
    @Test func overflowDisconnectsAndReleasesQueuedBytes() async throws {
        let (client, channel) = try await makeClient()
        defer { client.close(); channel.close(promise: nil) }
        // Distinct allocations model a stalled viewer, with only 8 MiB + 8 KiB input.
        for _ in 0..<1025 { client.deliverInboundBinary(Data(repeating: 0x61, count: 8192)) }
        #expect(client.bufferedByteCountForTesting == 0)
        do {
            _ = try await client.receive()
            Issue.record("Expected explicit overflow failure")
        } catch TerminalSessionClient.ClientError.receiveBufferOverflow {}
        client.deliverInboundBinary(Data([1]))
        #expect(client.bufferedByteCountForTesting == 0)
    }

    @Test func explicitAndAbruptCloseDiscardOutput() async throws {
        let (client, channel) = try await makeClient()
        defer { channel.close(promise: nil) }
        client.deliverInboundBinary(Data([1, 2, 3]))
        client.deliverInboundText("grid")
        client.close()
        #expect(client.bufferedByteCountForTesting == 0)
        await #expect(throws: (any Error).self) { _ = try await client.receive() }
        client.deliverInboundText("late")
        #expect(client.bufferedByteCountForTesting == 0)
        let (abrupt, otherChannel) = try await makeClient()
        defer { otherChannel.close(promise: nil) }
        abrupt.deliverInboundBinary(Data([4]))
        abrupt.handleChildClose()
        #expect(abrupt.bufferedByteCountForTesting == 0)
    }

    @Test func explicitCloseReleasesPayloadStorage() async throws {
        let (client, channel) = try await makeClient()
        defer { channel.close(promise: nil) }
        let released = ReleaseFlag()
        let count = 64 * 1024
        func payload() -> Data {
            let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
            storage.initializeMemory(as: UInt8.self, repeating: 0x61, count: count)
            return Data(bytesNoCopy: storage, count: count, deallocator: .custom { pointer, _ in
                pointer.deallocate()
                released.mark()
            })
        }
        client.deliverInboundBinary(payload())
        #expect(!released.value)
        client.close()
        #expect(released.value)
    }

    @Test func normalExitDrainsOutputInOrder() async throws {
        let (client, channel) = try await makeClient()
        defer { client.close(); channel.close(promise: nil) }
        client.deliverInboundBinary(Data([1, 2]))
        client.deliverInboundText("control")
        client.deliverInboundBinary(Data([3]))
        client.handleSessionEnded(exitStatus: 7)
        client.handleChildClose()
        #expect(try await client.receive() == .binary(Data([1, 2])))
        #expect(try await client.receive() == .text("control"))
        #expect(try await client.receive() == .binary(Data([3])))
        do {
            _ = try await client.receive()
            Issue.record("Expected exit status")
        } catch TerminalSessionClient.ClientError.sessionEnded(let status) {
            #expect(status == 7)
        }
    }

    @Test func canceledWaiterDoesNotConsumeSubsequentOutput() async throws {
        let (client, channel) = try await makeClient()
        defer { client.close(); channel.close(promise: nil) }
        let receiver = Task { try await client.receive() }
        let deadline = ContinuousClock.now + .seconds(2)
        while client.pendingReceiverCountForTesting == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(client.pendingReceiverCountForTesting == 1)
        receiver.cancel()
        await #expect(throws: CancellationError.self) { try await receiver.value }
        #expect(client.pendingReceiverCountForTesting == 0)
        client.deliverInboundBinary(Data([9]))
        #expect(try await client.receive() == .binary(Data([9])))
        let alreadyCanceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.receive()
        }
        await #expect(throws: CancellationError.self) { try await alreadyCanceled.value }
        #expect(client.pendingReceiverCountForTesting == 0)
    }

    @Test func closeResumesAllWaiters() async throws {
        let (client, channel) = try await makeClient()
        defer { channel.close(promise: nil) }
        let receivers = (0..<3).map { _ in Task { try await client.receive() } }
        let deadline = ContinuousClock.now + .seconds(2)
        while client.pendingReceiverCountForTesting < 3 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        client.close()
        for task in receivers { await #expect(throws: (any Error).self) { try await task.value } }
        #expect(client.pendingReceiverCountForTesting == 0)
    }

    private final class ReleaseFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var released = false
        var value: Bool { lock.withLock { released } }
        func mark() { lock.withLock { released = true } }
    }

    private func makeClient() async throws -> (TerminalSessionClient, NIOAsyncTestingChannel) {
        let channel = NIOAsyncTestingChannel()
        let client = try await channel.eventLoop.submit {
            let key = Curve25519.Signing.PrivateKey()
            let publicKey = try RemoteIdentityPublicKey(rawRepresentation: key.publicKey.rawRepresentation)
            let handler = SSHClientSetup.makeHandler(clientKey: key,
                expectedHostFingerprint: .init(of: publicKey), allocator: channel.allocator)
            return TerminalSessionClient(parentChannel: channel, parentHandler: handler, sessionName: "buffer-test")
        }.get()
        return (client, channel)
    }
}
