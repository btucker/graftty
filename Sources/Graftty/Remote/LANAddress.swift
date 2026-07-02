import Darwin
import Foundation

/// Resolves the Mac's primary LAN IPv4 address for the pairing URL the
/// QR payload advertises. The pairing listener binds `0.0.0.0`; this
/// picks the address a phone on the same network should dial.
enum LANAddress {

    /// The best LAN IPv4 address of this machine, or `nil` when no
    /// usable interface is up (e.g. no network at all).
    static func primaryIPv4() -> String? {
        select(from: ipv4Interfaces())
    }

    /// Pure selection over `(interface name, IPv4 address)` candidates:
    /// skips loopback (`lo*` / `127.*`), tunnels (`utun*`), Apple
    /// Wireless Direct Link (`awdl*`), and link-local self-assigned
    /// addresses (`169.254.*`); prefers `en*` interfaces (Wi-Fi /
    /// Ethernet) over other survivors, preserving candidate order
    /// within each tier.
    static func select(from candidates: [(name: String, address: String)]) -> String? {
        let usable = candidates.filter { candidate in
            !candidate.name.hasPrefix("lo")
                && !candidate.name.hasPrefix("utun")
                && !candidate.name.hasPrefix("awdl")
                && !candidate.address.hasPrefix("127.")
                && !candidate.address.hasPrefix("169.254.")
        }
        return (usable.first { $0.name.hasPrefix("en") } ?? usable.first)?.address
    }

    /// Walks `getifaddrs` collecting every up interface's IPv4 address.
    private static func ipv4Interfaces() -> [(name: String, address: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  (Int32(entry.pointee.ifa_flags) & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            result.append((name: String(cString: entry.pointee.ifa_name), address: String(cString: host)))
        }
        return result
    }
}
