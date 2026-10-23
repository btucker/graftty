import Darwin
import Foundation
import GrafttyProtocol
import Testing

@testable import GrafttyKit

@Suite("@spec REMOTE-2.15: When a host advertises wake addresses, the application shall include each eligible interface's valid active link-layer and permanent hardware addresses for its IPv4 address without duplicates.")
struct HostWakeOnLANTests {
    @Test(arguments: [true, false])
    func includesPrivateAndPermanentAddresses(linkFirst: Bool) throws {
        let result = try targets(active: [2, 17, 34, 51, 68, 85], linkFirst: linkFirst)
        #expect(Set(result) == [
            WakeOnLANTarget(macAddress: "02:11:22:33:44:55", ipv4Address: "192.168.1.10"),
            WakeOnLANTarget(macAddress: "00:11:22:33:44:55", ipv4Address: "192.168.1.10"),
        ])
    }

    @Test
    func deduplicatesMatchingAddresses() throws {
        let result = try targets(active: [0, 17, 34, 51, 68, 170], permanent: "00:11:22:33:44:AA")
        #expect(result == [
            WakeOnLANTarget(macAddress: "00:11:22:33:44:aa", ipv4Address: "192.168.1.10")
        ])
    }

    @Test
    func omitsInvalidPermanentAddress() throws {
        let result = try targets(active: [2, 17, 34, 51, 68, 85], permanent: "00:00:00:00:00:00")
        #expect(result == [
            WakeOnLANTarget(macAddress: "02:11:22:33:44:55", ipv4Address: "192.168.1.10")
        ])
    }

    @Test(arguments: [
        [UInt8](), [0, 0, 0, 0, 0, 0], [1, 17, 34, 51, 68, 85],
        [2, 17, 34, 51, 68], [2, 17, 34, 51, 68, 85, 102],
    ])
    func ignoresInvalidActiveAddresses(active: [UInt8]) throws {
        let result = try targets(active: active)
        #expect(result == [
            WakeOnLANTarget(macAddress: "00:11:22:33:44:55", ipv4Address: "192.168.1.10")
        ])
    }

    @Test(arguments: [UInt8(7), UInt8(16)])
    func ignoresTruncatedLinkAddress(length: UInt8) throws {
        let result = try targets(active: [2, 17, 34, 51, 68, 85], linkLength: length)
        #expect(result == [
            WakeOnLANTarget(macAddress: "00:11:22:33:44:55", ipv4Address: "192.168.1.10")
        ])
    }

    @Test
    func preservesInterfaceEligibility() throws {
        for flags in [IFF_UP | IFF_BROADCAST, IFF_UP | IFF_RUNNING, IFF_UP | IFF_RUNNING | IFF_BROADCAST | IFF_LOOPBACK] {
            #expect(try targets(active: [2, 17, 34, 51, 68, 85], flags: UInt32(flags)).isEmpty)
        }
    }

    private func targets(
        active: [UInt8],
        permanent: String = "00:11:22:33:44:55",
        linkFirst: Bool = true,
        linkLength: UInt8? = nil,
        flags: UInt32 = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
    ) throws -> [WakeOnLANTarget] {
        let name = try #require(strdup("en0"))
        defer { free(name) }
        var ipv4 = sockaddr_in()
        ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ipv4.sin_family = sa_family_t(AF_INET)
        #expect(inet_pton(AF_INET, "192.168.1.10", &ipv4.sin_addr) == 1)
        var link = sockaddr_dl()
        link.sdl_len = UInt8(MemoryLayout<sockaddr_dl>.size)
        link.sdl_family = sa_family_t(AF_LINK)
        link.sdl_nlen = 3
        link.sdl_alen = UInt8(active.count)
        withUnsafeMutableBytes(of: &link.sdl_data) { bytes in
            bytes.copyBytes(from: Array("en0".utf8) + active)
        }
        if let linkLength { link.sdl_len = linkLength }
        return withUnsafeMutablePointer(to: &ipv4) { ipv4Pointer in
            ipv4Pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { ipv4Address in
                withUnsafeMutablePointer(to: &link) { linkPointer in
                    linkPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { linkAddress in
                        var ipv4Record = ifaddrs()
                        ipv4Record.ifa_name = name
                        ipv4Record.ifa_flags = flags
                        ipv4Record.ifa_addr = ipv4Address
                        var linkRecord = ifaddrs()
                        linkRecord.ifa_name = name
                        linkRecord.ifa_flags = flags
                        linkRecord.ifa_addr = linkAddress
                        return withUnsafeMutablePointer(to: &ipv4Record) { ipv4RecordPointer in
                            withUnsafeMutablePointer(to: &linkRecord) { linkRecordPointer in
                                if linkFirst { linkRecordPointer.pointee.ifa_next = ipv4RecordPointer }
                                else { ipv4RecordPointer.pointee.ifa_next = linkRecordPointer }
                                return HostWakeOnLAN.targets(
                                    hardwareAddresses: ["en0": permanent],
                                    interfaces: linkFirst ? linkRecordPointer : ipv4RecordPointer
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}
