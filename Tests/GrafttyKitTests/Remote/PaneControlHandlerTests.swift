import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("PaneControlHandler — decodes RPC requests, dispatches to mutator, replies with response.")
struct PaneControlHandlerTests {

    @Test
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
