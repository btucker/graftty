import Testing
import Foundation
@testable import EspalierKit

@Suite("TailscaleLocalAPI — parsing")
struct TailscaleLocalAPIParsingTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "fixture \(name).json missing"
        )
        return try Data(contentsOf: url)
    }

    @Test func parseStatus_extractsOwnerAndIPs() throws {
        let data = try fixture("tailscale-status")
        let status = try TailscaleLocalAPI.parseStatus(data)
        #expect(status.loginName == "ben@example.com")
        #expect(status.tailscaleIPs.count == 2)
        #expect(status.tailscaleIPs.contains("100.64.0.5"))
        #expect(status.tailscaleIPs.contains("fd7a:115c:a1e0::5"))
    }

    @Test func parseWhois_ownerLoginName() throws {
        let data = try fixture("tailscale-whois-owner")
        let whois = try TailscaleLocalAPI.parseWhois(data)
        #expect(whois.loginName == "ben@example.com")
    }

    @Test func parseWhois_peerLoginName() throws {
        let data = try fixture("tailscale-whois-peer")
        let whois = try TailscaleLocalAPI.parseWhois(data)
        #expect(whois.loginName == "someone-else@example.com")
    }

    @Test func parseStatus_malformedReturnsNil() throws {
        let data = Data("{ not valid json".utf8)
        #expect(throws: DecodingError.self) {
            _ = try TailscaleLocalAPI.parseStatus(data)
        }
    }
}
