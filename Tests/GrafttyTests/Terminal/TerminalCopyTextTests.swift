import Testing
@testable import Graftty

@Suite("@spec TERM-8.11: When a selected terminal line has an indented continuation whose first word would not fit within the current terminal columns, the application shall join the lines and remove continuation indentation while preserving paragraph, item, and code boundaries.")
struct TerminalCopyTextTests {
    @Test func joinsIndentedContinuationWhenNextWordCouldNotFit() {
        let copied = """
        The build command reported a diagnostic near the terminal's right edge at
            SourceFile.swift:120:9: Expected a value here.
        """
        #expect(TerminalCopyText.clean(copied, columns: 90) ==
            "The build command reported a diagnostic near the terminal's right edge at SourceFile.swift:120:9: Expected a value here.")
    }

    @Test("""
    @spec TERM-8.12: When a selected agent transcript begins with a `└` or `⎿` line-numbered diagnostic and ends with an expansion hint, the application shall copy each visible entry as one line and omit the expansion hint.
    """)
    func joinsTranscriptDiagnosticsWithoutMergingEntries() {
        let copied = """
         └ 6912:􀢄  Test "Claude session binding mutations are serialized within a process." recorded an issue at
            TeamPresenceStorageTests.swift:276:9: Expectation failed: (firstEntered.wait(timeout: .now() + 1) → .timedOut) == .success
            7120:􀢄  Test "Returns root + spawned child" recorded an issue at ProcessTreeWalkerTests.swift:63:9: Expectation failed: (pids.count →
            +7 lines (ctrl+t to view transcript)
        """
        let expected = """
        6912:􀢄  Test "Claude session binding mutations are serialized within a process." recorded an issue at TeamPresenceStorageTests.swift:276:9: Expectation failed: (firstEntered.wait(timeout: .now() + 1) → .timedOut) == .success
        7120:􀢄  Test "Returns root + spawned child" recorded an issue at ProcessTreeWalkerTests.swift:63:9: Expectation failed: (pids.count →
        """
        #expect(TerminalCopyText.clean(copied, columns: 120) == expected)
    }

    @Test func copiesSingleVisibleDiagnosticWithoutExpansionHint() {
        let copied = " └ 6912:􀢄 Test failed\n    +7 lines (ctrl+t to view transcript)"
        #expect(TerminalCopyText.clean(copied, columns: 120) == "6912:􀢄 Test failed")
    }

    @Test func joinsTranscriptDiagnosticWithAlternateMarker() {
        let copied = """
         ⎿ 6912:􀢄  Test "Claude session binding mutations are serialized within a process." recorded an issue at
            TeamPresenceStorageTests.swift:276:9: Expectation failed
            +7 lines (ctrl+t to view transcript)
        """
        #expect(TerminalCopyText.clean(copied, columns: 120) ==
            "6912:􀢄  Test \"Claude session binding mutations are serialized within a process.\" recorded an issue at TeamPresenceStorageTests.swift:276:9: Expectation failed")
    }

    @Test("""
    @spec TERM-8.13: When a selected code block starts after the first line's number gutter and later rows have a consistent numbered gutter, the application shall omit the later gutter numbers while preserving diff markers and code indentation.
    """)
    func removesLaterCodeLineNumbersWhenFirstLineStartsAfterGutter() {
        let copied = #"""
        @Test("""
            16 -    @spec old requirement
            16 +    @spec new requirement
            17      """)
               ⋮
            36
            37 +    @Test func newCase() { }
        """#
        let expected = #"""
        @Test("""
        -    @spec old requirement
        +    @spec new requirement
             """)
               ⋮

        +    @Test func newCase() { }
        """#
        #expect(TerminalCopyText.clean(copied, columns: 120) == expected)
    }

    @Test func keepsCodeLineNumbersWhenSelectionStartsInGutter() {
        let copied = """
         63                let first = lines.first?.trimmingCharacters(in: .whitespaces),
            64 -              first.hasPrefix("└ "), numberedDiagnostic(in: first) != nil else { return text }
            64 +              hasTranscriptMarker(first), numberedDiagnostic(in: first) != nil else { return text }
            65          lines.removeLast()
        """
        #expect(TerminalCopyText.clean(copied, columns: 70) == copied)
    }

    @Test func removesLaterPlainCodeLineNumbers() {
        let copied = "let first = 1\n    64     let second = 2\n    65     let third = 3"
        let expected = "let first = 1\n    let second = 2\n    let third = 3"
        #expect(TerminalCopyText.clean(copied, columns: 80) == expected)
    }

    @Test func keepsPlainCodeLineNumbersWhenSelectionStartsInGutter() {
        let copied = " 63     let first = 1\n    64     let second = 2\n    65     let third = 3"
        #expect(TerminalCopyText.clean(copied, columns: 20) == copied)
    }

    @Test func keepsNumberedRowsAfterAnIntro() {
        let copied = "Changes:\n    16 - failed\n    17 + fixed"
        #expect(TerminalCopyText.clean(copied, columns: 80) == copied)
    }

    @Test func keepsNumberedDiffRowsAfterAParenthesizedIntro() {
        let copied = "Summary (active)\n    16 - failed\n    17 + fixed"
        #expect(TerminalCopyText.clean(copied, columns: 80) == copied)
    }

    @Test func keepsNumberedLogRows() {
        let copied = "Summary\n    64  process started\n    65  process exited"
        #expect(TerminalCopyText.clean(copied, columns: 80) == copied)
    }

    @Test func joinsUnbulletedProseAtTerminalEdge() {
        let copied = """
        all in the same two existing timing sensitive areas. All three new copy tests passed in that
          run. The generated spec is current,
        """
        #expect(TerminalCopyText.clean(copied, columns: 96) ==
            "all in the same two existing timing sensitive areas. All three new copy tests passed in that run. The generated spec is current,")
    }

    @Test func keepsIntentionalIndentedLineBeforeTerminalEdge() {
        let copied = """
        let result = aVeryLongMethodCall(with: severalArguments, and: moreArguments)
            .map(transform)
        """
        #expect(TerminalCopyText.clean(copied, columns: 120) == copied)
    }

    @Test func keepsLiteralTranscriptHintInOrdinaryOutput() {
        let copied = "header\nbody\n+7 lines (ctrl+t to view transcript)"
        #expect(TerminalCopyText.clean(copied, columns: 120) == copied)
    }

    @Test func joinsFullWidthCharactersAtTerminalEdge() {
        let copied = String(repeating: "界", count: 10) + "\n  next word"
        #expect(TerminalCopyText.clean(copied, columns: 20) ==
            String(repeating: "界", count: 10) + " next word")
    }

    @Test func joinsAgentBulletContinuation() {
        let copied = """
        • For Claude and Codex selections, should the usual Cmd+C and Copy action clean wrapped prose
          automatically, or should Graftty offer a separate Copy clean text action? Cleaning automatically can
          alter intentional line breaks in code and logs.
        """
        #expect(TerminalCopyText.clean(copied, columns: 100) ==
            "• For Claude and Codex selections, should the usual Cmd+C and Copy action clean wrapped prose automatically, or should Graftty offer a separate Copy clean text action? Cleaning automatically can alter intentional line breaks in code and logs.")
    }

    @Test func preservesSeparateItemsAndParagraphs() {
        let copied = """
        • First item that wraps here
          onto another line
        • Second item

        A separate paragraph.
        """
        #expect(TerminalCopyText.clean(copied, columns: 32) ==
            "• First item that wraps here onto another line\n• Second item\n\nA separate paragraph.")
    }

    @Test func keepsNumberedItemAfterLongLine() {
        let copied = """
        A long explanation fills this display row before the next numbered list item begins
          1. Keep this as a separate item
        """
        #expect(TerminalCopyText.clean(copied, columns: 90) == copied)
    }

    @Test func keepsCodeAndShortIntentionalLines() {
        let copied = """
        Run this command:
            swift test
            swift build
        first line
          deliberate indent
        """
        #expect(TerminalCopyText.clean(copied, columns: 100) == copied)
    }

    @Test func keepsCodeContinuationAtTerminalEdge() {
        let copied = "let result = repository.loadRecords(matching: predicate, sortedBy: sortDescriptor)\n  return result"
        #expect(TerminalCopyText.clean(copied, columns: 85) == copied)
    }

    @Test func keepsStackFrameAfterFullWidthLogLine() {
        let copied = String(repeating: "x", count: 80) + "\n    at Source.swift:12:3"
        #expect(TerminalCopyText.clean(copied, columns: 80) == copied)
    }
}
