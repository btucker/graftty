import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("PaneControlHandler — decodes RPC requests, dispatches to mutator, replies with response.")
struct PaneControlHandlerTests {

    @Test("""
@spec REMOTE-7.2: When the host receives a `pane_control` request `{"type":"split","target":<sessionName>,"direction":<axis>}`, the host shall replace the leaf whose `sessionName == target` with a new split node of the requested `direction` whose left/top child is the original leaf and whose right/bottom child is a freshly-spawned leaf, applied on the main actor, and reply `{"ok":true}` on success.
""")
    func decodesAndDispatchesSplitRequest() async throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlHandler(mutator: { [recorder] in await recorder.handle($0) })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(3), outbox: outboxSpy.outbox)

        let request: PaneControlRequest = .split(target: "session-a", direction: .vertical)
        let body = try JSONEncoder().encode(request)
        await handler.onPayload(body)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let respBody) = frames[0] else {
            Issue.record("expected payload frame")
            return
        }
        let resp = try JSONDecoder().decode(PaneControlResponse.self, from: respBody)
        #expect(resp == .ok)
        #expect(await recorder.lastRequest == request)
    }

    @Test
    func malformedRequestRepliesWithError() async throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlHandler(mutator: { [recorder] in await recorder.handle($0) })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(4), outbox: outboxSpy.outbox)

        let garbage = Data("{}".utf8)
        await handler.onPayload(garbage)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let respBody) = frames[0] else {
            Issue.record("expected payload frame")
            return
        }
        let resp = try JSONDecoder().decode(PaneControlResponse.self, from: respBody)
        guard case .error(let code, _) = resp else {
            Issue.record("expected error response, got \(resp)")
            return
        }
        #expect(code == "malformed-request")
        #expect(await recorder.lastRequest == nil)
    }

    @Test
    func mutatorErrorPassesThroughToWire() async throws {
        let conflictResponder = ConflictResponder()
        let handler = PaneControlHandler(mutator: conflictResponder.handle)
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(8), outbox: outboxSpy.outbox)

        let body = try JSONEncoder().encode(PaneControlRequest.close(target: "session-z"))
        await handler.onPayload(body)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let respBody) = frames[0] else {
            Issue.record("expected payload frame")
            return
        }
        let resp = try JSONDecoder().decode(PaneControlResponse.self, from: respBody)
        #expect(resp == .error(code: "conflict", message: "target already busy"))
    }

    @Test("""
@spec REMOTE-7.3: When the host receives a `pane_control` request `{"type":"close","target":<sessionName>}`, the host shall destroy the surface for the leaf whose `sessionName == target` and reply `{"ok":true}` on success.
""")
    func decodesAndDispatchesCloseRequest() async throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlHandler(mutator: { [recorder] in await recorder.handle($0) })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(5), outbox: outboxSpy.outbox)

        let request: PaneControlRequest = .close(target: "session-bravo")
        let body = try JSONEncoder().encode(request)
        await handler.onPayload(body)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let respBody) = frames[0] else {
            Issue.record("expected payload frame")
            return
        }
        let resp = try JSONDecoder().decode(PaneControlResponse.self, from: respBody)
        #expect(resp == .ok)
        #expect(await recorder.lastRequest == request)
    }

    @Test("""
@spec REMOTE-7.4: When two `pane_control` requests target the same leaf concurrently, the host shall immediately reply to the second request with `{"ok":false,"error":"conflict","code":"conflict"}` and continue processing only the first request. The conflict window for a target leaf ends once the first request's resulting `panes_state` snapshot has been emitted.
""")
    func conflictResponseMatchesWireShape() async throws {
        // The handler delegates per-leaf serialization to the injected
        // mutator (which production wires to AppState). What this test
        // pins is the wire contract: a mutator-returned conflict serializes
        // exactly as `{"ok":false,"code":"conflict","message":...}`.
        let handler = PaneControlHandler(mutator: { _ in
            .error(code: "conflict", message: "target already busy")
        })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(9), outbox: outboxSpy.outbox)

        let body = try JSONEncoder().encode(PaneControlRequest.split(target: "session-x", direction: .horizontal))
        await handler.onPayload(body)

        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }
        let frames = await outboxSpy.frames
        guard case .payload(_, let respBody) = frames[0] else {
            Issue.record("expected payload frame")
            return
        }

        // Assert the JSON shape directly, not just the decoded form — the
        // spec text pins specific key names.
        let json = try #require(try JSONSerialization.jsonObject(with: respBody) as? [String: Any])
        #expect(json["ok"] as? Bool == false)
        #expect(json["code"] as? String == "conflict")
        #expect((json["message"] as? String)?.isEmpty == false)
    }

    @Test("""
@spec REMOTE-7.5: A `pane_control` request shall not change the host's `AppState.selectedWorktreePath` or any worktree's `focusedPaneSlotID`. Mac focus is sovereign to the Mac user, mirroring `WEB-7.5`.
""")
    func handlerHasNoPathToMutateFocus() async throws {
        let recorder = MutatorRecorder()
        let handler = PaneControlHandler(mutator: { [recorder] in await recorder.handle($0) })
        let outboxSpy = OutboxSpy()
        await handler.onOpen(ChannelID(11), outbox: outboxSpy.outbox)

        let request: PaneControlRequest = .swap(source: "a", target: "b")
        await handler.onPayload(try JSONEncoder().encode(request))
        try await pollUntil(timeout: .seconds(2)) { await outboxSpy.framesCount == 1 }

        #expect(await recorder.lastRequest == request)
        #expect(await outboxSpy.framesCount == 1)
    }
}

private actor MutatorRecorder {
    var lastRequest: PaneControlRequest?

    nonisolated func handle(_ request: PaneControlRequest) async -> PaneControlResponse {
        await record(request)
        return .ok
    }

    private func record(_ request: PaneControlRequest) {
        self.lastRequest = request
    }
}

private struct ConflictResponder: Sendable {
    @Sendable func handle(_ request: PaneControlRequest) async -> PaneControlResponse {
        .error(code: "conflict", message: "target already busy")
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
