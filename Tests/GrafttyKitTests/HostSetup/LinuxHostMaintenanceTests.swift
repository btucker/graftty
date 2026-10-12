import Foundation
import Testing
import GrafttyProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import GrafttyKit

struct LinuxHostMaintenanceTests {
    @Test("@spec REMOTE-22.35: When maintenance updates a valid service with whitespace around its executable assignment, the application shall replace exactly one host executable path before restarting and preserve unrelated settings.")
    func whitespaceServiceExecutableIsReplaced() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path,
                             "InstallerTests.test_maintenance_rewrites_execstart_assignment_whitespace",
                             "InstallerTests.test_maintenance_rejects_missing_effective_executable_before_mutation"]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    @Test("@spec REMOTE-22.20: When host maintenance selects a Graftty release, the application shall choose the newest published release with both the host architecture archive and checksum, independently of the Mac bundle version.")
    func publishedAssets() throws {
        let releases = [release("1.0.0", date: "2026-01-01T00:00:00Z"), release("1.1.0", date: "2026-02-01T00:00:00Z", checksum: false), release("1.2.0", date: "2026-03-01T00:00:00Z", draft: true)]
        #expect(try LinuxHostRelease.select(from: releases, architecture: "aarch64")?.version == "1.0.0")
        #expect(try LinuxHostRelease.select(from: releases, architecture: "x86_64") == nil)
    }

    @Test("@spec REMOTE-22.21: When an older saved remote host lacks maintenance metadata, the application shall preserve its pairing and leave the system SSH destination unset rather than reuse the Graftty listener.")
    func metadataMigration() throws {
        let key = try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 1, count: 32))
        let host = RemoteMac(id: .init(value: "linux"), label: "Host", fingerprint: .init(of: key), transport: .directSSH, directEndpoint: try .init(host: "host", port: 8801))
        let decoded = try JSONDecoder().decode(RemoteMac.self, from: JSONEncoder().encode(host))
        #expect(decoded.maintenanceDestination == nil)
        #expect(decoded.directEndpoint?.port == 8801)
        #expect(decoded.fingerprint == host.fingerprint)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LinuxHostDestination.self, from: Data("\"-oProxyCommand=bad\"".utf8)) }
    }

    @MainActor
    @Test("@spec REMOTE-22.28: When rediscovery or repeat pairing saves an existing host without maintenance metadata, the application shall preserve its validated system SSH destination; an explicit update shall allow clearing it.")
    func preserveDestinationOnRediscovery() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-store-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = RemoteMacStore(storeURL: url)
        let key = try RemoteIdentityPublicKey(rawRepresentation: Data(repeating: 1, count: 32))
        var remote = RemoteMac(id: .init(value: "host"), label: "Host", fingerprint: .init(of: key), maintenanceDestination: try .init("user@alias"))
        try store.add(remote)
        remote.maintenanceDestination = nil
        try store.add(remote)
        #expect(store.remoteMacs.first?.maintenanceDestination?.value == "user@alias")
        try store.update(remote)
        #expect(store.remoteMacs.first?.maintenanceDestination == nil)
    }

    @Test("@spec REMOTE-22.22: If maintenance discovers a different Graftty identity at the system SSH destination, then the application shall reject it before changing tools, service, pairing, or repositories.")
    func wrongHostRejected() async throws {
        let ssh = MaintenanceSSH(wrongIdentity: true)
        await #expect(throws: LinuxHostSetupError.self) { try await service(ssh).inspect(destination: .init("alias"), expected: expected) }
        #expect(await ssh.commands.count == 1)
        #expect(await ssh.commands.allSatisfy { !$0.contains("install.sh") && !$0.contains("trust-client") })
    }

    @Test("@spec REMOTE-22.23: When a selected maintenance component fails, the application shall retain other component outcomes and report partial failure without claiming every component succeeded.")
    func componentFailure() async throws {
        let ssh = MaintenanceSSH(failCodex: true)
        let maintenance = service(ssh)
        let inspection = try await maintenance.inspect(destination: .init("alias"), expected: expected)
        let results = await maintenance.run(inspection: inspection, components: [.codex, .claude])
        #expect(results.count == 2)
        #expect(results[0].status == .failed)
        #expect(results[1].status == .succeeded)
        #expect(await ssh.commands.allSatisfy { !$0.contains("trust-client") && !$0.contains("project add") })
    }

    @Test("@spec REMOTE-22.24: When maintenance is cancelled, the application shall stop subsequent components and describe an interrupted component's remote outcome as unknown.")
    func cancellation() async throws {
        let ssh = MaintenanceSSH(cancelCodex: true)
        let maintenance = service(ssh)
        let inspection = try await maintenance.inspect(destination: .init("alias"), expected: expected)
        let results = await maintenance.run(inspection: inspection, components: [.codex, .claude])
        #expect(results.map(\.status) == [.unknown, .skipped])
        #expect(await ssh.commands.count == 2)
    }

    @Test("@spec REMOTE-22.25: When selected agent tools are installed on Linux, the application shall use bounded official native installers, verify their executable versions in the user's local bin directory, and keep authentication separate.")
    func officialTools() {
        let codex = LinuxHostToolScripts.install(.codex)
        let claude = LinuxHostToolScripts.install(.claude)
        #expect(codex.contains("https://chatgpt.com/codex/install.sh"))
        #expect(claude.contains("https://claude.ai/install.sh"))
        for script in [codex, claude] {
            #expect(script.contains("timeout --kill-after=5 300"))
            #expect(script.contains("$HOME/.local/bin"))
            #expect(script.contains("--version"))
            #expect(!script.contains("login"))
        }
    }

    @Test("@spec REMOTE-22.27: When Linux host maintenance restarts Graftty, the installer shall preserve the existing service options and require effective KillMode=process without rerunning setup or importing projects.")
    func installerPreservesConfiguration() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/linux/test-packaging.py").path,
                             "InstallerTests.test_maintenance_preserves_service_configuration_and_skips_setup",
                             "InstallerTests.test_maintenance_rejects_effective_killmode_override"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("@spec REMOTE-22.29: When maintenance verifies an existing Linux identity, the application shall compare its exact public key and device ID without transferring private identity data or interpreting identity text as executable code.")
    func executableIdentityGuard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("user")
        let state = home.appendingPathComponent(".local/share/graftty")
        let identity = state.appendingPathComponent("Remote")
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let keys = (0...255).compactMap { byte -> Curve25519.Signing.PrivateKey? in
            let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: UInt8(byte), count: 32))
            return key?.publicKey.rawRepresentation.base64EncodedString().contains("/") == true ? key : nil
        }
        let key = try #require(keys.first)
        let deviceID = "host/quoted'\"\nGRAFTTY_VERIFY_IDENTITY_D782\n$(touch SHOULD_NOT_EXIST)"
        let seed = key.rawRepresentation.base64EncodedString()
        try JSONSerialization.data(withJSONObject: ["version": 2, "privateKeyData": seed]).write(to: identity.appendingPathComponent("host-identity.json"))
        try JSONSerialization.data(withJSONObject: ["version": 1, "deviceID": ["value": deviceID]]).write(to: identity.appendingPathComponent("host-device-id.json"))
        let status = String(decoding: try JSONSerialization.data(withJSONObject: ["running": true, "sshPort": 9001, "stateDirectory": state.path]), as: UTF8.self)
        let host = bin.appendingPathComponent("graftty-host")
        try ("#!/bin/sh\nprintf '%s' " + LinuxHostScripts.quote(status)).write(to: host, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
        try "1.0.0".write(to: home.appendingPathComponent(".local/VERSION"), atomically: true, encoding: .utf8)
        let expected = LinuxHostIdentity(deviceID: deviceID, displayName: "Host", publicKey: key.publicKey.rawRepresentation.base64EncodedString(), port: 9001)
        let script = root.appendingPathComponent("check.sh")
        // The fixture executes the same Python, OpenSSL, JSON and shell path on
        // macOS; only the remote operating-system check is substituted.
        try LinuxHostMaintenanceScripts.guardIdentity(expected)
            .replacingOccurrences(of: "if platform.system() != 'Linux':", with: "if False:")
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path, "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path]) { _, new in new }
        process.currentDirectoryURL = root
        let stdout = Pipe(); process.standardOutput = stdout
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(output.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        #expect(try String(contentsOf: identity.appendingPathComponent("host-identity.json")).contains(seed))
    }

    @Test("@spec REMOTE-22.30: If the installed Graftty build is newer than the available release or cannot be compared with it, then the application shall require explicit replacement selection before installing that release.")
    func replacementConfirmation() {
        let release = LinuxHostRelease(version: "1.0.0", architecture: "aarch64")
        #expect(!release.requiresReplacementConfirmation(current: "0.9.0"))
        #expect(!release.requiresReplacementConfirmation(current: "1.0.0-alpha.2"))
        #expect(release.requiresReplacementConfirmation(current: "1.1.0"))
        #expect(release.requiresReplacementConfirmation(current: "development"))
        #expect(release.requiresReplacementConfirmation(current: "0.9.0-ci.123"))
    }

    @Test("@spec REMOTE-22.32: When maintenance installs Graftty before agent tools, the application shall verify the reviewed identity and version under the installer lock and continue later components against the installed release without repeating pairing or imports.")
    func grafttyThenTools() async throws {
        let ssh = MaintenanceSSH()
        let record = release("1.0.0", date: "2026-01-01T00:00:00Z")
        let maintenance = LinuxHostMaintenance(ssh: ssh, releases: { [record] })
        let inspection = try await maintenance.inspect(destination: .init("alias"), expected: expected)
        let outcomes = await maintenance.run(inspection: inspection, components: [.graftty, .codex], confirmPublishedReplacement: true)
        #expect(outcomes.map(\.status) == [.succeeded, .succeeded])
        let commands = await ssh.commands
        let install = try #require(commands.first { $0.contains("unpacked/install.sh") })
        #expect(install.contains("GRAFTTY_MAINTENANCE_PREFLIGHT_FILE"))
        #expect(install.contains("--maintenance"))
        #expect(!commands.contains { $0.contains("trust-client") || $0.contains("project add") })
        #expect(commands.count == 3)
    }

    @Test("@spec REMOTE-22.34: If the installed Linux service does not own the inspected paired host's state lease, then the application shall reject Graftty maintenance before stopping or replacing that service.", arguments: [1234, 9999])
    func bindsServiceToPairedState(servicePID: Int) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maintenance-lease-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let python = #"""
        import os, pathlib, subprocess
        state = pathlib.Path(__file__).parent
        (state / 'host.lock').touch()
        lease = (state / 'host.lock').stat()
        (state / 'locks').write_text(f'1: POSIX ADVISORY WRITE 1234 {os.major(lease.st_dev):x}:{os.minor(lease.st_dev):x}:{lease.st_ino} 0 EOF\n')
        """#
        let script = root.appendingPathComponent("check.py")
        let check = LinuxHostMaintenanceScripts.serviceOwnershipPython
            .replacingOccurrences(of: "pathlib.Path('/proc/locks')", with: "(state / 'locks')")
        try (python + "\nsubprocess.check_output = lambda *args, **kwargs: b'\(servicePID)'\n" + check).write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path]
        try process.run(); process.waitUntilExit()
        #expect((process.terminationStatus == 0) == (servicePID == 1234))
    }

    private func release(_ version: String, date: String, checksum: Bool = true, draft: Bool = false) -> LinuxHostRelease.Record {
        let name = "graftty-linux-\(version)-aarch64.tar.gz"
        return .init(tag: "v" + version, publishedAt: date, draft: draft, assets: [name] + (checksum ? [name + ".sha256"] : []))
    }
    private var expected: LinuxHostIdentity { .init(deviceID: "linux", displayName: "Host", publicKey: Data(repeating: 1, count: 32).base64EncodedString(), port: 9001) }
    private func service(_ ssh: MaintenanceSSH) -> LinuxHostMaintenance { .init(ssh: ssh, releases: { [] }) }
}

private actor MaintenanceSSH: LinuxHostSSHExecuting {
    var commands: [String] = []
    let wrongIdentity: Bool
    let failCodex: Bool
    let cancelCodex: Bool
    init(wrongIdentity: Bool = false, failCodex: Bool = false, cancelCodex: Bool = false) {
        self.wrongIdentity = wrongIdentity; self.failCodex = failCodex; self.cancelCodex = cancelCodex
    }
    func capture(arguments: [String], inputFile: URL?) async throws -> CLIOutput {
        let command = arguments.last ?? ""
        commands.append(command)
        if command.contains("GRAFTTY_MAINTENANCE_PROBE") {
            let value = LinuxHostMaintenance.Probe(deviceID: wrongIdentity ? "other" : "linux", publicKey: Data(repeating: 1, count: 32).base64EncodedString(), architecture: "aarch64", version: "development", home: "/home/user", data: "/home/user/.local/share", sshPort: 9001)
            return .init(stdout: String(decoding: try JSONEncoder().encode(value), as: UTF8.self), stderr: "", exitCode: 0)
        }
        if command.contains("chatgpt.com/codex") {
            if cancelCodex { throw CancellationError() }
            if failCodex { return .init(stdout: "", stderr: "download failed", exitCode: 42) }
        }
        return .init(stdout: "tool 1.2.3", stderr: "", exitCode: 0)
    }
}
