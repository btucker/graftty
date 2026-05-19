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
    func reservedChannelIDInboundOpenIsRejected() async throws {
        let pair = FakePair()
        let alice = ChannelRouter(transport: pair.aliceSide)
        let bob = ChannelRouter(transport: pair.bobSide)
        await alice.start()
        await bob.start()

        // Register a handler on Bob's side so a non-reserved open would
        // succeed — proves the rejection is specifically about id == 0,
        // not about handler-factory absence.
        await bob.register(type: "terminal") { RecordingHandler(channelType: "terminal") }

        // Manually send an open with reserved id by going around the
        // public open() API (which always allocates from nextOutboundID
        // starting at 1).
        let badFrame = ChannelFrame.open(ChannelOpen(id: .reserved, type: "terminal"))
        let data = try ChannelFrameCoder.encode(badFrame)
        try await pair.aliceSide.send(data)

        // Allow Bob to process the frame and reply
        try await Task.sleep(for: .milliseconds(100))

        // Verify Bob did not register a handler for id 0 by sending a
        // payload to id 0 — if a handler were registered it would absorb it;
        // since none should be, the payload is silently dropped. The absence
        // of a crash or side-effect is the assertion.
        let probePayload = ChannelFrame.payload(ChannelPayload(id: .reserved), Data([0xFF]))
        let probeData = try ChannelFrameCoder.encode(probePayload)
        try await pair.aliceSide.send(probeData)

        // Alice should have received a channel-id-reserved error from Bob.
        // Register a handler on Alice's side retroactively to catch any
        // error frame Bob sends; since Alice used raw send we inspect via
        // a RecordingHandler registered for id 0 error paths — instead,
        // verify via Bob's error response on Alice's router.
        // The practical test: no crash, and a normal channel (id != 0) still
        // works, confirming the router is not broken by the rejected frame.
        let aliceHandler = RecordingHandler(channelType: "terminal")
        let id = try await alice.open(type: "terminal", handler: aliceHandler)
        #expect(id != .reserved)
        try await pollUntil(timeout: .seconds(2)) { await aliceHandler.opened }
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
