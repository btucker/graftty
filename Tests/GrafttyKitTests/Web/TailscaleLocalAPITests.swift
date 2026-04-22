import Testing
import Foundation
@testable import GrafttyKit

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

    @Test func parseStatus_extractsDNSNameStrippingTrailingDot() throws {
        let data = try fixture("tailscale-status")
        let status = try TailscaleLocalAPI.parseStatus(data)
        #expect(status.dnsName == "macbook.tail-abc12.ts.net")
    }

    @Test func parseStatus_missingDNSNameReturnsNil() throws {
        let raw = #"""
        {"Self":{"UserID":1,"TailscaleIPs":["100.64.0.5"]},"User":{"1":{"LoginName":"a@b"}}}
        """#
        let status = try TailscaleLocalAPI.parseStatus(Data(raw.utf8))
        #expect(status.dnsName == nil)
    }
}

@Suite("TailscaleLocalAPI — autoDetected transport selection")
struct TailscaleLocalAPIAutoDetectTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "tsapi-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        return dir
    }

    @Test func prefersUnixSocketWhenPresent() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // A plain file at the candidate path is enough for the existence probe.
        let fakeSocket = tmp + "/tailscaled.socket"
        FileManager.default.createFile(atPath: fakeSocket, contents: nil)
        // A macsys layout present too; socket should still win.
        try "9999".write(toFile: tmp + "/ipnport", atomically: true, encoding: .utf8)
        try "secret".write(toFile: tmp + "/sameuserproof-9999", atomically: true, encoding: .utf8)

        let api = try TailscaleLocalAPI.autoDetected(
            socketPaths: [fakeSocket],
            macsysSupportDir: tmp
        )
        #expect(api.transport == .unixSocket(path: fakeSocket))
    }

    @Test func fallsBackToMacsysTCPWhenSocketsAbsent() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "49161".write(toFile: tmp + "/ipnport", atomically: true, encoding: .utf8)
        try "token-abc-123".write(
            toFile: tmp + "/sameuserproof-49161", atomically: true, encoding: .utf8
        )

        let api = try TailscaleLocalAPI.autoDetected(
            socketPaths: ["/does/not/exist/tailscaled.socket"],
            macsysSupportDir: tmp
        )
        #expect(api.transport == .tcpLocalhost(port: 49161, authToken: "token-abc-123"))
    }

    @Test func readsPortFromIpnportSymlink() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // macsys writes ipnport as a symlink whose target is the port number.
        try FileManager.default.createSymbolicLink(
            atPath: tmp + "/ipnport", withDestinationPath: "49161"
        )
        try "token-xyz".write(
            toFile: tmp + "/sameuserproof-49161", atomically: true, encoding: .utf8
        )

        let api = try TailscaleLocalAPI.autoDetected(
            socketPaths: ["/does/not/exist/tailscaled.socket"],
            macsysSupportDir: tmp
        )
        #expect(api.transport == .tcpLocalhost(port: 49161, authToken: "token-xyz"))
    }

    @Test func trimsWhitespaceFromTokenAndPort() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "  49161\n".write(toFile: tmp + "/ipnport", atomically: true, encoding: .utf8)
        try "token-xyz\n".write(
            toFile: tmp + "/sameuserproof-49161", atomically: true, encoding: .utf8
        )
        let api = try TailscaleLocalAPI.autoDetected(
            socketPaths: ["/does/not/exist/tailscaled.socket"],
            macsysSupportDir: tmp
        )
        #expect(api.transport == .tcpLocalhost(port: 49161, authToken: "token-xyz"))
    }

    @Test func throwsSocketUnreachableWhenNothingPresent() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        #expect(throws: TailscaleLocalAPI.Error.socketUnreachable) {
            _ = try TailscaleLocalAPI.autoDetected(
                socketPaths: ["/does/not/exist/tailscaled.socket"],
                macsysSupportDir: tmp
            )
        }
    }

    /// `detectMacsysTCP` hands its port down to `openTCPLocalhost`
    /// which does `UInt16(port)` — a signed-overflow trap when the
    /// file-sourced Int is outside [0, 65535]. A corrupted `ipnport`,
    /// a user hand-edit, or a future Tailscale layout change writing
    /// a larger number would then crash Graftty the first time the
    /// web-access code path hits the Tailscale LocalAPI.
    ///
    /// Treat an out-of-range port as "not detected" at the parse
    /// boundary so autoDetected falls through cleanly to
    /// `.socketUnreachable` instead of storing a ticking-bomb port
    /// in the transport enum.
    @Test func outOfRangePortIsNotDetected() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "70000".write(toFile: tmp + "/ipnport", atomically: true, encoding: .utf8)
        try "token-xyz".write(
            toFile: tmp + "/sameuserproof-70000", atomically: true, encoding: .utf8
        )
        #expect(throws: TailscaleLocalAPI.Error.socketUnreachable) {
            _ = try TailscaleLocalAPI.autoDetected(
                socketPaths: ["/does/not/exist/tailscaled.socket"],
                macsysSupportDir: tmp
            )
        }
    }

    @Test func negativePortIsNotDetected() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "-1".write(toFile: tmp + "/ipnport", atomically: true, encoding: .utf8)
        try "token-xyz".write(
            toFile: tmp + "/sameuserproof--1", atomically: true, encoding: .utf8
        )
        #expect(throws: TailscaleLocalAPI.Error.socketUnreachable) {
            _ = try TailscaleLocalAPI.autoDetected(
                socketPaths: ["/does/not/exist/tailscaled.socket"],
                macsysSupportDir: tmp
            )
        }
    }

    @Test func missingTokenFileIsNotDetected() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "49161".write(toFile: tmp + "/ipnport", atomically: true, encoding: .utf8)
        // Intentionally no sameuserproof-49161 file.
        #expect(throws: TailscaleLocalAPI.Error.socketUnreachable) {
            _ = try TailscaleLocalAPI.autoDetected(
                socketPaths: ["/does/not/exist/tailscaled.socket"],
                macsysSupportDir: tmp
            )
        }
    }

    @Test func emptyTokenIsNotDetected() throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try "49161".write(toFile: tmp + "/ipnport", atomically: true, encoding: .utf8)
        try "   \n".write(
            toFile: tmp + "/sameuserproof-49161", atomically: true, encoding: .utf8
        )
        #expect(throws: TailscaleLocalAPI.Error.socketUnreachable) {
            _ = try TailscaleLocalAPI.autoDetected(
                socketPaths: ["/does/not/exist/tailscaled.socket"],
                macsysSupportDir: tmp
            )
        }
    }
}

@Suite("TailscaleLocalAPI — cert pair")
struct TailscaleLocalAPICertParsingTests {

    private func fixture(_ name: String, ext: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    @Test func parseCertPair_splitsCertAndKey() throws {
        let data = try fixture("tailscale-cert-pair", ext: "pem")
        let pair = try TailscaleLocalAPI.parseCertPair(data)
        let cert = String(data: pair.cert, encoding: .utf8) ?? ""
        let key = String(data: pair.key, encoding: .utf8) ?? ""
        #expect(cert.contains("-----BEGIN CERTIFICATE-----"))
        #expect(cert.contains("-----END CERTIFICATE-----"))
        #expect(!cert.contains("PRIVATE KEY"))
        #expect(key.contains("PRIVATE KEY"))
        #expect(!key.contains("CERTIFICATE"))
    }

    @Test func parseCertPair_missingKeyThrows() {
        let justCert = "-----BEGIN CERTIFICATE-----\nX\n-----END CERTIFICATE-----\n"
        #expect(throws: TailscaleLocalAPI.Error.malformedResponse) {
            _ = try TailscaleLocalAPI.parseCertPair(Data(justCert.utf8))
        }
    }

    @Test func classifyCertError_recognisesHTTPSDisabled() throws {
        let body = try fixture("tailscale-cert-disabled", ext: "json")
        #expect(TailscaleLocalAPI.isHTTPSCertsDisabled(httpStatus: 500, body: body))
    }

    @Test func classifyCertError_ignoresUnrelatedErrors() {
        let body = Data("internal server error".utf8)
        #expect(TailscaleLocalAPI.isHTTPSCertsDisabled(httpStatus: 500, body: body) == false)
    }

    @Test func classifyCertError_ignoresSuccess() {
        let body = Data("{}".utf8)
        #expect(TailscaleLocalAPI.isHTTPSCertsDisabled(httpStatus: 200, body: body) == false)
    }
}
