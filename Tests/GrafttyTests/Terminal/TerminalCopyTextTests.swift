import Testing
@testable import Graftty

@Suite("@spec TERM-8.11: When a terminal selection contains visually wrapped prose, the application shall join continuation lines and remove their display indentation while preserving separate paragraphs, list items, and code indentation.")
struct TerminalCopyTextTests {
    @Test("@spec TERM-8.12: When a selected agent transcript contains wrapped line-numbered diagnostic entries and an expansion hint, the application shall copy each visible entry as one line and omit the expansion hint.")
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

    @Test func joinsUnbulletedProseEvenWhenPaneIsWiderThanCopiedLine() {
        let copied = """
        all in the same two existing timing sensitive areas. All three new copy tests passed in that
          run. The generated spec is current,
        """
        #expect(TerminalCopyText.clean(copied, columns: 120) ==
            "all in the same two existing timing sensitive areas. All three new copy tests passed in that run. The generated spec is current,")
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
        #expect(TerminalCopyText.clean(copied, columns: 35) ==
            "• First item that wraps here onto another line\n• Second item\n\nA separate paragraph.")
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
}
