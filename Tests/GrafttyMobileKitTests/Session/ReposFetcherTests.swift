#if canImport(UIKit)
import Foundation
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
struct ReposFetcherTests {

    @Test
    func buildsRequestAgainstBaseURL() throws {
        let base = URL(string: "http://mac.ts.net:8799/")!
        let req = ReposFetcher.request(baseURL: base)
        #expect(req.url?.absoluteString == "http://mac.ts.net:8799/repos")
        #expect(req.httpMethod == "GET")
    }

    @Test
    func appendsReposPathEvenWhenBaseURLHasNoTrailingSlash() throws {
        let base = URL(string: "http://mac.ts.net:8799")!
        let req = ReposFetcher.request(baseURL: base)
        #expect(req.url?.absoluteString == "http://mac.ts.net:8799/repos")
    }

    @Test
    func decodesReposResponse() throws {
        let raw = #"""
        [
          {"path":"/Users/b/projects/graftty","displayName":"graftty"},
          {"path":"/Users/b/projects/other","displayName":"other"}
        ]
        """#
        let repos = try ReposFetcher.decode(Data(raw.utf8))
        #expect(repos.count == 2)
        #expect(repos[0].displayName == "graftty")
        #expect(repos[1].path == "/Users/b/projects/other")
    }

    @Test
    func decodeRejectsUnexpectedShape() {
        let raw = Data(#"{"not":"an array"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try ReposFetcher.decode(raw)
        }
    }
}
#endif
