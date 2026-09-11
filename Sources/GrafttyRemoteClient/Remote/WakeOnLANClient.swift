import Darwin
import Foundation
import GrafttyProtocol

enum WakeOnLANClient {
    /// Returns whether at least one packet was sent, not whether the host woke.
    static func send(_ targets: [WakeOnLANTarget]) async -> Bool {
        #if os(macOS)
        guard !Task.isCancelled else { return false }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return false }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        var sent = false
        while let pointer = cursor {
            guard !Task.isCancelled else { return sent }
            let interface = pointer.pointee
            cursor = interface.ifa_next
            let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
            guard interface.ifa_flags & required == required,
                interface.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                let address = interface.ifa_addr, address.pointee.sa_family == AF_INET,
                let mask = interface.ifa_netmask,
                let local = ipv4String(address), let netmask = ipv4String(mask)
            else { continue }
            for target in Set(targets) {
                guard let packet = target.magicPacket,
                    let broadcast = broadcastAddress(host: target.ipv4Address, local: local, netmask: netmask)
                else { continue }
                if send(packet, to: broadcast, interfaceIndex: if_nametoindex(interface.ifa_name)) {
                    sent = true
                }
            }
        }
        return sent
        #else
        // iOS broadcast requires Apple's managed multicast entitlement.
        // Enable the sender there only once distribution profiles include it.
        return false
        #endif
    }

    static func broadcastAddress(host: String, local: String, netmask: String) -> String? {
        guard let host = ipv4Number(host), let local = ipv4Number(local),
            let mask = ipv4Number(netmask), mask != 0
        else { return nil }
        let suffix = ~mask
        guard suffix > 1, suffix & (suffix &+ 1) == 0,
            host >> 24 != 0, host >> 24 != 127, host < 0xE000_0000,
            host & mask == local & mask,
            host & suffix != 0, host & suffix != suffix
        else { return nil }
        let broadcast = (local & mask) | suffix
        return [24, 16, 8, 0].map { String((broadcast >> $0) & 255) }.joined(separator: ".")
    }

    private static func ipv4Number(_ value: String) -> UInt32? {
        var address = in_addr()
        guard value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    #if os(macOS)
    private static func ipv4String(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        guard address.pointee.sa_family == AF_INET else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            guard inet_ntop(AF_INET, &$0.pointee.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
    }

    private static func send(_ packet: Data, to broadcast: String, interfaceIndex: UInt32) -> Bool {
        guard interfaceIndex != 0 else { return false }
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var enabled: Int32 = 1
        var index = interfaceIndex
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
            setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
            setsockopt(descriptor, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout.size(ofValue: index))) == 0
        else { return false }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(9).bigEndian
        guard broadcast.withCString({ inet_pton(AF_INET, $0, &destination.sin_addr) }) == 1 else { return false }
        var sent = false
        for _ in 0..<3 {
            let count = withUnsafePointer(to: &destination) { address in
                address.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    packet.withUnsafeBytes { bytes in
                        sendto(descriptor, bytes.baseAddress, bytes.count, 0, address, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            sent = sent || count == packet.count
        }
        return sent
    }
    #endif
}
