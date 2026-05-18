import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("TerminalChannelHandler — handles attach handshake, bridges PTY bytes both ways, cleans up on close.")
struct TerminalChannelHandlerTests {

    @Test
    func firstFrameAttachesToSessionAndForwardsOutboundBytes() async throws {
        let fakeStream = FakeTerminalByteStream()
        let factory: TerminalByteStreamFactory = { name in
            #expect(name == "test-session")
            return fakeStream
        }
        let handler = TerminalChannelHandler(factory: factory)
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(1), outbox: outboxSpy.outbox)

        let meta = try JSONEncoder().encode(TerminalChannelOpenMeta(sessionName: "test-session"))
        await handler.onPayload(meta)

        // After attach, the handler subscribes to stream.inboundBytes —
        // emit some and expect them as outbound payload frames.
        fakeStream.emit(Data([0x68, 0x69]))  // "hi"
        fakeStream.emit(Data([0x0A]))         // "\n"

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 2 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let first) = frames[0] else {
            Issue.record("expected payload frame")
            return
        }
        #expect(first == Data([0x68, 0x69]))
    }

    @Test
    func subsequentPayloadFramesAreForwardedAsInboundBytes() async throws {
        let fakeStream = FakeTerminalByteStream()
        let handler = TerminalChannelHandler(factory: { _ in fakeStream })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(2), outbox: outboxSpy.outbox)
        await handler.onPayload(try JSONEncoder().encode(TerminalChannelOpenMeta(sessionName: "s")))

        let keystroke = Data([0x65])  // "e"
        await handler.onPayload(keystroke)

        try await pollUntil(timeout: .seconds(2)) { fakeStream.sent == [keystroke] }
    }

    @Test
    func malformedAttachReturnsErrorFrame() async throws {
        let factoryCalls = FactoryCallTracker()
        let factory: TerminalByteStreamFactory = { name in
            await factoryCalls.record(name)
            return FakeTerminalByteStream()
        }
        let handler = TerminalChannelHandler(factory: factory)
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(3), outbox: outboxSpy.outbox)

        await handler.onPayload(Data("not-json".utf8))

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }
        let frames = await outboxSpy.frames
        guard case .error(let err) = frames[0] else {
            Issue.record("expected error frame, got \(frames[0])")
            return
        }
        #expect(err.code == "malformed-attach")
        #expect(await factoryCalls.callCount == 0)
    }

    @Test
    func closeCancelsOutboundTaskAndClosesStream() async throws {
        let fakeStream = FakeTerminalByteStream()
        let handler = TerminalChannelHandler(factory: { _ in fakeStream })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(4), outbox: outboxSpy.outbox)
        await handler.onPayload(try JSONEncoder().encode(TerminalChannelOpenMeta(sessionName: "s")))

        await handler.onClose()
        try await pollUntil(timeout: .seconds(2)) { fakeStream.isClosed }
    }
}

/// Thread-safe fake. Outbound bytes are delivered via an `AsyncStream`
/// driven by `emit(_:)`; inbound bytes (keystrokes from the channel)
/// are appended to `sent`.
private final class FakeTerminalByteStream: TerminalByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [Data] = []
    private var _isClosed = false
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init() {
        var c: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c = $0 }
        self.continuation = c
    }

    var sent: [Data] {
        lock.lock(); defer { lock.unlock() }
        return _sent
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isClosed
    }

    func send(_ bytes: Data) async throws {
        lock.withLock { _sent.append(bytes) }
    }

    func emit(_ bytes: Data) {
        continuation.yield(bytes)
    }

    func close() async {
        lock.withLock { _isClosed = true }
        continuation.finish()
    }
}

private actor OutboxSpy {
    var frames: [ChannelFrame] = []
    var framesCount: Int { frames.count }

    nonisolated var outbox: ChannelOutbox {
        ChannelOutbox { [weak self] frame in
            await self?.append(frame)
        }
    }

    func append(_ frame: ChannelFrame) {
        frames.append(frame)
    }
}

private actor FactoryCallTracker {
    private(set) var callCount = 0
    private(set) var names: [String] = []

    func record(_ name: String) {
        callCount += 1
        names.append(name)
    }
}

private struct PollTimeout: Error, CustomStringConvertible {
    let timeout: Duration
    var description: String { "pollUntil timed out after \(timeout)" }
}

private func pollUntil(
    timeout: Duration,
    interval: Duration = .milliseconds(20),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: interval)
    }
    throw PollTimeout(timeout: timeout)
}
