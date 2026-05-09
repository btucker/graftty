import Testing
@testable import GrafttyKit

@Suite("""
@spec ATTN-1.20: When `pane show` is invoked against a pane whose `--lines` argument is non-positive or exceeds the pane's available scrollback, the application shall clamp non-positive values to the pane's full scrollback and clamp excessive values to the available scrollback length.
""")
struct ScrollbackTailTests {
    @Test("Returns last N lines when N <= total")
    func returnsLastN() {
        let body = (1...10).map { "line\($0)" }.joined(separator: "\n")
        let tailed = ScrollbackTail.tail(body, lines: 3)
        #expect(tailed == "line8\nline9\nline10")
    }

    @Test("Returns full body when N > total (excessive clamps to available)")
    func clampsExcessive() {
        let body = "a\nb\nc"
        #expect(ScrollbackTail.tail(body, lines: 100) == body)
    }

    @Test("Non-positive N returns full body (clamps to available)")
    func clampsNonPositive() {
        let body = "a\nb\nc"
        #expect(ScrollbackTail.tail(body, lines: 0) == body)
        #expect(ScrollbackTail.tail(body, lines: -1) == body)
    }

    @Test("Trailing newline is preserved")
    func preservesTrailingNewline() {
        let body = "a\nb\nc\n"
        #expect(ScrollbackTail.tail(body, lines: 2) == "b\nc\n")
    }

    @Test("Empty input returns empty regardless of N")
    func emptyInput() {
        #expect(ScrollbackTail.tail("", lines: 100) == "")
        #expect(ScrollbackTail.tail("", lines: 0) == "")
    }
}
