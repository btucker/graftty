import Foundation
import Testing
@testable import GrafttyKit

struct AWSProviderTests {
    @Test func corruptAndFutureConfigurationAreNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("aws.json")
        let store = AWSProviderStore(directory: root)
        for data in [Data("broken".utf8), try JSONEncoder().encode(AWSProviderPreferences(version: 99))] {
            try data.write(to: file)
            #expect(throws: (any Error).self) { _ = try store.update { $0.profile = "new" } }
            #expect(try Data(contentsOf: file) == data)
        }
    }

    @Test func concurrentUpdatesKeepBothChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AWSProviderStore(directory: root)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try store.update { $0.profile = "work" } }
            group.addTask { _ = try store.update { $0.regions = ["us-east-1"] } }
            try await group.waitForAll()
        }
        #expect(try store.load()?.profile == "work")
        #expect(try store.load()?.regions == ["us-east-1"])
    }

    @Test("@spec REMOTE-31.10: When querying AWS Spot offers, the CLI shall compare the latest effective Linux prices for the configured pool by region and Availability Zone, filter architecture and resource requirements, use the preferred type only to break equal-price ties, and distinguish observed prices from verified capacity.")
    func comparesEligibleOffersUsingFreshObservationOfEffectivePrices() async throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let runner = AWSFixtureExecutor(prices: """
        {"SpotPriceHistory":[
          {"InstanceType":"t4g.xlarge","AvailabilityZone":"us-east-1a","SpotPrice":"0.050000","Timestamp":"2024-01-01T00:00:00Z","ProductDescription":"Linux/UNIX"},
          {"InstanceType":"t4g.xlarge","AvailabilityZone":"us-east-1a","SpotPrice":"0.100000","Timestamp":"2023-01-01T00:00:00.000Z","ProductDescription":"Linux/UNIX"},
          {"InstanceType":"m7g.xlarge","AvailabilityZone":"us-east-1b","SpotPrice":"0.050000","Timestamp":"2024-02-01T00:00:00Z","ProductDescription":"Linux/UNIX"},
          {"InstanceType":"m7g.xlarge","AvailabilityZone":"us-east-1c","SpotPrice":"0.040000","Timestamp":"2024-02-01T00:00:00Z","ProductDescription":"Linux/UNIX"},
          {"InstanceType":"m7i.xlarge","AvailabilityZone":"us-east-1a","SpotPrice":"0.010000","Timestamp":"2024-01-01T00:00:00Z","ProductDescription":"Linux/UNIX"},
          {"InstanceType":"t4g.xlarge","AvailabilityZone":"us-east-1d","SpotPrice":"0.001000","Timestamp":"2099-01-01T00:00:00Z","ProductDescription":"Linux/UNIX"}
        ]}
        """)
        let preferences = AWSProviderPreferences(profile: "work", regions: ["us-east-1"],
            instanceTypes: ["t4g.xlarge", "m7g.xlarge", "m7i.xlarge"], preferredInstanceType: "t4g.xlarge")
        let report = try await AWSProviderDiscovery(executor: runner).offers(
            preferences: preferences, requirements: .init(architecture: "arm64", minCPUs: 4, minMemoryMiB: 16384), at: now)
        #expect(report.offers.map(\.instanceType) == ["m7g.xlarge", "t4g.xlarge", "m7g.xlarge"])
        #expect(report.offers.first?.hourlyUSD == Decimal(string: "0.04"))
        #expect(report.offers[1].burstable)
        #expect(report.offers.allSatisfy { $0.observedAt == now && !$0.capacityVerified })
        #expect(report.unpricedInstanceTypes.isEmpty)
        #expect(report.excludedInstanceTypes == ["m7i.xlarge"])
        #expect(runner.calls.count == 2)
        #expect(runner.calls.allSatisfy { $0.command == "aws" && $0.timeout != nil })
        #expect(runner.calls.allSatisfy { $0.args.contains("--profile") && $0.args.contains("work") && $0.args.contains("--no-cli-auto-prompt") })
        #expect(runner.calls.last?.args.contains("--start-time") == true)
        #expect(runner.calls.allSatisfy { !$0.args.contains("--no-paginate") })
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        let encodedOffers = try #require(encoded?["offers"] as? [[String: Any]])
        #expect(encodedOffers.count == 3)
        #expect(encodedOffers.allSatisfy { ($0["capacityVerified"] as? Bool) == false })
    }

    @Test func filtersZonesAndBudgetAndReportsMissingPrices() async throws {
        let preferences = AWSProviderPreferences(profile: "work", regions: ["us-east-1"],
            instanceTypes: ["t4g.xlarge", "m7g.xlarge"], availabilityZones: ["us-east-1b"],
            maxHourlyUSD: Decimal(string: "0.06"))
        let runner = AWSFixtureExecutor(prices: """
        {"SpotPriceHistory":[
          {"InstanceType":"t4g.xlarge","AvailabilityZone":"us-east-1a","SpotPrice":"0.01","Timestamp":"2024-01-01T00:00:00Z","ProductDescription":"Linux/UNIX"},
          {"InstanceType":"m7g.xlarge","AvailabilityZone":"us-east-1b","SpotPrice":"0.07","Timestamp":"2024-01-01T00:00:00Z","ProductDescription":"Linux/UNIX"}
        ]}
        """)
        let report = try await AWSProviderDiscovery(executor: runner).offers(preferences: preferences, requirements: .init(architecture: "arm64"))
        #expect(report.offers.isEmpty)
        #expect(report.unpricedInstanceTypes == ["t4g.xlarge"])
        #expect(report.overBudgetOfferCount == 1)
    }

    @Test(arguments: ["NaN", "-1", "0", "1oops"])
    func rejectsInvalidPrices(price: String) async throws {
        let runner = AWSFixtureExecutor(prices: """
        {"SpotPriceHistory":[{"InstanceType":"t4g.xlarge","AvailabilityZone":"us-east-1a","SpotPrice":"\(price)","Timestamp":"2024-01-01T00:00:00Z","ProductDescription":"Linux/UNIX"}]}
        """)
        await #expect(throws: (any Error).self) {
            _ = try await AWSProviderDiscovery(executor: runner).offers(preferences: .init(profile: "work", regions: ["us-east-1"], instanceTypes: ["t4g.xlarge"]), requirements: .init(architecture: "arm64"))
        }
    }

    @Test func refusesIncompletePagination() async throws {
        let runner = AWSFixtureExecutor(prices: """
        {"SpotPriceHistory":[],"NextToken":"more"}
        """)
        await #expect(throws: (any Error).self) {
            _ = try await AWSProviderDiscovery(executor: runner).offers(preferences: .init(profile: "work", regions: ["us-east-1"], instanceTypes: ["t4g.xlarge"]), requirements: .init(architecture: "arm64"))
        }
    }

    @Test func incompleteConfigurationDoesNotInvokeAWS() async throws {
        let runner = AWSFixtureExecutor(prices: "{}")
        await #expect(throws: (any Error).self) {
            _ = try await AWSProviderDiscovery(executor: runner).offers(preferences: .init(), requirements: .init(architecture: "arm64"))
        }
        #expect(runner.calls.isEmpty)
    }

    @Test(arguments: [AWSOfferRequirements(architecture: "arm64", minCPUs: 8),
                      AWSOfferRequirements(architecture: "arm64", minMemoryMiB: 32768)])
    func resourceMismatchSkipsPriceQuery(requirements: AWSOfferRequirements) async throws {
        let runner = AWSFixtureExecutor(prices: "{}")
        let report = try await AWSProviderDiscovery(executor: runner).offers(
            preferences: .init(profile: "work", regions: ["us-east-1"], instanceTypes: ["t4g.xlarge"]), requirements: requirements)
        #expect(report.offers.isEmpty)
        #expect(report.excludedInstanceTypes == ["t4g.xlarge"])
        #expect(runner.calls.count == 1)
    }

    @Test(arguments: [CLIError.notFound(command: "aws"),
                      CLIError.nonZeroExit(command: "aws", exitCode: 255, stderr: "ExpiredToken")])
    func awsFailuresProduceActionableErrors(error: CLIError) async throws {
        let runner = AWSFixtureExecutor(prices: "{}", failure: error)
        do {
            _ = try await AWSProviderDiscovery(executor: runner).offers(
                preferences: .init(profile: "work", regions: ["us-east-1"], instanceTypes: ["t4g.xlarge"]), requirements: .init(architecture: "arm64"))
            Issue.record("Expected discovery to fail")
        } catch let failure as ProviderError {
            #expect(failure.description.contains(error == .notFound(command: "aws") ? "Install the AWS CLI" : "ExpiredToken"))
        }
        #expect(runner.calls.count == 1)
    }
}

private final class AWSFixtureExecutor: CLIExecutor, @unchecked Sendable {
    struct Call { var command: String; var args: [String]; var timeout: Duration? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    let prices: String
    let failure: CLIError?
    init(prices: String, failure: CLIError? = nil) { self.prices = prices; self.failure = failure }
    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: nil)
    }
    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory)
    }
    func run(command: String, args: [String], at directory: String, timeout: Duration?) async throws -> CLIOutput {
        record(.init(command: command, args: args, timeout: timeout))
        if let failure { throw failure }
        if args.contains("describe-instance-types") {
            let types = ["t4g.xlarge", "m7g.xlarge", "m7i.xlarge"].map { type in
                """
                {"InstanceType":"\(type)","VCpuInfo":{"DefaultVCpus":4},"MemoryInfo":{"SizeInMiB":16384},"ProcessorInfo":{"SupportedArchitectures":["\(type == "m7i.xlarge" ? "x86_64" : "arm64")"]},"SupportedUsageClasses":["spot","on-demand"],"BurstablePerformanceSupported":\(type == "t4g.xlarge")}
                """
            }.joined(separator: ",")
            return .init(stdout: "{\"InstanceTypes\":[\(types)]}", stderr: "", exitCode: 0)
        }
        #expect(args.contains("describe-spot-price-history"))
        return .init(stdout: prices, stderr: "", exitCode: 0)
    }
    private func record(_ call: Call) { lock.lock(); defer { lock.unlock() }; recorded.append(call) }
}
