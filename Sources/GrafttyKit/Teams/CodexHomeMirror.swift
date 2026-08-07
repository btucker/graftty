import Foundation

/// @spec TEAM-IDLE-1.1
/// Synthesizes a CODEX_HOME directory that mirrors the user's `~/.codex/`
/// via symlinks, with only `hooks.json` overridden by graftty's union-merged
/// version. `config.toml` remains linked to the durable user configuration;
/// the wrapper enables hooks with a launch-scoped CLI override. Idempotent -
/// runs via `graftty internal sync-codex-home` before managed sessions.
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
        let owned: Set<String> = ["hooks.json"]
        var mirroredEntries = sourceEntries.filter { !owned.contains($0) }
        if !mirroredEntries.contains("config.toml") {
            // Keep a dangling link when the user has no config yet. Codex can
            // create the durable target through it on the first config write.
            mirroredEntries.append("config.toml")
        }

        // Pass 1: write/refresh symlinks for every durable source entry.
        for name in mirroredEntries {
            let linkPath = mirrorDirectory.appendingPathComponent(name)
            let target = sourceDirectory.appendingPathComponent(name)
            try replaceSymlink(at: linkPath, target: target)
        }

        // Pass 2: prune mirror entries that no longer belong to the durable
        // source (excluding our owned hook file and the intentional dangling
        // config link).
        let mirrorEntries: [String] = (try? fm.contentsOfDirectory(atPath: mirrorDirectory.path)) ?? []
        let mirroredSet = Set(mirroredEntries)
        for name in mirrorEntries where !owned.contains(name) && !mirroredSet.contains(name) {
            try? fm.removeItem(at: mirrorDirectory.appendingPathComponent(name))
        }

        // Pass 3: write graftty's only owned file.
        try writeMergedHooks()
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
                return !handlers.contains(where: { handler in
                    guard let command = handler["command"] as? String else { return false }
                    return Self.isGrafttyCodexHookCommand(command)
                })
            }
            hooks[key] = event == .sessionStart
                ? stripped + [grafttyMatcherGroup(event: event)]
                : stripped
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

    private static func isGrafttyCodexHookCommand(_ command: String) -> Bool {
        command.hasPrefix(grafttyCommandPrefix) || command.contains(" team hook codex ")
    }

}
