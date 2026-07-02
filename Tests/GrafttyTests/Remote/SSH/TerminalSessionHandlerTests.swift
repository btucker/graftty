import Foundation
import GrafttyHostAgent
import GrafttyKit
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

/// `TerminalSessionHandler` spawns Swift-concurrency `Task`s (to await the
/// injected `streamFactory`, forward inbound bytes, resize, and close the
/// stream) and marshals their results back onto the channel via
/// `loop.execute`. `EmbeddedChannel`/`EmbeddedEventLoop` are single-thread-only,
/// so polling `embeddedEventLoop.run()` from the test thread while those
/// background `Task`s call `loop.execute` is a data race (NIO logs
/// "EmbeddedEventLoop is not thread-safe" and the process intermittently
/// crashes). These tests use `NIOAsyncTestingChannel`, whose loop *is*
/// thread-safe: `waitForOutboundWrite` drives the loop until a deferred write
/// lands, and the side-effect assertions poll thread-safe fakes — no busy-poll
/// of the embedded loop, no race.
final class TerminalSessionHandlerTests: XCTestCase {

    // MARK: - env + pty + shell -> attach

    func testShellCallsStreamFactoryWithEnvSessionName() async throws {
        let factory = RecordingStreamFactory(returning: .success(EchoStream()))
        let handler = Self.makeHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm-256color", cols: 80, rows: 24)
        try await sendShellRequest(channel)

        // Let the Task spawned by attach() run and call the factory.
        try await waitUntil { factory.received.count > 0 }

        XCTAssertEqual(factory.received, ["alpha"])
        _ = try? await channel.finish()
    }

    func testShellWithoutEnvSessionNameRejected() async throws {
        let factory = RecordingStreamFactory(returning: .success(EchoStream()))
        let handler = Self.makeHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(handler)

        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // The handler closes the channel synchronously (no async involved).
        await channel.testingEventLoop.run()

        XCTAssertTrue(factory.received.isEmpty)
        XCTAssertFalse(channel.isActive)
    }

    // MARK: - bytes round-trip

    func testBytesRoundTripThroughStream() async throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // Wait until attach installs the stream. env + pty acks fire before
        // attach; the shell ack (3rd success) fires from the same loop.execute
        // that sets `stream`, so `successCount >= 3` means the stream is
        // installed and inbound bytes won't be dropped by `guard stream != nil`.
        try await waitUntil { capture.successCount >= 3 }

        let bytes = ByteBuffer(string: "hello\n")
        try await channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(bytes)))

        // EchoStream.send() yields the bytes back via inboundBytes;
        // startInboundForwarding's Task calls loop.execute to writeAndFlush.
        // waitForOutboundWrite drives the loop until that write lands.
        let outbound = try await channel.waitForOutboundWrite(as: SSHChannelData.self)
        var echoed: String?
        if case let .byteBuffer(buf) = outbound.data {
            echoed = buf.getString(at: 0, length: buf.readableBytes)
        }

        XCTAssertEqual(echoed, "hello\n")
        _ = try? await channel.finish()
    }

    // MARK: - window-change

    func testWindowChangeForwardsToStream() async throws {
        let stream = RecordingResizeStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // Wait until attach installs the stream (shell ack = 3rd success) so
        // window-change is forwarded rather than dropped pre-attach.
        try await waitUntil { capture.successCount >= 3 }

        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: 120,
            terminalRowHeight: 40,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try await fireUserInboundEvent(channel, event)

        // resize is called from a Task; poll until it completes.
        try await waitUntil { stream.lastResize != nil }

        XCTAssertEqual(stream.lastResize?.cols, 120)
        XCTAssertEqual(stream.lastResize?.rows, 40)
        _ = try? await channel.finish()
    }

    // MARK: - close

    func testChannelCloseClosesStream() async throws {
        let stream = ClosableStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // Wait until attach installs the stream (shell ack = 3rd success) so
        // channelInactive has a stream to close.
        try await waitUntil { capture.successCount >= 3 }

        _ = try? await channel.finish()
        // close() is called from a Task in channelInactive; poll until done.
        try await waitUntil { stream.didClose }

        XCTAssertTrue(stream.didClose)
    }

    // MARK: - channelInactive race with factory

    /// Channel that closes while streamFactory is awaiting must not leak
    /// the freshly-obtained stream — channelInactive racing the factory
    /// completion previously left stream un-closed.
    func testChannelInactiveDuringFactoryAwaitClosesStream() async throws {
        let stream = ClosableStream()
        // Slow factory so we can fire channelInactive before it returns.
        let delayedFactory: @Sendable (String) async throws -> any TerminalByteStream = { _ in
            try await Task.sleep(for: .milliseconds(100))
            return stream
        }
        let handler = Self.makeHandler(streamFactory: delayedFactory)
        let channel = try await Self.channel(handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // Fire channelInactive while the factory is still sleeping.
        _ = try? await channel.finish()

        // Poll until the factory completes, loop.execute fires, and stream.close() is called.
        try await waitUntil(timeout: 3.0) { stream.didClose }

        XCTAssertTrue(stream.didClose, "stream from factory must be closed when channel is already inactive")
    }

    // MARK: - streamFactory throws

    func testStreamFactoryThrowsSendsExitStatusAndCloses() async throws {
        let factory = RecordingStreamFactory(returning: .failure(FactoryError.notFound))
        // Install a capture handler head-ward of TerminalSessionHandler so it
        // can record user outbound events (triggerUserOutboundEvent goes
        // head-ward through the pipeline).
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "missing")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)

        // The factory throws, then loop.execute fires exit-status + close.
        try await waitUntil { capture.sawExitStatus1 }

        XCTAssertTrue(capture.sawExitStatus1, "expected exit-status: 1 after factory throw")
    }

    // MARK: - REMOTE-9: display ownership on SSH terminals

    /// @spec REMOTE-9.1: When an SSH terminal session attaches via the control carrier, the host shall register the client in the display-ownership store with kind ios and the authenticated device identity.
    func testAttachRegistersClientWithIOSKindAndAuthenticatedDeviceIdentity() async throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: factory.callable,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-42")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        // The protocol-reported `kind: .web` must lose to the transport's
        // own `defaultKind: .ios` — mirrors the web bridge's
        // `requestDefaultKindWinsOverSpoofedFrameKind` guarantee.
        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .web,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))
        try await sendControlEnvelope(channel, .takeControl(
            clientID: DisplayClientID("ipad-1"),
            kind: .web,
            cols: 80,
            rows: 24
        ))

        try await waitUntil { store.snapshot(sessionName: "alpha").ownerClientID != nil }

        let snapshot = store.snapshot(sessionName: "alpha")
        XCTAssertEqual(snapshot.ownerKind, .ios)
        let ownerID = try XCTUnwrap(snapshot.ownerClientID?.rawValue)
        XCTAssertTrue(
            ownerID.hasPrefix("ssh-device-42-"),
            "expected clientID to embed the authenticated device identity, got \(ownerID)"
        )

        _ = try? await channel.finish()
    }

    /// @spec REMOTE-9.2: While an SSH terminal client is not the display owner, the host shall discard its terminal input bytes and rebroadcast the current ownership snapshot.
    func testNonOwnerBytesAreDiscardedAndSnapshotIsRebroadcast() async throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: factory.callable,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-1")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))
        // Drain the ownership envelope produced by the attach itself
        // before exercising the byte-send-while-not-owner path below.
        _ = try await nextOutboundEnvelope(channel)

        let bytes = ByteBuffer(string: "should-not-reach-the-pty")
        try await channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(bytes)))

        let envelope = try await nextOutboundEnvelope(channel)
        guard case let .ownership(snapshot) = envelope else {
            XCTFail("expected an ownership envelope, got \(envelope)")
            return
        }
        XCTAssertNil(snapshot.ownerClientID, "no owner has claimed control yet")

        // No echoed `.channel` frame should ever appear — the bytes were
        // discarded before reaching `EchoStream`/the PTY.
        let leftover = try await channel.readOutbound(as: SSHChannelData.self)
        XCTAssertNil(leftover, "non-owner bytes must not reach the PTY")

        _ = try? await channel.finish()
    }

    /// @spec REMOTE-9.3: When an SSH terminal client issues a take-control request, the host shall apply the same owner-eligibility rules as the web transport.
    func testTakeControlAppliesSameEligibilityRulesAsWebTransport() async throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: factory.callable,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-2")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        // `visible: false` is not owner-eligible (`AttachedClient.isOwnerEligible`)
        // — the exact same rule `SessionDisplayOwnershipStore.claimOwner`
        // enforces for the `/ws` web transport.
        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: false,
            cols: 80,
            rows: 24
        ))
        _ = try await nextOutboundEnvelope(channel)

        try await sendControlEnvelope(channel, .takeControl(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            cols: 80,
            rows: 24
        ))

        let envelope = try await nextOutboundEnvelope(channel)
        guard case let .ownership(snapshot) = envelope else {
            XCTFail("expected an ownership envelope, got \(envelope)")
            return
        }
        XCTAssertNil(
            snapshot.ownerClientID,
            "an invisible client must not be granted ownership, mirroring the web transport's eligibility gate"
        )

        _ = try? await channel.finish()
    }

    /// @spec REMOTE-9.4: When the PTY size changes, the host shall push grid and ownership envelopes to SSH terminal clients over the control carrier.
    func testPTYSizeChangePushesGridAndOwnershipEnvelopes() async throws {
        let stream = SizeReportingStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: factory.callable,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-9")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))

        try await waitUntil { stream.onPTYSize != nil }
        stream.onPTYSize?(120, 40)

        var sawGrid = false
        var sawOwnershipWithNewGrid = false
        let deadline = Date().addingTimeInterval(2.0)
        while !(sawGrid && sawOwnershipWithNewGrid) {
            if Date() >= deadline {
                XCTFail("timed out waiting for grid + ownership envelopes reflecting the new PTY size")
                break
            }
            let envelope = try await nextOutboundEnvelope(channel)
            switch envelope {
            case let .grid(cols, rows) where cols == 120 && rows == 40:
                sawGrid = true
            case let .ownership(snapshot) where snapshot.grid == (try DisplayGrid(cols: 120, rows: 40)):
                sawOwnershipWithNewGrid = true
            default:
                break
            }
        }

        XCTAssertTrue(sawGrid, "expected a `.grid` envelope reflecting the new PTY size")
        XCTAssertTrue(sawOwnershipWithNewGrid, "expected an `.ownership` envelope reflecting the new PTY size")

        _ = try? await channel.finish()
    }

    /// A `.hello` that arrives while the async `streamFactory` is still
    /// resolving (i.e. before `attach` installs the stream/coordinator)
    /// must be buffered and processed once attach completes — not
    /// silently dropped, which would leave the client permanently stuck
    /// in the ungated legacy mode with no way to ever take control.
    func testHelloArrivingBeforeAttachCompletesIsBufferedNotDropped() async throws {
        let stream = EchoStream()
        // Delayed factory so the hello can arrive mid-attach.
        let delayedFactory: @Sendable (String) async throws -> any TerminalByteStream = { _ in
            try await Task.sleep(for: .milliseconds(100))
            return stream
        }
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: delayedFactory,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-early")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        // Send hello IMMEDIATELY — before the factory's 100ms sleep elapses.
        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))

        // Now wait for attach to complete (shell ack is the 3rd success).
        try await waitUntil(timeout: 3.0) { capture.successCount >= 3 }

        try await sendControlEnvelope(channel, .takeControl(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            cols: 80,
            rows: 24
        ))

        try await waitUntil { store.snapshot(sessionName: "alpha").ownerClientID != nil }
        XCTAssertNotNil(
            store.snapshot(sessionName: "alpha").ownerClientID,
            "hello buffered during attach must activate the control carrier; takeControl must then succeed"
        )

        _ = try? await channel.finish()
    }

    /// A `.stdErr` frame header claiming an absurd length must not cause
    /// the host to buffer toward gigabytes — the control carrier is
    /// abandoned (poisoned) for that channel, and terminal bytes keep
    /// flowing untouched.
    func testOversizedControlFrameHeaderPoisonsCarrierButTerminalBytesStillFlow() async throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        // Header claims a ~4GB frame; only a few junk bytes follow.
        let oversized: [UInt8] = [0xff, 0xff, 0xff, 0xf0, 0x41, 0x42, 0x43]
        try await channel.writeInbound(
            SSHChannelData(type: .stdErr, data: .byteBuffer(ByteBuffer(bytes: oversized)))
        )

        // A hello after the poisoned header must NOT activate the carrier.
        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))

        // Terminal bytes still flow exactly as legacy.
        let bytes = ByteBuffer(string: "still-works\n")
        try await channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(bytes)))
        let outbound = try await channel.waitForOutboundWrite(as: SSHChannelData.self)
        XCTAssertEqual(outbound.type, .channel)
        var echoed: String?
        if case let .byteBuffer(buf) = outbound.data {
            echoed = buf.getString(at: 0, length: buf.readableBytes)
        }
        XCTAssertEqual(echoed, "still-works\n")

        // No `.stdErr` envelope may be emitted after poisoning.
        let leftover = try await channel.readOutbound(as: SSHChannelData.self)
        XCTAssertNil(leftover, "poisoned carrier must stay silent on .stdErr")

        _ = try? await channel.finish()
    }

    /// A client that has already sent `.hello` (proving it understands the
    /// control carrier) is receiving grid/ownership envelopes and having
    /// its `.channel` bytes owner-gated. If a subsequent `.stdErr` frame
    /// poisons the carrier, silently abandoning it (the pre-hello
    /// behavior) would strand the client: its outbound takeControl/resize
    /// can never be parsed again, and — if it isn't the owner — its
    /// keystrokes are discarded too, with no error and no way to recover
    /// short of a manual reconnect. The fix closes the channel instead so
    /// the client observes a disconnect and can reconnect.
    func testPostHelloOversizedControlFrameClosesChannel() async throws {
        let stream = ClosableStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        // Prove protocol awareness first, as a well-behaved client does.
        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))
        _ = try await nextOutboundEnvelope(channel)

        // A framing-unrecoverable `.stdErr` header arrives after hello.
        let oversized: [UInt8] = [0xff, 0xff, 0xff, 0xf0, 0x41, 0x42, 0x43]
        try await channel.writeInbound(
            SSHChannelData(type: .stdErr, data: .byteBuffer(ByteBuffer(bytes: oversized)))
        )

        try await waitUntil { !channel.isActive }
        // channelInactive's cleanup (detach()/stream.close()) must have run
        // exactly once as a result of that close, not zero or more times.
        try await waitUntil { stream.didClose }
        XCTAssertEqual(stream.closeCount, 1, "cleanup must run exactly once")

        _ = try? await channel.finish()
    }

    /// While an SSH client is attached via the control carrier but is
    /// NOT the display owner, an SSH-level `window-change` must not
    /// resize the shared PTY (same owner gate the web transport applies
    /// to its legacy `resize` frames). Pre-hello, window-change keeps
    /// its historical direct-resize behavior.
    func testWindowChangeAfterHelloIsOwnerGated() async throws {
        let stream = RecordingResizeStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: factory.callable,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-wc")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        // Attach as an owner-INELIGIBLE client (invisible).
        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: false,
            cols: 80,
            rows: 24
        ))
        _ = try await nextOutboundEnvelope(channel)

        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: 200,
            terminalRowHeight: 50,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try await fireUserInboundEvent(channel, event)

        // Give any (incorrect) resize Task time to land, then assert none did.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(
            stream.lastResize,
            "a non-owner's window-change must not reach the PTY once the control carrier is active"
        )

        _ = try? await channel.finish()
    }

    /// Positive-path counterpart to `testWindowChangeAfterHelloIsOwnerGated`:
    /// an OWNER's window-change must still reach the PTY once the control
    /// carrier is active. Nothing else in this file asserts the ACCEPTED
    /// path actually resizes the PTY — every other window-change test
    /// covers either the pre-hello legacy path or a rejected (non-owner)
    /// resize.
    func testWindowChangeAfterHelloReachesPTYForOwner() async throws {
        let stream = RecordingResizeStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: factory.callable,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-owner-wc")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        // Attach as an owner-ELIGIBLE client (visible) and take control.
        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))
        _ = try await nextOutboundEnvelope(channel)
        try await sendControlEnvelope(channel, .takeControl(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            cols: 80,
            rows: 24
        ))
        _ = try await nextOutboundEnvelope(channel)
        try await waitUntil { store.snapshot(sessionName: "alpha").ownerClientID != nil }

        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: 132,
            terminalRowHeight: 43,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try await fireUserInboundEvent(channel, event)

        try await waitUntil { stream.lastResize != nil }
        XCTAssertEqual(stream.lastResize?.cols, 132)
        XCTAssertEqual(stream.lastResize?.rows, 43)

        _ = try? await channel.finish()
    }

    /// A grid dimension that fits `UInt16` but exceeds
    /// `WebControlEnvelope.maxGridDimension` must be clamped before it
    /// reaches `SessionDisplayOwnershipStore` — `DisplayGrid` itself only
    /// checks `> 0`, so an unclamped over-cap grid would enter the store
    /// and get broadcast in an `.ownership` envelope that
    /// `WebControlEnvelope.parse` then rejects for EVERY client on the
    /// session (its `.ownership` decode path enforces the same cap),
    /// freezing every follower's view until a valid resize/restart.
    func testWindowChangeAboveGridCapIsClampedAndOwnershipStaysParseable() async throws {
        let stream = RecordingResizeStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: factory.callable,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-cap")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))
        _ = try await nextOutboundEnvelope(channel)
        try await sendControlEnvelope(channel, .takeControl(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            cols: 80,
            rows: 24
        ))
        _ = try await nextOutboundEnvelope(channel)
        try await waitUntil { store.snapshot(sessionName: "alpha").ownerClientID != nil }

        // 20_000 fits UInt16 (< 65_536) but is well above the 10_000 cap.
        let event = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: 20_000,
            terminalRowHeight: 50,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try await fireUserInboundEvent(channel, event)

        try await waitUntil { stream.lastResize != nil }
        let clampedCols = try XCTUnwrap(stream.lastResize?.cols)
        XCTAssertLessThanOrEqual(clampedCols, WebControlEnvelope.maxGridDimension)

        let storeGrid = store.snapshot(sessionName: "alpha").grid
        XCTAssertLessThanOrEqual(Int(storeGrid.cols), WebControlEnvelope.maxGridDimension)

        // The resulting `.ownership` broadcast must still parse — this is
        // the actual failure mode: an unclamped grid in the store poisons
        // every subsequent `.ownership` envelope for every client.
        let payload = try await drainNextStdErrPayload(channel)
        let envelope = try WebControlEnvelope.parse(payload)
        guard case let .ownership(snapshot) = envelope else {
            XCTFail("expected an ownership envelope reflecting the clamped resize, got \(envelope)")
            return
        }
        XCTAssertLessThanOrEqual(Int(snapshot.grid.cols), WebControlEnvelope.maxGridDimension)

        _ = try? await channel.finish()
    }

    /// A structurally-valid `.hello` — parses as JSON, `type == "hello"`,
    /// every other field present — whose declared grid exceeds
    /// `WebControlEnvelope.maxGridDimension` is rejected outright by
    /// `WebControlEnvelope.parse` (`.invalidDimension`). Because
    /// `drainControlFrames` swallows any parse failure with `try?`, and
    /// only a successfully-parsed `.hello` ever flips `receivedHello`,
    /// that would otherwise permanently strand an otherwise
    /// carrier-capable client: every future frame from it keeps failing
    /// to parse (the grid doesn't change), so it can never attach, never
    /// take control, and its keystrokes vanish into the pre-hello ungated
    /// path forever with no error surfaced. A lenient fallback must detect
    /// the hello shape and clamp the grid instead of dropping the frame.
    func testOversizedGridHelloStillAttachesViaLenientFallback() async throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: factory.callable,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-lenient")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        // WebControlEnvelope.parse rejects this outright — the grid is
        // out of range but every other field is well-formed.
        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 20_000,
            rows: 50
        ))
        try await sendControlEnvelope(channel, .takeControl(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            cols: 80,
            rows: 24
        ))

        try await waitUntil(timeout: 3.0) { store.snapshot(sessionName: "alpha").ownerClientID != nil }
        XCTAssertNotNil(
            store.snapshot(sessionName: "alpha").ownerClientID,
            "an oversized-grid hello must not permanently strand the client — a lenient hello " +
            "fallback should flip receivedHello and let a subsequent takeControl succeed"
        )

        _ = try? await channel.finish()
    }

    /// When the engine's `inboundBytes` finishes on its own (child EOF) —
    /// not because the handler called `close()` — the channel must close
    /// so `channelInactive`'s cleanup (coordinator detach, `stream.close()`)
    /// still runs. Before the fix, `startInboundForwarding`'s `for await`
    /// loop simply returned, leaving the channel open and the ownership
    /// store permanently holding a stale attached/owner entry for a client
    /// that is never coming back.
    func testInboundStreamFinishingOnItsOwnClosesChannelAndDetachesCoordinator() async throws {
        let stream = FinishableStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let store = SessionDisplayOwnershipStore()
        let broadcaster = DisplayOwnershipBroadcaster()
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(
            streamFactory: factory.callable,
            ownershipStore: store,
            ownershipBroadcaster: broadcaster,
            deviceID: RemoteDeviceID(value: "device-eof")
        )
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        try await sendControlEnvelope(channel, .hello(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            role: .interactive,
            visible: true,
            cols: 80,
            rows: 24
        ))
        _ = try await nextOutboundEnvelope(channel)
        try await sendControlEnvelope(channel, .takeControl(
            clientID: DisplayClientID("ipad-1"),
            kind: .ios,
            cols: 80,
            rows: 24
        ))
        _ = try await nextOutboundEnvelope(channel)
        try await waitUntil { store.snapshot(sessionName: "alpha").ownerClientID != nil }

        // Simulate the underlying child process exiting on its own —
        // ZmxAttachEngine's reader thread finishes `inboundBytes` on EOF
        // even when the caller never calls `close()`.
        stream.finishInboundForTesting()

        try await waitUntil(timeout: 3.0) { !channel.isActive }
        try await waitUntil { store.snapshot(sessionName: "alpha").ownerClientID == nil }

        XCTAssertFalse(channel.isActive, "channel must close when the engine's byte stream ends on its own")
        XCTAssertNil(
            store.snapshot(sessionName: "alpha").ownerClientID,
            "coordinator must detach (clearing ownership) once the channel closes"
        )

        _ = try? await channel.finish()
    }

    /// A legacy client (no `.hello` — today's `TerminalSessionClient` on
    /// the mobile side) must see byte flow exactly as before REMOTE-9,
    /// and must never be sent a `.stdErr` control frame, which it would
    /// misinterpret as terminal bytes and corrupt its display.
    func testLegacyClientWithoutHelloNeverReceivesStdErrFrames() async throws {
        let stream = EchoStream()
        let factory = RecordingStreamFactory(returning: .success(stream))
        let capture = OutboundEventCapture()
        let handler = Self.makeHandler(streamFactory: factory.callable)
        let channel = try await Self.channel(capture, handler)

        try await sendEnvRequest(channel, name: "GRAFTTY_SESSION", value: "alpha")
        try await sendPtyRequest(channel, term: "xterm", cols: 80, rows: 24)
        try await sendShellRequest(channel)
        try await waitUntil { capture.successCount >= 3 }

        let bytes = ByteBuffer(string: "legacy-bytes\n")
        try await channel.writeInbound(SSHChannelData(type: .channel, data: .byteBuffer(bytes)))

        let outbound = try await channel.waitForOutboundWrite(as: SSHChannelData.self)
        XCTAssertEqual(outbound.type, .channel, "a legacy client must only ever see `.channel` bytes echoed back")
        var echoed: String?
        if case let .byteBuffer(buf) = outbound.data {
            echoed = buf.getString(at: 0, length: buf.readableBytes)
        }
        XCTAssertEqual(echoed, "legacy-bytes\n")

        let leftover = try await channel.readOutbound(as: SSHChannelData.self)
        XCTAssertNil(leftover, "no `.stdErr` control envelope should ever be emitted to a legacy client")

        _ = try? await channel.finish()
    }

    // MARK: - helpers

    /// A `NIOAsyncTestingChannel` with `handlers` installed (in order, head-ward
    /// first) on its thread-safe loop, then connected so it is active — the safe
    /// substitute for `EmbeddedChannel` when the handler bounces through Swift
    /// concurrency. Connecting makes the channel active so `channelInactive`
    /// fires on close.
    private static func channel(_ handlers: NIOCore.ChannelHandler...) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        for handler in handlers {
            try await channel.pipeline.addHandler(handler).get()
        }
        try await channel.connect(to: SocketAddress(unixDomainSocketPath: "graftty-test")).get()
        return channel
    }

    /// Builds a `TerminalSessionHandler` with fresh REMOTE-9 dependencies
    /// by default, so tests that don't care about ownership (everything
    /// pre-dating REMOTE-9, plus the explicit legacy-path test) don't
    /// need to construct their own store/broadcaster/deviceID.
    private static func makeHandler(
        streamFactory: @escaping @Sendable (String) async throws -> TerminalByteStream,
        ownershipStore: SessionDisplayOwnershipStore = SessionDisplayOwnershipStore(),
        ownershipBroadcaster: DisplayOwnershipBroadcaster = DisplayOwnershipBroadcaster(),
        deviceID: RemoteDeviceID = RemoteDeviceID(value: "test-device")
    ) -> TerminalSessionHandler {
        TerminalSessionHandler(
            streamFactory: streamFactory,
            ownershipStore: ownershipStore,
            ownershipBroadcaster: ownershipBroadcaster,
            deviceID: deviceID
        )
    }

    /// Sends `envelope` inbound as a length-prefixed `.stdErr` frame —
    /// the REMOTE-9 control-carrier wire shape (`<u32 BE length><UTF-8 JSON>`).
    private func sendControlEnvelope(_ channel: NIOAsyncTestingChannel, _ envelope: WebControlEnvelope) async throws {
        let payload = Array(envelope.encoded().utf8)
        let length = UInt32(payload.count)
        var framed: [UInt8] = [
            UInt8((length >> 24) & 0xff),
            UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff),
            UInt8(length & 0xff),
        ]
        framed.append(contentsOf: payload)
        let buffer = ByteBuffer(bytes: framed)
        try await channel.writeInbound(SSHChannelData(type: .stdErr, data: .byteBuffer(buffer)))
    }

    /// Drains outbound `SSHChannelData` (both `.channel` and `.stdErr`
    /// frames share one outbound queue) until a complete `.stdErr`
    /// control frame decodes to a `WebControlEnvelope`, then returns it.
    /// `.channel` frames encountered along the way (byte echoes) are
    /// skipped. Reassembles the length-prefix framing across multiple
    /// `.stdErr` chunks, mirroring `TerminalSessionHandler.ingestStdErr`.
    private func nextOutboundEnvelope(_ channel: NIOAsyncTestingChannel) async throws -> WebControlEnvelope {
        var stdErrBuffer: [UInt8] = []
        while true {
            while stdErrBuffer.count >= 4 {
                let length = (UInt32(stdErrBuffer[0]) << 24)
                    | (UInt32(stdErrBuffer[1]) << 16)
                    | (UInt32(stdErrBuffer[2]) << 8)
                    | UInt32(stdErrBuffer[3])
                let total = 4 + Int(length)
                guard stdErrBuffer.count >= total else { break }
                let payload = Data(stdErrBuffer[4..<total])
                stdErrBuffer.removeFirst(total)
                if let envelope = try? WebControlEnvelope.parse(payload) {
                    return envelope
                }
            }
            // `waitForOutboundWrite` (rather than a `readOutbound` poll
            // loop) actually waits for a deferred write to land — see the
            // type-level doc comment on why `NIOAsyncTestingChannel` is
            // used here instead of `EmbeddedChannel`.
            let frame = try await channel.waitForOutboundWrite(as: SSHChannelData.self)
            guard case let .byteBuffer(buf) = frame.data else { continue }
            var view = buf
            guard let bytes = view.readBytes(length: view.readableBytes) else { continue }
            if frame.type == .stdErr {
                stdErrBuffer.append(contentsOf: bytes)
            }
        }
    }

    /// Drains outbound `SSHChannelData` until a complete `.stdErr` control
    /// frame is available, returning its RAW payload without attempting to
    /// parse it — unlike `nextOutboundEnvelope`, which silently skips (and
    /// keeps waiting past) any frame that fails to parse. That's fine for
    /// tests that only care about frames that DO parse, but a caller that
    /// wants to assert on a parse failure needs the raw bytes, and doing
    /// so via `nextOutboundEnvelope`'s loop would hang forever on
    /// `waitForOutboundWrite` (no internal timeout — see `waitUntil`'s
    /// doc) once no further frame ever arrives. Races
    /// `waitForOutboundWrite` (which, per that type's doc, actually drives
    /// the thread-safe testing loop — a plain `readOutbound` poll does
    /// not) against a bounded timeout so a parse failure surfaces as an
    /// ordinary test failure instead.
    private func drainNextStdErrPayload(
        _ channel: NIOAsyncTestingChannel,
        timeout: TimeInterval = 2.0
    ) async throws -> Data {
        var stdErrBuffer: [UInt8] = []
        while true {
            while stdErrBuffer.count >= 4 {
                let length = (UInt32(stdErrBuffer[0]) << 24)
                    | (UInt32(stdErrBuffer[1]) << 16)
                    | (UInt32(stdErrBuffer[2]) << 8)
                    | UInt32(stdErrBuffer[3])
                let total = 4 + Int(length)
                guard stdErrBuffer.count >= total else { break }
                return Data(stdErrBuffer[4..<total])
            }
            let frame = try await withBoundedTimeout(timeout) {
                try await channel.waitForOutboundWrite(as: SSHChannelData.self)
            }
            guard case let .byteBuffer(buf) = frame.data else { continue }
            var view = buf
            guard let bytes = view.readBytes(length: view.readableBytes) else { continue }
            if frame.type == .stdErr {
                stdErrBuffer.append(contentsOf: bytes)
            }
        }
    }

    /// Races `operation` against a `timeout`-second deadline, throwing
    /// `WaitTimedOut` if the deadline wins. Exists so a helper built on an
    /// inherently un-timed-out NIO async testing API (`waitForOutboundWrite`
    /// has none — see its doc comment on `waitUntil`) can still fail fast
    /// instead of hanging the whole test run.
    private func withBoundedTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw WaitTimedOut()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func sendEnvRequest(_ channel: NIOAsyncTestingChannel, name: String, value: String) async throws {
        let event = SSHChannelRequestEvent.EnvironmentRequest(
            wantReply: true,
            name: name,
            value: value
        )
        try await fireUserInboundEvent(channel, event)
    }

    private func sendPtyRequest(_ channel: NIOAsyncTestingChannel, term: String, cols: Int, rows: Int) async throws {
        let event = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        try await fireUserInboundEvent(channel, event)
    }

    private func sendShellRequest(_ channel: NIOAsyncTestingChannel) async throws {
        let event = SSHChannelRequestEvent.ShellRequest(wantReply: true)
        try await fireUserInboundEvent(channel, event)
    }

    /// Fires a user inbound event through the pipeline on the channel's loop.
    /// (`NIOAsyncTestingChannel` requires pipeline operations to run on the
    /// event loop; `executeInContext` provides that.)
    private func fireUserInboundEvent(_ channel: NIOAsyncTestingChannel, _ event: some Sendable) async throws {
        try await channel.testingEventLoop.executeInContext {
            channel.pipeline.fireUserInboundEventTriggered(event)
        }
    }

    /// Polls `condition` until it returns true or the deadline is reached,
    /// suspending briefly between checks so the background `Task`s spawned by
    /// the handler (and their `loop.execute` callbacks, which self-run on the
    /// thread-safe testing loop) can make progress. Unlike the old embedded-loop
    /// busy-poll, this never touches the loop from off-thread, so there is no
    /// data race.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            // Fail fast on timeout rather than returning silently — otherwise a
            // missed barrier falls through to `waitForOutboundWrite`, which has
            // no internal timeout and would hang the whole run.
            if Date() >= deadline {
                throw WaitTimedOut()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private struct WaitTimedOut: Error, CustomStringConvertible {
    var description: String { "waitUntil timed out" }
}

// MARK: - Outbound event capture handler

/// Installed head-ward of `TerminalSessionHandler` to intercept
/// user outbound events (which `triggerUserOutboundEvent` propagates
/// toward the head of the pipeline).
private final class OutboundEventCapture: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    private let lock = NIOLock()
    private var _sawExitStatus1 = false
    private var _successCount = 0

    var sawExitStatus1: Bool {
        lock.withLock { _sawExitStatus1 }
    }

    /// Count of `ChannelSuccessEvent`s the handler has emitted. The env-req and
    /// pty-req acks fire *synchronously* (before attach), while the shell-req
    /// ack fires from the same `loop.execute` block that installs the stream —
    /// so it is the LAST of the three and reaching that count is the reliable
    /// "attach complete" signal. A prior `sawSuccess` bool tripped on the env
    /// ack, letting bytes/window-change race ahead of stream install (dropped
    /// by the handler's `guard stream != nil`).
    var successCount: Int {
        lock.withLock { _successCount }
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        if let exitStatus = event as? SSHChannelRequestEvent.ExitStatus, exitStatus.exitStatus == 1 {
            lock.withLock { _sawExitStatus1 = true }
        }
        if event is ChannelSuccessEvent {
            lock.withLock { _successCount += 1 }
        }
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}

// MARK: - Test fakes

private enum FactoryError: Error { case notFound }

private final class RecordingStreamFactory: @unchecked Sendable {
    private let lock = NIOLock()
    private var _received: [String] = []
    private let result: Result<any TerminalByteStream, Error>

    var received: [String] { lock.withLock { _received } }

    init(returning result: Result<any TerminalByteStream, Error>) {
        self.result = result
    }

    var callable: @Sendable (String) async throws -> any TerminalByteStream {
        return { [self] name in
            self.lock.withLock { self._received.append(name) }
            return try self.result.get()
        }
    }
}

/// Echoes inbound bytes straight back to the caller via inboundBytes.
private final class EchoStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {
        continuation.yield(bytes)
    }

    func close() async {
        continuation.finish()
    }
}

/// Lets a test simulate the underlying process exiting on its own (child
/// EOF) by finishing `inboundBytes` directly — without the handler ever
/// calling `close()`. Mirrors `ZmxAttachEngine`'s reader-thread EOF path
/// (`dispatchExit` calls `continuation.finish()` even when the caller
/// never calls `close()`).
private final class FinishableStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {}

    func close() async {
        continuation.finish()
    }

    func finishInboundForTesting() {
        continuation.finish()
    }
}

/// Records resize calls without echoing bytes.
private final class RecordingResizeStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>
    private let lock = NIOLock()
    private var _lastResize: (cols: Int, rows: Int)?

    var lastResize: (cols: Int, rows: Int)? { lock.withLock { _lastResize } }

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {}
    func close() async { continuation.finish() }

    func resize(cols: Int, rows: Int) async {
        lock.withLock { _lastResize = (cols, rows) }
    }
}

/// Records close calls.
private final class ClosableStream: TerminalByteStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>
    private let lock = NIOLock()
    private var _didClose = false
    private var _closeCount = 0

    var didClose: Bool { lock.withLock { _didClose } }
    var closeCount: Int { lock.withLock { _closeCount } }

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {}

    func close() async {
        lock.withLock {
            _didClose = true
            _closeCount += 1
        }
        continuation.finish()
    }
}

/// `TerminalByteStream` + `TerminalSizeReporting` fake standing in for
/// `ZmxAttachEngine`'s size-poller callback. Tests invoke `onPTYSize`
/// directly to simulate a PTY resize (REMOTE-9.4) rather than driving a
/// real PTY.
private final class SizeReportingStream: TerminalByteStream, TerminalSizeReporting, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    let inboundBytes: AsyncStream<Data>
    private let lock = NIOLock()
    private var _onPTYSize: ((UInt16, UInt16) -> Void)?

    /// `TerminalSessionHandler.installCoordinator` sets this from the
    /// channel's event loop; the test reads/invokes it from the test's
    /// own task — lock-guarded so both sides see a consistent value.
    var onPTYSize: ((UInt16, UInt16) -> Void)? {
        get { lock.withLock { _onPTYSize } }
        set { lock.withLock { _onPTYSize = newValue } }
    }

    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    func send(_ bytes: Data) async throws {}
    func close() async { continuation.finish() }
}
