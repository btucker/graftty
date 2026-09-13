import Foundation
import Testing
@testable import GrafttyProtocol

struct TeamRPCSessionTests {
    @Test("@spec TEAM-14.29: While canceled or timed-out team requests still have unfinished network writes, the application shall retain their admission slots until those writes finish.")
    func canceledWritesRetainAdmissionSlots() async throws {
        let writes = BlockedTeamWrites()
        let session = TeamRPCSession(handler: { $0 }, writer: { _ in await writes.block() }, responseTimeout: .seconds(60))
        let requests = (0..<256).map { _ in Task { try await session.send(Data()) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await writes.count < 256, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await writes.count == 256)
        for request in requests { request.cancel() }
        for request in requests { _ = try? await request.value }
        let extra = Task { try await session.send(Data()) }
        let abort = Task {
            try? await Task.sleep(for: .milliseconds(100))
            extra.cancel()
        }
        await #expect(throws: TeamRPCSession.SessionError.overloaded) { try await extra.value }
        abort.cancel()
        await session.close()
        await writes.release()
    }

    @Test("@spec TEAM-14.30: When a team session closes before a queued request starts, the application shall discard that request without invoking its application handler.")
    func closeDiscardsQueuedRequest() async throws {
        let calls = TeamTestWrites()
        let session = TeamRPCSession(handler: { bytes in
            await calls.append(bytes)
            return bytes
        }, writer: { _ in })
        let envelope = TeamRPCEnvelope(kind: .request, requestID: UUID(), payload: Data("message".utf8))
        await session.enqueueThenCloseForTesting(try JSONEncoder().encode(envelope))
        // Let the canceled child task run before inspecting its side effects.
        try await Task.sleep(for: .milliseconds(20))
        #expect(await calls.values.isEmpty)
    }

    @Test("@spec TEAM-14.20: When either Mac sends concurrent team requests over one authenticated channel, the application shall correlate each response by its request identifier.")
    func duplexRequests() async throws {
        let link = TeamTestLink()
        let a = TeamRPCSession(handler: { Data("A:".utf8) + $0 }, writer: { await link.deliverToB($0) })
        let b = TeamRPCSession(handler: { Data("B:".utf8) + $0 }, writer: { await link.deliverToA($0) })
        await link.attach(a: a, b: b)
        async let first = a.send(Data("first".utf8))
        async let second = a.send(Data("second".utf8))
        async let reverse = b.send(Data("reverse".utf8))
        #expect(try await first == Data("B:first".utf8))
        #expect(try await second == Data("B:second".utf8))
        #expect(try await reverse == Data("A:reverse".utf8))
        await a.close()
        await b.close()
    }

    @Test("@spec TEAM-14.21: When a team channel closes, the application shall fail pending requests and reject subsequent sends.")
    func closeRejectsRequests() async throws {
        let writes = TeamTestWrites()
        let session = TeamRPCSession(handler: { $0 }, writer: { await writes.append($0) })
        let request = Task { try await session.send(Data()) }
        while await writes.values.isEmpty { await Task.yield() }
        await session.close()
        await #expect(throws: TeamRPCSession.SessionError.channelClosed) { try await request.value }
        await #expect(throws: TeamRPCSession.SessionError.channelClosed) { try await session.send(Data()) }
    }

    @Test("@spec TEAM-14.22: If a team response does not arrive before its deadline, then the application shall fail that request without matching its late response to another request.")
    func requestTimesOut() async throws {
        let writes = TeamTestWrites()
        let session = TeamRPCSession(handler: { $0 }, writer: { await writes.append($0) }, responseTimeout: .milliseconds(30))
        await #expect(throws: TeamRPCSession.SessionError.timedOut) { try await session.send(Data()) }
        let first = try JSONDecoder().decode(TeamRPCEnvelope.self, from: #require(await writes.values.first))
        let second = Task { try await session.send(Data("second".utf8)) }
        while await writes.values.count < 2 { await Task.yield() }
        let next = try JSONDecoder().decode(TeamRPCEnvelope.self, from: #require(await writes.values.last))
        await session.receive(try JSONEncoder().encode(TeamRPCEnvelope(kind: .response, requestID: first.requestID, payload: Data("late".utf8))))
        await session.receive(try JSONEncoder().encode(TeamRPCEnvelope(kind: .response, requestID: next.requestID, payload: Data("correct".utf8))))
        #expect(try await second.value == Data("correct".utf8))
        await session.close()
    }

    @Test("@spec TEAM-14.25: When a caller cancels a team request, the application shall release that request without closing the shared channel.")
    func cancellation() async throws {
        let writes = TeamTestWrites()
        let session = TeamRPCSession(handler: { $0 }, writer: { await writes.append($0) })
        let request = Task { try await session.send(Data()) }
        while await writes.values.isEmpty { await Task.yield() }
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        let second = Task { try await session.send(Data()) }
        while await writes.values.count < 2 { await Task.yield() }
        let next = try JSONDecoder().decode(TeamRPCEnvelope.self, from: #require(await writes.values.last))
        await session.receive(try JSONEncoder().encode(TeamRPCEnvelope(kind: .response, requestID: next.requestID, payload: Data("ok".utf8))))
        #expect(try await second.value == Data("ok".utf8))
        await session.close()
    }
}

private actor TeamTestWrites {
    var values: [Data] = []
    func append(_ data: Data) { values.append(data) }
}

private actor TeamTestLink {
    var a: TeamRPCSession?
    var b: TeamRPCSession?
    func attach(a: TeamRPCSession, b: TeamRPCSession) { self.a = a; self.b = b }
    func deliverToA(_ bytes: Data) async { await a?.receive(bytes) }
    func deliverToB(_ bytes: Data) async { await b?.receive(bytes) }
}

private actor BlockedTeamWrites {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var count = 0
    func block() async {
        count += 1
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private extension TeamRPCSession {
    func enqueueThenCloseForTesting(_ bytes: Data) async {
        await receive(bytes)
        close()
    }
}
