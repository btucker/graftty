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
