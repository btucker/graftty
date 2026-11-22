import Foundation
import Testing
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("""
@spec AGENT-6.175: When an Antigravity hook registers a session launched with a Graftty server credential, the application shall record the provider process's listening local port that accepts that credential for the session's conversation and shall store the credential in a file that only the user can read; if no listening port accepts the credential, then the application shall record no local agent server.
""")
struct AntigravityServerBinderTests {
    private let conversationID = "33baee6d-e7b9-450b-88d5-739d941230bf"

    @Test func recordsTheAcceptingPortAndStoresTheCredentialPrivately() throws {
        let directory = try temporaryDirectory()
        let probed = Probes()
        let binder = AntigravityServerBinder(
            tokenDirectory: directory,
            listeningPorts: { pid in pid == 4_242 ? [50_200, 50_201] : [] },
            servesConversation: { conversation, port, token in
                probed.append(port)
                return conversation == conversationID && port == 50_201 && token == "secret-token"
            },
            isAlive: { _ in true }
        )

        let transport = binder.bind(pid: 4_242, conversationID: conversationID, token: "secret-token")

        let tokenPath = directory.appendingPathComponent("4242.token").path
        #expect(transport == .antigravity(port: 50_201, conversationID: conversationID, tokenPath: tokenPath))
        #expect(probed.values == [50_200, 50_201])
        #expect(AntigravityServerBinder.readToken(atPath: tokenPath) == "secret-token")
        let permissions = try FileManager.default.attributesOfItem(atPath: tokenPath)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func recordsNoServerWhenNoPortAcceptsTheCredential() throws {
        let directory = try temporaryDirectory()
        let binder = AntigravityServerBinder(
            tokenDirectory: directory,
            listeningPorts: { _ in [50_200, 50_201] },
            servesConversation: { _, _, _ in false },
            isAlive: { _ in true }
        )

        #expect(binder.bind(pid: 4_242, conversationID: conversationID, token: "secret-token") == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("4242.token").path))
    }

    @Test func recordsNoServerWithoutALaunchCredential() throws {
        let binder = AntigravityServerBinder(
            tokenDirectory: try temporaryDirectory(),
            listeningPorts: { _ in [50_201] },
            servesConversation: { _, _, _ in true },
            isAlive: { _ in true }
        )

        #expect(binder.bind(pid: 4_242, conversationID: conversationID, token: nil) == nil)
        #expect(binder.bind(pid: 4_242, conversationID: conversationID, token: "") == nil)
    }

    @Test func removesCredentialsOfExitedProviders() throws {
        let directory = try temporaryDirectory()
        let stale = directory.appendingPathComponent("999.token")
        try Data("old".utf8).write(to: stale)
        let binder = AntigravityServerBinder(
            tokenDirectory: directory,
            listeningPorts: { _ in [50_201] },
            servesConversation: { _, _, _ in true },
            isAlive: { $0 == 4_242 }
        )

        _ = binder.bind(pid: 4_242, conversationID: conversationID, token: "secret-token")

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("4242.token").path))
    }

    @Test func listsTheListeningTCPPortsOfAProcess() throws {
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValueOrSelf), 0)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(descriptor, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        try #require(named == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))

        #expect(ProcessListeningPortReader.listeningTCPPorts(ofPID: getpid()).contains(port))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-antigravity-binder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private var ports: [Int] = []
        func append(_ port: Int) { lock.withLock { ports.append(port) } }
        var values: [Int] { lock.withLock { ports } }
    }
}

private extension Int32 {
    /// `SOCK_STREAM` is an `Int32` on Darwin and an enum on Glibc.
    var rawValueOrSelf: Int32 { self }
}

#if canImport(Glibc)
private extension __socket_type {
    var rawValueOrSelf: Int32 { Int32(rawValue) }
}
#endif
