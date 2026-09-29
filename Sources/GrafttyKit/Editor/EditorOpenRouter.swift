// Sources/GrafttyKit/Editor/EditorOpenRouter.swift
import Foundation
import Darwin
import UniformTypeIdentifiers

/// Pure logic that decides what to do with a URL string handed to us by
/// libghostty's `GHOSTTY_ACTION_OPEN_URL` event. `classify` produces a
/// `ClassifiedTarget`, `resolve` combines it with a `ResolvedEditor` to
/// emit an `EditorAction` the caller dispatches. No AppKit, no
/// `TerminalManager` — caller supplies pane CWD and existence check.
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
        let parsed = URL(string: urlString)

        if let scheme = parsed?.scheme, !scheme.isEmpty, scheme != "file" {
            return .browser(parsed!)
        }

        let candidate: String
        if let parsed, parsed.scheme == "file", !parsed.path.isEmpty {
            candidate = parsed.path
        } else {
            candidate = urlString
        }

        // Try raw candidate first so a real filename containing `:NN` wins
        // over the same string interpreted as `path:line`.
        if let resolved = resolvePath(candidate, paneCwd: paneCwd),
           fileExists(resolved) {
            return .editorOpen(absolutePath: resolved, line: nil, column: nil)
        }

        if let (stripped, line, col) = stripLineColSuffix(candidate),
           let resolved = resolvePath(stripped, paneCwd: paneCwd),
           fileExists(resolved) {
            return .editorOpen(absolutePath: resolved, line: line, column: col)
        }

        return .invalid
    }

    /// Expand `~` and resolve relative paths against `paneCwd`. Returns
    /// nil if the path is relative and `paneCwd` is unset.
    private static func resolvePath(_ path: String, paneCwd: String?) -> URL? {
        if path.hasPrefix("~") {
            let expanded = (path as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        guard let cwd = paneCwd else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(path)
            .standardizedFileURL
    }

    private static let lineColRegex: NSRegularExpression = {
        // Force-try: the pattern is a compile-time constant.
        try! NSRegularExpression(pattern: #"^(.+?)(?::(\d+)(?::(\d+))?)?$"#)
    }()

    /// Match an optional trailing `:line(:col)`. Returns nil if no suffix
    /// matched — the caller already tried the raw candidate.
    private static func stripLineColSuffix(_ s: String) -> (String, Int?, Int?)? {
        let range = NSRange(s.startIndex..., in: s)
        guard let match = lineColRegex.firstMatch(in: s, range: range),
              match.numberOfRanges >= 2 else { return nil }

        let pathPart = String(s[Range(match.range(at: 1), in: s)!])

        let lineRange = match.range(at: 2)
        guard lineRange.location != NSNotFound,
              let lineSwiftRange = Range(lineRange, in: s),
              let line = Int(s[lineSwiftRange]) else {
            return nil
        }

        let colRange = match.numberOfRanges > 3 ? match.range(at: 3) : NSRange(location: NSNotFound, length: 0)
        var col: Int?
        if colRange.location != NSNotFound,
           let colSwiftRange = Range(colRange, in: s),
           let parsedCol = Int(s[colSwiftRange]) {
            col = parsedCol
        }

        return (pathPart, line, col)
    }

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

    public enum EditorAction: Equatable {
        /// Spawn a new pane (split-right of source) with this string as the
        /// initial PTY input. Includes trailing `\n`.
        case openInPane(initialInput: String)

        /// Hand `file` to the GUI app at `app` via NSWorkspace.
        case openWithApp(file: URL, app: URL)

        /// Open a file with its system default app, like `open <file>`.
        case openWithDefaultApp(URL)

        /// Hand `url` to NSWorkspace.shared.open (default URL handler).
        case openInBrowser(URL)

        /// Nothing to do (invalid target, etc). Caller should beep.
        case noOp
    }

    /// Combine a classified target with the resolved editor preference
    /// to produce a concrete action for the caller to execute.
    public static func resolve(
        target: ClassifiedTarget,
        editor: ResolvedEditor?
    ) -> EditorAction {
        switch target {
        case .browser(let url):
            return .openInBrowser(url)

        case .invalid:
            return .noOp

        case .editorOpen(let absolutePath, let line, _):
            if isBinaryFile(absolutePath) {
                return .openWithDefaultApp(absolutePath)
            }
            guard let editor else { return .noOp }
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

    /// Check a small prefix so extensionless files and mislabeled binary
    /// files do not get sent to a text editor. A known non-text file type
    /// also catches formats whose headers happen to be valid UTF-8.
    private static func isBinaryFile(_ url: URL) -> Bool {
        if let sample = sampleIfMaterialized(url), !isTextSample(sample) {
            return true
        }

        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              !type.identifier.hasPrefix("dyn.") else { return false }
        return type != .data && !type.conforms(to: .text)
    }

    /// `stat` does not materialize iCloud placeholders. `O_NONBLOCK` avoids
    /// blocking if the path becomes a pipe before `open`; `fstat` rejects it.
    private static func sampleIfMaterialized(_ url: URL) -> Data? {
        var before = stat()
        guard stat(url.path, &before) == 0,
              MaterializedFilesystemEntry.isRegularFile(before),
              (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) != false else {
            return nil
        }

        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var after = stat()
        guard fstat(fd, &after) == 0,
              MaterializedFilesystemEntry.isRegularFile(after) else { return nil }

        var bytes = [UInt8](repeating: 0, count: 8 * 1024)
        let count = read(fd, &bytes, bytes.count)
        return count > 0 ? Data(bytes.prefix(count)) : nil
    }

    private static func isTextSample(_ sample: Data) -> Bool {
        if sample.starts(with: [0xEF, 0xBB, 0xBF]) {
            return !sample.contains(0) && isValidUTF8Sample(sample)
        }
        let decoded: String?
        if sample.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            decoded = String(data: sample, encoding: .utf32LittleEndian)
        } else if sample.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            decoded = String(data: sample, encoding: .utf32BigEndian)
        } else if sample.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: sample, encoding: .utf16LittleEndian)
        } else if sample.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: sample, encoding: .utf16BigEndian)
        } else {
            guard !sample.contains(0) else { return false }
            return isValidUTF8Sample(sample)
        }
        guard let decoded else { return false }
        return !decoded.unicodeScalars.contains { $0.value == 0 }
    }

    private static func isValidUTF8Sample(_ sample: Data) -> Bool {
        if String(data: sample, encoding: .utf8) != nil { return true }
        // Only a full sample can end halfway through a UTF-8 character.
        guard sample.count == 8 * 1024 else { return false }
        let bytes = [UInt8](sample)
        for suffixLength in 1...3 {
            let start = bytes.count - suffixLength
            let leading = bytes[start]
            let sequenceLength: Int
            switch leading {
            case 0xC2...0xDF: sequenceLength = 2
            case 0xE0...0xEF: sequenceLength = 3
            case 0xF0...0xF4: sequenceLength = 4
            default: continue
            }
            guard suffixLength < sequenceLength,
                  bytes[(start + 1)...].allSatisfy({ (0x80...0xBF).contains($0) }) else {
                continue
            }
            if String(data: Data(bytes[..<start]), encoding: .utf8) != nil {
                return true
            }
        }
        return false
    }
}
