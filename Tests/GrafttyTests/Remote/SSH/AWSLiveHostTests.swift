#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import Testing

/// Explicit opt-in: the JSON file selects an already provisioned test instance.
/// Creates public-key enrollment on that host, but never provisions resources or
/// copies a private key. Use only with disposable test hosts.
struct AWSLiveHostTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_LIVE_AWS_TARGET"] != nil), .timeLimit(.minutes(5)))
    func enrollsAndReadsPinnedHostThroughSSM() async throws {
        let file = try #require(ProcessInfo.processInfo.environment["GRAFTTY_LIVE_AWS_TARGET"])
        let target = try JSONDecoder().decode(AWSHostEnrollmentTarget.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-aws-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clientKey = Curve25519.Signing.PrivateKey()
        let serverKey = Curve25519.Signing.PrivateKey()
        let parent = LinuxHostTrustRequest(deviceID: UUID().uuidString, displayName: "Graftty live test",
            publicKey: clientKey.publicKey.rawRepresentation.base64EncodedString(),
            serverPublicKey: serverKey.publicKey.rawRepresentation.base64EncodedString())
        let peers = TrustedPeerStore(directory: root.appendingPathComponent("peers"))
        let enrollment = AWSHostEnrollment(directory: root.appendingPathComponent("enrollment"), peers: peers)
        let operation = UUID()
        let identity = try await enrollment.enroll(operationID: operation, target: target, parent: parent)
        let registry = try HostProviderRegistry(providers: [AWSHostProvider(enrollment: enrollment)])
        let plan = try await registry.prepareConnection(binding: .init(provider: "aws", operationID: operation), parent: parent)
        #expect(plan.identity == identity)
        let fingerprint = RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: try #require(Data(base64Encoded: identity.publicKey))))
        let connection = DirectSSHHostConnection(clientKey: clientKey, expectedHostFingerprint: fingerprint)
        guard case .proxy(let command, let arguments) = plan.transport else { throw ProviderError("Expected SSM transport") }
        let proxy = try DuplexSubprocess(command: command, arguments: arguments)
        do {
            try await connection.connect(input: proxy.output, output: proxy.input)
            try registry.authorize(plan, parent: parent)
            let observation = try #require(try await connection.resourceObservation())
            #expect(observation.isFresh())
            #expect(observation.sample.cpuCount.map { $0 > 0 } == true)
            #expect(observation.sample.memoryAvailableBytes.map { $0 > 0 } == true)
            try peers.remove(id: .init(value: identity.deviceID))
            #expect(throws: (any Error).self) { try registry.authorize(plan, parent: parent) }
            await connection.close()
            await proxy.stop()
        } catch {
            await connection.close()
            await proxy.stop()
            throw error
        }
    }
}
