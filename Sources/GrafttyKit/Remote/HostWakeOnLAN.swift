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
        return targets(hardwareAddresses: addresses, interfaces: interfaces)
    }

    static func targets(
        hardwareAddresses: [String: String],
        interfaces: UnsafeMutablePointer<ifaddrs>?
    ) -> [WakeOnLANTarget] {
        var cursor = interfaces
        var activeAddresses: [String: String] = [:]
        var ipv4Addresses: [String: Set<String>] = [:]
        while let pointer = cursor {
            let interface = pointer.pointee
            cursor = interface.ifa_next
            let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
            guard interface.ifa_flags & required == required,
                interface.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                let address = interface.ifa_addr,
                let namePointer = interface.ifa_name
            else { continue }
            let name = String(cString: namePointer)
            guard hardwareAddresses[name] != nil else { continue }
            if address.pointee.sa_family == AF_LINK {
                activeAddresses[name] = linkMACAddress(address)
                continue
            }
            guard address.pointee.sa_family == AF_INET else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                inet_ntop(AF_INET, &$0.pointee.sin_addr, &buffer, socklen_t(buffer.count))
            }
            guard ip != nil else { continue }
            ipv4Addresses[name, default: []].insert(String(cString: buffer))
        }
        var targets = Set<WakeOnLANTarget>()
        for (name, ips) in ipv4Addresses {
            // SC supplies the permanent MAC, which may differ from the active
            // private Wi-Fi address. Keep both for hardware wake compatibility.
            let macAddresses = Set([hardwareAddresses[name]?.lowercased(), activeAddresses[name]].compactMap { $0 })
            for ip in ips {
                for mac in macAddresses {
                    let target = WakeOnLANTarget(macAddress: mac, ipv4Address: ip)
                    if target.magicPacket != nil { targets.insert(target) }
                }
            }
        }
        return Array(targets.sorted {
            if $0.macAddress == $1.macAddress { return $0.ipv4Address < $1.ipv4Address }
            return $0.macAddress < $1.macAddress
        }.prefix(16))
    }

    private static func linkMACAddress(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data)!
        let length = Int(address.pointee.sa_len)
        guard length >= dataOffset else { return nil }
        return address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
            let offset = dataOffset + Int(link.pointee.sdl_nlen)
            guard link.pointee.sdl_alen == 6, offset + 6 <= length else { return nil }
            let bytes = UnsafeRawPointer(address).advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return UnsafeBufferPointer(start: bytes, count: 6)
                .map { String(format: "%02x", $0) }.joined(separator: ":")
        }
    }
}
