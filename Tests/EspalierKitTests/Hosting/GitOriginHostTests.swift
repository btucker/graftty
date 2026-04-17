import Testing
import Foundation
@testable import EspalierKit

@Suite("GitOriginHost.parse")
struct GitOriginHostParseTests {
    @Test func parsesGitHubSSHURL() {
        let origin = GitOriginHost.parse(remoteURL: "git@github.com:btucker/espalier.git")
        #expect(origin == HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "espalier"))
    }

    @Test func parsesGitHubHTTPSURL() {
        let origin = GitOriginHost.parse(remoteURL: "https://github.com/btucker/espalier.git")
        #expect(origin == HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "espalier"))
    }

    @Test func parsesGitHubHTTPSWithoutDotGit() {
        let origin = GitOriginHost.parse(remoteURL: "https://github.com/btucker/espalier")
        #expect(origin == HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "espalier"))
    }

    @Test func parsesGitLabSSHURL() {
        let origin = GitOriginHost.parse(remoteURL: "git@gitlab.com:foo/bar.git")
        #expect(origin == HostingOrigin(provider: .gitlab, host: "gitlab.com", owner: "foo", repo: "bar"))
    }

    @Test func enterpriseGitHubMatchesByHostSubstring() {
        let origin = GitOriginHost.parse(remoteURL: "git@github.acme.com:team/proj.git")
        #expect(origin == HostingOrigin(provider: .github, host: "github.acme.com", owner: "team", repo: "proj"))
    }

    @Test func enterpriseGitLabMatchesByHostSubstring() {
        let origin = GitOriginHost.parse(remoteURL: "git@gitlab.acme.com:team/proj.git")
        #expect(origin == HostingOrigin(provider: .gitlab, host: "gitlab.acme.com", owner: "team", repo: "proj"))
    }

    @Test func unrecognizedHostIsUnsupported() {
        let origin = GitOriginHost.parse(remoteURL: "git@bitbucket.org:foo/bar.git")
        #expect(origin?.provider == .unsupported)
    }

    @Test func localPathReturnsNil() {
        #expect(GitOriginHost.parse(remoteURL: "/some/local/path") == nil)
        #expect(GitOriginHost.parse(remoteURL: "file:///some/path") == nil)
    }

    @Test func emptyReturnsNil() {
        #expect(GitOriginHost.parse(remoteURL: "") == nil)
    }

    @Test func gitProtocolReturnsNil() {
        #expect(GitOriginHost.parse(remoteURL: "git://example.com/foo/bar.git") == nil)
    }
}
