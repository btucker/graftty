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
    func testEnvironmentRequestRoutesToTerminalSession() async throws {
        let factory = RecordingStreamFactory()
        let dispatcher = makeDispatcher(streamFactory: factory.callable)
        let channel = NIOAsyncTestingChannel()
        try await channel.pipeline.addHandler(dispatcher).get()

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

        try await waitFor(channel: channel) { factory.received.count > 0 }

        XCTAssertEqual(
            factory.received,
            ["alpha"],
            "TerminalSessionHandler should have received the env value via its attach call"
        )
        _ = try? await channel.finish()
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
    func testPanesStateSubsystemRoutesToPanesStateChannelHandler() async throws {
        let factory = RecordingStreamFactory()
        let dispatcher = makeDispatcher(streamFactory: factory.callable)
        let channel = NIOAsyncTestingChannel()
        try await channel.pipeline.addHandler(dispatcher).get()
        try await channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).get()

        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.panesState,
                wantReply: false
            )
        )
        try await waitFor(channel: channel) {
            try await Self.dispatcherRemoved(from: channel, dispatcher: dispatcher)
        }

        let removed = try await Self.dispatcherRemoved(from: channel, dispatcher: dispatcher)
        XCTAssertTrue(
            removed,
            "dispatcher should have removed itself after routing to panes-state"
        )
        _ = try? await channel.finish()
    }

    /// Subsystem request with `wantReply: true` for `pane-control@graftty.dev`
    /// triggers a `ChannelSuccessEvent` ack AND installs the handler.
    func testPaneControlSubsystemRoutesAndAcknowledgesWantReply() async throws {
        let factory = RecordingStreamFactory()
        let dispatcher = makeDispatcher(
            streamFactory: factory.callable,
            paneControlMutator: { _ in .ok }
        )
        let channel = NIOAsyncTestingChannel()
        let capture = OutboundEventCapture()
        try await channel.pipeline.addHandler(capture).get()
        try await channel.pipeline.addHandler(dispatcher).get()

        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.SubsystemRequest(
                subsystem: SSHChannelTypeNames.paneControl,
                wantReply: true
            )
        )

        try await waitFor(channel: channel) { capture.sawSuccess }

        XCTAssertTrue(capture.sawSuccess, "expected ChannelSuccessEvent ack for wantReply subsystem")
        XCTAssertFalse(capture.sawFailure, "should not have failed for known subsystem")
        let removed = try await Self.dispatcherRemoved(from: channel, dispatcher: dispatcher)
        XCTAssertTrue(
            removed,
            "dispatcher should have removed itself after routing to pane-control"
        )
        _ = try? await channel.finish()
    }

    /// Unknown subsystem name: dispatcher must reply with ChannelFailureEvent
    /// (when `wantReply: true`) and close the channel.
    func testUnknownSubsystemFailsAndCloses() async throws {
        let factory = RecordingStreamFactory()
        let dispatcher = makeDispatcher(streamFactory: factory.callable)
        let channel = NIOAsyncTestingChannel()
        let capture = OutboundEventCapture()
        try await channel.pipeline.addHandler(capture).get()
        try await channel.pipeline.addHandler(dispatcher).get()
        try await channel.connect(to: .init(unixDomainSocketPath: "/tmp/test")).get()

        channel.pipeline.fireUserInboundEventTriggered(
            SSHChannelRequestEvent.SubsystemRequest(
                subsystem: "evil-subsystem@example.com",
                wantReply: true
            )
        )
        // Drain so the close lands.
        try await waitFor(channel: channel) { !channel.isActive }

        XCTAssertTrue(capture.sawFailure, "expected ChannelFailureEvent for unknown subsystem")
        XCTAssertFalse(capture.sawSuccess, "should not have acknowledged unknown subsystem")
        XCTAssertFalse(channel.isActive, "channel should be closed after refusing unknown subsystem")
    }

    // MARK: - helpers

    private func makeDispatcher(
        streamFactory: @escaping @Sendable (String) async throws -> any TerminalByteStream,
        panesStateSubscribe: PanesStateChannelHandler.Subscribe? = nil,
        paneControlMutator: PaneControlChannelHandler.Mutator? = nil,
        ownershipStore: SessionDisplayOwnershipStore? = nil,
        ownershipBroadcaster: DisplayOwnershipBroadcaster? = nil,
        deviceID: RemoteDeviceID? = nil
    ) -> SubsystemDispatcher {
        SubsystemDispatcher(
            streamFactory: streamFactory,
            panesStateSubscribe: panesStateSubscribe ?? { _ in
                PanesStateChannelHandler.Cancellable(cancel: {})
            },
            paneControlMutator: paneControlMutator ?? { _ in .ok },
            ownershipStore: ownershipStore ?? SessionDisplayOwnershipStore(),
            ownershipBroadcaster: ownershipBroadcaster ?? DisplayOwnershipBroadcaster(),
            deviceIDProvider: { deviceID ?? RemoteDeviceID(value: "test-device") }
        )
    }

    /// Drives the `NIOAsyncTestingChannel`'s (thread-safe) testing loop in
    /// short bursts, polling `condition` until it holds or the timeout
    /// elapses. `testingEventLoop.run()` flushes work the dispatcher and its
    /// installed handlers enqueue (handler installs, `loop.execute`-marshaled
    /// writes, channel closes); the inter-burst sleep yields to the
    /// Swift-concurrency Tasks those handlers spawn. Unlike the old
    /// `EmbeddedEventLoop`-driven busy-poll, this never races the background
    /// Tasks — the testing loop is thread-safe.
    private func waitFor(
        channel: NIOAsyncTestingChannel,
        timeout: TimeInterval = 2.0,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            await channel.testingEventLoop.run()
            if try await condition() { return }
            // Fail fast on timeout rather than returning silently — a silent
            // return lets a genuine regression slip past into a later assertion
            // (or a timeout-less wait) instead of failing here.
            if Date() >= deadline { throw WaitTimedOut() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Whether `dispatcher` has removed itself from `channel`'s pipeline.
    /// `syncOperations.context(handler:)` must run on the event loop, so the
    /// probe is hopped onto the (thread-safe) testing loop via
    /// `executeInContext`, which returns the `Sendable` `Bool` result.
    private static func dispatcherRemoved(
        from channel: NIOAsyncTestingChannel,
        dispatcher: SubsystemDispatcher
    ) async throws -> Bool {
        try await channel.testingEventLoop.executeInContext {
            (try? channel.pipeline.syncOperations.context(handler: dispatcher)) == nil
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


private struct WaitTimedOut: Error, CustomStringConvertible {
    var description: String { "waitFor timed out" }
}
