import Foundation

/// Composes the shareable URL used in the "Copy web URL" action.
/// No statefulness; pure transformation from (host, port, session).
public enum WebURLComposer {

    /// Compose the URL. Bracket-notation for IPv6 hosts; percent-encode
    /// the session name.
    public static func url(session: String, host: String, port: Int) -> String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let encodedSession = session.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed.subtracting(
                CharacterSet(charactersIn: " ")
            )
        ) ?? session
        return "http://\(hostPart):\(port)/?session=\(encodedSession)"
    }

    /// Prefer the first IPv4 address; fall back to the first IPv6 only
    /// if no IPv4 is present. `nil` when the input is empty.
    public static func chooseHost(from ips: [String]) -> String? {
        if let v4 = ips.first(where: { !$0.contains(":") }) { return v4 }
        return ips.first
    }
}
