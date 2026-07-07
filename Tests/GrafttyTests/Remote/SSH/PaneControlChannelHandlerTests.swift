import Foundation
import GrafttyHostAgent
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest

/// `PaneControlChannelHandler.channelRead` spawns a `Task` that runs the
/// mutator on the Swift-concurrency global executor and then marshals the
/// response write back via `loop.execute`. `EmbeddedChannel`/`EmbeddedEventLoop`
/// are single-thread-only, so polling `embeddedEventLoop.run()` from the test
/// thread while that background `Task` calls `loop.execute` is a data race
/// (NIO logs "EmbeddedEventLoop is not thread-safe" and the process
/// intermittently crashes). These tests use `NIOAsyncTestingChannel`, whose
/// loop *is* thread-safe and whose `waitForOutboundWrite` drives the loop
/// until the handler's deferred write lands — no busy-poll, no race.
final class PaneControlChannelHandlerTests: XCTestCase {

    /// @spec REMOTE-7.2: When the host receives a `pane_control` request `{"type":"split","target":<sessionName>,"direction":<right|down|left|up>}`, the host shall replace the leaf whose `sessionName == target` with a new split node placed to the requested side of the original leaf, applied on the main actor, and reply `{"ok":true}` on success.
    func testDecodesAndDispatchesSplitRequest() async throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlChannelHandler(mutator: { [recorder] req in
            await recorder.handle(req)
        })

        let channel = try await Self.channel(with: handler)

        let request: PaneControlRequest = .split(target: "session-a", direction: .down)
        try await channel.writeInbound(Self.frame(request))

        let responseBuf = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        let resp = try JSONDecoder().decode(
            PaneControlResponse.self,
            from: Data(responseBuf.readableBytesView)
        )
        XCTAssertEqual(resp, .ok)
        XCTAssertEqual(recorder.lastRequest, request)
    }

    func testDecodesAndDispatchesSplitUpRequest() async throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlChannelHandler(mutator: { [recorder] req in
            await recorder.handle(req)
        })

        let channel = try await Self.channel(with: handler)

        let request: PaneControlRequest = .split(target: "session-a", direction: .up)
        try await channel.writeInbound(Self.frame(request))

        let responseBuf = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        let resp = try JSONDecoder().decode(
            PaneControlResponse.self,
            from: Data(responseBuf.readableBytesView)
        )
        XCTAssertEqual(resp, .ok)
        XCTAssertEqual(recorder.lastRequest, request)
    }

    func testMalformedRequestRepliesError() async throws {
        let handler = PaneControlChannelHandler(mutator: { _ in .ok })
        let channel = try await Self.channel(with: handler)

        var garbage = channel.allocator.buffer(capacity: 2)
        garbage.writeBytes(Data("{}".utf8))
        try await channel.writeInbound(garbage)

        let responseBuf = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        let resp = try JSONDecoder().decode(
            PaneControlResponse.self,
            from: Data(responseBuf.readableBytesView)
        )
        guard case .error(let code, _) = resp else {
            return XCTFail("expected error response, got \(resp)")
        }
        XCTAssertEqual(code, "malformed-request")
    }

    /// @spec REMOTE-7.3: When the host receives a `pane_control` request `{"type":"close","target":<sessionName>}`, the host shall destroy the surface for the leaf whose `sessionName == target` and reply `{"ok":true}` on success.
    func testDecodesAndDispatchesCloseRequest() async throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlChannelHandler(mutator: { [recorder] req in
            await recorder.handle(req)
        })

        let channel = try await Self.channel(with: handler)

        let request: PaneControlRequest = .close(target: "session-bravo")
        try await channel.writeInbound(Self.frame(request))

        let responseBuf = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        let resp = try JSONDecoder().decode(
            PaneControlResponse.self,
            from: Data(responseBuf.readableBytesView)
        )
        XCTAssertEqual(resp, .ok)
        XCTAssertEqual(recorder.lastRequest, request)
    }

    /// @spec REMOTE-7.4: When two `pane_control` requests target the same leaf concurrently, the host shall immediately reply to the second request with `{"ok":false,"code":"conflict","message":<human-readable>}` and continue processing only the first request. The conflict window for a target leaf ends once the first request's resulting `panes_state` snapshot has been emitted.
    func testConflictResponseShape() async throws {
        // The handler delegates per-leaf serialization to the injected
        // mutator (which production wires to AppState). What this test
        // pins is the wire contract: a mutator-returned conflict serializes
        // exactly as `{"ok":false,"code":"conflict","message":...}`.
        let handler = PaneControlChannelHandler(mutator: { _ in
            .error(code: "conflict", message: "target already busy")
        })

        let channel = try await Self.channel(with: handler)

        try await channel.writeInbound(
            Self.frame(.split(target: "session-x", direction: .right))
        )

        let responseBuf = try await channel.waitForOutboundWrite(as: ByteBuffer.self)

        // Assert the JSON shape directly, not just the decoded form —
        // the spec text pins specific key names.
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(responseBuf.readableBytesView))
                as? [String: Any]
        )
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["code"] as? String, "conflict")
        let message = try XCTUnwrap(json["message"] as? String)
        XCTAssertFalse(message.isEmpty)
    }

    /// @spec REMOTE-7.5: While the host services `pane_control` requests, the application shall route mutations through an injected mutator callback without giving `PaneControlHandler` a reference to `AppState`, enforcing per-client focus sovereignty by construction.
    func testHandlerHasNoAppStateReference() async throws {
        // Structural assertion: PaneControlChannelHandler.init takes only a
        // `Mutator` closure. Constructing it here with just that closure
        // demonstrates by construction that no AppState (or any other
        // ambient host state) is reachable from the handler — the only
        // path to mutate host state is through the injected callback.
        let mutator: PaneControlChannelHandler.Mutator = { _ in .ok }
        let handler = PaneControlChannelHandler(mutator: mutator)

        let channel = try await Self.channel(with: handler)

        try await channel.writeInbound(Self.frame(.close(target: "session-iso")))

        let responseBuf = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        let resp = try JSONDecoder().decode(
            PaneControlResponse.self,
            from: Data(responseBuf.readableBytesView)
        )
        XCTAssertEqual(resp, .ok)
    }

    // MARK: - helpers

    /// A `NIOAsyncTestingChannel` with `handler` installed on its (thread-safe)
    /// loop — the safe substitute for `EmbeddedChannel` when the handler bounces
    /// through Swift concurrency.
    private static func channel(
        with handler: PaneControlChannelHandler
    ) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        try await channel.pipeline.addHandler(handler).get()
        return channel
    }

    /// Encode `request` as the one-`ByteBuffer`-per-envelope frame the handler
    /// expects downstream of `LengthPrefixedFraming`.
    private static func frame(_ request: PaneControlRequest) -> ByteBuffer {
        let body = try! JSONEncoder().encode(request)
        var buf = ByteBufferAllocator().buffer(capacity: body.count)
        buf.writeBytes(body)
        return buf
    }
}

// MARK: - MutatorRecorder

/// Records the last request dispatched through the mutator.
/// Uses NIOLock for thread-safety (not NSLock).
private final class MutatorRecorder: @unchecked Sendable {
    private let lock = NIOLock()
    private var _lastRequest: PaneControlRequest?

    var lastRequest: PaneControlRequest? { lock.withLock { _lastRequest } }

    func handle(_ request: PaneControlRequest) async -> PaneControlResponse {
        lock.withLock { _lastRequest = request }
        return .ok
    }
}
