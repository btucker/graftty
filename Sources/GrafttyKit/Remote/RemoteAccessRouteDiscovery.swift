import Foundation
import GrafttyProtocol

/// @spec REMOTE-2.6: Tailscale route discovery and refresh shall not depend on
/// Browser Web Access being enabled. Loss of Tailscale shall leave the LAN
/// route available; later recovery shall restore MagicDNS and Tailscale-IP
/// routes.
// Builds the routes a paired client can use to reach this Mac. Tailscale
// discovery is intentionally independent of browser Web Access: native
// paired-device signaling always uses its own stable HTTP listener.
public enum RemoteAccessRouteDiscovery {
    public static func routes(
        lanBaseURL: URL
    ) async -> [RemoteConnectionRoute] {
        var routes = [
            RemoteConnectionRoute(kind: .lan, baseURL: lanBaseURL)
        ]
        guard let api = try? TailscaleLocalAPI.autoDetected(),
            let status = try? await api.status()
        else {
            return routes
        }
        if let dnsName = status.dnsName,
            let url = remoteAccessURL(host: dnsName)
        {
            routes.append(RemoteConnectionRoute(kind: .tailscaleDNS, baseURL: url))
        }
        routes.append(
            contentsOf: status.tailscaleIPs.compactMap { host in
                remoteAccessURL(host: host).map {
                    RemoteConnectionRoute(kind: .tailscaleIP, baseURL: $0)
                }
            })
        return routes
    }

    public static func remoteAccessURL(host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.host =
            normalizedHost.contains(":")
            && !normalizedHost.hasPrefix("[")
            ? "[\(normalizedHost)]"
            : normalizedHost
        components.port = RemoteAccessProtocol.pairedAccessPort
        return components.url
    }
}
