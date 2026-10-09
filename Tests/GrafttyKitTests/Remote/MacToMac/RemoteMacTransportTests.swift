import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

struct RemoteMacTransportTests {
    private func record() throws -> RemoteMac {
        RemoteMac(id: RemoteDeviceID(value: "linux"), label: "Linux",
                  fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: 1, count: 32)))
    }

    @Test("@spec REMOTE-20.1: When a saved remote host has no transport field, the application shall use WebRTC.")
    func legacyDefaultsToWebRTC() throws {
        let encoded = try JSONEncoder().encode(record())
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "transport")
        json.removeValue(forKey: "directEndpoint")
        let decoded = try JSONDecoder().decode(RemoteMac.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.transport == .webRTC)
        #expect(decoded.directEndpoint == nil)
    }

    @Test("@spec REMOTE-20.2: When a remote host uses direct SSH, the application shall persist its explicit Graftty endpoint with default port 8801.")
    func directEndpointRoundTrips() throws {
        var host = try record()
        host.transport = .directSSH
        host.directEndpoint = try DirectSSHEndpoint(host: "linux.example")
        let decoded = try JSONDecoder().decode(RemoteMac.self, from: JSONEncoder().encode(host))
        #expect(decoded.transport == .directSSH)
        #expect(decoded.directEndpoint?.host == "linux.example")
        #expect(decoded.directEndpoint?.port == 8801)
        #expect(throws: DirectSSHEndpoint.ValidationError.self) { try DirectSSHEndpoint(host: "", port: 8801) }
        #expect(throws: DirectSSHEndpoint.ValidationError.self) { try DirectSSHEndpoint(host: "linux", port: 0) }
    }
}
