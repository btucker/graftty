// Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift
import XCTest
@testable import GrafttyKit

final class EditorOpenRouterClassifyTests: XCTestCase {

    /// Bug-reproduction test for the "-50 / paramErr" dialog seen when
    /// cmd-clicking a file path. libghostty hands us a schemeless URL like
    /// `Sources/Foo.swift:42:1`; routing it as a browser URL is what
    /// triggers the dialog. After the router lands, this URL must
    /// classify as `.editorOpen`, never `.browser`.
    func test_schemelessPath_doesNotProduceBrowserDispatch() {
        let result = EditorOpenRouter.classify(
            urlString: "/tmp/exists.txt",
            paneCwd: nil,
            fileExists: { _ in true }
        )
        if case .browser = result {
            XCTFail("Schemeless path must not classify as .browser (this would be the -50 bug)")
        }
    }

    func test_httpsURL_classifiesAsBrowser() {
        let result = EditorOpenRouter.classify(
            urlString: "https://example.com",
            paneCwd: nil,
            fileExists: { _ in false }
        )
        guard case .browser(let url) = result else {
            return XCTFail("expected .browser, got \(result)")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com")
    }

    func test_fileScheme_classifiesAsEditor() {
        let result = EditorOpenRouter.classify(
            urlString: "file:///etc/hosts",
            paneCwd: nil,
            fileExists: { $0.path == "/etc/hosts" }
        )
        guard case .editorOpen(let url, let line, let col) = result else {
            return XCTFail("expected .editorOpen, got \(result)")
        }
        XCTAssertEqual(url.path, "/etc/hosts")
        XCTAssertNil(line)
        XCTAssertNil(col)
    }

    func test_absolutePathWithLineCol_capturesLineAndColumn() {
        let result = EditorOpenRouter.classify(
            urlString: "/abs/foo.swift:42:1",
            paneCwd: nil,
            fileExists: { $0.path == "/abs/foo.swift" }
        )
        guard case .editorOpen(let url, let line, let col) = result else {
            return XCTFail("expected .editorOpen, got \(result)")
        }
        XCTAssertEqual(url.path, "/abs/foo.swift")
        XCTAssertEqual(line, 42)
        XCTAssertEqual(col, 1)
    }

    func test_relativePath_resolvesAgainstPaneCwd() {
        let result = EditorOpenRouter.classify(
            urlString: "Sources/Foo.swift:7",
            paneCwd: "/Users/x/proj",
            fileExists: { $0.path == "/Users/x/proj/Sources/Foo.swift" }
        )
        guard case .editorOpen(let url, let line, _) = result else {
            return XCTFail("expected .editorOpen, got \(result)")
        }
        XCTAssertEqual(url.path, "/Users/x/proj/Sources/Foo.swift")
        XCTAssertEqual(line, 7)
    }

    func test_tildePath_expandsToHome() {
        // Build the expected absolute path the same way the router will,
        // so the test isn't sensitive to the test runner's home.
        let home = NSHomeDirectory()
        let expected = "\(home)/notes.md"

        let result = EditorOpenRouter.classify(
            urlString: "~/notes.md",
            paneCwd: nil,
            fileExists: { $0.path == expected }
        )
        guard case .editorOpen(let url, _, _) = result else {
            return XCTFail("expected .editorOpen, got \(result)")
        }
        XCTAssertEqual(url.path, expected)
    }

    func test_literalColonInFilename_prefersExactMatch() {
        // File literally named `weird:42` exists, no `weird` file. Classifier
        // should NOT strip the suffix.
        let result = EditorOpenRouter.classify(
            urlString: "/tmp/weird:42",
            paneCwd: nil,
            fileExists: { $0.path == "/tmp/weird:42" }
        )
        guard case .editorOpen(let url, let line, _) = result else {
            return XCTFail("expected .editorOpen, got \(result)")
        }
        XCTAssertEqual(url.path, "/tmp/weird:42")
        XCTAssertNil(line, "Should not have stripped a literal :42 from a real filename")
    }

    func test_pathWithSuffix_strippedWhenExactDoesNotExist() {
        // No file at /tmp/foo:42, but /tmp/foo exists. Classifier should
        // strip the suffix and return the line number.
        let result = EditorOpenRouter.classify(
            urlString: "/tmp/foo:42",
            paneCwd: nil,
            fileExists: { $0.path == "/tmp/foo" }
        )
        guard case .editorOpen(let url, let line, _) = result else {
            return XCTFail("expected .editorOpen, got \(result)")
        }
        XCTAssertEqual(url.path, "/tmp/foo")
        XCTAssertEqual(line, 42)
    }

    func test_nonExistentPath_classifiesAsInvalid() {
        let result = EditorOpenRouter.classify(
            urlString: "/no/such/file.txt",
            paneCwd: nil,
            fileExists: { _ in false }
        )
        if case .invalid = result { return }
        XCTFail("expected .invalid, got \(result)")
    }

    func test_emptyString_classifiesAsInvalid() {
        let result = EditorOpenRouter.classify(
            urlString: "",
            paneCwd: nil,
            fileExists: { _ in false }
        )
        if case .invalid = result { return }
        XCTFail("expected .invalid, got \(result)")
    }

    func test_relativePathWithoutPaneCwd_isInvalid() {
        // Without a pane PWD, we can't resolve relative paths — classifier
        // must not silently use process CWD or filesystem root.
        let result = EditorOpenRouter.classify(
            urlString: "src/foo.swift",
            paneCwd: nil,
            fileExists: { _ in true }
        )
        if case .invalid = result { return }
        XCTFail("Relative path with no paneCwd must classify as invalid")
    }
}

final class EditorOpenRouterCliCommandTests: XCTestCase {

    func test_nvim_simplePath() {
        let cmd = EditorOpenRouter.buildCliCommand(
            editor: "nvim",
            path: "/tmp/foo.swift",
            line: nil
        )
        XCTAssertEqual(cmd, "nvim '/tmp/foo.swift'\n")
    }

    func test_nvim_withLine_appendsPlusFlag() {
        let cmd = EditorOpenRouter.buildCliCommand(
            editor: "nvim",
            path: "/tmp/foo.swift",
            line: 42
        )
        XCTAssertEqual(cmd, "nvim '/tmp/foo.swift' +42\n")
    }

    func test_pathWithSpaces_isQuoted() {
        let cmd = EditorOpenRouter.buildCliCommand(
            editor: "vim",
            path: "/tmp/has space/file.txt",
            line: nil
        )
        XCTAssertEqual(cmd, "vim '/tmp/has space/file.txt'\n")
    }

    func test_pathWithSingleQuote_isEscaped() {
        let cmd = EditorOpenRouter.buildCliCommand(
            editor: "nvim",
            path: "/tmp/it's mine.txt",
            line: nil
        )
        XCTAssertEqual(cmd, "nvim '/tmp/it'\\''s mine.txt'\n")
    }

    func test_emacsNoWindow_preservesArgs_andUsesPlusLine() {
        let cmd = EditorOpenRouter.buildCliCommand(
            editor: "emacs -nw",
            path: "/tmp/foo.txt",
            line: 7
        )
        XCTAssertEqual(cmd, "emacs -nw '/tmp/foo.txt' +7\n")
    }

    func test_unknownCli_omitsLineFlag() {
        let cmd = EditorOpenRouter.buildCliCommand(
            editor: "exotic-editor --foo",
            path: "/tmp/foo.txt",
            line: 42
        )
        XCTAssertEqual(cmd, "exotic-editor --foo '/tmp/foo.txt'\n",
                       "Unknown editors should not get +<line> appended (might mean something else)")
    }

    func test_helix_aliasHx_recognized() {
        let cmd = EditorOpenRouter.buildCliCommand(
            editor: "hx",
            path: "/tmp/foo.txt",
            line: 12
        )
        XCTAssertEqual(cmd, "hx '/tmp/foo.txt' +12\n")
    }

    func test_columnArgument_isDropped() {
        // Column is captured but intentionally not used in v1.
        // The function signature takes only `line` to make this explicit.
        let cmd = EditorOpenRouter.buildCliCommand(
            editor: "nvim",
            path: "/tmp/foo.txt",
            line: 5
        )
        XCTAssertFalse(cmd.contains(":"), "Column should not appear in CLI command")
    }
}

final class EditorOpenRouterResolveTests: XCTestCase {

    private let dummyURL = URL(fileURLWithPath: "/tmp/foo.swift")
    private let dummyApp = URL(fileURLWithPath: "/Applications/Cursor.app")

    func test_browserTarget_passesThroughToBrowser() {
        let url = URL(string: "https://x.com")!
        let action = EditorOpenRouter.resolve(
            target: .browser(url),
            editor: ResolvedEditor(kind: .cli(command: "nvim"), source: .shellEnv)
        )
        guard case .openInBrowser(let outURL) = action else {
            return XCTFail("expected .openInBrowser, got \(action)")
        }
        XCTAssertEqual(outURL, url)
    }

    func test_invalid_isNoOp() {
        let action = EditorOpenRouter.resolve(
            target: .invalid,
            editor: ResolvedEditor(kind: .cli(command: "nvim"), source: .shellEnv)
        )
        if case .noOp = action { return }
        XCTFail("expected .noOp, got \(action)")
    }

    func test_editorOpen_withCliEditor_buildsPaneCommand() {
        let action = EditorOpenRouter.resolve(
            target: .editorOpen(absolutePath: dummyURL, line: 42, column: nil),
            editor: ResolvedEditor(kind: .cli(command: "nvim"), source: .shellEnv)
        )
        guard case .openInPane(let initialInput) = action else {
            return XCTFail("expected .openInPane, got \(action)")
        }
        XCTAssertEqual(initialInput, "nvim '/tmp/foo.swift' +42\n")
    }

    func test_editorOpen_withGuiApp_emitsOpenWithApp() {
        let action = EditorOpenRouter.resolve(
            target: .editorOpen(absolutePath: dummyURL, line: nil, column: nil),
            editor: ResolvedEditor(kind: .app(bundleURL: dummyApp), source: .userPreference)
        )
        guard case .openWithApp(let file, let app) = action else {
            return XCTFail("expected .openWithApp, got \(action)")
        }
        XCTAssertEqual(file, dummyURL)
        XCTAssertEqual(app, dummyApp)
    }
}
