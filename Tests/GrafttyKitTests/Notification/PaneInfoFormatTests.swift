import Testing
@testable import GrafttyKit

/// ATTN-1.11: `graftty pane list` output format. Extracted from the
/// CLI's print loop so it's testable without a running server.
@Suite("""
PaneInfo.formattedLine

@spec ATTN-1.11: Each row of `graftty pane list` output shall be formatted as `<marker> <id><padding> <title?>` where `marker` is `*` for the focused pane or a space otherwise, `id` is right-padded to at least width 3 for typical layouts (so ids 1–99 align their titles at the same column), and exactly one space separates the id from the title regardless of id width — so ids ≥ 100 don't collide visually with their title. Panes with no title render without trailing whitespace. A whitespace-only title is treated the same as nil / empty (same blank-vs-content rule as `LAYOUT-2.14`) so the row clips cleanly rather than rendering `*  3      ` with trailing spaces where a label should be.
""")
struct PaneInfoFormatTests {

    @Test func unfocusedSingleDigitIdAlignsWithFocus() {
        let line = PaneInfo(id: 1, title: "zsh", focused: false).formattedLine()
        // leading "  " = space-for-marker + space-separator, then
        // id right-padded to width 3, single space, title.
        #expect(line == "  1   zsh")
    }

    @Test func focusedPrintsAsterisk() {
        let line = PaneInfo(id: 2, title: "zsh", focused: true).formattedLine()
        #expect(line == "* 2   zsh")
    }

    @Test func twoDigitIdPadsOnce() {
        let line = PaneInfo(id: 10, title: "t", focused: false).formattedLine()
        #expect(line == "  10  t")
    }

    /// The previous format used `max(0, 3 - count)` padding with no
    /// fallback separator. For id=100 the padding collapsed to zero and
    /// the title ran straight into the id: "  100zsh". The fix keeps at
    /// least one space between the id and the title at every id width.
    @Test func threeDigitIdStillHasSeparatorBeforeTitle() {
        let line = PaneInfo(id: 100, title: "zsh", focused: false).formattedLine()
        #expect(line == "  100 zsh")
    }

    @Test func fourDigitIdStillHasSeparatorBeforeTitle() {
        let line = PaneInfo(id: 1234, title: "zsh", focused: false).formattedLine()
        #expect(line == "  1234 zsh")
    }

    @Test func emptyTitleRendersTrimmedLine() {
        // A pane with no title gets no trailing whitespace — avoids
        // `wc -L`-style tools counting extra trailing spaces the user
        // isn't looking at.
        let line = PaneInfo(id: 1, title: nil, focused: false).formattedLine()
        #expect(line == "  1")
    }

    @Test func nilAndEmptyStringAreEquivalent() {
        // Server protocol returns nil; some callers might pass "".
        let nilTitle = PaneInfo(id: 5, title: nil, focused: true).formattedLine()
        let emptyTitle = PaneInfo(id: 5, title: "", focused: true).formattedLine()
        #expect(nilTitle == emptyTitle)
        #expect(nilTitle == "* 5")
    }

    /// LAYOUT-2.14-adjacent: a PaneInfo constructed with a
    /// whitespace-only title (three spaces, a tab, a newline-that-slipped-
    /// through) rendered as `"* 5      "` — the capsule-equivalent of
    /// LAYOUT-2.14 for the `pane list` CLI output, where the user sees a
    /// focus marker + id + spaces and wonders whether the title is set.
    /// Treat whitespace-only as "no title" so the row clips cleanly,
    /// matching `PaneTitle.display`.
    @Test func whitespaceOnlyTitleRendersAsNoTitle() {
        let line = PaneInfo(id: 3, title: "   ", focused: false).formattedLine()
        #expect(line == "  3")
    }

    @Test func tabOnlyTitleRendersAsNoTitle() {
        let line = PaneInfo(id: 3, title: "\t", focused: true).formattedLine()
        #expect(line == "* 3")
    }

    @Test func contentfulTitleWithSurroundingWhitespacePreserved() {
        // Mirrors PaneTitle.display: blank-vs-content check, not a trim.
        let line = PaneInfo(id: 3, title: " claude ", focused: false).formattedLine()
        #expect(line == "  3    claude ")
    }
}
