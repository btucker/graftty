import Foundation
import GrafttyProtocol

/// @spec REMOTE-2.6: Tailscale route discovery and refresh shall not depend on
/// Browser Web Access being enabled. Loss of Tailscale shall leave the LAN route
/// available; later recovery shall restore Tailscale-IP routes. Native clients
/// shall not advertise plaintext fully qualified MagicDNS routes that Apple
/// Transport Security rejects.
// Builds the routes a paired client can use to reach this Mac. Tailscale
// discovery is intentionally independent of browser Web Access: native
// paired-device signaling always uses its own stable HTTP listener.
public enum RemoteAccessRouteDiscovery {
    public static func routes(
        lanBaseURL: URL
    ) async -> [RemoteConnectionRoute] {
        guard let api = try? TailscaleLocalAPI.autoDetected(),
            let status = try? await api.status()
        else {
            return nativeRoutes(lanBaseURL: lanBaseURL, tailscaleIPs: [])
        }
        return nativeRoutes(
            lanBaseURL: lanBaseURL,
            tailscaleIPs: status.tailscaleIPs
        )
    }

    static func nativeRoutes(
        lanBaseURL: URL,
        tailscaleIPs: [String]
    ) -> [RemoteConnectionRoute] {
        // Every advertised route must reach the listener that answered this
        // exchange, so the Tailscale routes follow the LAN route's port
        // rather than the protocol default.
        let port = lanBaseURL.port ?? RemoteAccessProtocol.pairedAccessPort
        return [RemoteConnectionRoute(kind: .lan, baseURL: lanBaseURL)]
            + tailscaleIPs.compactMap { host in
                remoteAccessURL(host: host, port: port).map {
                    RemoteConnectionRoute(kind: .tailscaleIP, baseURL: $0)
                }
            }
    }

    public static func remoteAccessURL(
        host: String,
        port: Int = RemoteAccessProtocol.pairedAccessPort
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.host =
            normalizedHost.contains(":")
            && !normalizedHost.hasPrefix("[")
            ? "[\(normalizedHost)]"
            : normalizedHost
        components.port = port
        return components.url
    }
}
