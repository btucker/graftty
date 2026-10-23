import Testing
import Foundation
import NIOHTTP1
@testable import GrafttyKit

#if os(macOS)
/// The REST wire map of each outcome, without a server, so CI covers it (the
/// endpoint and transcript suites skip in CI). Values match the transcript
/// in `WebServerRouteGoldenTests`.
@Suite("@spec WEB-7.15: When a REST worktree create, delete or default-branch pull finishes, the application shall answer success with 200 and its JSON result, invalid input with 400, an unknown worktree with 404, a Git refusal or conflict with 409, and any other failure with 500, each failure carrying a JSON error message and a delete 409 also carrying whether a forced retry is allowed.")
struct WebServerRESTResponseTests {
    private func expectResponses(_ cases: [(WebServer.RESTResponse, HTTPResponseStatus, NSDictionary)]) throws {
        for (response, status, body) in cases {
            #expect(response.status == status)
            #expect(response.contentType == "application/json; charset=utf-8")
            #expect(try #require(JSONSerialization.jsonObject(with: response.body) as? NSDictionary) == body)
        }
    }

    @Test func createOutcomes() throws {
        try expectResponses([
            (WebServer.CreateWorktreeOutcome.success(.init(sessionName: "s", worktreePath: "/w")).restResponse, .ok,
             ["sessionName": "s", "worktreePath": "/w"]),
            (WebServer.CreateWorktreeOutcome.invalid("bad").restResponse, .badRequest, ["error": "bad"]),
            (WebServer.CreateWorktreeOutcome.gitFailed("git").restResponse, .conflict, ["error": "git"]),
            (WebServer.CreateWorktreeOutcome.conflict(message: "mounted").restResponse, .conflict, ["error": "mounted"]),
            (WebServer.CreateWorktreeOutcome.internalFailure("boom").restResponse, .internalServerError, ["error": "boom"]),
        ])
    }

    @Test func pullOutcomes() throws {
        try expectResponses([
            (WebServer.PullDefaultBranchOutcome.success(.init(ok: true)).restResponse, .ok, ["ok": true]),
            (WebServer.PullDefaultBranchOutcome.invalid("not behind").restResponse, .badRequest, ["error": "not behind"]),
            (WebServer.PullDefaultBranchOutcome.gitFailed("ff").restResponse, .conflict, ["error": "ff"]),
            (WebServer.PullDefaultBranchOutcome.internalFailure("boom").restResponse, .internalServerError, ["error": "boom"]),
        ])
    }

    @Test func deleteOutcomes() throws {
        try expectResponses([
            (WebServer.DeleteWorktreeOutcome.success(.init(dismissed: true)).restResponse, .ok, ["dismissed": true]),
            (WebServer.DeleteWorktreeOutcome.invalid("main").restResponse, .badRequest, ["error": "main"]),
            (WebServer.DeleteWorktreeOutcome.notFound("unknown").restResponse, .notFound, ["error": "unknown"]),
            (WebServer.DeleteWorktreeOutcome.gitFailedForceable(stderr: "dirty", shortStatus: "?? a").restResponse, .conflict,
             ["error": "dirty", "forceAllowed": true, "shortStatus": "?? a"]),
            (WebServer.DeleteWorktreeOutcome.gitFailedFinal("locked").restResponse, .conflict,
             ["error": "locked", "forceAllowed": false]),
            (WebServer.DeleteWorktreeOutcome.internalFailure("boom").restResponse, .internalServerError, ["error": "boom"]),
        ])
    }
}
#endif
