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

@Suite("PaneTitle.sanitize")
struct PaneTitleSanitizeTests {

    /// `GHOSTTY_ACTION_SET_TITLE` feeds arbitrary OSC 2 payloads into
    /// `titles[id]` with no length cap or control-char filter beyond
    /// the env-assignment leak rejection. A program (malicious or
    /// buggy) can push a 100 KB title — or worse, one laced with ANSI
    /// escapes — and that payload sits in the pane's dict for the
    /// lifetime of the session. The sidebar clips rendering via
    /// `.lineLimit(1)` but memory pressure and state.json bloat (the
    /// titles aren't persisted, but transient heap cost is real for a
    /// long-lived app) are uncapped.
    ///
    /// `sanitize` returns nil to reject; the caller keeps the prior
    /// title (same semantics as `isLikelyEnvAssignment`).
    @Test func shortValidTitlePassesThrough() {
        #expect(PaneTitle.sanitize("claude") == "claude")
        #expect(PaneTitle.sanitize("docker compose up") == "docker compose up")
    }

    @Test func envAssignmentLeakIsRejected() {
        #expect(PaneTitle.sanitize("FOO=bar") == nil)
        #expect(PaneTitle.sanitize("GHOSTTY_ZSH_ZDOTDIR=/x") == nil)
    }

    @Test func titleAtMaxLengthIsAccepted() {
        let t = String(repeating: "a", count: PaneTitle.maxStoredLength)
        #expect(t.count == PaneTitle.maxStoredLength)
        #expect(PaneTitle.sanitize(t) == t)
    }

    @Test func titleOverMaxLengthIsRejected() {
        let t = String(repeating: "a", count: PaneTitle.maxStoredLength + 1)
        #expect(PaneTitle.sanitize(t) == nil)
    }

    @Test func hugeTitleIsRejected() {
        // A 100 KB title from a misbehaving program must not land in
        // the titles dict. This is the memory-bloat scenario.
        let t = String(repeating: "b", count: 100_000)
        #expect(PaneTitle.sanitize(t) == nil)
    }

    @Test func graphemeClusterLengthGate() {
        // Swift's `.count` counts grapheme clusters; a ZWJ-emoji family
        // is one cluster. 199 plain chars + one family emoji should fit
        // the 200-cluster cap.
        let t = String(repeating: "a", count: PaneTitle.maxStoredLength - 1) + "👨‍👩‍👧‍👦"
        #expect(t.count == PaneTitle.maxStoredLength)
        #expect(PaneTitle.sanitize(t) == t)
    }

    @Test func emptyTitlePassesThrough() {
        // The display-layer fallback (LAYOUT-2.14) already handles
        // empty/whitespace-only. sanitize is a storage gate only; it
        // doesn't care about blank-vs-content.
        #expect(PaneTitle.sanitize("") == "")
        #expect(PaneTitle.sanitize("   ") == "   ")
    }

    /// OSC 2 is a byte stream from the inner shell's program. A program
    /// (buggy or hostile) can push any Unicode, including Cc (control)
    /// scalars. The sidebar renders titles via SwiftUI `Text` with
    /// `.lineLimit(1)`: newlines clip, tabs render at implementation-
    /// defined width, and ANSI escapes like `\e[31m` land as literal
    /// glyphs (the ESC byte is invisible in SwiftUI Text, producing
    /// strings like `[31mred[0m` in the sidebar). That's the same
    /// garbage-rendering class as CLI's ATTN-1.12; the server-side
    /// title intake deserves the same guard.
    @Test func newlineInTitleIsRejected() {
        #expect(PaneTitle.sanitize("hello\nworld") == nil)
        #expect(PaneTitle.sanitize("hello\rworld") == nil)
    }

    @Test func tabInTitleIsRejected() {
        #expect(PaneTitle.sanitize("col1\tcol2") == nil)
    }

    @Test func ansiEscapeInTitleIsRejected() {
        #expect(PaneTitle.sanitize("\u{1B}[31mred\u{1B}[0m") == nil)
    }

    @Test func bellInTitleIsRejected() {
        // Legit programs don't embed BEL in titles; a program sending
        // one is signalling intent to annoy. Also `\u{07}` is the
        // terminator in OSC 2 framing itself — a title that still has
        // one post-parse means the parser may have swallowed garbage.
        #expect(PaneTitle.sanitize("ding\u{07}") == nil)
    }

    @Test func deleteCharInTitleIsRejected() {
        #expect(PaneTitle.sanitize("x\u{7F}y") == nil) // DEL
    }

    @Test func emojiAndPunctuationPassThrough() {
        // Non-Cc Unicode is fine; these are the titles users actually
        // see in real-world setups.
        #expect(PaneTitle.sanitize("✓ build passing") == "✓ build passing")
        #expect(PaneTitle.sanitize("docker compose up — running") == "docker compose up — running")
    }

    // LAYOUT-2.18: sibling rule to ATTN-1.14. A rogue inner-shell
    // program can push an OSC 2 payload like `printf
    // '\e]0;\u202Edecoy\u202C\a'` that slips past LAYOUT-2.17's
    // Cc-only check (BIDI overrides are Cf, not Cc) and renders
    // RTL-reversed in the sidebar capsule — the same Trojan-Source
    // visual deception ATTN-1.14 blocks on the notify surface.
    @Test func bidiOverrideInTitleIsRejected() {
        #expect(PaneTitle.sanitize("\u{202E}evil") == nil)             // RLO
        #expect(PaneTitle.sanitize("ok\u{202A}x\u{202C}") == nil)      // LRE..PDF
        #expect(PaneTitle.sanitize("ok\u{2066}hidden\u{2069}") == nil) // LRI..PDI
    }

    @Test func naturalRtlTitleStillAccepted() {
        // RTL-natural scripts use character-intrinsic directionality;
        // no override scalars. Must still sanitize cleanly.
        #expect(PaneTitle.sanitize("مرحبا") == "مرحبا")
        #expect(PaneTitle.sanitize("שלום") == "שלום")
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

    /// LAYOUT-2.14: a program pushing OSC-2 with a whitespace-only title
    /// (rare — usually a buggy title-setting program — but observed in
    /// practice) used to store `"   "` as the pane label. The sidebar
    /// then rendered blank space where a label belongs, making the pane
    /// look mislabelled or broken. Treat whitespace-only as "no title"
    /// and fall through to the PWD basename like nil/empty does.
    @Test("whitespace-only stored title falls through to PWD basename")
    func ignoresWhitespaceOnlyStoredTitle() {
        #expect(PaneTitle.display(storedTitle: "   ", pwd: "/tmp/work") == "work")
        #expect(PaneTitle.display(storedTitle: "\t", pwd: "/tmp/work") == "work")
    }

    @Test("whitespace-only stored title with no PWD still returns empty")
    func whitespaceOnlyStoredTitleWithoutPWDIsEmpty() {
        #expect(PaneTitle.display(storedTitle: "   ", pwd: nil) == "")
        #expect(PaneTitle.display(storedTitle: "\t\t", pwd: "") == "")
    }

    @Test("stored title with surrounding whitespace is preserved as-is")
    func preservesSurroundingWhitespaceInContentfulTitle() {
        // Trim-for-blankness check is a blank-vs-content test, not a
        // normalize-the-title operation. A title like " claude " keeps
        // its spaces so a program that deliberately formatted its own
        // padding gets honored.
        #expect(PaneTitle.display(storedTitle: " claude ", pwd: nil) == " claude ")
    }
}
