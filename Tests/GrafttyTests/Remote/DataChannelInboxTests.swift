import Foundation
import Testing
@testable import GrafttyHostAgent

/// Drives the inbox through its internal ingestion seams — no native
/// WebRTC objects (this suite must never start the WebRTC engine; see
/// `WebRTCHostAgentReconnectTests`' doc comment for the CI-hang
/// history).
@Suite("""
@spec REMOTE-11.4: While a data channel's SSH transport has not yet attached, the application shall buffer inbound data-channel bytes losslessly from the moment the channel is announced and deliver them to the transport in arrival order ahead of live traffic.
""")
struct DataChannelInboxTests {

    private final class Consumed: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        var events: [String] { lock.withLock { _events } }
        func append(_ event: String) { lock.withLock { _events.append(event) } }
    }

    private func attach(_ inbox: DataChannelInbox, into consumed: Consumed) {
        inbox.attach(
            onOpen: { consumed.append("open") },
            onClose: { consumed.append("close") },
            onMessage: { consumed.append("msg:\(String(data: $0, encoding: .utf8) ?? "?")") }
        )
    }

    @Test func bufferedEventsReplayInArrivalOrderOnAttach() {
        let inbox = DataChannelInbox()
        let consumed = Consumed()

        inbox.observeOpen()
        inbox.receive(Data("SSH-2.0-banner".utf8))
        inbox.receive(Data("KEXINIT".utf8))
        attach(inbox, into: consumed)

        #expect(consumed.events == ["open", "msg:SSH-2.0-banner", "msg:KEXINIT"])
    }

    @Test func liveEventsForwardDirectlyAfterAttach() {
        let inbox = DataChannelInbox()
        let consumed = Consumed()

        attach(inbox, into: consumed)
        inbox.observeOpen()
        inbox.receive(Data("late".utf8))
        inbox.observeClosed()

        #expect(consumed.events == ["open", "msg:late", "close"])
    }

    @Test func closeObservedBeforeAttachReplaysAfterBufferedMessages() {
        let inbox = DataChannelInbox()
        let consumed = Consumed()

        inbox.observeOpen()
        inbox.receive(Data("tail".utf8))
        inbox.observeClosed()
        attach(inbox, into: consumed)

        #expect(consumed.events == ["open", "msg:tail", "close"])
    }

    @Test func preAttachFloodPoisonsToCloseInsteadOfGrowingUnbounded() {
        let inbox = DataChannelInbox()
        let consumed = Consumed()

        let megabyte = Data(repeating: 0x41, count: 1024 * 1024)
        inbox.receive(megabyte)
        inbox.receive(Data("one-byte-over".utf8))
        attach(inbox, into: consumed)

        #expect(consumed.events == ["close"])
    }
}
