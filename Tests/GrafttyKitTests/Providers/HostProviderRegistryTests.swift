import Foundation
import Testing
@testable import GrafttyKit

@Suite("@spec REMOTE-24.20: When connecting through a registered compute provider, the application shall select the adapter by provider identifier, preserve the enrollment operation and pinned host identity, and recheck adapter authorization without requiring AWS-specific identifiers in shared connection code.")
struct HostProviderRegistryTests {
    private let parent = LinuxHostTrustRequest(deviceID: "parent", displayName: "Mac",
        publicKey: Data(repeating: 1, count: 32).base64EncodedString(), serverPublicKey: Data(repeating: 2, count: 32).base64EncodedString())

    @Test func secondProviderUsesOpaqueTargetAndSharedTransport() async throws {
        let provider = FixtureProvider(identifier: "test-cloud")
        let registry = try HostProviderRegistry(providers: [provider])
        let binding = HostProviderBinding(provider: "test-cloud", operationID: UUID())
        let connection = try await registry.prepareConnection(binding: binding, parent: parent)
        #expect(connection.binding == binding)
        #expect(connection.target == "sandbox/worker-A")
        #expect(connection.transport == .directSSH(host: "localhost", port: 8801))
        try registry.authorize(connection, parent: parent)
    }

    @Test func rejectsDuplicateUnknownAndMismatchedProviders() async throws {
        #expect(throws: (any Error).self) {
            _ = try HostProviderRegistry(providers: [FixtureProvider(identifier: "test-cloud"), FixtureProvider(identifier: "test-cloud")])
        }
        let registry = try HostProviderRegistry(providers: [FixtureProvider(identifier: "test-cloud", wrongBinding: true)])
        await #expect(throws: (any Error).self) {
            _ = try await registry.prepareConnection(binding: .init(provider: "unknown", operationID: UUID()), parent: parent)
        }
        await #expect(throws: (any Error).self) {
            _ = try await registry.prepareConnection(binding: .init(provider: "test-cloud", operationID: UUID()), parent: parent)
        }
    }

    @Test func adapterRevocationIsNotBypassedByPreparedConnection() async throws {
        let registry = try HostProviderRegistry(providers: [FixtureProvider(identifier: "test-cloud", revoked: true)])
        await #expect(throws: (any Error).self) {
            _ = try await registry.prepareConnection(binding: .init(provider: "test-cloud", operationID: UUID()), parent: parent)
        }
    }
}

private struct FixtureProvider: HostProvider {
    let identifier: String
    var wrongBinding = false
    var revoked = false
    func prepareConnection(operationID: UUID, parent: LinuxHostTrustRequest) async throws -> HostProviderConnection {
        .init(binding: .init(provider: wrongBinding ? "aws" : identifier, operationID: operationID),
              target: "sandbox/worker-A", identity: .init(deviceID: "sandbox-worker", displayName: "Worker",
              publicKey: Data(repeating: 3, count: 32).base64EncodedString(), port: 8801),
              transport: .directSSH(host: "localhost", port: 8801))
    }
    func authorize(_ connection: HostProviderConnection, parent: LinuxHostTrustRequest) throws {
        if revoked { throw ProviderError("revoked") }
    }
}
