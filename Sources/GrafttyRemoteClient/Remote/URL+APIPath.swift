import Foundation

extension URL {
    /// Join an API suffix like `worktrees/panes` onto this URL, respecting
    /// whatever path the user's saved host already has. The trailing-slash
    /// handling matters because hosts behind reverse proxies sometimes
    /// include a path prefix (e.g. `https://proxy.example/graftty/`).
    func appendingAPIPath(_ suffix: String) -> URL? {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let existing = components?.path ?? ""
        components?.path = existing.hasSuffix("/") ? existing + suffix : existing + "/" + suffix
        return components?.url
    }
}
