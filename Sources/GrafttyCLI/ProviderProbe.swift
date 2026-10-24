import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

struct ProviderProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "probe", abstract: "Authenticate an enrolled AWS host and read its current load",
        discussion: "Uses AWS CLI v2 and the Session Manager plugin on this Mac, plus the saved enrollment. The host must be running graftty-host and SSM Agent. No inbound ports are required. This command closes its connection after one observation; it does not start background replication.")
    @Argument(help: "Compute provider: aws") var provider: String
    @Option(help: "Completed enrollment operation UUID") var operationId: String
    @Flag(help: "Print pinned identity and resource observation as JSON") var json = false

    func validate() throws {
        try ProviderOutput.validate(provider)
        guard UUID(uuidString: operationId) != nil else { throw ValidationError("--operation-id must be a UUID") }
    }

    func run() async throws {
        #if os(macOS)
        do {
            let result = try await withCLIInterruptCancellation { try await probe() }
            if json { try ProviderOutput.json(result) }
            else {
                print("Authenticated \(result.instanceID) as \(result.host.deviceID.value).")
                let sample = result.resources?.isFresh() == true ? result.resources?.sample : nil
                print("CPU fraction: \(sample?.cpuUtilization.map(String.init(describing:)) ?? "unknown"); available memory bytes: \(sample?.memoryAvailableBytes.map(String.init) ?? "unknown"); active worktrees: \(sample?.activeWorktrees.description ?? "unknown")")
            }
        } catch is CancellationError { throw ExitCode(130) }
        #else
        throw ValidationError("Run provider probe on the parent Mac with Graftty running.")
        #endif
    }

    private func probe() async throws -> ProbeResult {
        guard let operationID = UUID(uuidString: operationId) else { throw ValidationError("--operation-id must be a UUID") }
        let parent: LinuxHostTrustRequest
        switch try CLIEnv.sendRequest(.linuxSetupIdentity) {
        case .linuxSetupIdentity(let identity): parent = identity
        case .error(let error): throw ValidationError(error)
        default: throw ValidationError("Update and relaunch Graftty to probe an AWS host.")
        }
        guard let key = try ClientIdentityStore(directory: ClientIdentityStore.defaultDirectory).load(),
              key.publicKey.rawRepresentation.base64EncodedString() == parent.publicKey else {
            throw ValidationError("The parent's saved SSH client identity is missing or changed.")
        }
        let enrollment = AWSHostEnrollment(peers: TrustedPeerStore(directory: TrustedPeerStore.defaultDirectory))
        let registry = try HostProviderRegistry(providers: [AWSHostProvider(enrollment: enrollment)])
        let plan = try await registry.prepareConnection(binding: .init(provider: provider, operationID: operationID), parent: parent)
        let fingerprint = RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: Data(base64Encoded: plan.identity.publicKey)!))
        let connection = DirectSSHHostConnection(clientKey: key, expectedHostFingerprint: fingerprint)
        try Task.checkCancellation()
        var proxy: DuplexSubprocess?
        do {
            switch plan.transport {
            case .directSSH(let host, let port):
                try await connection.connect(host: host, port: port)
            case .proxy(let command, let arguments):
                let process = try DuplexSubprocess(command: command, arguments: arguments)
                proxy = process
                try await connection.connect(input: process.output, output: process.input)
            }
            try registry.authorize(plan, parent: parent)
            let resources = try await connection.resourceObservation()
            try registry.authorize(plan, parent: parent)
            await connection.close()
            await proxy?.stop()
            return ProbeResult(instanceID: plan.target,
                host: .init(deviceID: .init(value: plan.identity.deviceID), fingerprint: fingerprint), resources: resources)
        } catch {
            await connection.close()
            await proxy?.stop()
            // AWS/plugin diagnostics may contain session URLs or tokens. Keep
            // them out of CLI output; users can diagnose SSM directly with AWS.
            if error is CancellationError { throw error }
            throw ValidationError("AWS host probe failed: \(error). Check the Session Manager plugin, SSM access, graftty-host readiness, and enrollment trust.")
        }
    }

    private struct ProbeResult: Encodable {
        let instanceID: String
        let host: RemoteMacConnectionSummary.ID
        let resources: HostResourceObservation?
    }
}
