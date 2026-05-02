#if canImport(UIKit)
import Foundation
import UIKit

/// Process-local cache of resolved Ghostty configs keyed by baseURL.
/// Fetched once per host per app launch — navigating pane→pane on the
/// same host doesn't re-issue the HTTP request or re-parse the file.
@MainActor
private final class GhosttyConfigCache {
    static let shared = GhosttyConfigCache()
    private var byBaseURL: [URL: String] = [:]
    private var inflight: [URL: Task<String?, Never>] = [:]

    func configuredText(for baseURL: URL) async -> String? {
        if let cached = byBaseURL[baseURL] { return cached }
        if let existing = inflight[baseURL] { return await existing.value }
        let task = Task<String?, Never> { [baseURL] in
            await GhosttyConfigFetcher.fetchUncached(baseURL: baseURL)
        }
        inflight[baseURL] = task
        let result = await task.value
        inflight[baseURL] = nil
        if let result { byBaseURL[baseURL] = result }
        return result
    }

    func invalidate(baseURL: URL) {
        byBaseURL.removeValue(forKey: baseURL)
    }
}

/// Pulls the Mac server's resolved Ghostty config text from
/// `GET <baseURL>/ghostty-config` so TerminalController can render with
/// the same fonts/colors as the desktop app.
public enum GhosttyConfigFetcher {

    /// Ratio by which the iOS font-size scales relative to the Mac
    /// config's font-size. 0.8 → 20% smaller. Applied by appending an
    /// override line, so the Mac config is what drives the baseline and
    /// the scale is a single knob to tune.
    public static let iosFontScale: Double = 0.8

    /// Default font size to use when the Mac config has no `font-size =`
    /// line to scale. 13 matches upstream Ghostty's built-in default.
    private static let defaultMacFontSize: Double = 13

    /// Cached fetch. Prefer this from UI — identical results across
    /// multiple pane views on the same host, one network round-trip per
    /// host per app launch.
    @MainActor
    public static func fetch(baseURL: URL) async -> String? {
        await GhosttyConfigCache.shared.configuredText(for: baseURL)
    }

    /// Bypass the cache — useful for a "reload config" UI if we add one.
    @MainActor
    public static func invalidateCache(for baseURL: URL) {
        GhosttyConfigCache.shared.invalidate(baseURL: baseURL)
    }

    static func fetchUncached(
        baseURL: URL,
        session: URLSession = .shared
    ) async -> String? {
        guard let url = baseURL.appendingAPIPath("ghostty-config") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("text/plain", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let text = String(decoding: data, as: UTF8.self)
            guard !text.isEmpty else { return nil }
            return scaledForIOS(text)
        } catch {
            return nil
        }
    }

    /// Scale the font-size in the Mac config down for iOS. Reads the last
    /// `font-size = …` value (later keys override earlier ones in
    /// Ghostty's loader, so "last" is the effective value) and appends a
    /// scaled override. If no value is found, appends
    /// `defaultMacFontSize * iosFontScale`.
    static func scaledForIOS(_ macConfig: String) -> String {
        let macSize = lastFontSize(in: macConfig) ?? defaultMacFontSize
        let iosSize = macSize * iosFontScale
        let formatted = String(format: "%.1f", iosSize)
        return macConfig + "\n# GrafttyMobile override — \(Int(iosFontScale * 100))% of desktop\nfont-size = \(formatted)\n"
    }

    /// Parse the last `font-size = N` line out of a Ghostty config file.
    /// Tolerates whitespace, comments, and unrelated keys. Returns nil if
    /// no such line exists.
    static func lastFontSize(in config: String) -> Double? {
        var last: Double?
        for line in config.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard key == "font-size" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if let n = Double(value) {
                last = n
            }
        }
        return last
    }

    /// Infer the preferred UIUserInterfaceStyle from a Ghostty config string.
    ///
    /// Ghostty supports two `theme` formats:
    /// - Single theme: `theme = Dracula` or `theme = "Gruvbox Dark Hard"` —
    ///   an explicit choice that should be respected regardless of the system
    ///   appearance. libghostty-spm's `setColorScheme()` call from
    ///   `traitCollectionDidChange` would otherwise override it with a
    ///   system-default light theme when the device is in Light Mode.
    /// - Light/dark pair: `theme = light:GitHub Light,dark:Dracula` — the
    ///   user wants adaptive appearance; leave the system appearance alone.
    ///
    /// For single themes the name is checked for the word "light"
    /// (case-insensitive) to catch themes like "Solarized Light". Everything
    /// else defaults to `.dark` since the vast majority of terminal themes are
    /// dark. The returned style is applied as `overrideUserInterfaceStyle` on
    /// the terminal container view so `traitCollectionDidChange` never
    /// delivers a conflicting color scheme to libghostty.
    static func preferredInterfaceStyle(for config: String) -> UIUserInterfaceStyle {
        var lastTheme: String?
        for line in config.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard key == "theme" else { continue }
            lastTheme = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard let theme = lastTheme else { return .unspecified }
        // light:/dark: prefix → user wants adaptive appearance.
        if theme.contains("light:") || theme.contains("dark:") { return .unspecified }
        // Single theme — infer from name; "light" wins, everything else is dark.
        return theme.lowercased().contains("light") ? .light : .dark
    }

    /// Nil-safe wrapper: returns `.unspecified` when `config` is nil.
    static func preferredInterfaceStyle(for config: String?) -> UIUserInterfaceStyle {
        guard let config else { return .unspecified }
        return preferredInterfaceStyle(for: config)
    }
}
#endif
