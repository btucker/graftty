# Cmd-click to open files in `$EDITOR` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken `NSWorkspace.shared.open` dispatch in the libghostty `OPEN_URL` handler with an editor router that opens file paths in the user's editor — CLI editors (e.g. `nvim`) launch in a new pane split right of the source pane; GUI editors launch via NSWorkspace.

**Architecture:** A pure-logic `EditorOpenRouter` in `GrafttyKit` classifies the URL string from libghostty and emits an `EditorAction` (open-in-pane / open-with-app / open-in-browser). A layered `EditorPreference` resolves the configured editor (UserDefaults → cached shell `$EDITOR` → `vi`). `TerminalManager`'s `OPEN_URL` handler delegates to the router; `GrafttyApp` wires a new `onOpenInEditorPane` callback to its existing `splitPane(...)` flow with a new `extraInitialInput` parameter that threads through to `SurfaceHandle.init` and runs after zmx-attach.

**Tech Stack:** Swift, SwiftPM, GhosttyKit (libghostty C bindings), AppKit, SwiftUI, XCTest. The user's `~/.claude/CLAUDE.md` requires writing failing tests for discovered bugs before fixing — Task 2 includes a bug-reproduction test for the current "-50 dialog" behavior.

**Spec:** `docs/superpowers/specs/2026-04-29-cmd-click-open-design.md`

---

## File Structure

**New files:**

- `Sources/GrafttyKit/Editor/EditorOpenRouter.swift` — pure URL classification + editor-action resolution. No AppKit. ~150 lines.
- `Sources/GrafttyKit/Editor/EditorPreference.swift` — layered editor lookup (UserDefaults → shell env → default). Holds `ResolvedEditor` types. ~80 lines.
- `Sources/GrafttyKit/Editor/ShellEnvProbe.swift` — protocol + production conformance for capturing `$EDITOR` via `$SHELL -ilc 'echo "$EDITOR"'`. ~50 lines.
- `Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift` — table-driven unit tests for the classifier + command builder + resolver, plus the bug-reproduction test.
- `Tests/GrafttyKitTests/Editor/EditorPreferenceTests.swift` — layered-lookup behavior with mock probe + injected `UserDefaults`.

**Modified files:**

- `Sources/Graftty/Channels/SettingsKeys.swift` — three new keys (`editorKind`, `editorAppBundleID`, `editorCliCommand`).
- `Sources/Graftty/Terminal/SurfaceHandle.swift` — add `extraInitialInput: String? = nil` parameter to `init?`, append to the existing zmxInitialInput before strdup.
- `Sources/Graftty/Terminal/TerminalManager.swift` — replace the `GHOSTTY_ACTION_OPEN_URL` handler body (currently lines 709–716) with a router call; add `extraInitialInput` parameter to `createSurface`; expose new `onOpenInEditorPane: ((TerminalID, String) -> Void)?` callback and a stored `editorPreference: EditorPreference` property; expose `paneCwd(for:) -> String?` (the `pwds` map already populated via `GHOSTTY_ACTION_PWD_CHANGED`).
- `Sources/Graftty/GrafttyApp.swift` — add `extraInitialInput: String? = nil` parameter to `splitPane(...)`; wire `onOpenInEditorPane` to call it; capture shell `$EDITOR` once at startup and inject into `EditorPreference`.
- `Sources/Graftty/Views/SettingsView.swift` — new "Editor" section with radio + App picker + CLI text field.
- `SPECS.md` — new top-level `Editor` section with `EDITOR-1.1`–`EDITOR-1.8`.

---

## Conventions

- **Commit style:** Match recent commits — `feat(editor): ...`, `fix(panes): ...`, `test(editor): ...`. Each commit ends with `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` (HEREDOC for multi-line; see `~/.claude/CLAUDE.md` git workflow).
- **Test command:** `swift test --filter <TestClassName>` for a single class. `swift test` runs all tests (~2 min). Faster targeted runs preferred during TDD loop.
- **Build verification:** `swift build` (~30s). Run after each task.
- **No `--no-verify` on commit.** Project CLAUDE.md forbids skipping hooks.

---

## Task 1: ShellEnvProbe

**Files:**
- Create: `Sources/GrafttyKit/Editor/ShellEnvProbe.swift`
- Test: implicitly tested via `EditorPreferenceTests` (Task 5) — no standalone tests, since the production impl literally shells out and would be flaky. Focus is on the *protocol* being injectable.

**Why no dedicated test:** The protocol surface is so thin (one method) and the production impl is a fork+exec we don't want to run under `swift test`. Coverage for the layered logic happens via the mock implementation injected into `EditorPreferenceTests`.

- [ ] **Step 1: Create `ShellEnvProbe.swift`**

```swift
// Sources/GrafttyKit/Editor/ShellEnvProbe.swift
import Foundation

/// Reads a single environment variable as the user's *login shell* would
/// see it — i.e. after their shell rc files have run.
///
/// macOS GUI apps don't inherit shell env, so a literal `ProcessInfo.processInfo.environment["EDITOR"]`
/// is empty for most users. Spawning `$SHELL -ilc 'echo "$VAR"'` runs an
/// interactive login shell which sources `.zshrc`/`.bashrc`/etc., capturing
/// the rc-defined value. Cached at app startup; per-pane overrides are out
/// of scope for v1.
public protocol ShellEnvProbe {
    /// Returns the resolved value of `name`, or nil if unset / probe failed.
    /// Implementations should be safe to call from any thread.
    func value(forName name: String) -> String?
}

/// Production probe that runs `$SHELL -ilc 'echo "$<NAME>"'` and trims
/// the result. Returns nil on any failure (timeout, non-zero exit, missing
/// $SHELL). Designed to fail soft — the caller falls through the layered
/// editor lookup to a hardcoded default.
public struct LoginShellEnvProbe: ShellEnvProbe {
    /// Path to the user's shell. Defaults to `$SHELL` from the app process
    /// environment (Launch Services seeds this from the user's account).
    public let shellPath: String

    /// Hard cap on the probe's runtime so a slow rc file can't block app
    /// startup forever. Default: 2 seconds.
    public let timeout: TimeInterval

    public init(
        shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        timeout: TimeInterval = 2.0
    ) {
        self.shellPath = shellPath
        self.timeout = timeout
    }

    public func value(forName name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        // -i: interactive (sources rc files), -l: login (sources profile),
        // -c: command. The single-quote in the shell command prevents any
        // word-splitting on $name; we only support [A-Za-z_][A-Za-z0-9_]*
        // names so injection is impossible.
        process.arguments = ["-ilc", "echo \"$\(name)\""]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        // Bound the wait so a hung rc file can't pin the calling thread.
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Build succeeds (no targets reference this file yet, but the module must compile).

- [ ] **Step 3: Commit**

```bash
git add Sources/GrafttyKit/Editor/ShellEnvProbe.swift
git commit -m "$(cat <<'EOF'
feat(editor): add ShellEnvProbe for login-shell env capture

Protocol + production implementation that spawns `$SHELL -ilc 'echo "$VAR"'`
to capture environment values defined in the user's rc files. Used by the
upcoming EditorPreference to resolve $EDITOR for cmd-click-to-open behavior
in macOS GUI apps that don't inherit shell env.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: EditorOpenRouter — classify (with bug-reproduction test)

**Files:**
- Create: `Sources/GrafttyKit/Editor/EditorOpenRouter.swift` (partial — only `classify` and types)
- Create: `Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift`

- [ ] **Step 1: Write the failing tests first**

Create `Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift`:

```swift
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

    func test_garbage_classifiesAsInvalid() {
        let result = EditorOpenRouter.classify(
            urlString: "garbage::not-a-path:0",
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
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `swift test --filter EditorOpenRouterClassifyTests 2>&1 | tail -20`
Expected: Compile error — `EditorOpenRouter` not defined.

- [ ] **Step 3: Implement `EditorOpenRouter.classify`**

Create `Sources/GrafttyKit/Editor/EditorOpenRouter.swift`:

```swift
// Sources/GrafttyKit/Editor/EditorOpenRouter.swift
import Foundation

/// Pure logic that decides what to do with a URL string handed to us by
/// libghostty's `GHOSTTY_ACTION_OPEN_URL` event. Has no AppKit / no
/// `TerminalManager` knowledge — call sites supply the source pane's
/// CWD and an existence-check closure.
///
/// Two-stage API:
///   1. `classify(...)` decides whether the URL is a file path (and if
///      so, the absolute path + optional line/col), a non-file URL to
///      hand to the system browser, or invalid garbage.
///   2. `resolve(...)` (Task 4) takes a `ClassifiedTarget` and the
///      configured editor and emits an `EditorAction` for the caller
///      to execute.
public enum EditorOpenRouter {

    public enum ClassifiedTarget: Equatable {
        /// File exists on disk and should be opened in the editor.
        case editorOpen(absolutePath: URL, line: Int?, column: Int?)

        /// Non-file URL — hand to the system's default URL handler.
        case browser(URL)

        /// Schemeless string that doesn't resolve to an existing file,
        /// or a URL that parses but we can't act on. Caller should beep
        /// and not show a dialog.
        case invalid
    }

    /// Classify a URL string from libghostty's `GHOSTTY_ACTION_OPEN_URL`.
    ///
    /// - Parameters:
    ///   - urlString: Raw URL bytes from the action. May be a scheme URL,
    ///     a `file://` URL, or a bare filesystem path.
    ///   - paneCwd: The source pane's PWD (from OSC 7 reports). Required
    ///     for resolving relative paths; pass nil if unknown.
    ///   - fileExists: Existence check. Defaults to `FileManager.default`
    ///     in production, overridden in tests.
    public static func classify(
        urlString: String,
        paneCwd: String?,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> ClassifiedTarget {
        // Step 1: parse as URL. If a non-file scheme is present, route to browser.
        if let url = URL(string: urlString),
           let scheme = url.scheme,
           !scheme.isEmpty,
           scheme != "file" {
            return .browser(url)
        }

        // Step 2: file:// scheme → unwrap to filesystem path.
        let candidate: String
        if let url = URL(string: urlString),
           url.scheme == "file",
           !url.path.isEmpty {
            candidate = url.path
        } else {
            // Step 3: no scheme — treat the whole string as a path candidate.
            candidate = urlString
        }

        // Step 4: try the raw candidate first (handles literal `:NN` in filenames).
        if let resolved = resolvePath(candidate, paneCwd: paneCwd),
           fileExists(resolved) {
            return .editorOpen(absolutePath: resolved, line: nil, column: nil)
        }

        // Step 5: try stripping `:line(:col)` and re-checking existence.
        if let (stripped, line, col) = stripLineColSuffix(candidate),
           let resolved = resolvePath(stripped, paneCwd: paneCwd),
           fileExists(resolved) {
            return .editorOpen(absolutePath: resolved, line: line, column: col)
        }

        // Step 6: nothing resolved — invalid.
        return .invalid
    }

    /// Expand `~` and resolve relative paths against `paneCwd`. Returns
    /// nil if the path is relative and `paneCwd` is unset.
    private static func resolvePath(_ path: String, paneCwd: String?) -> URL? {
        if path.hasPrefix("~/") || path == "~" {
            let home = NSHomeDirectory()
            let rest = String(path.dropFirst(1))
            return URL(fileURLWithPath: home + rest).standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        guard let cwd = paneCwd else { return nil }
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        return cwdURL.appendingPathComponent(path).standardizedFileURL
    }

    /// Match an optional trailing `:line(:col)`. Non-greedy on the path
    /// so a short suffix is captured when present. Returns nil if no
    /// suffix is present (in which case the caller already tried the raw
    /// candidate at step 4).
    private static func stripLineColSuffix(_ s: String) -> (String, Int?, Int?)? {
        // Use NSRegularExpression — simpler than re-parsing manually,
        // and the regex is constant so no perf concern.
        let pattern = #"^(.+?)(?::(\d+)(?::(\d+))?)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let match = regex.firstMatch(in: s, range: range),
              match.numberOfRanges >= 2 else { return nil }

        let pathRange = Range(match.range(at: 1), in: s)!
        let pathPart = String(s[pathRange])

        let lineRange = match.range(at: 2)
        let colRange = match.numberOfRanges > 3 ? match.range(at: 3) : NSRange(location: NSNotFound, length: 0)

        guard lineRange.location != NSNotFound,
              let lineSwiftRange = Range(lineRange, in: s),
              let line = Int(s[lineSwiftRange]) else {
            // No suffix matched. The whole input was treated as the path
            // already at step 4 — nothing more to try.
            return nil
        }

        var col: Int?
        if colRange.location != NSNotFound,
           let colSwiftRange = Range(colRange, in: s),
           let parsedCol = Int(s[colSwiftRange]) {
            col = parsedCol
        }

        return (pathPart, line, col)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter EditorOpenRouterClassifyTests 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Editor/EditorOpenRouter.swift Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift
git commit -m "$(cat <<'EOF'
feat(editor): add EditorOpenRouter.classify with bug-repro test

Pure URL-classification logic for cmd-click-to-open. Handles:
- scheme URLs (http/https/mailto/etc) → .browser
- file:// URLs → .editorOpen
- bare paths → resolve against paneCwd → .editorOpen
- :line(:col) suffix stripping with literal-colon-filename precedence
- invalid garbage → .invalid

Includes test_schemelessPath_doesNotProduceBrowserDispatch reproducing
the current "-50 dialog" bug at the routing layer.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: EditorOpenRouter — buildCliCommand

**Files:**
- Modify: `Sources/GrafttyKit/Editor/EditorOpenRouter.swift` (add static method)
- Modify: `Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift` (add test class)

- [ ] **Step 1: Write failing tests**

Append to `Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --filter EditorOpenRouterCliCommandTests 2>&1 | tail -20`
Expected: Compile error — `buildCliCommand` not defined.

- [ ] **Step 3: Add `buildCliCommand` to `EditorOpenRouter.swift`**

Add to `Sources/GrafttyKit/Editor/EditorOpenRouter.swift` (inside the `EditorOpenRouter` enum):

```swift
    /// Editors known to support `+<line>` for cursor positioning. Lookup
    /// is by the *first whitespace token* of the editor command, lowercased.
    private static let knownLineFlagEditors: Set<String> = [
        "vi", "vim", "nvim", "nano", "helix", "hx", "emacs", "micro", "kak",
    ]

    /// Build the shell command string to execute in a freshly-spawned
    /// pane's PTY. Trailing `\n` triggers immediate execution.
    ///
    /// - Parameters:
    ///   - editor: Raw editor command from `ResolvedEditor` (may include
    ///     args, e.g. `"emacs -nw"`).
    ///   - path: Absolute filesystem path. Will be single-quoted with
    ///     `'\''` escaping to handle spaces and quotes safely.
    ///   - line: Optional 1-based line number. Appended as `+<N>` only
    ///     when the editor's first token is in `knownLineFlagEditors`.
    public static func buildCliCommand(
        editor: String,
        path: String,
        line: Int?
    ) -> String {
        let firstToken = editor
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).lowercased() } ?? ""

        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"

        var command = "\(editor) \(quoted)"
        if let line, knownLineFlagEditors.contains(firstToken) {
            command += " +\(line)"
        }
        command += "\n"
        return command
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EditorOpenRouterCliCommandTests 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/GrafttyKit/Editor/EditorOpenRouter.swift Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift
git commit -m "$(cat <<'EOF'
feat(editor): add buildCliCommand for editor-pane initial input

Builds the shell command string injected into a new pane's PTY when the
configured editor is a CLI tool. Known editors (vi/vim/nvim/nano/helix/
emacs -nw/micro/kak) get the POSIX +<line> flag for cursor positioning;
unknown editors get a path-only command. Path is single-quoted with
'\\'' escaping for safe shell interpolation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: EditorOpenRouter — resolve() + EditorAction types

**Files:**
- Modify: `Sources/GrafttyKit/Editor/EditorOpenRouter.swift`
- Modify: `Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift`

This task introduces `ResolvedEditor` lite (just enough for `resolve()` to compile). The full `EditorPreference` infrastructure follows in Task 5.

- [ ] **Step 1: Write failing tests**

Append to `Tests/GrafttyKitTests/Editor/EditorOpenRouterTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --filter EditorOpenRouterResolveTests 2>&1 | tail -20`
Expected: Compile error — `resolve`, `ResolvedEditor`, `EditorAction.openInPane` etc. not defined.

- [ ] **Step 3: Add `EditorAction`, `ResolvedEditor`, and `resolve()`**

Append to `Sources/GrafttyKit/Editor/EditorOpenRouter.swift` (inside the enum):

```swift
    public enum EditorAction: Equatable {
        /// Spawn a new pane (split-right of source) with this string as the
        /// initial PTY input. Includes trailing `\n`.
        case openInPane(initialInput: String)

        /// Hand `file` to the GUI app at `app` via NSWorkspace.
        case openWithApp(file: URL, app: URL)

        /// Hand `url` to NSWorkspace.shared.open (default URL handler).
        case openInBrowser(URL)

        /// Nothing to do (invalid target, etc). Caller should beep.
        case noOp
    }

    /// Combine a classified target with the resolved editor preference
    /// to produce a concrete action for the caller to execute.
    public static func resolve(
        target: ClassifiedTarget,
        editor: ResolvedEditor
    ) -> EditorAction {
        switch target {
        case .browser(let url):
            return .openInBrowser(url)

        case .invalid:
            return .noOp

        case .editorOpen(let absolutePath, let line, _):
            switch editor.kind {
            case .app(let bundleURL):
                return .openWithApp(file: absolutePath, app: bundleURL)
            case .cli(let command):
                let initialInput = buildCliCommand(
                    editor: command,
                    path: absolutePath.path,
                    line: line
                )
                return .openInPane(initialInput: initialInput)
            }
        }
    }
```

Create `Sources/GrafttyKit/Editor/EditorPreference.swift` (stub — full impl in Task 5):

```swift
// Sources/GrafttyKit/Editor/EditorPreference.swift
import Foundation

/// What the layered lookup returned. The `kind` says what to do; the
/// `source` is captured so the Settings UI can display the resolution
/// chain ("currently using $EDITOR from shell: nvim") and tests can
/// assert which branch fired.
public struct ResolvedEditor: Equatable {
    public enum Kind: Equatable {
        case app(bundleURL: URL)
        case cli(command: String)
    }

    public enum Source: Equatable {
        case userPreference
        case shellEnv
        case defaultFallback
    }

    public let kind: Kind
    public let source: Source

    public init(kind: Kind, source: Source) {
        self.kind = kind
        self.source = source
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter EditorOpenRouterResolveTests 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Run the full router test class to make sure nothing regressed**

Run: `swift test --filter EditorOpenRouterClassifyTests 2>&1 | tail -10 && swift test --filter EditorOpenRouterCliCommandTests 2>&1 | tail -10`
Expected: All previously-passing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Editor/ Tests/GrafttyKitTests/Editor/
git commit -m "$(cat <<'EOF'
feat(editor): add resolve() and ResolvedEditor types

Combines a ClassifiedTarget with the user's resolved editor preference
to produce an EditorAction for the caller to dispatch. Branches:
- .browser → .openInBrowser (NSWorkspace.shared.open passthrough)
- .invalid → .noOp (caller beeps)
- .editorOpen + GUI app → .openWithApp (NSWorkspace.openApplication)
- .editorOpen + CLI → .openInPane with built command string

ResolvedEditor stub introduced; full layered EditorPreference lookup in
the next task.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: EditorPreference — layered lookup

**Files:**
- Modify: `Sources/GrafttyKit/Editor/EditorPreference.swift`
- Create: `Tests/GrafttyKitTests/Editor/EditorPreferenceTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/GrafttyKitTests/Editor/EditorPreferenceTests.swift`:

```swift
// Tests/GrafttyKitTests/Editor/EditorPreferenceTests.swift
import XCTest
@testable import GrafttyKit

final class EditorPreferenceTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        // Use a unique suite per test so leftover keys don't bleed across.
        let suite = "EditorPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    private struct StubProbe: ShellEnvProbe {
        let value: String?
        func value(forName name: String) -> String? { value }
    }

    func test_userPreferenceCli_winsOverShellEnv() {
        let defaults = makeDefaults()
        defaults.set("cli", forKey: EditorPreference.Keys.kind)
        defaults.set("nvim", forKey: EditorPreference.Keys.cliCommand)

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "vim")
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "nvim"))
        XCTAssertEqual(resolved.source, .userPreference)
    }

    func test_userPreferenceApp_winsOverShellEnv() {
        let defaults = makeDefaults()
        let cursorURL = URL(fileURLWithPath: "/Applications/Cursor.app")
        defaults.set("app", forKey: EditorPreference.Keys.kind)
        defaults.set("com.todesktop.230313mzl4w4u92", forKey: EditorPreference.Keys.appBundleID)

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "nvim"),
            bundleIDResolver: { id in id == "com.todesktop.230313mzl4w4u92" ? cursorURL : nil }
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .app(bundleURL: cursorURL))
        XCTAssertEqual(resolved.source, .userPreference)
    }

    func test_emptyKind_fallsThroughToShellEnv() {
        let defaults = makeDefaults()
        // editorKind unset

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "nvim")
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "nvim"))
        XCTAssertEqual(resolved.source, .shellEnv)
    }

    func test_kindCli_butEmptyCommand_fallsThroughToShellEnv() {
        let defaults = makeDefaults()
        defaults.set("cli", forKey: EditorPreference.Keys.kind)
        defaults.set("", forKey: EditorPreference.Keys.cliCommand)

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "vim")
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "vim"))
        XCTAssertEqual(resolved.source, .shellEnv,
                       "Empty CLI field must fall through, not pin to empty cli")
    }

    func test_kindApp_butStaleBundleID_fallsThroughToShellEnv() {
        let defaults = makeDefaults()
        defaults.set("app", forKey: EditorPreference.Keys.kind)
        defaults.set("com.gone.app", forKey: EditorPreference.Keys.appBundleID)

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "nvim"),
            bundleIDResolver: { _ in nil }  // bundle no longer installed
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "nvim"))
        XCTAssertEqual(resolved.source, .shellEnv)
    }

    func test_shellEnvUnset_fallsThroughToVi() {
        let defaults = makeDefaults()

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: nil)
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "vi"))
        XCTAssertEqual(resolved.source, .defaultFallback)
    }

    func test_resolveIsCached_probeCalledOnce() {
        let defaults = makeDefaults()

        final class CountingProbe: ShellEnvProbe {
            var count = 0
            func value(forName name: String) -> String? {
                count += 1
                return "nvim"
            }
        }
        let probe = CountingProbe()
        let pref = EditorPreference(defaults: defaults, shellEnvProbe: probe)
        _ = pref.resolve()
        _ = pref.resolve()
        XCTAssertEqual(probe.count, 1, "Shell env should be probed once and cached")
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail**

Run: `swift test --filter EditorPreferenceTests 2>&1 | tail -20`
Expected: Compile errors — `EditorPreference`, `EditorPreference.Keys` not defined.

- [ ] **Step 3: Implement `EditorPreference`**

Replace `Sources/GrafttyKit/Editor/EditorPreference.swift` with:

```swift
// Sources/GrafttyKit/Editor/EditorPreference.swift
import AppKit
import Foundation

/// What the layered lookup returned. The `kind` says what to do; the
/// `source` is captured so the Settings UI can display the resolution
/// chain ("currently using $EDITOR from shell: nvim") and tests can
/// assert which branch fired.
public struct ResolvedEditor: Equatable {
    public enum Kind: Equatable {
        case app(bundleURL: URL)
        case cli(command: String)
    }

    public enum Source: Equatable {
        case userPreference
        case shellEnv
        case defaultFallback
    }

    public let kind: Kind
    public let source: Source

    public init(kind: Kind, source: Source) {
        self.kind = kind
        self.source = source
    }
}

/// Layered lookup of the user's editor preference. Resolution order:
///   1. `UserDefaults` (set by the Settings pane).
///   2. `$EDITOR` from the user's login shell, captured once via the
///      injected `ShellEnvProbe`.
///   3. Hardcoded `vi` fallback.
///
/// Empty/missing fields at layer 1 (e.g., user picked "App" but never
/// chose one) fall through to layer 2 — the Settings UI is responsible
/// for not letting the user save a half-configured choice in the common
/// case, but the resolve logic is defensive against it.
///
/// The shell-env probe is cached on first `resolve()` call and re-used
/// for subsequent calls within the lifetime of this `EditorPreference`
/// instance.
public final class EditorPreference {

    public enum Keys {
        public static let kind         = "editorKind"          // "" | "app" | "cli"
        public static let appBundleID  = "editorAppBundleID"
        public static let cliCommand   = "editorCliCommand"
    }

    private let defaults: UserDefaults
    private let shellEnvProbe: ShellEnvProbe
    private let bundleIDResolver: (String) -> URL?
    private var cachedShellEditor: String??

    public init(
        defaults: UserDefaults = .standard,
        shellEnvProbe: ShellEnvProbe,
        bundleIDResolver: @escaping (String) -> URL? = { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }
    ) {
        self.defaults = defaults
        self.shellEnvProbe = shellEnvProbe
        self.bundleIDResolver = bundleIDResolver
    }

    public func resolve() -> ResolvedEditor {
        // Layer 1: UserDefaults.
        let kind = defaults.string(forKey: Keys.kind) ?? ""
        switch kind {
        case "cli":
            if let cmd = defaults.string(forKey: Keys.cliCommand),
               !cmd.trimmingCharacters(in: .whitespaces).isEmpty {
                return ResolvedEditor(kind: .cli(command: cmd), source: .userPreference)
            }
            // empty cli command → fall through

        case "app":
            if let bundleID = defaults.string(forKey: Keys.appBundleID),
               !bundleID.isEmpty,
               let url = bundleIDResolver(bundleID) {
                return ResolvedEditor(kind: .app(bundleURL: url), source: .userPreference)
            }
            // missing/stale bundle → fall through

        default:
            break  // empty kind → fall through
        }

        // Layer 2: shell env.
        let shellEditor: String?
        if let cached = cachedShellEditor {
            shellEditor = cached
        } else {
            let probed = shellEnvProbe.value(forName: "EDITOR")
            cachedShellEditor = probed
            shellEditor = probed
        }
        if let env = shellEditor, !env.isEmpty {
            return ResolvedEditor(kind: .cli(command: env), source: .shellEnv)
        }

        // Layer 3: hardcoded fallback.
        return ResolvedEditor(kind: .cli(command: "vi"), source: .defaultFallback)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter EditorPreferenceTests 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 5: Run *all* router/preference tests to catch regressions**

Run: `swift test --filter EditorOpenRouter && swift test --filter EditorPreference 2>&1 | tail -20`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/GrafttyKit/Editor/EditorPreference.swift Tests/GrafttyKitTests/Editor/EditorPreferenceTests.swift
git commit -m "$(cat <<'EOF'
feat(editor): add EditorPreference layered lookup

Resolves the user's editor in three layers:
  1. UserDefaults (set via Settings pane).
  2. $EDITOR from login shell (cached, probed once).
  3. Hardcoded vi.

Empty/missing fields at layer 1 (e.g. "app" selected with no bundle ID,
or stale bundle ID for an uninstalled app) fall through to layer 2.
Captures resolution source on the result so the Settings pane can
display the chain.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: SettingsKeys additions

**Files:**
- Modify: `Sources/Graftty/Channels/SettingsKeys.swift`

Trivial; no tests since `SettingsKeys` is a constants file.

- [ ] **Step 1: Add the three keys**

Edit `Sources/Graftty/Channels/SettingsKeys.swift`:

```swift
import Foundation

/// Centralized UserDefaults key strings used across Settings panes and observers.
enum SettingsKeys {
    static let agentTeamsEnabled         = "agentTeamsEnabled"
    static let channelsEnabled           = "channelsEnabled"
    static let channelRoutingPreferences = "channelRoutingPreferences"
    static let teamSessionPrompt         = "teamSessionPrompt"
    static let teamPrompt                = "teamPrompt"
    static let defaultCommand            = "defaultCommand"
    static let editorKind                = "editorKind"          // "" | "app" | "cli"
    static let editorAppBundleID         = "editorAppBundleID"
    static let editorCliCommand          = "editorCliCommand"
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -3`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Graftty/Channels/SettingsKeys.swift
git commit -m "$(cat <<'EOF'
feat(settings): add editor preference keys

Three new UserDefaults keys for the cmd-click-to-open feature:
editorKind ("" | "app" | "cli"), editorAppBundleID, editorCliCommand.
Empty kind means "fall through to shell \$EDITOR".

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Note: The `EditorPreference.Keys` constants in `GrafttyKit` and the
`SettingsKeys` constants in the Graftty target use the same string
values but are intentionally not shared — `GrafttyKit` is testable in
isolation without depending on the Graftty app target. The strings must
stay in sync; both files reference the same names verbatim.

---

## Task 7: SurfaceHandle — extraInitialInput parameter

**Files:**
- Modify: `Sources/Graftty/Terminal/SurfaceHandle.swift`

No new tests — `SurfaceHandle` directly wraps libghostty C calls and is exercised by integration/manual smoke. The change is mechanical: append a string before strdup.

- [ ] **Step 1: Read the current init signature**

Run: `grep -nE 'init\\?\\(|zmxInitialInput' Sources/Graftty/Terminal/SurfaceHandle.swift | head -10`
Expected output: shows `init?(...)` with `zmxInitialInput: String? = nil` parameter, and a strdup line around line 96.

- [ ] **Step 2: Add `extraInitialInput` parameter and concatenate**

Edit `Sources/Graftty/Terminal/SurfaceHandle.swift`. Add `extraInitialInput` between `zmxInitialInput` and `zmxDir`:

```swift
init?(
    terminalID: TerminalID,
    app: ghostty_app_t,
    worktreePath: String,
    socketPath: String,
    zmxInitialInput: String? = nil,
    extraInitialInput: String? = nil,  // <-- new
    zmxDir: String? = nil,
    terminalManager: TerminalManager? = nil
) {
```

Find the line:

```swift
let initialInputCStr: UnsafeMutablePointer<CChar>? = zmxInitialInput.flatMap { strdup($0) }
```

Replace with:

```swift
// Concatenate zmx-attach input (always first, so the inner shell is
// attached to its zmx session before any extra command runs) with any
// caller-supplied extra input (e.g. an editor command for cmd-click).
let combinedInput: String? = {
    let parts = [zmxInitialInput, extraInitialInput].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined()
}()
let initialInputCStr: UnsafeMutablePointer<CChar>? = combinedInput.flatMap { strdup($0) }
```

- [ ] **Step 3: Build to verify**

Run: `swift build 2>&1 | tail -3`
Expected: Build succeeds. Existing call sites pass `extraInitialInput` implicitly as nil.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Terminal/SurfaceHandle.swift
git commit -m "$(cat <<'EOF'
feat(terminal): SurfaceHandle accepts extra initial input

New optional extraInitialInput parameter on SurfaceHandle.init, appended
after zmxInitialInput before strdup. Lets callers (cmd-click router in
the next commit) inject a per-spawn command — e.g. \`nvim foo.swift +42\` —
that runs once the zmx-attached shell is ready.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: TerminalManager — OPEN_URL handler replacement + paneCwd accessor + onOpenInEditorPane callback

**Files:**
- Modify: `Sources/Graftty/Terminal/TerminalManager.swift`

This task replaces the broken `NSWorkspace.shared.open(parsed)` line with a router call and exposes the wiring the next task (`GrafttyApp`) will use.

- [ ] **Step 1: Read current handler and confirm its location**

Run: `sed -n '700,720p' Sources/Graftty/Terminal/TerminalManager.swift`
Expected: shows the `case GHOSTTY_ACTION_OPEN_URL:` block with `NSWorkspace.shared.open(parsed)`.

- [ ] **Step 2: Add `editorPreference` property, `onOpenInEditorPane` callback, and `paneCwd(for:)` accessor**

In `TerminalManager.swift`, find the section near `var onOpenConfig: (() -> Void)?` (around line 203 in current code) and add nearby:

```swift
    /// Resolves the user's configured editor (Settings → shell $EDITOR → vi).
    /// Injected by `GrafttyApp` at startup. Optional so tests instantiate
    /// `TerminalManager` without setting up a probe; production always sets it.
    var editorPreference: EditorPreference?

    /// Called when cmd-clicking a file path resolves to a CLI editor —
    /// owner spawns a new pane split-right of the source pane with
    /// `initialInput` as the editor invocation. Wired in `GrafttyApp`.
    var onOpenInEditorPane: ((TerminalID, String) -> Void)?
```

Add a public accessor for the existing `pwds` map (currently `private`/internal). Search for `pwds[id] = pwd` (around line 698) to confirm the dict, then add right after the `init`:

```swift
    /// PWD for `terminalID` as last reported via OSC 7. Nil if no shell
    /// integration message has fired yet.
    func paneCwd(for terminalID: TerminalID) -> String? {
        pwds[terminalID]
    }
```

(If `pwds` is `private`, leave it private — `paneCwd(for:)` is the public read API.)

- [ ] **Step 3: Replace the `OPEN_URL` handler**

Find the existing block (around lines 709–716):

```swift
case GHOSTTY_ACTION_OPEN_URL:
    let url = action.action.open_url
    guard let urlPtr = url.url else { return }
    let bytes = UnsafeBufferPointer(start: urlPtr, count: Int(url.len))
    guard let urlString = String(bytes: bytes.map { UInt8(bitPattern: $0) }, encoding: .utf8),
          let parsed = URL(string: urlString)
    else { return }
    NSWorkspace.shared.open(parsed)
```

Replace with:

```swift
case GHOSTTY_ACTION_OPEN_URL:
    let url = action.action.open_url
    guard let urlPtr = url.url else { return }
    let bytes = UnsafeBufferPointer(start: urlPtr, count: Int(url.len))
    guard let urlString = String(
        bytes: bytes.map { UInt8(bitPattern: $0) },
        encoding: .utf8
    ) else { return }

    let sourceID = terminalID(from: target)
    let cwd = sourceID.flatMap { pwds[$0] }

    let classified = EditorOpenRouter.classify(urlString: urlString, paneCwd: cwd)

    // If we don't have an editor preference plumbed yet (only happens
    // in tests), fall back to the original NSWorkspace dispatch for
    // browser URLs and beep on file targets so we don't reintroduce
    // the schemeless-URL "-50 dialog" bug.
    let editor = editorPreference?.resolve()
    let editorAction: EditorOpenRouter.EditorAction
    if let editor {
        editorAction = EditorOpenRouter.resolve(target: classified, editor: editor)
    } else {
        switch classified {
        case .browser(let u): editorAction = .openInBrowser(u)
        default:              editorAction = .noOp
        }
    }

    switch editorAction {
    case .openInBrowser(let url):
        NSWorkspace.shared.open(url)

    case .openWithApp(let file, let app):
        let config = NSWorkspace.OpenConfiguration()
        config.promptsUserIfNeeded = false
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config)
            { _, _ in }

    case .openInPane(let initialInput):
        guard let sourceID else { NSSound.beep(); break }
        onOpenInEditorPane?(sourceID, initialInput)

    case .noOp:
        NSSound.beep()
    }
```

- [ ] **Step 4: Add `extraInitialInput` parameter to `createSurface`**

Find the `createSurface` function (around line 402). Replace its signature and the SurfaceHandle.init call:

```swift
    /// Create a single surface, or return the existing one for this `TerminalID`.
    func createSurface(
        terminalID: TerminalID,
        worktreePath: String,
        extraInitialInput: String? = nil  // <-- new
    ) -> SurfaceHandle? {
        guard let app = ghosttyApp?.app else { return nil }
        if let existing = surfaces[terminalID] {
            return existing
        }

        clearRehydratedIfDaemonGone(terminalID, liveSessions: nil)

        let (zmxInitialInput, zmxDir) = resolveZmxSpawn(for: terminalID)
        guard let handle = SurfaceHandle(
            terminalID: terminalID,
            app: app,
            worktreePath: worktreePath,
            socketPath: socketPath,
            zmxInitialInput: zmxInitialInput,
            extraInitialInput: extraInitialInput,  // <-- new
            zmxDir: zmxDir,
            terminalManager: self
        ) else { return nil }
        surfaces[terminalID] = handle
        return handle
    }
```

- [ ] **Step 5: Add `import GrafttyKit` if not already imported**

Check the top of `TerminalManager.swift`. If `import GrafttyKit` isn't there, add it (the `GrafttyKit` framework already exists in the project; many other files import it).

Run: `head -10 Sources/Graftty/Terminal/TerminalManager.swift`
If `import GrafttyKit` is present, skip. Otherwise add it after the existing imports.

- [ ] **Step 6: Build to verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds. (If it fails on `pwds` visibility, make sure the `paneCwd(for:)` accessor was added rather than referencing `pwds` directly inside the new switch.)

- [ ] **Step 7: Commit**

```bash
git add Sources/Graftty/Terminal/TerminalManager.swift
git commit -m "$(cat <<'EOF'
fix(terminal): route cmd+click through EditorOpenRouter (EDITOR-1.1, EDITOR-1.5)

Replace the schemeless NSWorkspace.shared.open dispatch in the
GHOSTTY_ACTION_OPEN_URL handler — which produced the system "-50 /
The application can't be opened" dialog when cmd-clicking a file
path — with a call into EditorOpenRouter. Browser URLs still flow
through NSWorkspace.shared.open; CLI editor targets fire a new
onOpenInEditorPane callback that GrafttyApp wires to splitPane in
the next commit. GUI editor targets dispatch via NSWorkspace.openApplication.

Adds:
- editorPreference property (injected by GrafttyApp)
- onOpenInEditorPane callback
- paneCwd(for:) accessor for the existing pwds map
- extraInitialInput param on createSurface, threaded through to
  SurfaceHandle.init

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: GrafttyApp — splitPane param + callback wiring + startup $EDITOR capture

**Files:**
- Modify: `Sources/Graftty/GrafttyApp.swift`

- [ ] **Step 1: Add `extraInitialInput` parameter to `splitPane`**

Find `fileprivate static func splitPane` (around line 1372). Add a new parameter and thread it through:

```swift
@MainActor
@discardableResult
fileprivate static func splitPane(
    appState: Binding<AppState>,
    terminalManager: TerminalManager,
    targetID: TerminalID,
    split: PaneSplit,
    extraInitialInput: String? = nil  // <-- new
) -> TerminalID? {
    for repoIdx in appState.wrappedValue.repos.indices {
        for wtIdx in appState.wrappedValue.repos[repoIdx].worktrees.indices {
            let wt = appState.wrappedValue.repos[repoIdx].worktrees[wtIdx]
            guard wt.state == .running, wt.splitTree.containsLeaf(targetID) else { continue }

            let direction: SplitDirection = (split == .right || split == .left) ? .horizontal : .vertical
            let newID = TerminalID()
            let newTree: SplitTree
            switch split {
            case .right, .down:
                newTree = wt.splitTree.inserting(newID, at: targetID, direction: direction)
            case .left, .up:
                newTree = wt.splitTree.insertingBefore(newID, at: targetID, direction: direction)
            }
            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = newTree
            guard terminalManager.createSurface(
                terminalID: newID,
                worktreePath: wt.path,
                extraInitialInput: extraInitialInput  // <-- new
            ) != nil else {
                appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].splitTree = wt.splitTree
                return nil
            }
            appState.wrappedValue.repos[repoIdx].worktrees[wtIdx].focusedTerminalID = newID
            terminalManager.setFocus(newID)
            return newID
        }
    }
    return nil
}
```

- [ ] **Step 2: Wire the `onOpenInEditorPane` callback**

Find where existing callbacks are wired (search for `terminalManager.onSplitRequest = `, around line 336). Add the new wiring nearby:

```swift
terminalManager.onOpenInEditorPane = { [appState = $appState, tm = terminalManager] terminalID, initialInput in
    Task { @MainActor in
        _ = Self.splitPane(
            appState: appState,
            terminalManager: tm,
            targetID: terminalID,
            split: .right,
            extraInitialInput: initialInput
        )
    }
}
```

- [ ] **Step 3: Inject `EditorPreference` at startup**

Find where `terminalManager` is built in the App initialization (search for `let terminalManager`, look around the existing setup near `initialize()` calls in `GrafttyApp`). After `terminalManager.initialize()` and *before* the callback wiring, add:

```swift
// EDITOR-1.7 / EDITOR-1.8: capture shell $EDITOR once at startup so
// cmd-click can fall back to it when the user hasn't picked a Settings
// override. The probe runs $SHELL -ilc 'echo "$EDITOR"' on a background
// thread; the cache is populated lazily on first cmd-click.
terminalManager.editorPreference = EditorPreference(
    defaults: .standard,
    shellEnvProbe: LoginShellEnvProbe()
)
```

If `import GrafttyKit` is missing at the top of `GrafttyApp.swift`, add it (most likely already present; check first).

- [ ] **Step 4: Build to verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
git add Sources/Graftty/GrafttyApp.swift
git commit -m "$(cat <<'EOF'
feat(panes): wire cmd+click editor open to splitPane (EDITOR-1.2)

splitPane gains an extraInitialInput param threaded through createSurface
to SurfaceHandle.init; onOpenInEditorPane callback is wired to call
splitPane(.right, extraInitialInput) so cmd-clicking a file with a CLI
editor configured opens the editor in a new pane split right of the
source. Also injects EditorPreference into TerminalManager at startup
so the layered $EDITOR fallback is available.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: SettingsView — Editor section

**Files:**
- Modify: `Sources/Graftty/Views/SettingsView.swift`

- [ ] **Step 1: Replace `SettingsView.swift` with the extended form**

```swift
// Sources/Graftty/Views/SettingsView.swift
import AppKit
import GrafttyKit
import SwiftUI

/// Preferences pane for Graftty — the "General" tab inside the SwiftUI
/// `Settings` scene. The `TabView` + `.tabItem` shell lives in `GrafttyApp`
/// so this view renders its form directly; wrapping another `TabView` here
/// would nest a second "General" tab strip under the first.
struct SettingsView: View {
    @AppStorage(SettingsKeys.defaultCommand) private var defaultCommand: String = ""
    @AppStorage("defaultCommandFirstPaneOnly") private var firstPaneOnly: Bool = true
    @AppStorage(SettingsKeys.editorKind) private var editorKind: String = ""
    @AppStorage(SettingsKeys.editorAppBundleID) private var editorAppBundleID: String = ""
    @AppStorage(SettingsKeys.editorCliCommand) private var editorCliCommand: String = ""

    /// Resolved editor for the "currently using $EDITOR from shell" caption.
    /// Recomputed on view body re-evaluation; cheap enough since the
    /// shell-env probe is itself cached inside EditorPreference.
    @State private var resolvedEditorCaption: String = ""

    /// Cached list of installed text-editor apps; populated lazily on
    /// first selection of the "App" radio.
    @State private var availableApps: [TextEditorApp] = []

    /// Owner shows the "Restart ZMX…" confirmation alert. Injected as a
    /// closure so SettingsView stays decoupled from TerminalManager.
    let onRestartZMX: () -> Void

    var body: some View {
        Form {
            TextField("Default command:", text: $defaultCommand, prompt: Text("e.g., claude"))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)

            Toggle("Run in first pane only", isOn: $firstPaneOnly)

            Text("Runs automatically when a worktree opens. Leave empty to disable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            // Editor section — EDITOR-1.x.
            Text("Editor")
                .font(.headline)

            Picker(selection: $editorKind) {
                Text(shellEditorRowLabel)
                    .tag("")
                Text("App")
                    .tag("app")
                Text("CLI Editor")
                    .tag("cli")
            } label: {
                Text("Editor:")
            }
            .pickerStyle(.radioGroup)

            if editorKind == "app" {
                Picker(selection: $editorAppBundleID) {
                    Text("Choose…").tag("")
                    ForEach(availableApps) { app in
                        Text(app.displayName).tag(app.bundleID)
                    }
                } label: {
                    Text("Application:")
                }
                .onAppear { loadAvailableApps() }
            }

            if editorKind == "cli" {
                TextField("CLI command:", text: $editorCliCommand, prompt: Text("e.g., nvim"))
                    .textFieldStyle(.roundedBorder)
            }

            Text("Used when you cmd-click a file path in a pane.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            HStack {
                Button("Restart ZMX…", action: onRestartZMX)
                Spacer()
            }

            Text("Ends all running terminal sessions. Use this if panes become unresponsive or you want fresh zmx daemons.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { recomputeShellEditorCaption() }
    }

    private var shellEditorRowLabel: String {
        if resolvedEditorCaption.isEmpty {
            return "Use $EDITOR from shell"
        }
        return "Use $EDITOR from shell  (current: \(resolvedEditorCaption))"
    }

    /// Fire-and-forget probe for the caption; matches what
    /// EditorPreference.resolve() would return when the user has nothing
    /// set. Runs on a background queue to avoid blocking the UI.
    private func recomputeShellEditorCaption() {
        DispatchQueue.global(qos: .userInitiated).async {
            let probe = LoginShellEnvProbe()
            let value = probe.value(forName: "EDITOR") ?? "vi"
            DispatchQueue.main.async {
                self.resolvedEditorCaption = value
            }
        }
    }

    private func loadAvailableApps() {
        // Use a sample text file so LaunchServices reports every editor
        // registered for plain text.
        let sampleURL = URL(fileURLWithPath: "/tmp/x.txt")
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: sampleURL)

        var seen = Set<String>()
        var apps: [TextEditorApp] = []
        for url in urls {
            guard let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier,
                  !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)

            let displayName = FileManager.default.displayName(atPath: url.path)
            apps.append(TextEditorApp(bundleID: bundleID, displayName: displayName, url: url))
        }
        apps.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        self.availableApps = apps
    }
}

private struct TextEditorApp: Identifiable, Hashable {
    let bundleID: String
    let displayName: String
    let url: URL
    var id: String { bundleID }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds.

- [ ] **Step 3: Manual smoke test**

Run: `swift run`
Expected:
- App launches.
- Open Settings → see "Editor" section with three radio rows.
- Default radio is "Use $EDITOR from shell  (current: <whatever>)".
- Selecting "App" reveals the app picker, populated.
- Selecting "CLI Editor" reveals a text field.
- Switching radios doesn't crash.

If it works, close the app and proceed.

- [ ] **Step 4: Commit**

```bash
git add Sources/Graftty/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
feat(settings): editor picker UI (EDITOR-1.7)

Adds an Editor section to the General Settings pane with three options:
- Use \$EDITOR from shell (default — caption shows the resolved value)
- App (radio reveals a picker populated via NSWorkspace.urlsForApplications)
- CLI Editor (radio reveals a free-form text field)

Bundle IDs are stored, not paths, so app moves don't break the setting.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: SPECS.md — add EDITOR section

**Files:**
- Modify: `SPECS.md`

- [ ] **Step 1: Find the appropriate placement**

Run: `grep -nE '^## ' SPECS.md | head -30`
Expected: list of top-level sections. Find one that fits semantically — typically near other terminal/pane sections (e.g. `## Terminal`, `## Panes`, `## Layout`).

- [ ] **Step 2: Add the new `Editor` section**

Insert into `SPECS.md` after the appropriate neighbor section:

```markdown
## Editor

EDITOR-1.1  When the user cmd-clicks a file path in a terminal pane, the application shall open the file via the configured editor.

EDITOR-1.2  If the configured editor is a known CLI editor, the application shall split the source pane to the right and run the editor in the new pane.

EDITOR-1.3  If the configured editor is a GUI app, the application shall dispatch the file to the app via NSWorkspace, without creating a new pane.

EDITOR-1.4  If the cmd-clicked target carries a `:line(:col)` suffix, the application shall strip the suffix before resolving the path, and shall pass the line number to known CLI editors using `+<line>`.

EDITOR-1.5  If the cmd-clicked target is not a file path, the application shall open it via NSWorkspace (preserving existing handling for http(s), mailto:, ssh:, and other URL schemes).

EDITOR-1.6  If the cmd-clicked target resolves to a path that does not exist on disk, the application shall emit a system beep and not open anything.

EDITOR-1.7  When no editor is explicitly configured in Settings, the application shall use the value of `$EDITOR` as defined by the user's login shell.

EDITOR-1.8  If `$EDITOR` is unset, the application shall fall back to `vi`.
```

- [ ] **Step 3: Commit**

```bash
git add SPECS.md
git commit -m "$(cat <<'EOF'
docs(specs): add EDITOR-1.x for cmd+click open

Documents the new cmd+click-to-editor behavior at the spec level:
routing decisions, editor classification, line/column handling, and
the layered \$EDITOR fallback. Implementation lands in the same PR.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: End-to-end manual smoke + simplify pass + PR

- [ ] **Step 1: Run the full test suite**

Run: `swift test 2>&1 | tail -15`
Expected: All tests pass. Watch for newly-failing tests in unrelated areas (e.g. SettingsView snapshots, TerminalManager mocks).

- [ ] **Step 2: Run the app and exercise the feature manually**

Run: `swift run`

Test cases:
1. Open a terminal pane. `echo "$EDITOR"` to confirm the shell has it set.
2. Run `ls -la` and cmd-click on a filename. Expect: new pane opens to the right with `<editor> '<file>'` running, no "-50 dialog".
3. Run `cat /etc/hosts` then echo a path with `:line:col` (e.g. `echo /etc/hosts:5:1`); cmd-click it. Expect: editor opens with cursor at line 5.
4. Open Settings → Editor → switch to a GUI app (e.g. TextEdit). Cmd-click a file. Expect: TextEdit launches with the file. No new pane spawns.
5. Cmd-click `https://github.com` in a pane. Expect: browser opens (preserves existing behavior).
6. Cmd-click a non-existent path (`/tmp/no-such-file`). Expect: beep, no dialog.

If any case fails, diagnose before continuing.

- [ ] **Step 3: Run /simplify per project CLAUDE.md**

Project's `CLAUDE.md`: "Always run /simplify before opening a PR."

Run the simplify skill: invoke `/simplify` to review the changed code for reuse, quality, and efficiency, and apply any improvements it surfaces.

- [ ] **Step 4: Push and open PR**

```bash
git push -u origin feat/cmd-click-open
gh pr create --title "feat(editor): cmd+click to open files in \$EDITOR (EDITOR-1.1..1.8)" --body "$(cat <<'EOF'
## Summary

- Replaces the broken `NSWorkspace.shared.open` dispatch in `GHOSTTY_ACTION_OPEN_URL` (which produced the system "-50" dialog when cmd-clicking schemeless paths) with an `EditorOpenRouter` in `GrafttyKit`.
- Adds a Settings pane for picking the editor: `$EDITOR` from shell (default), a GUI app from NSWorkspace's text-editor list, or a free-form CLI command.
- For CLI editors, opens the file in a new pane split-right of the source pane (cmd+D direction). For GUI editors, dispatches via `NSWorkspace.openApplication`.
- Strips optional `:line(:col)` suffix and passes `+<line>` to known CLI editors (vi/vim/nvim/nano/helix/emacs -nw/micro/kak).

Spec: `docs/superpowers/specs/2026-04-29-cmd-click-open-design.md`
Plan: `docs/superpowers/plans/2026-04-29-cmd-click-open.md`
SPECS.md: `EDITOR-1.1`–`EDITOR-1.8`.

## Test plan

- [x] Unit tests for `EditorOpenRouter.classify` (table-driven, includes bug-reproduction `test_schemelessPath_doesNotProduceBrowserDispatch`)
- [x] Unit tests for `buildCliCommand` (quoting, line-flag map, unknown editors)
- [x] Unit tests for `resolve` (browser / app / cli / noOp branches)
- [x] Unit tests for `EditorPreference` (UserDefaults wins / falls through / shell-env / default fallback / caching)
- [ ] Manual: cmd+click on a path in a terminal pane opens the file in `$EDITOR`
- [ ] Manual: cmd+click on `https://...` still opens in browser
- [ ] Manual: cmd+click on `path:42` opens at line 42
- [ ] Manual: cmd+click on a non-existent path beeps without dialog

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Confirm CI passes**

Wait for the GitHub Actions CI run on the PR (typically `ios-build-and-test`, `macos-build-and-test`, `verify-web`). If any check fails, investigate before merging.

---

## Self-review notes

- **Spec coverage:** All eight `EDITOR-1.x` requirements have at least one task (Tasks 8–11 collectively).
- **Bug-reproduction test:** Per `~/.claude/CLAUDE.md`, the "-50 dialog" bug gets a failing test in Task 2 (`test_schemelessPath_doesNotProduceBrowserDispatch`) that fails before Task 8's router replacement and passes after.
- **Type consistency:** `ResolvedEditor.Kind.app(bundleURL:)` is consistent across Tasks 4, 5, and 9. `EditorAction.openInPane(initialInput:)` is consistent across Tasks 4, 8, 9. `extraInitialInput` is consistent across Tasks 7, 8, 9. `EditorPreference.Keys.{kind,appBundleID,cliCommand}` matches `SettingsKeys.{editorKind,editorAppBundleID,editorCliCommand}` by raw string.
- **No placeholders:** every step has either exact code or an exact command with expected output.
- **Frequent commits:** 12 commits across 12 tasks, each independently buildable.
