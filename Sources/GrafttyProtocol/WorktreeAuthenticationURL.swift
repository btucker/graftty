import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An OAuth authorization page and the local listener waiting for its response.
/// @spec PORTS-5.15: When a terminal offers an OAuth authorization URL with one HTTP(S) loopback redirect, the application shall preserve the authorization and callback URLs and reject ambiguous or non-loopback redirects.
public struct WorktreeAuthenticationURL: Sendable, Equatable {
    public let authorizationURL: URL
    public let callbackURL: URL
    public let callbackHost: String
    public let callbackPort: UInt16

    public init?(url: URL) {
        guard Self.isWebURL(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let redirects = items.filter { $0.name == "redirect_uri" }
        guard redirects.count == 1, let value = redirects[0].value,
              let callback = URL(string: value), Self.isWebURL(callback),
              let host = callback.host, Self.isLoopbackHost(host), callback.fragment == nil,
              let port = UInt16(exactly: callback.port ?? (callback.scheme?.lowercased() == "https" ? 443 : 80)),
              port > 0 else { return nil }
        authorizationURL = url
        callbackURL = callback
        callbackHost = Self.normalizedHost(host)
        callbackPort = port
    }

    /// Select an actual worktree listener, including a concrete address for
    /// localhost so DNS cannot choose another worktree's listener on that port.
    public func resolveCallbackHost(in listeners: [WorktreePort]) -> String? {
        listeners.filter { $0.port == callbackPort && Self.isLoopbackHost($0.host) }
            .map { Self.normalizedHost($0.host) }.sorted().first { host in
                callbackHost == "localhost" || host == callbackHost || host == "localhost"
            }.map { $0 == "localhost" ? callbackHost : $0 }
    }

    public static func isLoopbackHost(_ host: String) -> Bool {
        canonicalLoopbackHost(host) != nil
    }

    public static func canonicalLoopbackHost(_ host: String) -> String? {
        let host = normalizedHost(host)
        if host == "localhost" || host == "::1" { return host }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127", octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
        return host
    }

    private static func normalizedHost(_ host: String) -> String {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var address = in6_addr()
        if inet_pton(AF_INET6, host, &address) == 1 {
            let loopback = withUnsafeBytes(of: address) { bytes in
                bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            }
            if loopback { return "::1" }
        }
        return host
    }

    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
}
