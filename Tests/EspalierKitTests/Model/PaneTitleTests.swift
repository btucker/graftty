import Testing
@testable import EspalierKit

@Suite("PaneTitle.isLikelyEnvAssignment")
struct PaneTitleEnvAssignmentTests {

    @Test("the Ghostty shell-integration leak is filtered")
    func filtersGhosttyZdotdirLeak() {
        #expect(PaneTitle.isLikelyEnvAssignment("GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\""))
        #expect(PaneTitle.isLikelyEnvAssignment("GHOSTTY_ZSH_ZDOTDIR=/path/to/dir ZDOTDIR=/other"))
    }

    @Test("any uppercase env-name prefix is filtered")
    func filtersGenericEnvAssignments() {
        #expect(PaneTitle.isLikelyEnvAssignment("FOO=bar"))
        #expect(PaneTitle.isLikelyEnvAssignment("_FOO=bar"))
        #expect(PaneTitle.isLikelyEnvAssignment("PATH=/usr/bin"))
    }

    @Test("leading whitespace does not hide the assignment")
    func toleratesLeadingWhitespace() {
        #expect(PaneTitle.isLikelyEnvAssignment("  FOO=bar"))
    }

    @Test("lowercase-leading titles are not filtered")
    func keepsLowercaseTitles() {
        #expect(!PaneTitle.isLikelyEnvAssignment("espalier"))
        #expect(!PaneTitle.isLikelyEnvAssignment("claude code: running"))
    }

    @Test("legitimate titles containing = pass through")
    func keepsUIShapedTitlesContainingEquals() {
        // Matches common human-facing title patterns: program output with
        // `=` in the middle (e.g. "build=ok"), version strings, etc.
        #expect(!PaneTitle.isLikelyEnvAssignment("build=ok"))
        #expect(!PaneTitle.isLikelyEnvAssignment("docker compose up"))
        #expect(!PaneTitle.isLikelyEnvAssignment("vim README.md"))
    }

    @Test("empty / no-equals inputs are not assignments")
    func rejectsNonAssignments() {
        #expect(!PaneTitle.isLikelyEnvAssignment(""))
        #expect(!PaneTitle.isLikelyEnvAssignment("   "))
        #expect(!PaneTitle.isLikelyEnvAssignment("=bar"))
        #expect(!PaneTitle.isLikelyEnvAssignment("Makefile: build"))
    }

    @Test("mixed-case identifiers are not filtered")
    func keepsMixedCaseIdentifiers() {
        // Real env vars are all-uppercase by convention; titles like
        // `Foo=bar` are more likely program output than env leakage.
        #expect(!PaneTitle.isLikelyEnvAssignment("Foo=bar"))
    }
}

@Suite("PaneTitle.basenameLabel")
struct PaneTitleBasenameTests {

    @Test func returnsDirectoryBasename() {
        #expect(PaneTitle.basenameLabel(pwd: "/Users/btucker/projects/espalier") == "espalier")
        #expect(PaneTitle.basenameLabel(pwd: "/Users/btucker/projects/espalier/Sources") == "Sources")
    }

    @Test func stripsTrailingSlash() {
        #expect(PaneTitle.basenameLabel(pwd: "/Users/btucker/projects/espalier/") == "espalier")
    }

    @Test func returnsNilForRootAndEmpty() {
        #expect(PaneTitle.basenameLabel(pwd: "") == nil)
        #expect(PaneTitle.basenameLabel(pwd: "/") == nil)
        #expect(PaneTitle.basenameLabel(pwd: "   ") == nil)
    }
}

@Suite("PaneTitle.display")
struct PaneTitleDisplayTests {

    @Test("prefers stored title when non-empty")
    func prefersStoredTitle() {
        #expect(PaneTitle.display(storedTitle: "claude", pwd: "/Users/btucker") == "claude")
    }

    @Test("falls back to PWD basename when no title")
    func fallsBackToPWDBasename() {
        #expect(PaneTitle.display(storedTitle: nil, pwd: "/Users/btucker/projects/espalier") == "espalier")
        #expect(PaneTitle.display(storedTitle: "", pwd: "/Users/btucker/projects/espalier") == "espalier")
    }

    @Test("returns empty string when neither is available")
    func emptyWhenNothingKnown() {
        // The view is expected to render "shell" when this returns "",
        // so assert the empty-string contract explicitly.
        #expect(PaneTitle.display(storedTitle: nil, pwd: nil) == "")
        #expect(PaneTitle.display(storedTitle: "", pwd: nil) == "")
        #expect(PaneTitle.display(storedTitle: nil, pwd: "") == "")
    }
}
