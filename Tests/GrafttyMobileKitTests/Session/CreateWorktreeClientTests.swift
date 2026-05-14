#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit

@Suite
struct CreateWorktreeClientTests {

    @Test
    func buildsPOSTRequestAgainstBaseURLWithJSONBody() throws {
        let base = URL(string: "http://mac.ts.net:8799/")!
        let body = CreateWorktreeClient.Request(
            repoPath: "/repo",
            worktreeName: "feature-xyz",
            branchName: "feature-xyz"
        )
        let req = try CreateWorktreeClient.request(baseURL: base, body: body)
        #expect(req.url?.absoluteString == "http://mac.ts.net:8799/worktrees")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try #require(req.httpBody.map { try JSONSerialization.jsonObject(with: $0) as? [String: AnyHashable] })
        #expect(json == [
            "repoPath": "/repo",
            "worktreeName": "feature-xyz",
            "branchName": "feature-xyz",
            "existing": false,
        ])
    }

    @Test
    func appendsPathEvenWhenBaseURLHasNoTrailingSlash() throws {
        let base = URL(string: "http://mac.ts.net:8799")!
        let body = CreateWorktreeClient.Request(repoPath: "/r", worktreeName: "x", branchName: "x")
        let req = try CreateWorktreeClient.request(baseURL: base, body: body)
        #expect(req.url?.absoluteString == "http://mac.ts.net:8799/worktrees")
    }

    @Test
    func decodesSuccessResponse() throws {
        let raw = #"{"sessionName":"graftty-abcd1234","worktreePath":"/repo/.worktrees/feature"}"#
        let resp = try CreateWorktreeClient.decodeResponse(Data(raw.utf8))
        #expect(resp.sessionName == "graftty-abcd1234")
        #expect(resp.worktreePath == "/repo/.worktrees/feature")
    }

    @Test
    func extractsErrorMessageFromEnvelope() throws {
        let raw = #"{"error":"fatal: A branch named 'foo' already exists."}"#
        let msg = CreateWorktreeClient.decodeErrorMessage(Data(raw.utf8))
        #expect(msg == "fatal: A branch named 'foo' already exists.")
    }

    @Test
    func decodeErrorMessageReturnsNilOnUnparseableBody() {
        let msg = CreateWorktreeClient.decodeErrorMessage(Data("not json".utf8))
        #expect(msg == nil)
    }

    @Test
    func userMessageSurfacesServerErrorVerbatim() {
        let err = CreateWorktreeClient.CreateError.gitFailed("fatal: worktree already exists")
        #expect(err.userMessage == "fatal: worktree already exists")
    }

    @Test
    func userMessageHasStableFallbackForTransportErrors() {
        #expect(CreateWorktreeClient.CreateError.transport.userMessage == "Couldn't reach the server.")
        #expect(CreateWorktreeClient.CreateError.forbidden.userMessage.contains("tailnet"))
        #expect(CreateWorktreeClient.CreateError.http(500).userMessage == "HTTP 500")
    }
}
#endif
