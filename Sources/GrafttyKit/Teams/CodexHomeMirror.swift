import Foundation

/// @spec TEAM-IDLE-1.1
/// Synthesizes a CODEX_HOME directory that mirrors the user's `~/.codex/`
/// via symlinks, with `hooks.json` and `config.toml` overridden by graftty's
/// versions (union-merged with user's). Idempotent — runs on every wrapper
/// invocation via `graftty internal sync-codex-home`.
public struct CodexHomeMirror: Sendable {
    public static let grafttyCommandPrefix = "graftty team hook codex"

    public let sourceDirectory: URL
    public let mirrorDirectory: URL
    public let grafttyCLIPath: String

    public init(sourceDirectory: URL, mirrorDirectory: URL, grafttyCLIPath: String) {
        self.sourceDirectory = sourceDirectory
        self.mirrorDirectory = mirrorDirectory
        self.grafttyCLIPath = grafttyCLIPath
    }

    /// `<rootDirectory>/codex-home/` where rootDirectory = AgentHookInstaller's root.
    public static func defaultMirrorDirectory(rootDirectory: URL = AgentHookInstaller.rootDirectory()) -> URL {
        rootDirectory.appendingPathComponent("codex-home", isDirectory: true)
    }

    public static func defaultSourceDirectory() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
    }

    /// Strip-and-rewrite. Idempotent.
    public func rebuild() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mirrorDirectory, withIntermediateDirectories: true)

        let sourceEntries: [String] = (try? fm.contentsOfDirectory(atPath: sourceDirectory.path)) ?? []
        let preserved: Set<String> = ["hooks.json", "config.toml"]

        // Pass 1: write/refresh symlinks for source entries we don't own.
        for name in sourceEntries where !preserved.contains(name) {
            let linkPath = mirrorDirectory.appendingPathComponent(name)
            let target = sourceDirectory.appendingPathComponent(name)
            try replaceSymlink(at: linkPath, target: target)
        }

        // Pass 2: prune mirror entries that no longer exist in source (excluding our owned files).
        let mirrorEntries: [String] = (try? fm.contentsOfDirectory(atPath: mirrorDirectory.path)) ?? []
        let sourceSet = Set(sourceEntries)
        for name in mirrorEntries where !preserved.contains(name) && !sourceSet.contains(name) {
            try? fm.removeItem(at: mirrorDirectory.appendingPathComponent(name))
        }

        // Pass 3: write graftty-owned files.
        try writeMergedHooks()
        try writeMergedConfig()
    }

    private func replaceSymlink(at link: URL, target: URL) throws {
        let fm = FileManager.default
        // Existing symlink to the same target — keep as-is (idempotent).
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path),
           existing == target.path {
            return
        }
        try? fm.removeItem(at: link)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
    }

    private func writeMergedHooks() throws {
        let userHooksURL = sourceDirectory.appendingPathComponent("hooks.json")
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: userHooksURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for event in TeamHookEvent.allCases {
            let key = event.camelCaseKey
            let existing = (hooks[key] as? [[String: Any]]) ?? []
            let stripped = existing.filter { group in
                let handlers = (group["hooks"] as? [[String: Any]]) ?? []
                return !handlers.contains(where: {
                    ($0["command"] as? String)?.hasPrefix(Self.grafttyCommandPrefix) == true
                })
            }
            hooks[key] = stripped + [grafttyMatcherGroup(event: event)]
        }
        root["hooks"] = hooks

        let outURL = mirrorDirectory.appendingPathComponent("hooks.json")
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outURL, options: .atomic)
    }

    private func grafttyMatcherGroup(event: TeamHookEvent) -> [String: Any] {
        [
            "hooks": [
                [
                    "type": "command",
                    "command": "\(grafttyCLIPath) team hook codex \(event.rawValue)",
                ],
            ],
        ]
    }

    /// Read user's config.toml (if any), ensure [features].codex_hooks = true,
    /// preserve every other key/table, write merged file.
    private func writeMergedConfig() throws {
        let userConfigURL = sourceDirectory.appendingPathComponent("config.toml")
        let userText = (try? String(contentsOf: userConfigURL)) ?? ""
        let merged = TomlEditor.ensureBool(userText, table: "features", key: "codex_hooks", value: true)
        let outURL = mirrorDirectory.appendingPathComponent("config.toml")
        try merged.write(to: outURL, atomically: true, encoding: .utf8)
    }
}

/// Tiny TOML editor for the narrow case of toggling a boolean in a known table
/// without disturbing comments or other keys.
///
/// **Limitations** (acceptable for our single-key feature-flag use case):
/// - Does not handle inline tables (`features = { codex_hooks = true }`).
///   If a user expresses `features` as an inline table, this editor will
///   produce invalid TOML by also appending a `[features]` section header.
/// - Does not handle multiline strings spanning section boundaries.
/// - Does not handle dotted keys (`features.codex_hooks = true` at top level).
///
/// If your use case requires any of the above, switch to a real TOML library.
enum TomlEditor {
    static func ensureBool(_ text: String, table: String, key: String, value: Bool) -> String {
        // 1. If the key is already set inside the target table, replace its value.
        // 2. Else if the target table exists, insert the key after its header.
        // 3. Else append a new [table] block with the key.
        if let replaced = replaceWithinTable(text, table: table, key: key, value: value) {
            return replaced
        }
        if textHasTableHeader(text, table: table) {
            return insertAfterTableHeader(text, table: table, line: "\(key) = \(value)")
        }
        let trailing = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        let separator = text.isEmpty ? "" : "\n"
        return text + "\(trailing)\(separator)[\(table)]\n\(key) = \(value)\n"
    }

    /// Returns nil if the key is not present inside the target table; otherwise the rewritten text.
    private static func replaceWithinTable(_ text: String, table: String, key: String, value: Bool) -> String? {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var inTargetTable = false
        var didReplace = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inTargetTable = (trimmed == "[\(table)]")
                out.append(line)
                continue
            }
            if inTargetTable && (trimmed.hasPrefix("\(key) ") || trimmed.hasPrefix("\(key)=") || trimmed.hasPrefix("\(key)\t")) {
                out.append("\(key) = \(value)")
                didReplace = true
                continue
            }
            out.append(line)
        }
        return didReplace ? out.joined(separator: "\n") : nil
    }

    private static func textHasTableHeader(_ text: String, table: String) -> Bool {
        text.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "[\(table)]" }
    }

    /// Insert a line directly after the `[table]` header. Caller must have verified the table exists.
    static func insertAfterTableHeader(_ text: String, table: String, line: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var inserted = false
        for current in lines {
            out.append(current)
            if !inserted, current.trimmingCharacters(in: .whitespaces) == "[\(table)]" {
                out.append(line)
                inserted = true
            }
        }
        return out.joined(separator: "\n")
    }
}
