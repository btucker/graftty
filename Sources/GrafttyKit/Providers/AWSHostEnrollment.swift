import Foundation
import GrafttyProtocol

/// Locally checked connection intent, not proof of the remote endpoint. The
/// caller must still authenticate SSH against `identity.publicKey`.
public struct AWSHostConnectionPlan: Sendable, Equatable {
    public let operationID: UUID
    public let target: AWSHostEnrollmentTarget
    public let identity: LinuxHostIdentity
    public var arguments: [String] {
        ["ssm", "start-session", "--target", target.instanceID,
         "--document-name", "AWS-StartSSHSession", "--parameters", "{\"portNumber\":[\"\(identity.port)\"]}",
         "--profile", target.profile, "--region", target.region, "--no-cli-pager", "--no-cli-auto-prompt",
         "--cli-connect-timeout", "10", "--cli-read-timeout", "20"]
    }
}

public struct AWSHostEnrollmentTarget: Codable, Sendable, Equatable {
    public let profile: String
    public let accountID: String
    public let region: String
    public let instanceID: String
    public let user: String
    public let executable: String
    public let stateDirectory: String

    public init(profile: String, accountID: String, region: String, instanceID: String,
                user: String, executable: String, stateDirectory: String) {
        self.profile = profile; self.accountID = accountID; self.region = region; self.instanceID = instanceID
        self.user = user; self.executable = executable; self.stateDirectory = stateDirectory
    }

    public func validate() throws {
        try AWSProviderPreferences(profile: profile, regions: [region]).validate()
        guard accountID.utf8.count == 12, accountID.range(of: #"^[0-9]{12}$"#, options: .regularExpression) != nil,
              [10, 19].contains(instanceID.utf8.count), instanceID.range(of: #"^i-([0-9a-f]{8}|[0-9a-f]{17})$"#, options: .regularExpression) != nil,
              user.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil, user != "root", !user.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              [executable, stateDirectory].allSatisfy({ path in
                  path.hasPrefix("/") && path.utf8.count <= 2048
                    && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                    && path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
              }) else { throw ProviderError("Enrollment requires an AWS account, exact EC2 instance ID, non-root development user, and absolute host executable and state paths.") }
    }

    func sameInstance(as other: Self) -> Bool {
        accountID == other.accountID && region == other.region && instanceID == other.instanceID
    }
}

/// Binds an explicitly selected AWS instance to its public SSH identity. This
/// method is local administration, not an endpoint offered to untrusted hosts.
public struct AWSHostEnrollment: Sendable {
    public static var defaultDirectory: URL { AppState.defaultDirectory.appendingPathComponent("Providers/Enrollment", isDirectory: true) }
    private let directory: URL
    private let peers: TrustedPeerStore
    private let executor: any CLIExecutor
    private let pause: @Sendable () async throws -> Void

    public init(directory: URL = Self.defaultDirectory, peers: TrustedPeerStore,
                executor: any CLIExecutor = CLIRunner(terminatesOnCancellation: true)) {
        self.init(directory: directory, peers: peers, executor: executor, pause: { try await Task.sleep(for: .seconds(2)) })
    }

    init(directory: URL, peers: TrustedPeerStore, executor: any CLIExecutor, pause: @escaping @Sendable () async throws -> Void) {
        self.directory = directory; self.peers = peers; self.executor = executor; self.pause = pause
    }

    private struct Record: Codable {
        var version = 1
        let operationID: UUID
        let target: AWSHostEnrollmentTarget
        let parent: LinuxHostTrustRequest
        var commandID: String?
        var identity: LinuxHostIdentity?
    }

    public func prepareConnection(operationID: UUID, parent: LinuxHostTrustRequest) async throws -> AWSHostConnectionPlan {
        let plan = try connectionPlan(operationID: operationID, parent: parent)
        try await verifyAccount(plan.target, deadline: .now.advanced(by: .seconds(45)))
        try validateConnection(plan, parent: parent)
        return plan
    }

    /// Recheck before admitting requests and after awaiting transport setup.
    /// Removing enrollment or revoking pairing invalidates an existing plan.
    public func validateConnection(_ plan: AWSHostConnectionPlan, parent: LinuxHostTrustRequest) throws {
        guard try connectionPlan(operationID: plan.operationID, parent: parent) == plan else {
            throw ProviderError("The saved AWS connection binding changed.")
        }
    }

    func connectionPlan(operationID: UUID, parent: LinuxHostTrustRequest) throws -> AWSHostConnectionPlan {
        try Task.checkCancellation()
        try ProviderHostEnrollment.validate(parent)
        let file = JSONFileStore<Record>(fileURL: directory.appendingPathComponent(operationID.uuidString + ".json"))
        guard let record = try file.load(), record.version == 1, record.operationID == operationID,
              record.parent == parent, let identity = record.identity else {
            throw ProviderError("No completed enrollment matches this operation and parent identity.")
        }
        try record.target.validate()
        try verifyTrust(identity)
        return AWSHostConnectionPlan(operationID: operationID, target: record.target, identity: identity)
    }

    /// The caller supplies the provisioning operation and exact instance returned
    /// by AWS, or an explicit local enrollment request. Retries preserve intent.
    public func enroll(operationID: UUID, target: AWSHostEnrollmentTarget, parent: LinuxHostTrustRequest) async throws -> LinuxHostIdentity {
        try target.validate()
        try ProviderHostEnrollment.validate(parent)
        try Task.checkCancellation()
        let lease: ExclusiveFileLock
        do { lease = try ExclusiveFileLock(url: directory.appendingPathComponent("enrollment.lock"), wait: false) }
        catch let error as POSIXError where error.code == .EWOULDBLOCK {
            throw ProviderError("Another AWS enrollment is running. Retry after it finishes.")
        }
        defer { withExtendedLifetime(lease) {} }
        let file = JSONFileStore<Record>(fileURL: directory.appendingPathComponent(operationID.uuidString + ".json"), posixPermissions: 0o600)
        var record = try file.load() ?? Record(operationID: operationID, target: target, parent: parent)
        guard record.version == 1, record.operationID == operationID, record.target == target, record.parent == parent else {
            throw ProviderError("Enrollment retry changed its recorded target or parent identity.")
        }
        if let identity = record.identity {
            try verifyTrust(identity)
            return identity
        }
        try file.save(record)
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        try await verifyAccount(target, deadline: deadline)
        if record.commandID == nil {
            let request = ProviderHostEnrollmentRequest(operationID: operationID, parent: parent)
            let input = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            // SSM runs as root. Execute as the same user and with the explicit
            // state directory used by graftty-host serve, without a login shell.
            let script = "set -eu\n" + "printf '%s' " + LinuxHostScripts.quote(input)
                + " | runuser -u " + LinuxHostScripts.quote(target.user) + " -- " + LinuxHostScripts.quote(target.executable)
                + " enroll-parent --stdin --state-directory " + LinuxHostScripts.quote(target.stateDirectory)
            let parameters = String(decoding: try JSONEncoder().encode(["commands": [script], "executionTimeout": ["60"]]), as: UTF8.self)
            let sent: SendResponse = try await query(["ssm", "send-command", "--instance-ids", target.instanceID,
                "--document-name", "AWS-RunShellScript", "--document-version", "1", "--timeout-seconds", "60",
                "--parameters", parameters], target: target, deadline: deadline)
            guard UUID(uuidString: sent.Command.CommandId) != nil,
                  sent.Command.InstanceIds == [target.instanceID], sent.Command.DocumentName == "AWS-RunShellScript" else {
                throw ProviderError("AWS returned a command for an unexpected instance or document.")
            }
            record.commandID = sent.Command.CommandId
            try file.save(record)
        }
        guard let commandID = record.commandID, UUID(uuidString: commandID) != nil else { throw ProviderError("Invalid recorded enrollment command.") }
        for _ in 0..<60 {
            try Task.checkCancellation()
            let invocation: Invocation
            do {
                invocation = try await query(["ssm", "get-command-invocation", "--command-id", commandID,
                    "--instance-id", target.instanceID], target: target, deadline: deadline)
            } catch CLIError.nonZeroExit(_, _, let stderr) where stderr.contains("(InvocationDoesNotExist)") {
                try await pause()
                continue
            }
            guard invocation.CommandId == commandID, invocation.InstanceId == target.instanceID,
                  invocation.DocumentName == "AWS-RunShellScript" else {
                throw ProviderError("AWS returned an invocation for an unexpected command, instance, or document.")
            }
            if ["Pending", "InProgress", "Delayed"].contains(invocation.Status) { try await pause(); continue }
            guard invocation.Status == "Success", invocation.ResponseCode == 0,
                  invocation.StandardErrorContent.isEmpty, invocation.StandardOutputContent.utf8.count <= 8192 else {
                throw ProviderError("Host enrollment did not complete successfully. Check SSM access, the development user, and graftty-host setup. Fix the failure and explicitly start a new enrollment operation.")
            }
            let response = try JSONDecoder().decode(ProviderHostEnrollmentResponse.self, from: Data(invocation.StandardOutputContent.utf8))
            guard response.operationID == operationID, response.parent == parent else {
                throw ProviderError("Host enrollment returned a different operation or parent identity.")
            }
            try response.identity.validate()
            guard ProviderHostEnrollment.validDeviceID(response.identity.deviceID), ProviderHostEnrollment.validLabel(response.identity.displayName),
                  Data(base64Encoded: response.identity.publicKey)?.base64EncodedString() == response.identity.publicKey else {
                throw ProviderError("Host enrollment returned an invalid public identity.")
            }
            // Recheck the profile after provider calls, before trusting results.
            try await verifyAccount(target, deadline: deadline)
            try checkPreviousBindings(target: target, identity: response.identity)
            try Task.checkCancellation()
            record.identity = response.identity
            try file.save(record)
            let key = try RemoteIdentityPublicKey(rawRepresentation: Data(base64Encoded: response.identity.publicKey)!)
            try peers.enrollWithoutReplacingIdentity(.init(id: .init(value: response.identity.deviceID), kind: .linux, publicKey: key,
                displayName: response.identity.displayName, capabilities: .init(terminalControl: .disabled, portTunnel: .disabled,
                screenView: .disabled, screenControl: .disabled, worktreeManagement: .disabled, replication: .allowed), pairedAt: Date(), lastSeenAt: nil))
            try verifyTrust(response.identity)
            return response.identity
        }
        throw ProviderError("Timed out waiting for SSM enrollment. Retry with the same operation ID to resume its recorded command.")
    }

    private func verifyTrust(_ identity: LinuxHostIdentity) throws {
        try identity.validate()
        guard let peer = try peers.get(id: .init(value: identity.deviceID)), peer.kind == .linux,
              peer.publicKey.rawRepresentation.base64EncodedString() == identity.publicKey, peer.capabilities.replication == .allowed else {
            throw ProviderError("Enrollment trust is incomplete, changed, or revoked. A retry cannot restore it; review the saved binding and explicitly enroll again.")
        }
    }

    private func checkPreviousBindings(target: AWSHostEnrollmentTarget, identity: LinuxHostIdentity) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= 10000 else { throw ProviderError("Enrollment history is full.") }
        for url in files {
            guard let previous = try JSONFileStore<Record>(fileURL: url).load(), previous.version == 1 else {
                throw ProviderError("Invalid enrollment history; refusing to replace a recorded identity.")
            }
            guard let prior = previous.identity else { continue }
            let sameIdentity = prior.deviceID == identity.deviceID && prior.publicKey == identity.publicKey
            if previous.target.sameInstance(as: target) {
                guard sameIdentity else { throw ProviderError("The instance's saved identity changed. Verify the replacement before explicitly removing its old enrollment.") }
            } else if prior.deviceID == identity.deviceID || prior.publicKey == identity.publicKey {
                throw ProviderError("This host identity is already bound to a different AWS instance.")
            }
        }
    }

    private func verifyAccount(_ target: AWSHostEnrollmentTarget, deadline: ContinuousClock.Instant) async throws {
        let caller: Caller = try await query(["sts", "get-caller-identity"], target: target, deadline: deadline)
        guard caller.Account == target.accountID else { throw ProviderError("The AWS profile does not belong to the recorded account.") }
    }

    private func query<T: Decodable>(_ arguments: [String], target: AWSHostEnrollmentTarget, deadline: ContinuousClock.Instant) async throws -> T {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw ProviderError("AWS enrollment deadline expired; retry with the same operation ID.") }
        let output: CLIOutput
        do {
            output = try await executor.run(command: "aws", args: arguments + ["--profile", target.profile, "--region", target.region,
                "--output", "json", "--no-cli-pager", "--no-cli-auto-prompt", "--cli-connect-timeout", "10", "--cli-read-timeout", "20"],
                at: NSHomeDirectory(), timeout: min(remaining, .seconds(45)))
        } catch CLIError.notFound { throw ProviderError("Install AWS CLI v2 and configure the selected profile before enrolling a host.") }
        try Task.checkCancellation()
        guard output.stdout.utf8.count <= 65536 else { throw ProviderError("AWS returned an oversized enrollment response.") }
        return try JSONDecoder().decode(T.self, from: Data(output.stdout.utf8))
    }

    private struct Caller: Decodable { let Account: String }
    private struct SendResponse: Decodable {
        let Command: CommandResult
        struct CommandResult: Decodable { let CommandId: String; let InstanceIds: [String]; let DocumentName: String }
    }
    private struct Invocation: Decodable {
        let CommandId: String
        let InstanceId: String
        let DocumentName: String
        let Status: String
        let ResponseCode: Int
        let StandardOutputContent: String
        let StandardErrorContent: String
    }
}
