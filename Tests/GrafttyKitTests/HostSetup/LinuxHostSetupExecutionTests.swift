import Foundation
import Testing
@testable import GrafttyKit

struct LinuxHostSetupExecutionTests {
    @Test("@spec REMOTE-21.8: When Linux setup installs a release, the application shall use an explicit version and architecture archive, verify its SHA-256 checksum, install a user service, and exchange only public identity over authenticated OpenSSH.")
    func releaseAndPublicTrust() async throws {
        let ssh = RecordingSetupSSH()
        let setup = LinuxHostSetup(executor: SetupConfigExecutor(), ssh: ssh)
        let client = LinuxHostTrustRequest(deviceID: "mac-id", displayName: "My Mac", publicKey: Data(repeating: 3, count: 32).base64EncodedString())
        let plan = LinuxHostSetupPlan(destination: try .init("config-alias"), destinationRoot: "~/projects", projects: [], archive: .release(version: "1.2.3-beta.1"), client: client)
        let result = try await setup.run(plan: plan)
        #expect(result.openSSH.hostname == "192.0.2.44")
        #expect(result.openSSH.port == 2222)
        #expect(result.identity.port == 8801)
        let calls = await ssh.calls
        let install = try #require(calls.first { $0.arguments.last?.contains("install.sh") == true })
        #expect(install.arguments.last?.contains("graftty-linux-1.2.3-beta.1-aarch64.tar.gz") == true)
        #expect(install.arguments.last?.contains("sha256sum --check") == true)
        #expect(install.arguments.last?.contains("--bind-address 0.0.0.0 --ssh-port 8801") == true)
        let trust = try #require(calls.first { $0.arguments.last?.contains("trust-client") == true })
        let trustData = try #require(trust.input)
        #expect(try JSONDecoder().decode(LinuxHostTrustRequest.self, from: trustData) == client)
        #expect(trust.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(trust.arguments.contains("BatchMode=yes"))
        #expect(trust.arguments.contains("config-alias"))
        let keys = try #require(JSONSerialization.jsonObject(with: trustData) as? [String: Any])
        #expect(Set(keys.keys) == Set(["deviceID", "displayName", "publicKey"]))
    }

    @Test("@spec REMOTE-21.9: When a development archive is selected, the application shall transfer that archive over authenticated OpenSSH without fetching a release or transferring private credentials.")
    func localArchive() async throws {
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-dev-\(UUID().uuidString).tar.gz")
        let bytes = Data("developer tar bytes".utf8)
        try bytes.write(to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        let ssh = RecordingSetupSSH()
        let setup = LinuxHostSetup(executor: SetupConfigExecutor(), ssh: ssh)
        let plan = LinuxHostSetupPlan(destination: try .init("host"), destinationRoot: "/srv/projects", projects: [], archive: .local(archive), client: .init(deviceID: "mac", displayName: "Mac", publicKey: Data(repeating: 1, count: 32).base64EncodedString()))
        _ = try await setup.run(plan: plan)
        let calls = await ssh.calls
        let upload = try #require(calls.first { $0.arguments.last?.contains("cat >") == true })
        #expect(upload.input == bytes)
        let install = try #require(calls.first { $0.arguments.last?.contains("install.sh") == true })
        #expect(install.arguments.last?.contains("curl") == false)
    }

    @Test("@spec REMOTE-21.10: When Linux setup is cancelled during an OpenSSH command, the application shall terminate the bootstrap process and stop subsequent setup commands before allowing a retry.")
    func processCancellation() async throws {
        let runner = LinuxHostSSHRunner(executable: "/bin/sleep", timeout: 20)
        let task = Task { try await runner.capture(arguments: ["30"], inputFile: nil) }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test func processTimeout() async throws {
        let runner = LinuxHostSSHRunner(executable: "/bin/sleep", timeout: 0.1)
        await #expect(throws: CLIError.self) { try await runner.capture(arguments: ["10"], inputFile: nil) }
    }

    @Test func invalidIdentityStopsBeforeBootstrap() async throws {
        let ssh = RecordingSetupSSH()
        let plan = LinuxHostSetupPlan(destination: try .init("host"), destinationRoot: "/tmp/projects", projects: [], archive: .release(version: "latest"), client: .init(deviceID: "mac", displayName: "Mac", publicKey: "private-key-is-not-allowed"))
        await #expect(throws: LinuxHostIdentityError.self) { try await LinuxHostSetup(executor: SetupConfigExecutor(), ssh: ssh).run(plan: plan) }
        #expect(await ssh.calls.isEmpty)
    }
}

private struct SetupConfigExecutor: CLIExecutor {
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        #expect(command == "/usr/bin/ssh")
        #expect(args.first == "-G")
        return .init(stdout: "hostname 192.0.2.44\nuser developer\nport 2222\n", stderr: "", exitCode: 0)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
}

private actor RecordingSetupSSH: LinuxHostSSHExecuting {
    struct Call: Sendable { let arguments: [String]; let input: Data? }
    private(set) var calls: [Call] = []
    func capture(arguments: [String], inputFile: URL?) async throws -> CLIOutput {
        calls.append(.init(arguments: arguments, input: try inputFile.map { try Data(contentsOf: $0) }))
        let command = arguments.last ?? ""
        if command.contains("/etc/os-release") { return .init(stdout: "ubuntu\naarch64\n/home/developer\n", stderr: "", exitCode: 0) }
        if command.contains("mktemp -d /tmp/graftty-setup") { return .init(stdout: "/tmp/graftty-setup.test123\n", stderr: "", exitCode: 0) }
        if command.contains("trust-client") {
            let identity = LinuxHostIdentity(deviceID: "linux", displayName: "Ubuntu", publicKey: Data(repeating: 2, count: 32).base64EncodedString(), port: 8801)
            return .init(stdout: String(decoding: try JSONEncoder().encode(identity), as: UTF8.self), stderr: "", exitCode: 0)
        }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }
}
