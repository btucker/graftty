import Foundation

/// Reads the user's on-disk Ghostty config files and concatenates them in
/// the same priority order `GhosttyConfig.init` applies them at runtime:
///   1. `$XDG_CONFIG_HOME/ghostty/config` (or `~/.config/ghostty/config`)
///   2. `~/Library/Application Support/com.mitchellh.ghostty/config`
///
/// Later files override earlier ones in Ghostty's loader, so the order
/// here mirrors that layering. `config-file = …` includes are NOT
/// recursively resolved — the forthcoming iOS client applies the result
/// through libghostty's parser, which honors `config-file` itself when
/// present but only relative to the client's filesystem (where the
/// referenced files don't exist). Users who split their Ghostty config
/// across multiple files on the Mac won't have their overrides reach the
/// iOS client until we recurse here. Flagged for a future follow-up.
public enum GhosttyConfigReader {

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
