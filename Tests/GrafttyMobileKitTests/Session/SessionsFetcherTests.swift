#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
struct SessionsFetcherTests {

    @Test
    func buildsRequestAgainstBaseURL() throws {
        let base = URL(string: "http://mac.ts.net:8799/")!
        let request = SessionsFetcher.request(baseURL: base)
        #expect(request.url?.absoluteString == "http://mac.ts.net:8799/sessions")
        #expect(request.httpMethod == "GET")
    }

    @Test
    func appendsSessionsPathEvenWhenBaseURLHasNoTrailingSlash() throws {
        let base = URL(string: "http://mac.ts.net:8799")!
        let request = SessionsFetcher.request(baseURL: base)
        #expect(request.url?.absoluteString == "http://mac.ts.net:8799/sessions")
    }

    @Test
    func decodesSessionsResponse() throws {
        let raw = #"""
        [
          {"name":"graftty-abcd1234","worktreePath":"/w/a","repoDisplayName":"r","worktreeDisplayName":"a"},
          {"name":"graftty-abcd5678","worktreePath":"/w/b","repoDisplayName":"r","worktreeDisplayName":"b"}
        ]
        """#
        let result = try SessionsFetcher.decode(Data(raw.utf8))
        #expect(result.count == 2)
        #expect(result.map(\.name) == ["graftty-abcd1234", "graftty-abcd5678"])
    }
}
#endif
