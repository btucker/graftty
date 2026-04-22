#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
struct WorktreeCreatorTests {

    private func sampleRequest() -> CreateWorktreeRequest {
        CreateWorktreeRequest(
            repoPath: "/Users/b/projects/graftty",
            worktreeName: "new-feature",
            branchName: "new-feature"
        )
    }

    @Test
    func buildsPOSTRequestAgainstBaseURL() throws {
        let base = URL(string: "http://mac.ts.net:8799/")!
        let req = try WorktreeCreator.request(baseURL: base, body: sampleRequest())
        #expect(req.url?.absoluteString == "http://mac.ts.net:8799/worktrees")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        // Body should be valid JSON round-tripping the input.
        let body = try #require(req.httpBody)
        let decoded = try JSONDecoder().decode(CreateWorktreeRequest.self, from: body)
        #expect(decoded == sampleRequest())
    }

    @Test
    func appendsWorktreesPathEvenWhenBaseURLHasNoTrailingSlash() throws {
        let base = URL(string: "http://mac.ts.net:8799")!
        let req = try WorktreeCreator.request(baseURL: base, body: sampleRequest())
        #expect(req.url?.absoluteString == "http://mac.ts.net:8799/worktrees")
    }

    @Test
    func decodesSuccessResponse() throws {
        let raw = #"""
        {"sessionName":"graftty-abcd1234","worktreePath":"/Users/b/projects/graftty/.worktrees/new-feature"}
        """#
        let response = try WorktreeCreator.decodeSuccess(Data(raw.utf8))
        #expect(response.sessionName == "graftty-abcd1234")
        #expect(response.worktreePath.hasSuffix("/new-feature"))
    }

    @Test
    func decodeErrorReturnsStderrMessageFromErrorBody() {
        let raw = Data(#"{"error":"fatal: invalid reference: feature@home"}"#.utf8)
        let msg = WorktreeCreator.decodeError(raw)
        #expect(msg == "fatal: invalid reference: feature@home")
    }

    @Test
    func decodeErrorReturnsNilForMalformedBody() {
        let raw = Data("not-json".utf8)
        let msg = WorktreeCreator.decodeError(raw)
        #expect(msg == nil)
    }
}
#endif
