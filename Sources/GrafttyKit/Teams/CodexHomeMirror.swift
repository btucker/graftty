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
            let key = Self.codexEventKey(event)
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

    /// Codex's hooks.json uses CamelCase event keys; map our kebab-case enum.
    private static func codexEventKey(_ event: TeamHookEvent) -> String {
        switch event {
        case .sessionStart: return "SessionStart"
        case .postToolUse: return "PostToolUse"
        case .stop: return "Stop"
        }
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

        let merged: String
        if userText.contains("codex_hooks") {
            merged = TomlEditor.setBool(userText, table: "features", key: "codex_hooks", value: true)
        } else if userText.contains("[features]") {
            merged = TomlEditor.insertAfterTableHeader(userText, table: "features", line: "codex_hooks = true")
        } else {
            let trailing = userText.isEmpty || userText.hasSuffix("\n") ? "" : "\n"
            let separator = userText.isEmpty ? "" : "\n"
            merged = userText + "\(trailing)\(separator)[features]\ncodex_hooks = true\n"
        }

        let outURL = mirrorDirectory.appendingPathComponent("config.toml")
        try merged.write(to: outURL, atomically: true, encoding: .utf8)
    }
}

/// Tiny TOML editor for the narrow case of toggling a boolean in a known table
/// without disturbing comments or other keys. Falls back to text manipulation
/// because most TOML libraries don't preserve round-trip comments.
enum TomlEditor {
    static func setBool(_ text: String, table: String, key: String, value: Bool) -> String {
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
        if didReplace { return out.joined(separator: "\n") }
        return insertAfterTableHeader(text, table: table, line: "\(key) = \(value)")
    }

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
        if !inserted {
            let trailing = text.hasSuffix("\n") || text.isEmpty ? "" : "\n"
            return text + "\(trailing)\n[\(table)]\n\(line)\n"
        }
        return out.joined(separator: "\n")
    }
}
