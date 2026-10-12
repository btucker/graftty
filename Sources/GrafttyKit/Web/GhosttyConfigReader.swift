import Foundation

/// Reads the user's on-disk Ghostty config files and concatenates them in
/// the same priority order `GhosttyConfig.init` applies them at runtime:
///   1. `$XDG_CONFIG_HOME/ghostty/config` (or `~/.config/ghostty/config`)
///   2. `~/Library/Application Support/com.mitchellh.ghostty/config`
///
/// Later files override earlier ones in Ghostty's loader. `resolvedConfig`
/// retains raw directives for the legacy HTTP endpoint. `portableConfig`
/// flattens includes for authenticated host presentation; the host supplies
/// resolved colors separately so mobile needs no theme files.
public enum GhosttyConfigReader {

    /// Flatten host includes in Ghostty's load order. Presentation consumers
    /// cannot access the host filesystem, so omit theme and include directives.
    /// The host renderer appends the resolved theme colors separately.
    public static func portableConfig() -> String {
        portableConfig(paths: candidatePaths())
    }

    static func portableConfig(paths: [String]) -> String {
        var lines: [String] = []
        var includes: [String] = []
        var loaded: Set<String> = []

        func load(_ path: String) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard !trimmed.hasPrefix("#"), parts.count == 2 else {
                    lines.append(line)
                    continue
                }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                if key == "theme" { continue }
                guard key == "config-file" else {
                    lines.append(line)
                    continue
                }
                // FileIterator removes outer quotes before Path.parse sees
                // the optional marker; Path.parse can then remove inner quotes.
                var value = unquoted(parts[1].trimmingCharacters(in: .whitespaces))
                // An empty repeatable config-file value clears earlier includes.
                guard !value.isEmpty else { includes.removeAll(); continue }
                if value.hasPrefix("?") { value.removeFirst() }
                value = unquoted(value)
                guard !value.isEmpty else { continue }
                // Ghostty preserves absolute spellings, expands only ~/,
                // and resolves relative includes through their symlink target.
                if value.hasPrefix("/") {
                    includes.append(value)
                } else if value.hasPrefix("~/") {
                    let home = ProcessInfo.processInfo.environment["HOME"]
                        ?? FileManager.default.homeDirectoryForCurrentUser.path
                    includes.append(home + value.dropFirst())
                } else {
                    let url = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(value)
                    includes.append(url.resolvingSymlinksInPath().standardizedFileURL.path)
                }
            }
        }

        // Ghostty loads all root configs first, then walks the include list.
        // Roots are not pre-seeded in the include set: a cycle can reload a
        // root once before Ghostty rejects an already-loaded include.
        for path in paths { load(path) }
        var index = 0
        while index < includes.count {
            let path = includes[index]
            // A loaded file can clear and replace the list. Ghostty retains
            // its cursor, so replacement entries before it are not loaded.
            index += 1
            guard loaded.insert(path).inserted else { continue }
            load(path)
        }
        return lines.joined(separator: "\n")
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    public static func resolvedConfig() -> String {
        var parts: [String] = []
        for path in candidatePaths() {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                parts.append("# from \(path)")
                parts.append(contents)
            }
        }
        return parts.joined(separator: "\n")
    }

    static func candidatePaths() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var paths: [String] = []

        let xdgHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(home)/.config"
        paths.append("\(xdgHome)/ghostty/config")

        paths.append("\(home)/Library/Application Support/com.mitchellh.ghostty/config")

        return paths
    }
}
