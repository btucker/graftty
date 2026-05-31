import Foundation
import GrafttyHostAgent
import GrafttyProtocol
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest

final class PaneControlChannelHandlerTests: XCTestCase {

    /// @spec REMOTE-7.2: When the host receives a `pane_control` request `{"type":"split","target":<sessionName>,"direction":<axis>}`, the host shall replace the leaf whose `sessionName == target` with a new split node of the requested `direction` whose left/top child is the original leaf and whose right/bottom child is a freshly-spawned leaf, applied on the main actor, and reply `{"ok":true}` on success.
    func testDecodesAndDispatchesSplitRequest() throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlChannelHandler(mutator: { [recorder] req in
            await recorder.handle(req)
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)

        let request: PaneControlRequest = .split(target: "session-a", direction: .vertical)
        let body = try JSONEncoder().encode(request)
        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)
        try channel.writeInbound(buf)

        var outboundBuf: ByteBuffer?
        runLoopUntil(channel: channel) {
            outboundBuf = try? channel.readOutbound(as: ByteBuffer.self)
            return outboundBuf != nil
        }

        guard let responseBuf = outboundBuf else {
            return XCTFail("expected one outbound frame after split request")
        }
        let resp = try JSONDecoder().decode(
            PaneControlResponse.self,
            from: Data(responseBuf.readableBytesView)
        )
        XCTAssertEqual(resp, .ok)
        let lastRequest = recorder.lastRequest
        XCTAssertEqual(lastRequest, request)
    }

    func testMalformedRequestRepliesError() throws {
        let handler = PaneControlChannelHandler(mutator: { _ in .ok })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)

        let garbage = Data("{}".utf8)
        var buf = channel.allocator.buffer(capacity: garbage.count)
        buf.writeBytes(garbage)
        try channel.writeInbound(buf)

        var outboundBuf: ByteBuffer?
        runLoopUntil(channel: channel) {
            outboundBuf = try? channel.readOutbound(as: ByteBuffer.self)
            return outboundBuf != nil
        }

        guard let responseBuf = outboundBuf else {
            return XCTFail("expected one outbound frame after malformed request")
        }
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
    func testDecodesAndDispatchesCloseRequest() throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlChannelHandler(mutator: { [recorder] req in
            await recorder.handle(req)
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)

        let request: PaneControlRequest = .close(target: "session-bravo")
        let body = try JSONEncoder().encode(request)
        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)
        try channel.writeInbound(buf)

        var outboundBuf: ByteBuffer?
        runLoopUntil(channel: channel) {
            outboundBuf = try? channel.readOutbound(as: ByteBuffer.self)
            return outboundBuf != nil
        }

        guard let responseBuf = outboundBuf else {
            return XCTFail("expected one outbound frame after close request")
        }
        let resp = try JSONDecoder().decode(
            PaneControlResponse.self,
            from: Data(responseBuf.readableBytesView)
        )
        XCTAssertEqual(resp, .ok)
        let lastRequest = recorder.lastRequest
        XCTAssertEqual(lastRequest, request)
    }

    /// @spec REMOTE-7.4: When two `pane_control` requests target the same leaf concurrently, the host shall immediately reply to the second request with `{"ok":false,"code":"conflict","message":<human-readable>}` and continue processing only the first request. The conflict window for a target leaf ends once the first request's resulting `panes_state` snapshot has been emitted.
    func testConflictResponseShape() throws {
        // The handler delegates per-leaf serialization to the injected
        // mutator (which production wires to AppState). What this test
        // pins is the wire contract: a mutator-returned conflict serializes
        // exactly as `{"ok":false,"code":"conflict","message":...}`.
        let handler = PaneControlChannelHandler(mutator: { _ in
            .error(code: "conflict", message: "target already busy")
        })

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)

        let body = try JSONEncoder().encode(
            PaneControlRequest.split(target: "session-x", direction: .horizontal)
        )
        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)
        try channel.writeInbound(buf)

        var outboundBuf: ByteBuffer?
        runLoopUntil(channel: channel) {
            outboundBuf = try? channel.readOutbound(as: ByteBuffer.self)
            return outboundBuf != nil
        }

        guard let responseBuf = outboundBuf else {
            return XCTFail("expected one outbound frame after conflict-returning mutator")
        }

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
    func testHandlerHasNoAppStateReference() throws {
        // Structural assertion: PaneControlChannelHandler.init takes only a
        // `Mutator` closure. Constructing it here with just that closure
        // demonstrates by construction that no AppState (or any other
        // ambient host state) is reachable from the handler — the only
        // path to mutate host state is through the injected callback.
        let mutator: PaneControlChannelHandler.Mutator = { _ in .ok }
        let handler = PaneControlChannelHandler(mutator: mutator)

        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(handler)

        let body = try JSONEncoder().encode(PaneControlRequest.close(target: "session-iso"))
        var buf = channel.allocator.buffer(capacity: body.count)
        buf.writeBytes(body)
        try channel.writeInbound(buf)

        var outboundBuf: ByteBuffer?
        runLoopUntil(channel: channel) {
            outboundBuf = try? channel.readOutbound(as: ByteBuffer.self)
            return outboundBuf != nil
        }

        guard let responseBuf = outboundBuf else {
            return XCTFail("expected one outbound frame")
        }
        let resp = try JSONDecoder().decode(
            PaneControlResponse.self,
            from: Data(responseBuf.readableBytesView)
        )
        XCTAssertEqual(resp, .ok)
    }

    // MARK: - helpers

    /// EmbeddedChannel polling helper. Tasks spawned by the handler run
    /// on the global executor and schedule writes back via
    /// `loop.execute`. Spinning `RunLoop.main` lets those Tasks complete,
    /// then `embeddedEventLoop.run()` drains the pending writes.
    private func runLoopUntil(channel: EmbeddedChannel, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2.0)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            channel.embeddedEventLoop.run()
        }
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
