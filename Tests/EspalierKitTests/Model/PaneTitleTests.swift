import Testing
@testable import EspalierKit

@Suite("PaneTitle.isLikelyEnvAssignment")
struct PaneTitleEnvAssignmentTests {

    @Test("the Ghostty shell-integration leak is filtered")
    func filtersGhosttyZdotdirLeak() {
        #expect(PaneTitle.isLikelyEnvAssignment("GHOSTTY_ZSH_ZDOTDIR=\"$ZDOTDIR\""))
        #expect(PaneTitle.isLikelyEnvAssignment("GHOSTTY_ZSH_ZDOTDIR=/path/to/dir ZDOTDIR=/other"))
    }

    @Test("the post-ZMX-6.4 conditional bootstrap leak is filtered")
    func filtersZmxBootstrapLeak() {
        // After ZMX-6.4 (PR #35), the prefix changed shape from a naked
        // `GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR" ZDOTDIR=…` (which the original
        // uppercase-env-name heuristic caught) to a full shell conditional
        // `if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; fi; ZDOTDIR=…`.
        // The new form starts with lowercase `if` and snuck past the
        // uppercase-prefix filter — the entire 200+ char bootstrap string
        // then showed up as the pane title in the sidebar, crowding out
        // any real label. Caught live in cycle 79 dogfood. Title contains
        // the literal `GHOSTTY_ZSH_ZDOTDIR` marker in both old and new
        // shapes, so widening the filter to match either prefix OR that
        // literal lets both forms land cleanly.
        let leak = #"if [ -n "$ZDOTDIR" ]; then export GHOSTTY_ZSH_ZDOTDIR="$ZDOTDIR"; fi; ZDOTDIR='/Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration/zsh' exec '/Applications/Espalier.app/Contents/Helpers/zmx' attach 'espalier-deadbeef' '/bin/zsh'"#
        #expect(PaneTitle.isLikelyEnvAssignment(leak))
    }

    @Test("a bare `if` statement without GHOSTTY marker is not filtered")
    func keepsLegitimateIfStatements() {
        // Defensive: don't over-reject titles. A user whose program
        // legitimately names itself "if you see this" shouldn't get
        // swallowed. The marker we anchor on is `GHOSTTY_ZSH_ZDOTDIR`,
        // not the lowercase `if` that happens to lead our current form.
        #expect(!PaneTitle.isLikelyEnvAssignment("if you are reading this"))
        #expect(!PaneTitle.isLikelyEnvAssignment("if-then-else flow"))
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
