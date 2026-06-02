import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

final class SubsystemDispatcherTests: XCTestCase {

    // MARK: - Env (terminal session) routing

    /// Firing an `EnvironmentRequest("GRAFTTY_SESSION", "alpha")` —
    /// the canonical R4 client opener — must install a
    /// `TerminalSessionHandler` and re-deliver the env event so it lands
    /// at the new handler. Verifying TerminalSessionHandler is installed:
    /// follow up with `pty-req` + `shell` and confirm the streamFactory
    /// is called with the env value. Only the R4 handler implements that
    /// behaviour, so this is a sufficient witness.
    func testEnvironmentRequestRoutesToTerminalSession() throws {
        let factory = RecordingStreamFactory()
        let dispatcher = makeDispatcher(streamFactory: factory.callable)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(dispatcher)

        // Send env → pty-req → shell. The dispatcher hands off to
        // TerminalSessionHandler on the first event; that handler
        // accumulates env, then attaches on shell.
        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: true,
                name: "GRAFTTY_SESSION",
                value: "alpha"
            )
        )
        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true,
                term: "xterm",
                terminalCharacterWidth: 80,
                terminalRowHeight: 24,
                terminalPixelWidth: 0,
                terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:])
            )
        )
        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.ShellRequest(wantReply: true)
        )

        drainAsync(channel: channel, until: { factory.received.count > 0 })

        XCTAssertEqual(
            factory.received,
            ["alpha"],
            "TerminalSessionHandler should have received the env value via its attach call"
        )
        _ = try? channel.finish()
    }

    // MARK: - panes-state subsystem routing

    /// `SubsystemRequest("panes-state@graftty.dev")` installs
    /// `LengthPrefixedFraming` + `PanesStateChannelHandler` and removes
    /// the dispatcher. Structural witness: after routing, the dispatcher
    /// is no longer reachable in the pipeline via its handler reference.
    /// (Asserting on `subscribe` firing would require channelActive to
    /// propagate to the post-install handler, which NIO doesn't do for
    /// handlers added after activation — that path is exercised by
    /// PanesStateChannelHandlerTests directly.)
    func testPanesStateSubsystemRoutesToPanesStateChannelHandler() throws {
        let factory = RecordingStreamFactory()
        let dispatcher = makeDispatcher(streamFactory: factory.callable)
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(dispatcher)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()

        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.panesState,
                wantReply: false
            )
        )
        drainAsync(channel: channel, until: {
            (try? channel.pipeline.syncOperations.context(handler: dispatcher)) == nil
        })

        XCTAssertNil(
            try? channel.pipeline.syncOperations.context(handler: dispatcher),
            "dispatcher should have removed itself after routing to panes-state"
        )
        _ = try? channel.finish()
    }

    /// Subsystem request with `wantReply: true` for `pane-control@graftty.dev`
    /// triggers a `ChannelSuccessEvent` ack AND installs the handler.
    func testPaneControlSubsystemRoutesAndAcknowledgesWantReply() throws {
        let factory = RecordingStreamFactory()
        let dispatcher = makeDispatcher(
            streamFactory: factory.callable,
            paneControlMutator: { _ in .ok }
        )
        let channel = EmbeddedChannel()
        let capture = OutboundEventCapture()
        try channel.pipeline.syncOperations.addHandler(capture)
        try channel.pipeline.syncOperations.addHandler(dispatcher)

        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.paneControl,
                wantReply: true
            )
        )

        XCTAssertTrue(capture.sawSuccess, "expected ChannelSuccessEvent ack for wantReply subsystem")
        XCTAssertFalse(capture.sawFailure, "should not have failed for known subsystem")
        XCTAssertNil(
            try? channel.pipeline.syncOperations.context(handler: dispatcher),
            "dispatcher should have removed itself after routing to pane-control"
        )
        _ = try? channel.finish()
    }

    /// Unknown subsystem name: dispatcher must reply with ChannelFailureEvent
    /// (when `wantReply: true`) and close the channel.
    func testUnknownSubsystemFailsAndCloses() throws {
        let factory = RecordingStreamFactory()
        let dispatcher = makeDispatcher(streamFactory: factory.callable)
        let channel = EmbeddedChannel()
        let capture = OutboundEventCapture()
        try channel.pipeline.syncOperations.addHandler(capture)
        try channel.pipeline.syncOperations.addHandler(dispatcher)
        try channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).wait()

        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.SubsystemRequest(
                subsystem: "evil-subsystem@example.com",
                wantReply: true
            )
        )
        // Drain so the close lands.
        channel.embeddedEventLoop.run()

        XCTAssertTrue(capture.sawFailure, "expected ChannelFailureEvent for unknown subsystem")
        XCTAssertFalse(capture.sawSuccess, "should not have acknowledged unknown subsystem")
        XCTAssertFalse(channel.isActive, "channel should be closed after refusing unknown subsystem")
    }

    // MARK: - helpers

    private func makeDispatcher(
        streamFactory: @escaping @Sendable (String) async throws -> any TerminalByteStream,
        panesStateSubscribe: PanesStateChannelHandler.Subscribe? = nil,
        paneControlMutator: PaneControlChannelHandler.Mutator? = nil
    ) -> SubsystemDispatcher {
        SubsystemDispatcher(
            streamFactory: streamFactory,
            panesStateSubscribe: panesStateSubscribe ?? { _ in
                PanesStateChannelHandler.Cancellable(cancel: {})
            },
            paneControlMutator: paneControlMutator ?? { _ in .ok }
        )
    }

    /// Drain helper from PanesStateChannelHandlerTests / TerminalSessionHandlerTests.
    private func drainAsync(
        channel: EmbeddedChannel,
        until condition: () -> Bool,
        timeout: TimeInterval = 2.0
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            channel.embeddedEventLoop.run()
        }
    }
}

// MARK: - OutboundEventCapture

/// Installed head-ward of `SubsystemDispatcher` to intercept user
/// outbound events. `triggerUserOutboundEvent` propagates toward the
/// head of the pipeline, so head-ward placement captures the events
/// the dispatcher sends in response to subsystem requests.
private final class OutboundEventCapture: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    private let lock = NIOLock()
    private var _sawSuccess = false
    private var _sawFailure = false

    var sawSuccess: Bool { lock.withLock { _sawSuccess } }
    var sawFailure: Bool { lock.withLock { _sawFailure } }

    func triggerUserOutboundEvent(
        context: ChannelHandlerContext,
        event: Any,
        promise: EventLoopPromise<Void>?
    ) {
        if event is ChannelSuccessEvent {
            lock.withLock { _sawSuccess = true }
        } else if event is ChannelFailureEvent {
            lock.withLock { _sawFailure = true }
        }
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}

// MARK: - RecordingStreamFactory

private final class RecordingStreamFactory: @unchecked Sendable {
    private let lock = NIOLock()
    private var _received: [String] = []

    var received: [String] { lock.withLock { _received } }

    var callable: @Sendable (String) async throws -> any TerminalByteStream {
        return { [self] name in
            self.lock.withLock { self._received.append(name) }
            return EchoStream()
        }
    }
}

private final class EchoStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws { continuation.yield(bytes) }
    func close() async { continuation.finish() }
}

