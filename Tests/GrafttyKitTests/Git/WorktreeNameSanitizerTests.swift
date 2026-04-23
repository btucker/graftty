import Testing
@testable import GrafttyKit

@Suite("WorktreeNameSanitizer")
struct WorktreeNameSanitizerTests {

    @Test func passesThroughSafeCharacters() {
        #expect(WorktreeNameSanitizer.sanitize("feature-xyz") == "feature-xyz")
        #expect(WorktreeNameSanitizer.sanitize("Fix_123.2") == "Fix_123.2")
        #expect(WorktreeNameSanitizer.sanitize("") == "")
    }

    @Test func replacesSpacesWithDash() {
        #expect(WorktreeNameSanitizer.sanitize("my feature") == "my-feature")
        #expect(WorktreeNameSanitizer.sanitize("a b c") == "a-b-c")
    }

    @Test func replacesGitRefReservedCharsWithDash() {
        // git check-ref-format disallows: space, ~, ^, :, ?, *, [, \
        // plus ASCII control chars. All should collapse to '-'.
        #expect(WorktreeNameSanitizer.sanitize("foo~bar") == "foo-bar")
        #expect(WorktreeNameSanitizer.sanitize("foo^bar") == "foo-bar")
        #expect(WorktreeNameSanitizer.sanitize("foo:bar") == "foo-bar")
        #expect(WorktreeNameSanitizer.sanitize("foo?bar") == "foo-bar")
        #expect(WorktreeNameSanitizer.sanitize("foo*bar") == "foo-bar")
        #expect(WorktreeNameSanitizer.sanitize("foo[bar") == "foo-bar")
        #expect(WorktreeNameSanitizer.sanitize("foo\\bar") == "foo-bar")
    }

    @Test func preservesPathSeparator() {
        // '/' is the conventional branch-namespace separator; we allow it
        // through untouched and let `git worktree add` handle the resulting
        // nested `.worktrees/<ns>/<leaf>` directory.
        #expect(WorktreeNameSanitizer.sanitize("feature/foo") == "feature/foo")
        #expect(WorktreeNameSanitizer.sanitize("user/ben/x") == "user/ben/x")
    }

    @Test func preservesSlashWhenMixedWithReplacedCharacters() {
        // Spaces still collapse to '-' but the '/' in the same input
        // survives — each character is decided independently.
        #expect(WorktreeNameSanitizer.sanitize("my feature/foo") == "my-feature/foo")
    }

    @Test func doesNotCollapseConsecutiveSlashes() {
        // We delegate `//` rejection to `git check-ref-format` at submit time
        // rather than duplicating the rule client-side.
        #expect(WorktreeNameSanitizer.sanitize("foo//bar") == "foo//bar")
    }

    @Test func replacesControlCharactersWithDash() {
        #expect(WorktreeNameSanitizer.sanitize("a\tb") == "a-b")
        #expect(WorktreeNameSanitizer.sanitize("a\nb") == "a-b")
    }

    @Test func collapsesConsecutiveReplacements() {
        #expect(WorktreeNameSanitizer.sanitize("foo   bar") == "foo-bar")
        #expect(WorktreeNameSanitizer.sanitize("a!!!b") == "a-b")
        // Mixed runs of illegal chars still collapse; legal chars between
        // them (like '/') act as boundaries that reset the collapse window.
        #expect(WorktreeNameSanitizer.sanitize("a  !  b") == "a-b")
    }

    @Test func preservesExistingRunsOfDashes() {
        // User-typed '-' characters are allowed; we shouldn't collapse them.
        // Only the synthetic '-' we inserted for an illegal char should collapse
        // with adjacent synthetic '-'. A simple and predictable rule: collapse
        // any run of '-' (typed or inserted) into a single '-'.
        #expect(WorktreeNameSanitizer.sanitize("foo--bar") == "foo-bar")
        #expect(WorktreeNameSanitizer.sanitize("foo- -bar") == "foo-bar")
    }

    @Test func doesNotTrimLeadingOrTrailing() {
        // Trimming mid-type would swallow the user's next keystroke context;
        // e.g. typing "foo " then "b" must yield "foo-b", not "foob".
        #expect(WorktreeNameSanitizer.sanitize("foo ") == "foo-")
        #expect(WorktreeNameSanitizer.sanitize(" foo") == "-foo")
    }

    @Test func unicodeLettersAreReplaced() {
        // Keep the safe set ASCII-only: git branches technically accept some
        // Unicode, but worktree paths differ by locale and are a source of
        // surprises. Be conservative.
        #expect(WorktreeNameSanitizer.sanitize("café") == "caf-")
    }

    @Test func prefillSanitizesJiraStyleTitle() {
        #expect(
            WorktreeNameSanitizer.sanitizeForPrefill("PROJ-123: Fix the login race condition")
                == "PROJ-123-Fix-the-login-race-condition"
        )
    }

    @Test func prefillReturnsEmptyForPunctuationOrWhitespaceOnly() {
        #expect(WorktreeNameSanitizer.sanitizeForPrefill("!!!   ") == "")
        #expect(WorktreeNameSanitizer.sanitizeForPrefill("") == "")
    }

    @Test func prefillTrimsLeadingAndTrailingWhitespaceArtifacts() {
        #expect(WorktreeNameSanitizer.sanitizeForPrefill("\n\t  whitespace-around  \n") == "whitespace-around")
    }

    @Test func prefillTruncatesToDefault100() {
        let long = String(repeating: "a", count: 250)
        let expected = String(repeating: "a", count: 100)
        #expect(WorktreeNameSanitizer.sanitizeForPrefill(long) == expected)
    }

    @Test func prefillTrimsTrailingDashAfterTruncation() {
        // 99 a's + "-..." — truncation lands on '-' (dash collapses the "...").
        // Expected: trailing '-' removed, leaving the 99 a's.
        let input = String(repeating: "a", count: 99) + "-..."
        #expect(WorktreeNameSanitizer.sanitizeForPrefill(input) == String(repeating: "a", count: 99))
    }

    @Test func prefillCollapsesNewlinesInMultilineSelection() {
        #expect(WorktreeNameSanitizer.sanitizeForPrefill("multi\nline\nselection") == "multi-line-selection")
    }

    @Test func prefillDropsUnicodeAndTrimsEdges() {
        #expect(WorktreeNameSanitizer.sanitizeForPrefill("   -unicode-café-") == "unicode-caf")
    }

    @Test func prefillPreservesSlashes() {
        #expect(WorktreeNameSanitizer.sanitizeForPrefill("a/b/c-feature") == "a/b/c-feature")
    }
}
