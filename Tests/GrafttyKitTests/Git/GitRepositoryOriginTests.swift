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

    @Test("Recognized GitHub and GitLab hosts share repository identity across transports")
    func hostedForgeOrigins() {
        for host in ["github.com", "github.example.com", "gitlab.com", "gitlab.example.com"] {
            #expect(GitRepositoryOrigin.parse("deploy@\(host):team/repo.git")
                == GitRepositoryOrigin.parse("https://\(host)/team/repo"))
        }
    }

    @Test("Generic SSH servers retain usernames, path roots, and transport identity")
    func genericSSHOriginsStayDistinct() {
        for (first, second) in [
            ("git@example.com:team/repo.git", "git@example.com:/team/repo.git"),
            ("alice@example.com:repo.git", "bob@example.com:repo.git"),
            ("ssh://alice@example.com/repo.git", "ssh://bob@example.com/repo.git"),
            ("ssh://git@example.com/team/repo.git", "https://example.com/team/repo.git"),
            ("ssh://alice@github.example.com:2222/~/repo.git", "ssh://bob@github.example.com:2222/~/repo.git"),
            ("git@example.com:repo", "git@example.com:repo.git"),
        ] {
            let origin = GitRepositoryOrigin.parse(first)
            #expect(origin != nil)
            #expect(origin != GitRepositoryOrigin.parse(second))
        }
        #expect(GitRepositoryOrigin.parse("git@example.com:/team/repo.git")
            == GitRepositoryOrigin.parse("ssh://git@example.com:22/team/repo.git"))
        #expect(GitRepositoryOrigin.parse("git@example.com:~alice/repo.git")
            == GitRepositoryOrigin.parse("ssh://git@example.com/~alice/repo.git"))
    }

    @Test("Bracketed IPv6 scp URLs match equivalent SSH URLs")
    func ipv6SSHOrigins() {
        let expected = GitRepositoryOrigin.parse("ssh://git@[2001:db8::1]/team/repo.git")
        #expect(expected != nil)
        #expect(GitRepositoryOrigin.parse("git@[2001:DB8::1]:/team/repo.git") == expected)
        #expect(GitRepositoryOrigin.parse("git@[2001:db8::2]:/team/repo.git") != expected)
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
