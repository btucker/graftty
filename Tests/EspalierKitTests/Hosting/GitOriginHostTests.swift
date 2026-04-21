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

    @Test func stripsDotGitSuffixWhenScpUrlHasTrailingSlash() {
        // `.git` strip previously ran before the trailing-slash strip,
        // so scp-style inputs like `git@github.com:owner/repo.git/`
        // (URL's auto-normalisation doesn't apply to the manual scp
        // parse path) ended with repo="repo.git". The resulting
        // `gh pr list --repo owner/repo.git` returned an empty list
        // and the sidebar showed no PR badge.
        let origin = GitOriginHost.parse(remoteURL: "git@github.com:btucker/espalier.git/")
        #expect(origin == HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "espalier"))
    }

    @Test func stripsTrailingSlashOnScpUrlWithoutDotGit() {
        let origin = GitOriginHost.parse(remoteURL: "git@github.com:btucker/espalier/")
        #expect(origin == HostingOrigin(provider: .github, host: "github.com", owner: "btucker", repo: "espalier"))
    }
}

@Suite("GitOriginHost.detect", .serialized)
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

    @Test func throwsOnTransientGitFailure() async throws {
        // PR-4.4: any `git remote get-url origin` failure OTHER than
        // "no such remote" is transient (e.g., `.git/config` being
        // rewritten during a concurrent `git worktree add`, a `.git`
        // lock held briefly under load, an FSEvents-driven re-read
        // mid-pack-operation). `detect` must throw so PR-7.11's caller
        // safeguard can skip caching — otherwise the transient nil
        // poisons `hostByRepo` for the whole session and the repo's
        // PR status never resolves until Espalier is relaunched.
        let fake = FakeCLIExecutor()
        fake.stub(
            command: "git",
            args: ["remote", "get-url", "origin"],
            error: .nonZeroExit(command: "git", exitCode: 128, stderr: "fatal: unable to read tree")
        )
        GitRunner.configure(executor: fake)
        defer { GitRunner.resetForTests() }

        await #expect(throws: (any Error).self) {
            _ = try await GitOriginHost.detect(repoPath: "/tmp/repo")
        }
    }
}
