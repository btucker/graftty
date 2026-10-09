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
@testable import GrafttyHost

@Suite(.serialized) @MainActor
struct HostServiceTests {
    private struct Fixture {
        let root: URL
        let repository: URL
        var configuration: HostConfiguration

        init() throws {
            let path = "/tmp/gs-" + UUID().uuidString
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            root = URL(fileURLWithPath: CanonicalPath.canonicalize(path), isDirectory: true)
            repository = root.appendingPathComponent("repo", isDirectory: true)
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            git.arguments = ["git", "init", "--initial-branch=main", repository.path]
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try git.run(); git.waitUntilExit()
            guard git.terminationStatus == 0 else { throw HostRuntimeError.invalid("fixture Git initialization failed") }
            configuration = HostConfiguration(httpPort: 0, sshPort: 0,
                stateDirectory: root.appendingPathComponent("state"),
                runtimeDirectory: root.appendingPathComponent("run"),
                zmxExecutable: URL(fileURLWithPath: "/bin/true"))
            try configuration.prepareDirectories()
            try AppState(repos: [RepoEntry(path: repository.path, displayName: "fixture",
                worktrees: [WorktreeEntry(path: repository.path, branch: "main")])])
                .save(to: configuration.stateDirectory)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("@spec REMOTE-22.15: When the headless host service starts its direct SSH listener, the application shall immediately serve authenticated team roster requests through the configured runtime handler.", .timeLimit(.minutes(1)))
    func runtimeTeamHandlerIsActiveAtStartup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = try HostService(configuration: fixture.configuration, enablePairing: false)
        let clientKey = Curve25519.Signing.PrivateKey()
        try HostService.trust(LinuxHostTrustRequest(deviceID: "test-client", displayName: "Test Mac",
            publicKey: clientKey.publicKey.rawRepresentation.base64EncodedString()),
            publicKeyData: clientKey.publicKey.rawRepresentation, configuration: fixture.configuration)
        let identity = try HostService.identity(configuration: fixture.configuration)
        let hostKey = try RemoteIdentityPublicKey(rawRepresentation: #require(Data(base64Encoded: identity.publicKey)))
        let client = DirectSSHHostConnection(clientKey: clientKey, expectedHostFingerprint: RemoteIdentityFingerprint(of: hostKey))
        do {
            let port = try await service.start()
            guard case .status(let status) = try await HostAdministrationServer.request(.status, configuration: fixture.configuration) else {
                throw HostRuntimeError.invalid("missing live host status")
            }
            #expect(status.running)
            #expect(status.repositoryCount == 1)
            try await client.connect(host: "127.0.0.1", port: port)
            let team = try await client.makeTeamClient(handler: { $0 }, onClose: {})
            defer { team.close() }
            try await team.open()
            let bytes = try await team.send(JSONEncoder().encode(RemoteTeamRequest.list))
            let response = try JSONDecoder().decode(RemoteTeamResponse.self, from: bytes)
            guard case .members(let members) = response else { throw HostRuntimeError.invalid("unexpected team response: \(response)") }
            #expect(members.count == 1)
            #expect(members.first?.worktreePath == fixture.repository.path)
            #expect(members.first?.branch == "main")
        } catch {
            await client.close(); await service.stop()
            throw error
        }
        await client.close(); await service.stop()
    }

    @Test("@spec REMOTE-22.16: If the headless SSH listener cannot bind, then the application shall keep its readiness administration socket unavailable and clean up local control sockets.", .timeLimit(.minutes(1)))
    func failedListenerDoesNotPublishReadiness() async throws {
        let occupyingFixture = try Fixture()
        var failedFixture = try Fixture()
        defer { occupyingFixture.cleanup(); failedFixture.cleanup() }
        let occupying = try HostService(configuration: occupyingFixture.configuration, enablePairing: false)
        do {
            failedFixture.configuration.sshPort = try await occupying.start()
            let replacement = try HostService(configuration: failedFixture.configuration, enablePairing: false)
            let adminPath = HostAdministrationServer.socketPath(configuration: failedFixture.configuration)
            let observer = Task { @MainActor in
                while !Task.isCancelled {
                    if FileManager.default.fileExists(atPath: adminPath) { return true }
                    await Task.yield()
                }
                return false
            }
            await #expect(throws: (any Error).self) { try await replacement.start() }
            observer.cancel()
            #expect(await observer.value == false)
            #expect(!FileManager.default.fileExists(atPath: adminPath))
            #expect(!FileManager.default.fileExists(atPath: failedFixture.configuration.socketPath))
            await replacement.stop()
        } catch {
            await occupying.stop()
            throw error
        }
        await occupying.stop()
    }
}
