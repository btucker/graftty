#if canImport(UIKit)
import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@Suite
struct ReposFetcherTests {

    @Test
    func buildsRequestAgainstBaseURL() throws {
        let base = URL(string: "http://mac.ts.net:8799/")!
        let request = try ReposFetcher.request(
            baseURL: base,
            includeRemoteWorktrees: true
        )
        #expect(request.url?.absoluteString == "http://mac.ts.net:8799/repos")
        #expect(request.httpMethod == "GET")
        #expect(
            request.value(
                forHTTPHeaderField: RemoteWorktreeFeatures.headerName
            ) == RemoteWorktreeFeatures.oneHopRelay
        )
    }

    @Test
    func omitsRelayFeatureForUnpairedHosts() throws {
        let base = URL(string: "http://mac.ts.net:8799/")!
        let request = try ReposFetcher.request(baseURL: base)
        #expect(
            request.value(
                forHTTPHeaderField: RemoteWorktreeFeatures.headerName
            ) == nil
        )
    }

    @Test
    func appendsReposPathEvenWhenBaseURLHasNoTrailingSlash() throws {
        let base = URL(string: "http://mac.ts.net:8799")!
        let request = try ReposFetcher.request(baseURL: base)
        #expect(request.url?.absoluteString == "http://mac.ts.net:8799/repos")
    }

    @Test
    func decodesReposResponse() throws {
        let raw = #"""
        [
          {"path":"/Users/a/projects/alpha","displayName":"alpha"},
          {"path":"/Users/a/projects/beta","displayName":"beta"}
        ]
        """#
        let result = try ReposFetcher.decode(Data(raw.utf8))
        #expect(result.count == 2)
        #expect(result.map(\.displayName) == ["alpha", "beta"])
        #expect(result.first?.path == "/Users/a/projects/alpha")
    }

    @Test
    func decodesTargetMacOriginForRemoteRepository() throws {
        let raw = #"""
        [
          {
            "path":"relay-repository-token",
            "displayName":"graftty",
            "origin":{
              "deviceID":{"value":"studio-mac"},
              "deviceLabel":"Studio Mac",
              "relayDepth":1
            }
          }
        ]
        """#
        let result = try ReposFetcher.decode(Data(raw.utf8))
        #expect(result.first?.origin?.deviceID.value == "studio-mac")
        #expect(result.first?.origin?.deviceLabel == "Studio Mac")
        #expect(result.first?.origin?.relayDepth == 1)
    }

    @Test
    func decodesRelayedBranchSource() throws {
        let raw = #"""
        [
          {
            "path":"relay-repository-token",
            "displayName":"graftty",
            "branches":[
              {
                "name":"remote-feature",
                "source":"remote_only",
                "lastCommitDate":0,
                "pullRequest":null
              }
            ]
          }
        ]
        """#

        let result = try ReposFetcher.decode(Data(raw.utf8))

        #expect(result.first?.branches?.first?.name == "remote-feature")
        #expect(result.first?.branches?.first?.source == .remoteOnly)
    }
}
#endif
