#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient
import GrafttyTailcat
import Testing
@testable import GrafttyRunner

@Suite(.serialized) @MainActor
struct RunnerTailcatServeTests {
    private struct Fixture {
        let root: URL
        let configuration: HostConfiguration
        let clientKey = Curve25519.Signing.PrivateKey()
        let hostFingerprint: RemoteIdentityFingerprint

        init() throws {
            root = URL(fileURLWithPath: "/tmp/gt-" + UUID().uuidString, isDirectory: true)
            configuration = HostConfiguration(httpPort: 0, sshPort: 0,
                stateDirectory: root.appendingPathComponent("state"),
                runtimeDirectory: root.appendingPathComponent("run"),
                zmxExecutable: URL(fileURLWithPath: "/bin/true"))
            try configuration.prepareDirectories()
            try HostService.trust(LinuxHostTrustRequest(deviceID: "test-client", displayName: "Test Mac",
                publicKey: clientKey.publicKey.rawRepresentation.base64EncodedString()),
                publicKeyData: clientKey.publicKey.rawRepresentation, configuration: configuration)
            let identity = try HostService.identity(configuration: configuration)
            hostFingerprint = RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(
                rawRepresentation: #require(Data(base64Encoded: identity.publicKey))))
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// The endpoint the running service reports once Tailcat is listening.
        func endpoint() async throws -> TailcatEndpoint {
            for _ in 0..<300 {
                if case .tailcatEndpoint(let endpoint?) = try await HostAdministrationServer.request(.tailcatEndpoint, configuration: configuration) {
                    return endpoint
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw HostRuntimeError.invalid("the runner never reported a Tailcat endpoint")
        }
    }

    @Test("@spec REMOTE-33.4: While the runner is serving, the application shall accept paired SSH sessions over Tailcat.",
          .timeLimit(.minutes(2)))
    func acceptsPairedSessionsOverTailcat() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = try HostService(configuration: fixture.configuration, enablePairing: false)
        let client = DirectSSHHostConnection(clientKey: fixture.clientKey, expectedHostFingerprint: fixture.hostFingerprint)
        var peer: TailcatPeer?
        var pipe: TailcatPipe?
        do {
            _ = try await service.start()
            let endpoint = try await fixture.endpoint()
            guard case .status(let status) = try await HostAdministrationServer.request(.status, configuration: fixture.configuration) else {
                throw HostRuntimeError.invalid("missing live host status")
            }
            #expect(status.tailcat == true)
            peer = try TailcatPeer.client(address: endpoint.address)
            pipe = try await peer!.dial(port: endpoint.port)
            try await client.connect(input: pipe!.file, output: pipe!.file)
            try pipe!.file.close()
            let team = try await client.makeTeamClient(handler: { $0 }, onClose: {})
            defer { team.close() }
            try await team.open()
            let bytes = try await team.send(JSONEncoder().encode(RemoteTeamRequest.list))
            guard case .members = try JSONDecoder().decode(RemoteTeamResponse.self, from: bytes) else {
                throw HostRuntimeError.invalid("unexpected team response")
            }
        } catch {
            await client.close(); await pipe?.close(); await peer?.close(); await service.stop()
            throw error
        }
        await client.close(); await pipe?.close(); await peer?.close(); await service.stop()
    }

    @Test("@spec REMOTE-33.5: When a worktree-management client asks a runner for its Tailcat endpoint, the application shall return the endpoint it is listening on.",
          .timeLimit(.minutes(2)))
    func reportsEndpointToClients() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = try HostService(configuration: fixture.configuration, enablePairing: false)
        let client = DirectSSHHostConnection(clientKey: fixture.clientKey, expectedHostFingerprint: fixture.hostFingerprint)
        do {
            let port = try await service.start()
            let endpoint = try await fixture.endpoint()
            try await client.connect(host: "127.0.0.1", port: port)
            #expect(try await client.sendWorktreeManagement(.tailcatEndpoint) == .tailcatEndpoint(endpoint))
        } catch {
            await client.close(); await service.stop()
            throw error
        }
        await client.close(); await service.stop()
    }
}
