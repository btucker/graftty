import Testing
@testable import GrafttyKit

@Suite("Repository origin identity")
struct GitRepositoryOriginTests {
    @Test("Origin identity normalizes transport, credentials, host case, and .git suffixes")
    func equivalentOrigins() {
        let expected = GitRepositoryOrigin.parse("git@github.com:team/subgroup/repo.git")
        #expect(expected != nil)
        for url in [
            "https://user:secret@GitHub.Com/team/subgroup/repo.git/",
            "http://github.com:80/team/subgroup/repo",
            "ssh://git@github.com:22/team/subgroup/repo.git",
            "git://github.com:9418/team/subgroup/repo.git",
            "deploy@github.com:team/subgroup/repo",
        ] {
            #expect(GitRepositoryOrigin.parse(url) == expected)
        }
    }

    @Test("Distinct hosts, repository paths, path case, and custom ports stay distinct")
    func distinctOrigins() {
        let expected = GitRepositoryOrigin.parse("https://example.com/team/repo.git")
        for url in [
            "https://other.example/team/repo.git",
            "https://example.com/fork/repo.git",
            "https://example.com/team/Repo.git",
            "ssh://git@example.com:2222/team/repo.git",
            "https://example.com:8443/team/repo.git",
        ] {
            #expect(GitRepositoryOrigin.parse(url) != expected)
        }
    }

    @Test("Machine-local origins cannot establish identity across Macs")
    func rejectsLocalAndMalformedOrigins() {
        for url in ["", "/repo.git", "../repo.git", "file:///repo.git", "https://host", "https://host/repo?other", "ext::helper"] {
            #expect(GitRepositoryOrigin.parse(url) == nil)
        }
    }
}
