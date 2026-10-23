import Testing
import Foundation
import NIOHTTP1
@testable import GrafttyKit

#if os(macOS)
/// The REST wire map of each outcome, without a server, so CI covers it (the
/// endpoint and transcript suites skip in CI). Values match the transcript
/// in `WebServerRouteGoldenTests`.
@Suite("@spec WEB-7.15: When a REST worktree route finishes, the application shall answer each outcome with its existing status and JSON body.")
struct WebServerRESTResponseTests {
    private func json(_ response: WebServer.RESTResponse) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: response.body) as? NSDictionary)
    }

    @Test func createOutcomes() throws {
        let cases: [(WebServer.CreateWorktreeOutcome, HTTPResponseStatus, NSDictionary)] = [
            (.success(.init(sessionName: "s", worktreePath: "/w")), .ok, ["sessionName": "s", "worktreePath": "/w"]),
            (.invalid("bad"), .badRequest, ["error": "bad"]),
            (.gitFailed("git"), .conflict, ["error": "git"]),
            (.conflict(message: "mounted"), .conflict, ["error": "mounted"]),
            (.internalFailure("boom"), .internalServerError, ["error": "boom"]),
        ]
        for (outcome, status, body) in cases {
            #expect(outcome.restResponse.status == status)
            #expect(outcome.restResponse.contentType == "application/json; charset=utf-8")
            #expect(try json(outcome.restResponse) == body)
        }
    }

    @Test func pullOutcomes() throws {
        let cases: [(WebServer.PullDefaultBranchOutcome, HTTPResponseStatus, NSDictionary)] = [
            (.success(.init(ok: true)), .ok, ["ok": true]),
            (.invalid("not behind"), .badRequest, ["error": "not behind"]),
            (.gitFailed("ff"), .conflict, ["error": "ff"]),
            (.internalFailure("boom"), .internalServerError, ["error": "boom"]),
        ]
        for (outcome, status, body) in cases {
            #expect(outcome.restResponse.status == status)
            #expect(try json(outcome.restResponse) == body)
        }
    }

    @Test func deleteOutcomes() throws {
        let cases: [(WebServer.DeleteWorktreeOutcome, HTTPResponseStatus, NSDictionary)] = [
            (.success(.init(dismissed: true)), .ok, ["dismissed": true]),
            (.invalid("main"), .badRequest, ["error": "main"]),
            (.notFound("unknown"), .notFound, ["error": "unknown"]),
            (.gitFailedForceable(stderr: "dirty", shortStatus: "?? a"), .conflict,
             ["error": "dirty", "forceAllowed": true, "shortStatus": "?? a"]),
            (.gitFailedFinal("locked"), .conflict, ["error": "locked", "forceAllowed": false]),
            (.internalFailure("boom"), .internalServerError, ["error": "boom"]),
        ]
        for (outcome, status, body) in cases {
            #expect(outcome.restResponse.status == status)
            #expect(try json(outcome.restResponse) == body)
        }
    }
}
#endif
