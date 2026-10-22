import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

@Suite("@spec REMOTE-26.20: When enrolling an AWS host, the parent shall bind the host's locally generated public identity to the recorded account, region, instance, and pending launch operation through authenticated provider command results before accepting SSH-authenticated callbacks, and shall reject unsolicited or changed-key enrollment without copying private keys.")
struct AWSHostEnrollmentTests {
    private let parent = LinuxHostTrustRequest(deviceID: "parent", displayName: "Parent Mac", publicKey: Data(repeating: 1, count: 32).base64EncodedString(), serverPublicKey: Data(repeating: 3, count: 32).base64EncodedString())
    private let host = LinuxHostIdentity(deviceID: "worker", displayName: "Worker", publicKey: Data(repeating: 2, count: 32).base64EncodedString(), port: 8801)
    private var target: AWSHostEnrollmentTarget {
        .init(profile: "development", accountID: "123456789012", region: "us-east-1", instanceID: "i-0123456789abcdef0",
              user: "ubuntu", executable: "/home/ubuntu/.local/bin/graftty-host", stateDirectory: "/home/ubuntu/.local/share/graftty")
    }

    @Test func enrollsExactInstanceAndResumesWithoutRepeatingCommandOrGrant() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let operation = UUID()
        let runner = EnrollmentExecutor(operation: operation, parent: parent, host: host)
        let peers = TrustedPeerStore(directory: root.appendingPathComponent("Remote"))
        let enrollment = AWSHostEnrollment(directory: root.appendingPathComponent("Enrollment"), peers: peers, executor: runner, pause: {})
        let result = try await enrollment.enroll(operationID: operation, target: target, parent: parent)
        #expect(result == host)
        let peer = try #require(try peers.get(id: .init(value: host.deviceID)))
        #expect(peer.kind == .linux)
        #expect(peer.capabilities.replication == .allowed)
        #expect(peer.capabilities.terminalControl == .disabled)
        #expect(peer.capabilities.worktreeManagement == .disabled)
        #expect(peer.capabilities.portTunnel == .disabled)
        let send = try #require(runner.calls.first { $0.contains("send-command") })
        #expect(send[try #require(send.firstIndex(of: "--instance-ids")) + 1] == target.instanceID)
        #expect(!send.contains("--targets"))
        #expect(runner.calls.allSatisfy { $0.contains("--profile") && $0.contains(target.profile) && $0.contains(target.region) })
        let serialized = send.joined(separator: " ")
        #expect(serialized.contains("runuser"))
        #expect(serialized.contains("enroll-parent"))
        #expect(!serialized.contains("privateKey"))
        let calls = runner.calls.count
        #expect(try await enrollment.enroll(operationID: operation, target: target, parent: parent) == host)
        #expect(runner.calls.count == calls)
        try peers.remove(id: peer.id)
        await #expect(throws: (any Error).self) { _ = try await enrollment.enroll(operationID: operation, target: target, parent: parent) }
        #expect(try peers.list().isEmpty)
    }

    @Test(arguments: ["account", "instance", "command", "operation", "parent", "status", "exit", "truncated", "document"])
    func rejectsUntrustedOrIncompleteResponses(fault: String) async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let operation = UUID()
        let runner = EnrollmentExecutor(operation: operation, parent: parent, host: host, fault: fault)
        let peers = TrustedPeerStore(directory: root.appendingPathComponent("Remote"))
        let enrollment = AWSHostEnrollment(directory: root.appendingPathComponent("Enrollment"), peers: peers, executor: runner, pause: {})
        await #expect(throws: (any Error).self) { _ = try await enrollment.enroll(operationID: operation, target: target, parent: parent) }
        #expect(try peers.list().isEmpty)
        if fault == "account" { #expect(runner.calls.count == 1) }
    }

    @Test func failedPollResumesRecordedCommandAndRejectsChangedIntent() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let operation = UUID()
        let peers = TrustedPeerStore(directory: root.appendingPathComponent("Remote"))
        let broken = EnrollmentExecutor(operation: operation, parent: parent, host: host, fault: "poll")
        let directory = root.appendingPathComponent("Enrollment")
        await #expect(throws: (any Error).self) {
            _ = try await AWSHostEnrollment(directory: directory, peers: peers, executor: broken, pause: {}).enroll(operationID: operation, target: target, parent: parent)
        }
        let runner = EnrollmentExecutor(operation: operation, parent: parent, host: host)
        let resumed = AWSHostEnrollment(directory: directory, peers: peers, executor: runner, pause: {})
        let otherParent = LinuxHostTrustRequest(deviceID: parent.deviceID, displayName: parent.displayName, publicKey: host.publicKey, serverPublicKey: parent.serverPublicKey)
        await #expect(throws: (any Error).self) { _ = try await resumed.enroll(operationID: operation, target: target, parent: otherParent) }
        #expect(runner.calls.isEmpty)
        #expect(try await resumed.enroll(operationID: operation, target: target, parent: parent) == host)
        #expect(!runner.calls.contains { $0.contains("send-command") })
    }

    @Test func rejectsChangedKeyForSameInstanceAcrossOperations() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let peers = TrustedPeerStore(directory: root.appendingPathComponent("Remote"))
        let directory = root.appendingPathComponent("Enrollment")
        let first = UUID()
        _ = try await AWSHostEnrollment(directory: directory, peers: peers,
            executor: EnrollmentExecutor(operation: first, parent: parent, host: host), pause: {}).enroll(operationID: first, target: target, parent: parent)
        let second = UUID()
        let changed = LinuxHostIdentity(deviceID: "replacement", displayName: "Worker", publicKey: parent.publicKey, port: 8801)
        await #expect(throws: (any Error).self) {
            _ = try await AWSHostEnrollment(directory: directory, peers: peers,
                executor: EnrollmentExecutor(operation: second, parent: parent, host: changed), pause: {}).enroll(operationID: second, target: target, parent: parent)
        }
        #expect(try peers.list().map(\.id.value) == [host.deviceID])
    }

    @Test func pendingAndEventualConsistencyResponsesAreRetried() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let operation = UUID()
        let runner = EnrollmentExecutor(operation: operation, parent: parent, host: host, fault: "pending")
        let result = try await AWSHostEnrollment(directory: root.appendingPathComponent("Enrollment"),
            peers: TrustedPeerStore(directory: root.appendingPathComponent("Remote")), executor: runner, pause: {}).enroll(operationID: operation, target: target, parent: parent)
        #expect(result == host)
        #expect(runner.calls.filter { $0.contains("get-command-invocation") }.count == 3)
    }

    @Test func cancellationBeforeEnrollmentDoesNotTrustOrInvokeAWS() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let operation = UUID()
        let runner = EnrollmentExecutor(operation: operation, parent: parent, host: host)
        let peers = TrustedPeerStore(directory: root.appendingPathComponent("Remote"))
        let enrollment = AWSHostEnrollment(directory: root.appendingPathComponent("Enrollment"), peers: peers, executor: runner, pause: {})
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await enrollment.enroll(operationID: operation, target: target, parent: parent)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(runner.calls.isEmpty)
        #expect(try peers.list().isEmpty)
    }

    @Test func corruptBindingHistoryFailsClosed() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Enrollment")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let badFile = directory.appendingPathComponent(UUID().uuidString + ".json")
        try Data("broken".utf8).write(to: badFile)
        let operation = UUID()
        let peers = TrustedPeerStore(directory: root.appendingPathComponent("Remote"))
        await #expect(throws: (any Error).self) {
            _ = try await AWSHostEnrollment(directory: directory, peers: peers,
                executor: EnrollmentExecutor(operation: operation, parent: parent, host: host), pause: {}).enroll(operationID: operation, target: target, parent: parent)
        }
        #expect(try peers.list().isEmpty)
        #expect(try Data(contentsOf: badFile) == Data("broken".utf8))
    }

    @Test func separateTrustStoreInstancesDoNotLoseConcurrentEnrollments() async throws {
        let root = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<32 {
                group.addTask {
                    let peer = TrustedPeer(id: .init(value: "worker-\(n)"), kind: .linux,
                        publicKey: try .init(rawRepresentation: Data(repeating: UInt8(n), count: 32)), displayName: "Worker",
                        capabilities: .init(terminalControl: .disabled, portTunnel: .disabled, screenView: .disabled,
                        screenControl: .disabled, replication: .allowed), pairedAt: Date(), lastSeenAt: nil)
                    try TrustedPeerStore(directory: root).enrollWithoutReplacingIdentity(peer)
                }
            }
            try await group.waitForAll()
        }
        #expect(try TrustedPeerStore(directory: root).list().count == 32)
    }

    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("enrollment-\(UUID())") }
}

private final class EnrollmentExecutor: CLIExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return recorded }
    let operation: UUID
    let parent: LinuxHostTrustRequest
    let host: LinuxHostIdentity
    let fault: String?
    let commandID = "11111111-2222-3333-4444-555555555555"
    init(operation: UUID, parent: LinuxHostTrustRequest, host: LinuxHostIdentity, fault: String? = nil) {
        self.operation = operation; self.parent = parent; self.host = host; self.fault = fault
    }
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput { try await run(command: command, args: args, at: directory, timeout: nil) }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput { try await run(command: command, args: args, at: directory) }
    func run(command: String, args: [String], at directory: String, timeout: Duration?) async throws -> CLIOutput {
        #expect(command == "aws")
        #expect(timeout != nil)
        record(args)
        var value: [String: Any]
        if args.starts(with: ["sts", "get-caller-identity"]) {
            value = ["Account": fault == "account" ? "999999999999" : "123456789012"]
        } else if args.contains("send-command") {
            value = ["Command": ["CommandId": commandID, "InstanceIds": ["i-0123456789abcdef0"], "DocumentName": fault == "document" ? "Other" : "AWS-RunShellScript"]]
        } else {
            #expect(args.contains("get-command-invocation"))
            if fault == "poll" { throw CLIError.nonZeroExit(command: "aws", exitCode: 255, stderr: "AccessDenied") }
            let count = calls.filter { $0.contains("get-command-invocation") }.count
            if fault == "pending", count == 1 { throw CLIError.nonZeroExit(command: "aws", exitCode: 255, stderr: "An error occurred (InvocationDoesNotExist) when calling the GetCommandInvocation operation: pending") }
            let response = ProviderHostEnrollmentResponse(operationID: fault == "operation" ? UUID() : operation,
                parent: fault == "parent" ? .init(deviceID: "intruder", displayName: "Intruder", publicKey: parent.publicKey) : parent, identity: host)
            let output = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
            value = ["CommandId": fault == "command" ? UUID().uuidString : commandID,
                "InstanceId": fault == "instance" ? "i-fffffffffffffffff" : "i-0123456789abcdef0", "DocumentName": "AWS-RunShellScript",
                "Status": fault == "status" ? "Failed" : (fault == "pending" && count == 2 ? "InProgress" : "Success"),
                "ResponseCode": fault == "exit" ? 1 : 0,
                "StandardOutputContent": fault == "truncated" ? String(output.dropLast()) : output, "StandardErrorContent": ""]
        }
        return .init(stdout: String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self), stderr: "", exitCode: 0)
    }
    private func record(_ args: [String]) { lock.lock(); defer { lock.unlock() }; recorded.append(args) }
}
