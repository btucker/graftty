import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("ChannelRouter — multiplexes channel frames + dispatches to handlers by type.")
struct ChannelRouterTests {

    @Test
    func openRegistersHandlerAndDispatchesPayload() async throws {
        let pair = FakePair()
        let alice = ChannelRouter(transport: pair.aliceSide)
        let bob = ChannelRouter(transport: pair.bobSide)
        await alice.start()
        await bob.start()

        let recorder = RecordingHandler(channelType: "terminal")
        await bob.register(type: "terminal") { recorder }

        let aliceHandler = RecordingHandler(channelType: "terminal")
        let id = try await alice.open(type: "terminal", handler: aliceHandler)
        #expect(id == ChannelID(1))

        // Allow the open frame to ride across the fake transport
        try await pollUntil(timeout: .seconds(2)) {
            await recorder.opened
        }
    }

    @Test
    func payloadFrameReachesRegisteredHandler() async throws {
        let pair = FakePair()
        let alice = ChannelRouter(transport: pair.aliceSide)
        let bob = ChannelRouter(transport: pair.bobSide)
        await alice.start()
        await bob.start()

        let bobRecorder = RecordingHandler(channelType: "panes_state")
        await bob.register(type: "panes_state") { bobRecorder }

        let aliceHandler = RecordingHandler(channelType: "panes_state")
        let id = try await alice.open(type: "panes_state", handler: aliceHandler)
        try await pollUntil(timeout: .seconds(2)) { await bobRecorder.opened }

        // Use Alice's outbox to send a payload frame on the channel she opened.
        let outbox = try #require(await aliceHandler.outbox)
        try await outbox.send(.payload(ChannelPayload(id: id), Data([0x42, 0x43])))
        try await pollUntil(timeout: .seconds(2)) { await bobRecorder.lastPayload == Data([0x42, 0x43]) }
    }

    @Test
    func openForUnregisteredTypeReturnsErrorFrame() async throws {
        let pair = FakePair()
        let alice = ChannelRouter(transport: pair.aliceSide)
        let bob = ChannelRouter(transport: pair.bobSide)
        await alice.start()
        await bob.start()

        let aliceHandler = RecordingHandler(channelType: "unknown_type")
        _ = try await alice.open(type: "unknown_type", handler: aliceHandler)

        try await pollUntil(timeout: .seconds(2)) {
            await aliceHandler.lastErrorCode == "channel-type-unknown"
        }
    }

    @Test
    func closeFrameNotifiesHandlerAndRemovesEntry() async throws {
        let pair = FakePair()
        let alice = ChannelRouter(transport: pair.aliceSide)
        let bob = ChannelRouter(transport: pair.bobSide)
        await alice.start()
        await bob.start()

        let bobRecorder = RecordingHandler(channelType: "terminal")
        await bob.register(type: "terminal") { bobRecorder }

        let aliceHandler = RecordingHandler(channelType: "terminal")
        let id = try await alice.open(type: "terminal", handler: aliceHandler)
        try await pollUntil(timeout: .seconds(2)) { await bobRecorder.opened }

        try await alice.close(id)
        try await pollUntil(timeout: .seconds(2)) { await bobRecorder.closed }
        try await pollUntil(timeout: .seconds(2)) { await aliceHandler.closed }
    }
}

/// In-process bidirectional fake `ChannelTransport`. Each side's `send`
/// puts the bytes on the other side's `onReceive`.
private final class FakePair: Sendable {
    let aliceSide: AliceTransport
    let bobSide: BobTransport
    init() {
        let aliceToBob = FakeBridge()
        let bobToAlice = FakeBridge()
        self.aliceSide = AliceTransport(out: aliceToBob, in: bobToAlice)
        self.bobSide = BobTransport(out: bobToAlice, in: aliceToBob)
    }
}

private actor FakeBridge {
    var subscriber: (@Sendable (Data) async -> Void)?
    func subscribe(_ s: @escaping @Sendable (Data) async -> Void) { subscriber = s }
    func publish(_ data: Data) async { await subscriber?(data) }
}

private struct AliceTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
    }
}

private struct BobTransport: ChannelTransport {
    let out: FakeBridge
    let `in`: FakeBridge
    func send(_ data: Data) async throws { await out.publish(data) }
    func onReceive(_ handler: @escaping @Sendable (Data) async -> Void) async {
        await `in`.subscribe(handler)
    }
}

private actor RecordingHandler: ChannelHandler {
    nonisolated let channelType: String
    var opened = false
    var closed = false
    var lastPayload: Data?
    var lastErrorCode: String?
    var outbox: ChannelOutbox?

    init(channelType: String) {
        self.channelType = channelType
    }

    func onOpen(_ id: ChannelID, outbox: ChannelOutbox) async {
        self.opened = true
        self.outbox = outbox
    }

    func onPayload(_ data: Data) async {
        self.lastPayload = data
    }

    func onClose() async {
        self.closed = true
    }

    func onError(_ code: String, message: String) async {
        self.lastErrorCode = code
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
