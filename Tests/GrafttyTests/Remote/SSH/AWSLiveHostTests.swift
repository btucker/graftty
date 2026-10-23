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
/// copies a private key. With GRAFTTY_LIVE_AWS_REPOSITORY it also creates and
/// deletes two fixture worktrees and runs native discovery inside their containers.
/// Use only with disposable test hosts and the documented fixture image.
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
            if let repository = ProcessInfo.processInfo.environment["GRAFTTY_LIVE_AWS_REPOSITORY"] {
                try await exercisePlacements(connection: connection, target: target, repository: repository, root: root)
            }
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

    private func exercisePlacements(connection: DirectSSHHostConnection, target: AWSHostEnrollmentTarget, repository: String, root: URL) async throws {
        let client = try await connection.makeWorktreeManagementClient()
        try await client.open()
        defer { client.close() }
        guard case .repositories(let repositories) = try await client.send(.listRepositories) else {
            throw ProviderError("Live host did not list repositories")
        }
        #expect(repositories.contains { $0.id == repository })
        let home = root.appendingPathComponent("fixture-home")
        let project = root.appendingPathComponent("fixture-project")
        func write(_ base: URL, _ path: String, _ contents: String) throws {
            let file = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        var selections: [HostAgentSkillRevision] = []
        for runtime in [TeamHookRuntime.codex, .claude] {
            let native = runtime == .codex ? ".agents" : ".claude"
            try write(home, native + "/skills/graftty-live-parent/SKILL.md", "---\nname: graftty-live-parent\ndescription: Verify parent skill transfer.\n---\nReport the fixture marker GRAFTTY_PARENT_SKILL.\n")
            try write(project, native + "/skills/graftty-live-project/SKILL.md", "---\nname: graftty-live-project\ndescription: Verify project skill transfer.\n---\nReport the fixture marker GRAFTTY_PROJECT_SKILL.\n")
            try write(home, native + "/skills/graftty-live-parent/reference.txt", String(repeating: "live multi-chunk payload\n", count: 30_000))
            let snapshot = try RemoteSkillSnapshot.capture(runtime: runtime, home: home, workspace: project, environment: [:])
            let transfer = UUID()
            for _ in 0..<2 {
                let staged = try await RemoteSkillTransferSender.transfer(snapshot, repositoryID: repository, operationID: transfer) { request in
                    guard case .agentSkills(let response) = try await client.send(.agentSkills(request)) else {
                        throw ProviderError("Live skill transfer failed")
                    }
                    return response
                }
                #expect(staged.phase == .staged)
            }
            selections.append(.init(runtime: runtime.rawValue, revision: try snapshot.revision))
        }
        let demand = HostPlacementDemand(architecture: "arm64", cpus: 0.5, memoryBytes: 512 * 1024 * 1024, diskBytes: 512 * 1024 * 1024)
        let rejected = HostPlacementIntent(repositoryID: repository, worktreeName: "missing-skill", branchName: "missing-skill", demand: demand,
            devContainer: .init(skills: [.init(runtime: "codex", revision: String(repeating: "0", count: 64))]))
        guard case .error = try await client.send(.placement(.createWithAgentSkills(operationID: UUID(), intent: rejected))) else {
            throw ProviderError("Live host accepted an unknown skill revision")
        }
        var records: [HostPlacementRecord] = []
        for runtime in ["codex", "claude"] {
            let operation = UUID()
            let name = "live-" + runtime + "-" + operation.uuidString.lowercased().prefix(8)
            let intent = HostPlacementIntent(repositoryID: repository, worktreeName: name, branchName: name, demand: demand,
                devContainer: .init(skills: selections, agentRuntime: runtime))
            let request = HostPlacementRequest.createWithAgentSkills(operationID: operation, intent: intent)
            var admission = try await client.send(.placement(request))
            // Native startup can briefly raise CPU usage above the host's
            // admission ceiling. Retry only explicit capacity rejections with
            // the same immutable operation; never retry an unknown outcome.
            for _ in 0..<20 {
                guard case .error(_, let message, _, _) = admission,
                      message.contains("Host admission rejected:") else { break }
                try await Task.sleep(for: .seconds(3))
                admission = try await client.send(.placement(request))
            }
            guard case .placement(var record) = admission else { throw ProviderError("Live placement admission failed: \(admission)") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(180))
            while record.state == .preparing && ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(1))
                guard case .placement(let value) = try await client.send(.placement(.status(operationID: operation))) else {
                    throw ProviderError("Live placement status failed")
                }
                record = value
            }
            records.append(record)
            if let file = ProcessInfo.processInfo.environment["GRAFTTY_LIVE_AWS_RESULT"] {
                try JSONEncoder().encode(records).write(to: URL(fileURLWithPath: file), options: .atomic)
            }
            try #require(record.state == .created, "Live placement failed: \(record.message ?? record.state.rawValue)")
            #expect(record.environment?.usesRelativeGitWorktree == true)
            #expect(record.environment?.agentSkillHome?.contains("/agent-profiles/" + operation.uuidString.lowercased() + "/") == true)
            #expect(record.environment?.agentReady == false)
            guard case .placement(let retry) = try await client.send(.placement(request)) else { throw ProviderError("Live placement retry failed") }
            #expect(retry == record)
        }
        #expect(records[0].environment?.agentSkillHome != records[1].environment?.agentSkillHome)
        try await verifyNativeAgents(records, target: target, root: root, retainedOnly: false)
        for record in records {
            guard case .deleted = try await client.send(.delete(worktreeID: record.intent.worktreePath, force: true)) else {
                throw ProviderError("Live worktree deletion failed")
            }
            guard case .placement(let released) = try await client.send(.placement(.status(operationID: record.operationID))) else {
                throw ProviderError("Live placement receipt missing after deletion")
            }
            #expect(released.state == .released)
        }
        try await verifyNativeAgents(records, target: target, root: root, retainedOnly: true)
    }

    private func verifyNativeAgents(_ records: [HostPlacementRecord], target: AWSHostEnrollmentTarget, root: URL, retainedOnly: Bool) async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let python = try String(contentsOf: repository.appendingPathComponent("scripts/linux/live-agent-skills.py"), encoding: .utf8)
        let encoded = try JSONEncoder().encode(records).base64EncodedString()
        let script = """
        set -eu
        umask 077
        graftty_probe_dir=$(mktemp -d /tmp/graftty-live-check-XXXXXXXX)
        trap 'rm -rf "$graftty_probe_dir"' EXIT
        printf '%s' '\(encoded)' | base64 -d > "$graftty_probe_dir/records.json"
        python3 - "$graftty_probe_dir/records.json" \(retainedOnly ? "retained" : "discover") <<'GRAFTTY_NATIVE_PROBE_PY'
        \(python)
        GRAFTTY_NATIVE_PROBE_PY
        """
        let parameters = root.appendingPathComponent("native-check.json")
        try JSONSerialization.data(withJSONObject: ["commands": [script], "executionTimeout": ["120"]]).write(to: parameters)
        let runner = CLIRunner(terminatesOnCancellation: true)
        let common = ["--profile", target.profile, "--region", target.region, "--output", "json", "--no-cli-pager"]
        let sent = try await runner.run(command: "aws", args: ["ssm", "send-command", "--instance-ids", target.instanceID,
            "--document-name", "AWS-RunShellScript", "--parameters", "file://" + parameters.path] + common, at: root.path, timeout: .seconds(30))
        let response = try #require(try JSONSerialization.jsonObject(with: Data(sent.stdout.utf8)) as? [String: Any])
        let command = try #require((response["Command"] as? [String: Any])?["CommandId"] as? String)
        for _ in 0..<40 {
            try await Task.sleep(for: .seconds(3))
            let result = try await runner.run(command: "aws", args: ["ssm", "get-command-invocation", "--instance-id", target.instanceID,
                "--command-id", command] + common, at: root.path, timeout: .seconds(30))
            let value = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
            let status = value["Status"] as? String
            if status == "Pending" || status == "InProgress" || status == "Delayed" { continue }
            try #require(status == "Success", "Native verification failed: \(value["StandardErrorContent"] ?? "unknown")")
            if let file = ProcessInfo.processInfo.environment["GRAFTTY_LIVE_AWS_RESULT"] {
                try Data((value["StandardOutputContent"] as? String ?? "").utf8).write(to: URL(fileURLWithPath: file + (retainedOnly ? ".retention" : ".native")))
            }
            return
        }
        throw ProviderError("Native verification deadline exceeded")
    }
}
