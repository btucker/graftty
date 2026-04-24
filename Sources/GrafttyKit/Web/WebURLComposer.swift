import Foundation

/// Composes the shareable URL used in the "Copy web URL" action and
/// the Settings-pane "Base URL" row. Pure transformation from
/// (host, port, session) to a string URL.
///
/// As of WEB-8, the host is always a MagicDNS FQDN (not an IP
/// literal) and the scheme is always HTTPS. The `authority(host:port:)`
/// helper is retained for the Settings-pane's diagnostic "Listening
/// on …" list, which still renders IP literals with bracketed IPv6
/// per WEB-1.10.
public enum WebURLComposer {

    /// Session-scoped URL. Percent-encodes the session segment with
    /// `urlPathAllowed` so session names containing reserved path
    /// separators (`?`, `#`) don't confuse the browser's URL parser
    /// (WEB-1.9).
    public static func url(session: String, host: String, port: Int) -> String {
        let encodedSession = session.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? session
        return "\(baseURL(host: host, port: port))session/\(encodedSession)"
    }

    /// Root URL of the server. HTTPS-only per WEB-6.1.
    public static func baseURL(host: String, port: Int) -> String {
        return "https://\(host):\(port)/"
    }

    /// Root URL for SSH tunnel mode. The Mac server binds HTTP to loopback
    /// only; SSH supplies the authenticated encrypted transport.
    public static func loopbackHTTPBaseURL(port: Int) -> String {
        return "http://127.0.0.1:\(port)/"
    }

    /// Compose a URI authority (`<host>:<port>`), bracketing IPv6.
    /// Used by the Settings-pane's "Listening on" diagnostic row
    /// (WEB-1.10) where host is still an IP literal.
    public static func authority(host: String, port: Int) -> String {
        let hostPart = host.contains(":") ? "[\(host)]" : host
        return "\(hostPart):\(port)"
    }
}
