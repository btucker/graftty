import Darwin
import Foundation
import GrafttyProtocol
import SystemConfiguration

public enum HostWakeOnLAN {
    /// Advertises physical interfaces with active IPv4 broadcast connectivity.
    /// Hardware and macOS power settings determine whether they can wake a Mac.
    public static func targets() -> [WakeOnLANTarget] {
        let hardware = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        var addresses: [String: String] = [:]
        for interface in hardware {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                let mac = SCNetworkInterfaceGetHardwareAddressString(interface) as String?
            else { continue }
            addresses[name] = mac
        }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return [] }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        var targets = Set<WakeOnLANTarget>()
        while let pointer = cursor {
            let interface = pointer.pointee
            cursor = interface.ifa_next
            let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
            guard interface.ifa_flags & required == required,
                interface.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                let address = interface.ifa_addr, address.pointee.sa_family == AF_INET,
                let mac = addresses[String(cString: interface.ifa_name)]
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                inet_ntop(AF_INET, &$0.pointee.sin_addr, &buffer, socklen_t(buffer.count))
            }
            guard ip != nil else { continue }
            let target = WakeOnLANTarget(macAddress: mac, ipv4Address: String(cString: buffer))
            if target.magicPacket != nil { targets.insert(target) }
        }
        return Array(targets.sorted {
            if $0.macAddress == $1.macAddress { return $0.ipv4Address < $1.ipv4Address }
            return $0.macAddress < $1.macAddress
        }.prefix(16))
    }
}
