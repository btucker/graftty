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

    @Test("@spec REMOTE-21.20: When Linux auto-setup prepares a host, the application shall ensure Claude Code and Codex are available before pairing, and stop with a provider-specific error if installation fails.")
    func agentsBeforePairing() async throws {
        for failedProvider in ["", "claude", "codex"] {
            let ssh = RecordingSetupSSH(agentFailure: failedProvider)
            let plan = LinuxHostSetupPlan(destination: try .init("host"), destinationRoot: "/srv/projects", projects: [], archive: .release(version: "1.2.3"), client: .init(deviceID: "mac", displayName: "Mac", publicKey: Data(repeating: 1, count: 32).base64EncodedString()))
            do {
                _ = try await LinuxHostSetup(executor: SetupConfigExecutor(), ssh: ssh).run(plan: plan)
                #expect(failedProvider.isEmpty)
            } catch let error as LinuxHostSetupError {
                #expect(!failedProvider.isEmpty)
                #expect(error.localizedDescription.contains(failedProvider == "claude" ? "Claude Code" : "Codex"))
                #expect(error.localizedDescription.contains("exit status 43"))
            }
            let commands = await ssh.calls.compactMap { $0.arguments.last }
            let host = try #require(commands.firstIndex { $0.contains("unpacked/install.sh") })
            let claude = try #require(commands.firstIndex { $0.contains("https://claude.ai/install.sh") })
            #expect(host < claude)
            if failedProvider != "claude" {
                let codex = try #require(commands.firstIndex { $0.contains("https://chatgpt.com/codex/install.sh") })
                #expect(claude < codex)
                if failedProvider.isEmpty {
                    let trust = try #require(commands.firstIndex { $0.contains("trust-client") })
                    #expect(codex < trust)
                }
            }
            if !failedProvider.isEmpty { #expect(!commands.contains { $0.contains("trust-client") }) }
        }
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

    @Test(arguments: ["22.04", "26.04"])
    func permitsOtherUbuntuVersions(ubuntuVersion: String) async throws {
        let ssh = RecordingSetupSSH(ubuntuVersion: ubuntuVersion)
        let plan = LinuxHostSetupPlan(destination: try .init("host"), destinationRoot: "/srv/projects", projects: [], archive: .release(version: "1.2.3"), client: .init(deviceID: "mac", displayName: "Mac", publicKey: Data(repeating: 1, count: 32).base64EncodedString()))
        _ = try await LinuxHostSetup(executor: SetupConfigExecutor(), ssh: ssh).run(plan: plan)
        #expect(await ssh.calls.contains { $0.arguments.last?.contains("unpacked/install.sh") == true })
    }

    @Test("@spec REMOTE-21.12: When a remote setup command fails, the application shall identify the operation and exit status, preserve available output, and explicitly report when no output was returned.", arguments: ["", "Installer stopped before starting the service"])
    func remoteFailureDetails(stdout: String) async throws {
        let ssh = RecordingSetupSSH(installFailure: .init(stdout: stdout, stderr: "", exitCode: 42))
        let plan = LinuxHostSetupPlan(destination: try .init("host"), destinationRoot: "/srv/projects", projects: [], archive: .release(version: "1.2.3"), client: .init(deviceID: "mac", displayName: "Mac", publicKey: Data(repeating: 1, count: 32).base64EncodedString()))
        do {
            _ = try await LinuxHostSetup(executor: SetupConfigExecutor(), ssh: ssh).run(plan: plan)
            Issue.record("Installation must fail")
        } catch let error as LinuxHostSetupError {
            let message = error.localizedDescription
            #expect(message.contains("Installing Linux host and user service"))
            #expect(message.contains("exit status 42"))
            #expect(message.contains(stdout.isEmpty ? "No output was returned" : stdout))
        }
        #expect(await ssh.calls.allSatisfy { $0.arguments.last?.contains("trust-client") != true })
    }

    @Test("@spec REMOTE-21.14: When Linux setup probes an archive, the application shall stage it privately on the configured installation data filesystem and remove only that staging directory after completion.")
    func stagingUsesInstallationFilesystem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataHome = root.appendingPathComponent("custom data 'home")
        let ssh = RecordingSetupSSH(dataDirectory: dataHome.path, executeStaging: true)
        let plan = LinuxHostSetupPlan(destination: try .init("host"), destinationRoot: "/srv/projects", projects: [], archive: .release(version: "1.2.3"), client: .init(deviceID: "mac", displayName: "Mac", publicKey: Data(repeating: 1, count: 32).base64EncodedString()))
        _ = try await LinuxHostSetup(executor: SetupConfigExecutor(), ssh: ssh).run(plan: plan)
        let path = try #require(await ssh.stagingPath)
        #expect(path.hasPrefix(dataHome.path + "/graftty/releases/.setup-"))
        #expect(await ssh.stagingPermissions == 0o700)
        // Cleanup is detached from cancellation, so wait for its observable result.
        for _ in 0..<100 where FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: dataHome.path))
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
    private let ubuntuVersion: String
    private let installFailure: CLIOutput?
    private let agentFailure: String
    private let dataDirectory: String
    private let executeStaging: Bool
    private(set) var stagingPath: String?
    private(set) var stagingPermissions: Int?
    init(ubuntuVersion: String = "24.04", agentFailure: String = "", installFailure: CLIOutput? = nil, dataDirectory: String = "/home/developer/.local/share", executeStaging: Bool = false) {
        self.ubuntuVersion = ubuntuVersion
        self.agentFailure = agentFailure
        self.installFailure = installFailure
        self.dataDirectory = dataDirectory
        self.executeStaging = executeStaging
    }
    func capture(arguments: [String], inputFile: URL?) async throws -> CLIOutput {
        calls.append(.init(arguments: arguments, input: try inputFile.map { try Data(contentsOf: $0) }))
        let command = arguments.last ?? ""
        if command.contains("/etc/os-release") { return .init(stdout: "ubuntu\n\(ubuntuVersion)\naarch64\n/home/developer\n\(dataDirectory)\n", stderr: "", exitCode: 0) }
        if command.contains("umask 077; mkdir -p --") {
            if executeStaging {
                let result = try await CLIRunner().run(command: "/bin/sh", args: ["-c", command], at: NSHomeDirectory())
                let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                stagingPath = path
                stagingPermissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
                return result
            }
            return .init(stdout: dataDirectory + "/graftty/releases/.setup-test1234\n", stderr: "", exitCode: 0)
        }
        if executeStaging, command.hasPrefix("/bin/sh -c 'rm -rf --") {
            return try await CLIRunner().run(command: "/bin/sh", args: ["-c", command], at: NSHomeDirectory())
        }
        if command.contains("unpacked/install.sh"), let installFailure { return installFailure }
        if !agentFailure.isEmpty, command.contains(agentFailure == "claude" ? "https://claude.ai/install.sh" : "https://chatgpt.com/codex/install.sh") {
            return .init(stdout: "", stderr: "Installer failed", exitCode: 43)
        }
        if command.contains("trust-client") {
            let identity = LinuxHostIdentity(deviceID: "linux", displayName: "Ubuntu", publicKey: Data(repeating: 2, count: 32).base64EncodedString(), port: 8801)
            return .init(stdout: String(decoding: try JSONEncoder().encode(identity), as: UTF8.self), stderr: "", exitCode: 0)
        }
        return .init(stdout: "", stderr: "", exitCode: 0)
    }
}

struct LinuxHostCompatibilityTests {
    @Test("@spec REMOTE-21.13: When Linux setup stages an archive, the application shall verify its host, CLI, and terminal binaries can execute before invoking the installer, and report incompatible binaries without changing the installed service.", arguments: ["none", "graftty-host", "graftty", "zmx"])
    func checksBinariesBeforeInstallation(failingBinary: String) async throws {
        let result = try await runInstallFixture(failingBinary: failingBinary)
        let output = result.output
        if failingBinary == "none" {
            #expect(output.exitCode == 0)
            #expect(result.installed)
        } else {
            #expect(output.exitCode != 0)
            #expect(output.stderr.contains("GRAFTTY_INCOMPATIBLE:" + failingBinary))
            #expect(output.stderr.contains("47"))
            #expect(!result.installed)
            #expect(result.lingerCalls.isEmpty)
        }
    }

    @Test("@spec REMOTE-21.15: When Linux setup installs a user service, the application shall enable and verify lingering for the authenticated user without interactive authorization, or stop before installation with an actionable administrator command.", arguments: ["enabled", "enables", "denied", "no-effect"])
    func ensuresLingeringBeforeInstallation(mode: String) async throws {
        let result = try await runInstallFixture(lingerMode: mode)
        #expect(result.output.stdout.isEmpty)
        #expect(result.lingerCalls.contains("show-user --property=Linger --value -- fixture-user"))
        if mode == "enabled" || mode == "enables" {
            #expect(result.output.exitCode == 0)
            #expect(result.installed)
        } else {
            #expect(result.output.exitCode != 0)
            #expect(!result.installed)
            #expect(result.output.stderr.contains("GRAFTTY_LINGER_REQUIRED:"))
            let message = LinuxHostSetupError.remoteFailure(result.output.stderr).localizedDescription
            #expect(message.contains("sudo loginctl enable-linger fixture-user"))
        }
        #expect(result.lingerCalls.contains("--no-ask-password enable-linger -- fixture-user") == (mode != "enabled"))
    }

    private func runInstallFixture(failingBinary: String = "none", lingerMode: String = "enabled") async throws -> (output: CLIOutput, installed: Bool, lingerCalls: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let staging = root.appendingPathComponent("staging")
        let tools = root.appendingPathComponent("tools")
        for directory in [source.appendingPathComponent("bin"), staging, tools] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func executable(_ path: URL, _ body: String) throws {
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        }
        // Only the finite fixture commands run here; timeout's deadline behavior
        // is provided by coreutils on the destination.
        try executable(tools.appendingPathComponent("timeout"), "shift 2; exec \"$@\"")
        try executable(tools.appendingPathComponent("id"), "test \"$*\" = -un || exit 99; echo fixture-user")
        let calls = LinuxHostScripts.quote(root.appendingPathComponent("linger-calls").path)
        let state = LinuxHostScripts.quote(root.appendingPathComponent("linger-state").path)
        try executable(tools.appendingPathComponent("loginctl"), """
        printf '%s\\n' "$*" >> \(calls)
        case "$*" in
          'show-user --property=Linger --value -- fixture-user')
            if test \(LinuxHostScripts.quote(lingerMode)) = enabled || test -f \(state); then echo yes; else echo no; fi ;;
          '--no-ask-password enable-linger -- fixture-user')
            echo 'authorization output must not escape'
            case \(LinuxHostScripts.quote(lingerMode)) in
              denied) echo 'Access denied' >&2; exit 1 ;;
              enables) touch \(state) ;;
            esac ;;
          *) exit 99 ;;
        esac
        """)
        for name in ["graftty-host", "graftty", "zmx"] {
            try executable(source.appendingPathComponent("bin/" + name), name == failingBinary ? "exit 47" : "exit 0")
        }
        let marker = root.appendingPathComponent("installed")
        try executable(source.appendingPathComponent("install.sh"), "touch " + LinuxHostScripts.quote(marker.path))
        _ = try await CLIRunner().run(command: "/usr/bin/tar", args: ["-czf", staging.appendingPathComponent("archive.tar.gz").path, "-C", source.path, "."], at: root.path)
        let script = "PATH=" + LinuxHostScripts.quote(tools.path) + ":\"$PATH\"\n" + LinuxHostScripts.install(staging: staging.path, archiveURL: nil)
        let output = try await CLIRunner().capture(command: "/bin/sh", args: ["-c", script], at: root.path)
        return (output, FileManager.default.fileExists(atPath: marker.path),
                (try? String(contentsOf: root.appendingPathComponent("linger-calls"), encoding: .utf8)) ?? "")
    }
}
