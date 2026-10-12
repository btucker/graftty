import Foundation

private enum LinuxHostMaintenanceFailure: Error, LocalizedError {
    case failed(String), unknown(String)
    var errorDescription: String? {
        switch self { case .failed(let message), .unknown(let message): message }
    }
}

public struct LinuxHostComponentOutcome: Sendable, Equatable, Identifiable {
    public enum Status: Sendable { case succeeded, failed, unknown, skipped }
    public let component: LinuxHostComponent
    public let status: Status
    public let message: String
    public var id: String { component.id }
}

public struct LinuxHostMaintenance: Sendable {
    let ssh: any LinuxHostSSHExecuting
    let releases: @Sendable () async throws -> [LinuxHostRelease.Record]
    public init(ssh: any LinuxHostSSHExecuting = LinuxHostSSHRunner(), releases: @escaping @Sendable () async throws -> [LinuxHostRelease.Record] = { try await LinuxHostRelease.published() }) {
        self.ssh = ssh; self.releases = releases
    }

    public struct Inspection: Sendable {
        public let destination: LinuxHostDestination
        public let expected: LinuxHostIdentity
        public let probe: Probe
        public let release: LinuxHostRelease?
        public let releaseMessage: String
    }
    public struct Probe: Codable, Sendable {
        public let deviceID: String
        public let publicKey: String
        public let architecture: String
        public let version: String
        public let home: String
        public let data: String
        public let sshPort: Int
    }

    public func inspect(destination: LinuxHostDestination, expected: LinuxHostIdentity, includePrereleases: Bool = false) async throws -> Inspection {
        try expected.validate()
        let output = try await remote(destination, command: LinuxHostMaintenanceScripts.probe)
        let probe = try JSONDecoder().decode(Probe.self, from: Data(output.stdout.utf8))
        guard probe.deviceID == expected.deviceID, probe.publicKey == expected.publicKey, probe.sshPort == expected.port else {
            throw LinuxHostSetupError.invalidPlan("This SSH destination has a different Graftty identity. No changes were made. Verify the destination; pairing must be changed explicitly.")
        }
        guard ["x86_64", "aarch64"].contains(probe.architecture),
              [probe.home, probe.data].allSatisfy({ $0.hasPrefix("/") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw LinuxHostSetupError.invalidPlan("The maintenance destination must be a supported Linux host with absolute user directories.")
        }
        var release: LinuxHostRelease?
        var releaseMessage = "No published Linux release has an archive and checksum for this host. Agent tools can still be updated."
        do {
            release = try LinuxHostRelease.select(from: await releases(), architecture: probe.architecture, includePrereleases: includePrereleases)
            if let release { releaseMessage = "Published Linux release: \(release.version). Current build: \(probe.version)." }
        } catch is CancellationError { throw CancellationError() }
        catch { releaseMessage = error.localizedDescription }
        return .init(destination: destination, expected: expected, probe: probe, release: release, releaseMessage: releaseMessage)
    }

    public func run(inspection: Inspection, components: [LinuxHostComponent], replaceCustomTools: Bool = false, confirmPublishedReplacement: Bool = false, progress: @escaping @Sendable (LinuxHostComponentOutcome) async -> Void = { _ in }) async -> [LinuxHostComponentOutcome] {
        var outcomes: [LinuxHostComponentOutcome] = []
        var interrupted = false
        var expectedVersion = inspection.probe.version
        for component in LinuxHostComponent.allCases where components.contains(component) {
            let outcome: LinuxHostComponentOutcome
            if interrupted || Task.isCancelled {
                outcome = .init(component: component, status: .skipped, message: "Not started after cancellation.")
            } else {
                do {
                    let script: String
                    if component == .graftty {
                        guard let release = inspection.release else { throw LinuxHostSetupError.invalidPlan(inspection.releaseMessage) }
                        guard confirmPublishedReplacement || !release.requiresReplacementConfirmation(current: inspection.probe.version) else {
                            throw LinuxHostSetupError.invalidPlan("Confirm replacing this newer or unversioned Graftty build with the published release before proceeding.")
                        }
                        script = try LinuxHostMaintenanceScripts.install(release: release, data: inspection.probe.data, expected: inspection.expected, version: expectedVersion)
                    } else { script = LinuxHostToolScripts.install(component, replaceCustom: replaceCustomTools) }
                    let output = try await remote(inspection.destination, command: LinuxHostMaintenanceScripts.guardIdentity(inspection.expected, version: expectedVersion) + "\n" + script)
                    if component == .graftty, let release = inspection.release { expectedVersion = release.version }
                    outcome = .init(component: component, status: .succeeded, message: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch is CancellationError {
                    interrupted = true
                    outcome = .init(component: component, status: .unknown, message: "Interrupted. The remote command may still be finishing; inspect the host before retrying.")
                } catch LinuxHostMaintenanceFailure.unknown(let message) {
                    interrupted = true
                    outcome = .init(component: component, status: .unknown, message: message)
                } catch CLIError.timedOut(_, _) {
                    interrupted = true
                    outcome = .init(component: component, status: .unknown, message: "SSH timed out. The remote command may still be finishing; inspect the host before retrying.")
                } catch {
                    outcome = .init(component: component, status: .failed, message: error.localizedDescription)
                }
            }
            outcomes.append(outcome)
            await progress(outcome)
        }
        return outcomes
    }

    private func remote(_ destination: LinuxHostDestination, command: String) async throws -> CLIOutput {
        try Task.checkCancellation()
        let output = try await ssh.capture(arguments: LinuxHostSetup.sshArguments(destination, command: command), inputFile: nil)
        try Task.checkCancellation()
        guard output.exitCode == 0 else {
            let message = "Host maintenance failed (exit \(output.exitCode)).\n\(output.stderr)\n\(output.stdout)"
            if output.exitCode == 255 {
                throw LinuxHostMaintenanceFailure.unknown("SSH disconnected without confirming the remote outcome. Inspect the host before retrying.\n\(message)")
            }
            throw LinuxHostMaintenanceFailure.failed(message)
        }
        return output
    }
}
