import Foundation
import Testing

struct MobileSignalingPackagingTests {
    @Test("@spec REMOTE-2.19: When the mobile client signals a paired Mac over Tailscale, the application shall permit HTTP signaling to Tailscale IPv4 and IPv6 ranges without disabling App Transport Security globally.")
    func tailscaleSignalingExceptions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Apps/GrafttyMobile/GrafttyMobile/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsArbitraryLoads"] as? Bool != true)
        let exceptions = try #require(ats["NSExceptionDomains"] as? [String: [String: Any]])
        for range in ["100.64.0.0/10", "fd7a:115c:a1e0::/48"] {
            #expect(exceptions[range]?["NSExceptionAllowsInsecureHTTPLoads"] as? Bool == true)
        }
        #expect(Set(exceptions.keys) == ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
    }
}
