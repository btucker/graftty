import Foundation
import Testing
@testable import GrafttyProtocol

struct TeamRPCSessionTests {
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
