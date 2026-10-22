import Foundation
import Testing
@testable import GrafttyKit

struct AWSHostInventoryTests {
    @Test("@spec REMOTE-24.11: When listing AWS provider instances, the CLI shall report account-scoped instance identity, lifecycle state, available hardware metadata, and observation time across configured regions, default to Graftty-tagged instances, and expose readiness and unmeasured load as unknown without treating tags as authenticated host ownership.")
    func inventoryIncludesHostsOutsideTheCurrentPoolWithoutClaimingReadiness() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let runner = InventoryExecutor(responses: [
            "us-east-1/describe-instances": try instances([
                instance("i-b", type: "m7g.xlarge", state: "stopped"),
                instance("i-a", type: "t4g.xlarge", state: "running", extra: ["CpuOptions": ["CoreCount": 1, "ThreadsPerCore": 2], "InstanceLifecycle": "spot", "PublicIpAddress": "203.0.113.1"]),
                instance("i-other", tagged: false)
            ]),
            "us-west-2/describe-instances": try instances([instance("i-a", state: "pending", extra: ["Placement": ["AvailabilityZone": "us-west-2a"]])], account: "222222222222"),
            "us-east-1/describe-instance-types": try metadata(["t4g.xlarge", "m7g.xlarge"]),
            "us-west-2/describe-instance-types": try metadata(["t4g.xlarge"])
        ])
        let preferences = AWSProviderPreferences(profile: "dev account", regions: ["us-west-2", "us-east-1"], instanceTypes: ["c7g.large"], availabilityZones: ["us-east-1z"])
        let report = try await AWSHostInventory(executor: runner).hosts(preferences: preferences, at: now)
        #expect(report.hosts.map(\.identity) == ["aws/111111111111/us-east-1/i-a", "aws/111111111111/us-east-1/i-b", "aws/222222222222/us-west-2/i-a"])
        #expect(report.hosts.map(\.state) == ["running", "stopped", "pending"])
        #expect(report.hosts.map(\.cpus) == [2, 4, 4])
        #expect(report.hosts.allSatisfy { $0.memoryMiB == 16384 && $0.observedAt == now && $0.grafttyTagged })
        #expect(report.hosts[0].market == "spot")
        #expect(report.hosts[1].market == "on-demand")
        #expect(report.hosts.allSatisfy { $0.readiness == "unknown" && $0.cpuUtilization == nil && $0.telemetryObservedAt == nil })
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        let entries = try #require(json["hosts"] as? [[String: Any]])
        for entry in entries {
            for key in ["cpuUtilization", "availableMemoryMiB", "freeDiskBytes", "pendingPlacements", "telemetryObservedAt"] {
                #expect(entry[key] is NSNull)
            }
        }
        #expect(runner.calls.count == 4)
        #expect(runner.calls.allSatisfy { $0.timeout != nil && $0.args.contains("--no-cli-auto-prompt") && $0.args.contains("dev account") })
        let inventories = runner.calls.filter { $0.args[1] == "describe-instances" }
        #expect(inventories.allSatisfy { $0.args.contains("Name=tag:graftty:managed,Values=true") })
        #expect(inventories.allSatisfy { !$0.args.contains("--no-paginate") && !$0.args.contains("--max-items") })
    }

    @Test func allIncludesUntaggedAndTerminatedHostsWithoutRequiringAPool() async throws {
        let runner = InventoryExecutor(responses: [
            "us-east-1/describe-instances": try instances([instance("i-a", state: "terminated", tagged: false)]),
            "us-east-1/describe-instance-types": try metadata(["t4g.xlarge"])
        ])
        let report = try await AWSHostInventory(executor: runner).hosts(preferences: preferences, includeUntagged: true)
        #expect(report.hosts.count == 1)
        #expect(report.hosts.first?.grafttyTagged == false)
        #expect(report.hosts.first?.state == "terminated")
        #expect(runner.calls.first?.args.contains("--filters") == false)
    }

    @Test func emptyInventorySkipsHardwareLookup() async throws {
        let runner = InventoryExecutor(responses: ["us-east-1/describe-instances": "{\"Reservations\":[]}"])
        let report = try await AWSHostInventory(executor: runner).hosts(preferences: preferences)
        #expect(report.hosts.isEmpty)
        #expect(runner.calls.count == 1)
    }

    @Test func missingMetadataRemainsUnknownAndDuplicateIdentitiesAreCoalesced() async throws {
        let host = instance("i-a")
        let runner = InventoryExecutor(responses: [
            "us-east-1/describe-instances": try instances([host, host]),
            "us-east-1/describe-instance-types": "{\"InstanceTypes\":[]}"
        ])
        let report = try await AWSHostInventory(executor: runner).hosts(preferences: preferences)
        #expect(report.hosts.count == 1)
        #expect(report.hosts.first?.cpus == nil)
        #expect(report.hosts.first?.memoryMiB == nil)
    }

    @Test(arguments: ["instances", "instance-types"])
    func rejectsTruncatedInventoryAndMetadata(operation: String) async throws {
        let runner = InventoryExecutor(responses: [
            "us-east-1/describe-instances": operation == "instances" ? "{\"Reservations\":[],\"NextToken\":\"more\"}" : try instances([instance("i-a")]),
            "us-east-1/describe-instance-types": "{\"InstanceTypes\":[],\"NextToken\":\"more\"}"
        ])
        await #expect(throws: ProviderError.self) {
            _ = try await AWSHostInventory(executor: runner).hosts(preferences: preferences)
        }
    }

    @Test func regionalFailureDoesNotReturnAPartialInventory() async throws {
        let runner = InventoryExecutor(responses: ["us-east-1/describe-instances": "{\"Reservations\":[]}"])
        await #expect(throws: ProviderError.self) {
            _ = try await AWSHostInventory(executor: runner).hosts(preferences: .init(profile: "dev account", regions: ["us-east-1", "us-west-2"]))
        }
        #expect(runner.calls.count == 2)
    }

    @Test func largeFleetsBatchMetadataRequestsAtOneHundredTypes() async throws {
        let types = (0..<205).map { "m\($0)g.xlarge" }
        let runner = InventoryExecutor(responses: [
            "us-east-1/describe-instances": try instances(types.enumerated().map { instance("i-\($0.offset)", type: $0.element) }),
            "us-east-1/describe-instance-types": try metadata(types)
        ])
        let report = try await AWSHostInventory(executor: runner).hosts(preferences: preferences)
        #expect(report.hosts.count == 205)
        let calls = runner.calls.filter { $0.args[1] == "describe-instance-types" }
        #expect(calls.count == 3)
        #expect(calls.map { $0.args[3].split(separator: ",").count - 1 } == [100, 100, 5])
    }

    @Test func missingProfileOrRegionFailsBeforeInvokingAWS() async throws {
        let runner = InventoryExecutor(responses: [:])
        for value in [AWSProviderPreferences(profile: "dev"), AWSProviderPreferences(regions: ["us-east-1"])] {
            await #expect(throws: ProviderError.self) {
                _ = try await AWSHostInventory(executor: runner).hosts(preferences: value)
            }
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func conflictingDuplicateInstancesFailInsteadOfSelectingAnArbitraryState() async throws {
        let runner = InventoryExecutor(responses: [
            "us-east-1/describe-instances": try instances([instance("i-a"), instance("i-a", state: "stopped")]),
            "us-east-1/describe-instance-types": try metadata(["t4g.xlarge"])
        ])
        await #expect(throws: ProviderError.self) {
            _ = try await AWSHostInventory(executor: runner).hosts(preferences: preferences)
        }
    }

    @Test func incompleteCPUOptionsDoNotFallBackToTheInstanceTypeCapacity() async throws {
        let runner = InventoryExecutor(responses: [
            "us-east-1/describe-instances": try instances([
                instance("i-a", extra: ["CpuOptions": ["CoreCount": 1]]),
                instance("i-b", extra: ["CpuOptions": ["CoreCount": 0, "ThreadsPerCore": 2]])
            ]),
            "us-east-1/describe-instance-types": try metadata(["t4g.xlarge"])
        ])
        let report = try await AWSHostInventory(executor: runner).hosts(preferences: preferences)
        #expect(report.hosts.count == 2)
        #expect(report.hosts.allSatisfy { $0.cpus == nil && $0.memoryMiB == 16384 })
    }

    private var preferences: AWSProviderPreferences { .init(profile: "dev account", regions: ["us-east-1"]) }

    private func instance(_ id: String, type: String = "t4g.xlarge", state: String = "running", tagged: Bool = true, extra: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["InstanceId": id, "InstanceType": type, "State": ["Name": state], "Architecture": "arm64", "Placement": ["AvailabilityZone": "us-east-1a"], "PrivateIpAddress": "10.0.0.1"]
        value["Tags"] = tagged ? [["Key": "graftty:managed", "Value": "true"], ["Key": "Name", "Value": "dev"]] : []
        value.merge(extra) { _, new in new }
        return value
    }

    private func instances(_ instances: [[String: Any]], account: String = "111111111111") throws -> String {
        try json(["Reservations": [["OwnerId": account, "Instances": instances]]])
    }

    private func metadata(_ types: [String]) throws -> String {
        try json(["InstanceTypes": types.map { ["InstanceType": $0, "VCpuInfo": ["DefaultVCpus": 4], "MemoryInfo": ["SizeInMiB": 16384], "ProcessorInfo": ["SupportedArchitectures": ["arm64"]], "SupportedUsageClasses": ["spot"], "BurstablePerformanceSupported": $0.hasPrefix("t")] as [String: Any] }])
    }

    private func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
}

private final class InventoryExecutor: CLIExecutor, @unchecked Sendable {
    struct Call { let args: [String]; let timeout: Duration? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    let responses: [String: String]
    init(responses: [String: String]) { self.responses = responses }
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: nil)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
    func run(command: String, args: [String], at directory: String, timeout: Duration?) async throws -> CLIOutput {
        record(.init(args: args, timeout: timeout))
        #expect(command == "aws")
        let regionIndex = try #require(args.firstIndex(of: "--region"))
        let key = args[regionIndex + 1] + "/" + args[1]
        guard let response = responses[key] else { throw CLIError.nonZeroExit(command: "aws", exitCode: 255, stderr: "Unavailable region") }
        return .init(stdout: response, stderr: "", exitCode: 0)
    }
    private func record(_ call: Call) { lock.lock(); defer { lock.unlock() }; recorded.append(call) }
}
