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
///   2. `resolve(...)` (added in a later task) takes a `ClassifiedTarget`
///      and the configured editor and emits an `EditorAction` for the
///      caller to execute.
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
