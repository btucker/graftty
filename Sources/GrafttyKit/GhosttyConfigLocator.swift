import Foundation

/// Pure logic for deciding which on-disk Ghostty config file "Open Ghostty
/// Settings" should open. Mirrors Ghostty-macOS's own priority order: the
/// highest-priority *existing* file wins; if none exist, falls back to
/// Ghostty-macOS's default location
/// (`~/Library/Application Support/com.mitchellh.ghostty/config`) so the
/// user always has a concrete file to edit even on a first run where they've
/// never authored a config.
///
/// Extracted from the GUI so the priority order, XDG env parsing, and the
/// "create if missing" branch are exercisable without AppKit /
/// NSWorkspace.
public enum GhosttyConfigLocator {
    /// Path fragment relative to `$HOME` for Ghostty-macOS's default config
    /// file. Matches `GhosttyConfig.loadGhosttyMacOSConfigIfPresent`'s load
    /// path so "open" and "load" point at the same file.
    public static let macOSDefaultRelativePath = "Library/Application Support/com.mitchellh.ghostty/config"

    /// Resolve the config file `open_config` should target. Priority:
    ///   1. `$XDG_CONFIG_HOME/ghostty/config` (only if `XDG_CONFIG_HOME` is set and non-empty)
    ///   2. `~/.config/ghostty/config`
    ///   3. `~/Library/Application Support/com.mitchellh.ghostty/config`
    /// Returns the first that exists. If none exist, returns (3) — callers
    /// should create the file before handing to `NSWorkspace.open`, or the
    /// macOS editor dispatch will silently fail.
    public static func resolveURL(
        home: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        var candidates: [URL] = []
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            candidates.append(
                URL(fileURLWithPath: xdg)
                    .appendingPathComponent("ghostty")
                    .appendingPathComponent("config")
            )
        }
        candidates.append(
            home.appendingPathComponent(".config/ghostty/config")
        )
        let macOSDefault = home.appendingPathComponent(macOSDefaultRelativePath)
        candidates.append(macOSDefault)

        for url in candidates where fileManager.fileExists(atPath: url.path) {
            return url
        }
        return macOSDefault
    }

    /// Create an empty file at `url` (and any missing parent directories)
    /// if one doesn't already exist. No-op if the file is already there,
    /// so this is safe to call unconditionally after `resolveURL`.
    public static func ensureExists(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: url.path) { return }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        fileManager.createFile(atPath: url.path, contents: Data())
    }
}
