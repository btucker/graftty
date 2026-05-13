#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
struct DeleteWorktreeClientTests {

    @Test
    func buildsPOSTRequestAgainstBaseURLWithJSONBody() throws {
        let base = URL(string: "http://mac.ts.net:8799/")!
        let body = DeleteWorktreeClient.Request(
            worktreePath: "/repo/.worktrees/feature",
            force: false
        )
        let req = try DeleteWorktreeClient.request(baseURL: base, body: body)
        #expect(req.url?.absoluteString == "http://mac.ts.net:8799/worktrees/delete")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(req.httpBody.map {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(json["worktreePath"] as? String == "/repo/.worktrees/feature")
        #expect(json["force"] as? Bool == false)
    }

    @Test
    func appendsPathEvenWhenBaseURLHasNoTrailingSlash() throws {
        let base = URL(string: "http://mac.ts.net:8799")!
        let body = DeleteWorktreeClient.Request(worktreePath: "/r", force: true)
        let req = try DeleteWorktreeClient.request(baseURL: base, body: body)
        #expect(req.url?.absoluteString == "http://mac.ts.net:8799/worktrees/delete")
    }

    @Test
    func forceTrueIsEncodedInBody() throws {
        let base = URL(string: "http://mac.ts.net:8799/")!
        let body = DeleteWorktreeClient.Request(worktreePath: "/r", force: true)
        let req = try DeleteWorktreeClient.request(baseURL: base, body: body)
        let json = try #require(req.httpBody.map {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any]
        })
        #expect(json["force"] as? Bool == true)
    }

    @Test
    func decodesSuccessResponseDismissedFalse() throws {
        let raw = #"{"dismissed":false}"#
        let resp = try DeleteWorktreeClient.decodeResponse(Data(raw.utf8))
        #expect(resp.dismissed == false)
    }

    @Test
    func decodesSuccessResponseDismissedTrue() throws {
        let raw = #"{"dismissed":true}"#
        let resp = try DeleteWorktreeClient.decodeResponse(Data(raw.utf8))
        #expect(resp.dismissed == true)
    }

    @Test
    func decodesForceableConflictBody() throws {
        let raw = #"{"error":"contains modified files","forceAllowed":true,"shortStatus":" M foo.swift"}"#
        let conflict = try #require(DeleteWorktreeClient.decodeConflict(Data(raw.utf8)))
        #expect(conflict.error == "contains modified files")
        #expect(conflict.forceAllowed == true)
        #expect(conflict.shortStatus == " M foo.swift")
    }

    @Test
    func decodesFinalConflictBodyWithoutShortStatus() throws {
        let raw = #"{"error":"main checkout cannot be removed","forceAllowed":false}"#
        let conflict = try #require(DeleteWorktreeClient.decodeConflict(Data(raw.utf8)))
        #expect(conflict.error == "main checkout cannot be removed")
        #expect(conflict.forceAllowed == false)
        #expect(conflict.shortStatus == nil)
    }

    @Test
    func decodeConflictReturnsNilOnUnparseableBody() {
        let conflict = DeleteWorktreeClient.decodeConflict(Data("not json".utf8))
        #expect(conflict == nil)
    }

    @Test
    func extractsErrorMessageFromEnvelope() throws {
        let raw = #"{"error":"worktree deletion not available"}"#
        let msg = DeleteWorktreeClient.decodeErrorMessage(Data(raw.utf8))
        #expect(msg == "worktree deletion not available")
    }

    @Test
    func decodeErrorMessageReturnsNilOnUnparseableBody() {
        let msg = DeleteWorktreeClient.decodeErrorMessage(Data("not json".utf8))
        #expect(msg == nil)
    }

    @Test
    func userMessageNilForForceableSoCallerShowsDialog() {
        let err = DeleteWorktreeClient.DeleteError.gitFailedForceable(
            stderr: "contains modified files",
            shortStatus: " M foo.swift"
        )
        #expect(err.userMessage == nil)
    }

    @Test
    func userMessageSurfacesFinalErrorVerbatim() {
        let err = DeleteWorktreeClient.DeleteError.gitFailedFinal("fatal: cannot remove main checkout")
        #expect(err.userMessage == "fatal: cannot remove main checkout")
    }

    @Test
    func userMessageHasStableFallbackForTransportErrors() {
        #expect(DeleteWorktreeClient.DeleteError.transport.userMessage == "Couldn't reach the server.")
        #expect(DeleteWorktreeClient.DeleteError.forbidden.userMessage?.contains("tailnet") == true)
        #expect(DeleteWorktreeClient.DeleteError.http(500).userMessage == "HTTP 500")
        #expect(DeleteWorktreeClient.DeleteError.notFound.userMessage?.contains("no longer") == true)
    }
}
#endif
