import Testing
import Foundation
import Darwin
@testable import GrafttyKit

@Suite("TailscaleLocalAPI — slow cert mint")
struct TailscaleLocalAPISlowMintTests {

    /// First-mint `tailscale cert` runs an ACME DNS-01 exchange and
    /// regularly takes 10–30 s; the legacy 2 s `SO_RCVTIMEO` shared
    /// with `whois`/`status` truncated the response and surfaced as
    /// `.certFetchFailed("malformedResponse")`.
    @Test("""
    @spec WEB-8.5: While reading a `/localapi/v0/cert/<fqdn>` response, the application shall use a recv timeout sized for first-time Let's Encrypt minting (≥60s), distinct from the 2s timeout used for `whois`/`status`, so a slow ACME exchange does not surface as `.certFetchFailed("malformedResponse")`.
    """)
    func certPair_succeedsAcrossSlowMint() async throws {
        let pem = """
        -----BEGIN PRIVATE KEY-----
        MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg/fakekey/
        -----END PRIVATE KEY-----
        -----BEGIN CERTIFICATE-----
        MIIBjDCCATGgAwIBAgIUKqUwaLSqXnvi7NnqRF/IuIiNUgI/fakecert/
        -----END CERTIFICATE-----

        """
        let response = """
        HTTP/1.0 200 OK\r
        Content-Type: application/x-pem-file\r
        \r
        \(pem)
        """

        // 2.5 s exceeds the legacy 2 s SO_RCVTIMEO; under the original
        // implementation `recv` returned EAGAIN and the loop's `n <= 0`
        // branch silently truncated the buffer to zero bytes.
        let port = try DelayedFakeLocalAPI.start(
            responseFrame: Data(response.utf8),
            delaySeconds: 2.5
        )
        let api = TailscaleLocalAPI(transport: .tcpLocalhost(port: port, authToken: "tok"))

        let pair = try await api.certPair(for: "fixture.example")
        let certOut = String(data: pair.cert, encoding: .utf8) ?? ""
        let keyOut = String(data: pair.key, encoding: .utf8) ?? ""
        #expect(certOut.contains("-----BEGIN CERTIFICATE-----"))
        #expect(certOut.contains("-----END CERTIFICATE-----"))
        #expect(keyOut.contains("-----BEGIN PRIVATE KEY-----"))
    }
}

/// One-shot 127.0.0.1 TCP responder. Accepts a single connection, reads
/// the request to `\r\n\r\n`, sleeps `delaySeconds`, writes the canned
/// frame, closes. Mirrors the slow ACME exchange tailscaled runs on
/// first-time cert mint (WEB-8.5).
private enum DelayedFakeLocalAPI {

    static func start(responseFrame: Data, delaySeconds: TimeInterval) throws -> Int {
        let listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw POSIXError(.EIO) }

        var enable: Int32 = 1
        _ = setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &enable,
                       socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { close(listenFD); throw POSIXError(.EIO) }

        var assigned = sockaddr_in()
        var assignedSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(listenFD, sockPtr, &assignedSize)
            }
        }
        guard nameResult == 0 else { close(listenFD); throw POSIXError(.EIO) }
        let port = Int(UInt16(bigEndian: assigned.sin_port))

        guard listen(listenFD, 1) == 0 else { close(listenFD); throw POSIXError(.EIO) }

        Thread.detachNewThread {
            defer { close(listenFD) }
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { close(clientFD) }

            var buf = [UInt8](repeating: 0, count: 4096)
            var collected = Data()
            while true {
                let n = buf.withUnsafeMutableBufferPointer { bp in
                    Darwin.recv(clientFD, bp.baseAddress, bp.count, 0)
                }
                if n <= 0 { break }
                collected.append(contentsOf: buf[0..<n])
                if collected.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil { break }
            }

            Thread.sleep(forTimeInterval: delaySeconds)

            responseFrame.withUnsafeBytes { ptr in
                _ = Darwin.send(clientFD, ptr.baseAddress, ptr.count, 0)
            }
        }

        return port
    }
}
