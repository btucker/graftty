import Testing
@testable import GrafttyKit

@Suite("@spec TERM-10.1: When the user drops one or more file URLs onto a terminal pane, the application shall insert each file's POSIX path at the cursor position. Paths that contain shell-special characters shall be POSIX-single-quoted (internal `'` rendered as `'\\''`) so the inserted text can be passed unchanged to bash/zsh; paths made entirely of shell-safe characters shall be inserted verbatim. Multiple paths shall be joined with a single space, matching how Ghostty.app, Terminal.app, and iTerm2 render multi-file drops.")
struct FileDropFormatterTests {

    @Test func plainPathIsInsertedVerbatim() {
        #expect(FileDropFormatter.format(paths: ["/Users/me/file.txt"]) == "/Users/me/file.txt")
    }

    @Test func pathWithSpaceIsSingleQuoted() {
        #expect(
            FileDropFormatter.format(paths: ["/Users/me/My Documents/notes.md"])
                == "'/Users/me/My Documents/notes.md'"
        )
    }

    @Test func pathWithApostropheUsesPosixCloseEscapeReopen() {
        #expect(
            FileDropFormatter.format(paths: ["/tmp/it's mine.txt"])
                == "'/tmp/it'\\''s mine.txt'"
        )
    }

    @Test func pathWithDollarOrBacktickIsSingleQuoted() {
        #expect(FileDropFormatter.format(paths: ["/tmp/$HOME"]) == "'/tmp/$HOME'")
        #expect(FileDropFormatter.format(paths: ["/tmp/`whoami`"]) == "'/tmp/`whoami`'")
    }

    @Test func pathWithGlobIsSingleQuoted() {
        #expect(FileDropFormatter.format(paths: ["/tmp/*.log"]) == "'/tmp/*.log'")
        #expect(FileDropFormatter.format(paths: ["/tmp/file?.txt"]) == "'/tmp/file?.txt'")
    }

    @Test func multiplePathsAreJoinedWithSingleSpace() {
        let result = FileDropFormatter.format(paths: [
            "/a/b.txt",
            "/c/d e.txt",
            "/x.txt",
        ])
        #expect(result == "/a/b.txt '/c/d e.txt' /x.txt")
    }

    @Test func emptyPathRendersAsEmptyQuotedString() {
        // An empty path shouldn't vanish: that would drop a separator and
        // silently merge the surrounding tokens into one.
        #expect(FileDropFormatter.format(paths: [""]) == "''")
    }

    @Test func emptyListProducesEmptyString() {
        #expect(FileDropFormatter.format(paths: []) == "")
    }

    @Test func safeCharsetCoversTypicalProjectPaths() {
        let path = "/Users/me/projects/repo-1.0/src/lib_2.swift"
        #expect(FileDropFormatter.format(paths: [path]) == path)
    }

    @Test func nonAsciiTriggersQuoting() {
        // Quote anything outside ASCII alphanumerics + the small punctuation
        // allowlist, so RTL-override / homoglyph bytes can't be inserted as
        // an unquoted token that the shell or terminal misrenders.
        #expect(FileDropFormatter.format(paths: ["/tmp/café.txt"]) == "'/tmp/café.txt'")
    }
}
