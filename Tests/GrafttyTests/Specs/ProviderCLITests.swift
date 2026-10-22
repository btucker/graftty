import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit
import GrafttyProtocol

struct ProviderCLITests {
    @Test("@spec REMOTE-24.18: When an agent creates or queries a remote placement, the CLI shall require a stable operation UUID and an unambiguous connected paired host and send its pinned identity with the request.")
    func placementCommandsRequireStableOperationIdentity() throws {
        let id = UUID().uuidString
        _ = try GrafttyCLI.parseAsRoot(["remote", "placement", "create", "--host", "linux", "--operation-id", id,
            "--repository", "/project", "--name", "task", "--architecture", "arm64", "--json"])
        _ = try GrafttyCLI.parseAsRoot(["remote", "placement", "status", "--host", "linux", "--operation-id", id, "--json"])
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["remote", "placement", "status", "--host", "linux", "--operation-id", "bad"]) }
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["remote", "placement", "create", "--host", "linux", "--repository", "/project", "--name", "task", "--architecture", "arm64"]) }
    }

    @Test func containerPlacementRequiresExplicitOptIn() throws {
        let args = ["remote", "placement", "create", "--host", "linux", "--operation-id", UUID().uuidString,
            "--repository", "/project", "--name", "task", "--architecture", "arm64"]
        _ = try GrafttyCLI.parseAsRoot(args + ["--dev-container", "--dev-container-config", ".devcontainer/custom/devcontainer.json"])
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(args + ["--dev-container-config", ".devcontainer/devcontainer.json"]) }
    }

    @Test func placementTargetPinsFingerprintAndRejectsAmbiguityAndOfflineHosts() throws {
        let fingerprint = try RemoteIdentityFingerprint(rawBytes: Data(repeating: 3, count: 32))
        func host(_ id: String, state: RemoteMacConnectionSummary.State = .connected) -> RemoteMacConnectionSummary {
            .init(deviceID: .init(value: id), fingerprint: fingerprint, label: "linux", lastKnownHost: nil, state: state)
        }
        let selected = try RemotePlacementTarget.resolve("one", hosts: [host("one"), host("two")])
        #expect(selected == host("one").id)
        #expect(throws: (any Error).self) { try RemotePlacementTarget.resolve("linux", hosts: [host("one"), host("two")]) }
        #expect(throws: (any Error).self) { try RemotePlacementTarget.resolve("one", hosts: [host("one", state: .offline)]) }
        let request = NotificationMessage.remotePlacement(host: selected, request: .status(operationID: UUID()))
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(request)) == request)
    }

    @Test func placementPlanCommandIsRegistered() throws {
        _ = try GrafttyCLI.parseAsRoot(["remote", "plan", "--architecture", "arm64", "--cpus", "2", "--memory-mib", "4096", "--disk-mib", "8192", "--json"])
    }

    @Test func authenticatedHostListCommandIsRegistered() throws {
        let command = try #require(GrafttyCLI.parseAsRoot(["remote", "hosts", "--json"]) as? RemoteHosts)
        #expect(command.json)
    }

    @Test func hostInventoryCommandIsRegistered() throws {
        let tagged = try #require(GrafttyCLI.parseAsRoot(["provider", "hosts", "aws", "--json"]) as? ProviderHosts)
        #expect(tagged.json && !tagged.all)
        let all = try #require(GrafttyCLI.parseAsRoot(["provider", "hosts", "aws", "--all"]) as? ProviderHosts)
        #expect(all.all && !all.json)
        #expect(throws: (any Error).self) { _ = try GrafttyCLI.parseAsRoot(["provider", "hosts", "aws-dev"]) }
    }

    @Test func providerCommandsAreRegistered() throws {
        _ = try GrafttyCLI.parseAsRoot([
            "provider", "configure", "aws", "--profile", "development", "--region", "us-east-1",
            "--instance-types", "t4g.large,t4g.xlarge", "--preferred-instance-type", "t4g.xlarge"
        ])
        _ = try GrafttyCLI.parseAsRoot(["provider", "show", "aws", "--json"])
        _ = try GrafttyCLI.parseAsRoot(["provider", "offers", "aws", "--architecture", "arm64", "--json"])
    }

    @Test("@spec REMOTE-24.1: When a user configures the aws compute provider, the CLI shall persist the selected existing AWS profile and placement preferences without copying AWS credentials.")
    func savesProfileReferenceAndPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AWSProviderStore(directory: root)
        let command = try #require(GrafttyCLI.parseAsRoot([
            "provider", "configure", "aws", "--profile", "development account",
            "--region", "us-east-1,us-west-2", "--instance-types", "t4g.large,t4g.xlarge",
            "--preferred-instance-type", "t4g.xlarge", "--market", "spot",
            "--max-instances", "3", "--max-hourly-usd", "0.50"
        ]) as? ProviderConfigure)
        let saved = try command.apply(to: store)
        #expect(try store.load() == saved)
        #expect(saved.profile == "development account")
        #expect(saved.regions == ["us-east-1", "us-west-2"])
        #expect(saved.instanceTypes == ["t4g.large", "t4g.xlarge"])
        #expect(saved.maxInstances == 3)
        #expect(saved.maxHourlyUSD == Decimal(string: "0.50"))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["aws.json", "aws.lock"])
        let json = try String(contentsOf: root.appendingPathComponent("aws.json"), encoding: .utf8)
        #expect(!json.contains("secretAccessKey"))
        #expect(!json.contains("accessKeyId"))
    }

    @Test("@spec REMOTE-24.2: When a user configures an instance pool or preferred instance type, the CLI shall persist, display, update, and clear those per-user settings without hard-coding a universal preferred instance type.")
    func updatesAndClearsWithoutResettingOtherSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AWSProviderStore(directory: root)
        #expect(try store.load() == nil)
        #expect(AWSProviderPreferences().preferredInstanceType == nil)
        #expect(AWSProviderPreferences().instanceTypes.isEmpty)
        let initial = try ProviderConfigure.parse([
            "aws", "--profile", "work", "--region", "us-east-1",
            "--instance-types", "m7g.large,t4g.xlarge", "--preferred-instance-type", "m7g.large"
        ])
        _ = try initial.apply(to: store)
        let updated = try ProviderConfigure.parse(["aws", "--preferred-instance-type", "t4g.xlarge"]).apply(to: store)
        #expect(updated.profile == "work")
        let show = try ProviderShow.parse(["aws", "--json"])
        #expect(try show.preferences(in: store) == updated)
        let cleared = try ProviderConfigure.parse(["aws", "--clear", "preferred-instance-type,instance-types"]).apply(to: store)
        #expect(cleared.preferredInstanceType == nil)
        #expect(cleared.instanceTypes.isEmpty)
        #expect(cleared.regions == ["us-east-1"])
        #expect(cleared.profile == "work")
        try ProviderRemove.parse(["aws"]).remove(from: store)
        #expect(try store.load() == nil)
    }

    @Test(arguments: [
        ["aws-dev", "--profile", "work"], ["aws", "--instance-types", ""],
        ["aws", "--instance-types", "t4g.xlarge,"], ["aws", "--max-instances", "0"],
        ["aws", "--max-hourly-usd", "NaN"], ["aws", "--max-hourly-usd", "-1"],
        ["aws", "--clear", "credentials"], ["aws", "--profile", "x", "--clear", "profile"],
        ["aws", "--market", "on-demand"], ["aws"]
    ])
    func rejectsInvalidConfiguration(arguments: [String]) {
        #expect(throws: (any Error).self) { _ = try ProviderConfigure.parse(arguments) }
    }

    @Test func invalidUpdateLeavesPreviousFileUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AWSProviderStore(directory: root)
        let old = try ProviderConfigure.parse(["aws", "--instance-types", "t4g.xlarge", "--preferred-instance-type", "t4g.xlarge"]).apply(to: store)
        let invalid = try ProviderConfigure.parse(["aws", "--instance-types", "m7g.large"])
        #expect(throws: (any Error).self) { _ = try invalid.apply(to: store) }
        #expect(try store.load() == old)
    }
}
