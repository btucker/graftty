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

    @Test func parsesSSHURLWithExplicitPort() {
        let origin = GitOriginHost.parse(remoteURL: "ssh://git@github.com:22/btucker/espalier.git")
        #expect(origin == HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "espalier"))
    }

    @Test func lowercasesHostForProviderMatching() {
        let origin = GitOriginHost.parse(remoteURL: "https://GitHub.Com/btucker/espalier.git")
        #expect(origin?.provider == .github)
    }

    @Test func rejectsFalsePositiveGithubSubstring() {
        // "github-mirror.example.com" is NOT GitHub — rejects substring match.
        let origin = GitOriginHost.parse(remoteURL: "git@github-mirror.example.com:x/y.git")
        #expect(origin?.provider == .unsupported)
    }

    @Test func parsesGitLabSubgroupURL() {
        // GitLab allows nested subgroups — repo path contains slashes.
        let origin = GitOriginHost.parse(remoteURL: "git@gitlab.com:group/subgroup/proj.git")
        #expect(origin?.slug == "group/subgroup/proj")
        #expect(origin?.provider == .gitlab)
    }
}

@Suite("GitOriginHost.detect")
struct GitOriginHostDetectTests {
    @Test func detectsGitHubOrigin() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["remote", "get-url", "origin"],
            output: CLIOutput(stdout: "git@github.com:btucker/espalier.git\n", stderr: "", exitCode: 0)
        )
        GitRunner.configure(executor: fake)
        defer { GitRunner.resetForTests() }

        let origin = try await GitOriginHost.detect(repoPath: "/tmp/repo")
        #expect(origin?.provider == .github)
        #expect(origin?.slug == "btucker/espalier")
    }

    @Test func returnsNilWhenRemoteMissing() async throws {
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["remote", "get-url", "origin"],
            error: .nonZeroExit(command: "git", exitCode: 128, stderr: "no such remote")
        )
        GitRunner.configure(executor: fake)
        defer { GitRunner.resetForTests() }

        let origin = try await GitOriginHost.detect(repoPath: "/tmp/repo")
        #expect(origin == nil)
    }
}
