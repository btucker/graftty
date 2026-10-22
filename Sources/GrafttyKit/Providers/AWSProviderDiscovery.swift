import Foundation
import GrafttyProtocol

public struct AWSOfferRequirements: Codable, Equatable, Sendable {
    public var architecture: String
    public var minCPUs: Int
    public var minMemoryMiB: Int
    public init(architecture: String, minCPUs: Int = 1, minMemoryMiB: Int = 1) {
        self.architecture = architecture
        self.minCPUs = minCPUs
        self.minMemoryMiB = minMemoryMiB
    }
    public func validate() throws {
        guard ["arm64", "x86_64"].contains(architecture), minCPUs > 0, minMemoryMiB > 0 else {
            throw ProviderError("Select arm64 or x86_64 and positive CPU and memory requirements.")
        }
    }
}

public struct AWSSpotOffer: Encodable, Equatable, Sendable {
    public let region: String
    public let availabilityZone: String
    public let instanceType: String
    public let architecture: String
    public let cpus: Int
    public let memoryMiB: Int
    public let hourlyUSD: Decimal
    /// The effective rate may have remained unchanged for months.
    public let priceEffectiveAt: Date
    /// Freshness refers to the query, not the last change in the rate.
    public let observedAt: Date
    public let burstable: Bool
    public let preferred: Bool
    public let capacityVerified = false

}

public struct AWSOfferReport: Encodable, Sendable {
    public let provider = "aws"
    public let preferences: AWSProviderPreferences
    public let requirements: AWSOfferRequirements
    public let offers: [AWSSpotOffer]
    public let excludedInstanceTypes: [String]
    public let unpricedInstanceTypes: [String]
    public let overBudgetOfferCount: Int
    public let observationsStartedAt: Date
    public let limitations = [
        "Prices do not verify available Spot capacity or existing host load.",
        "Hourly rates exclude storage, network charges, and surplus CPU credit charges.",
        "The hourly limit filters individual offers; this query does not account for an existing fleet's spend.",
        "Preferred instance type breaks equal-price ties. No instances are launched."
    ]
}

public struct AWSProviderDiscovery: Sendable {
    private let executor: any CLIExecutor
    public init(executor: any CLIExecutor = CLIRunner()) { self.executor = executor }

    public func offers(preferences: AWSProviderPreferences, requirements: AWSOfferRequirements,
                       at now: Date = Date()) async throws -> AWSOfferReport {
        try preferences.validateForDiscovery()
        try requirements.validate()
        let profile = preferences.profile!
        var offers: [AWSSpotOffer] = []
        var compatible = Set<String>()
        var priced = Set<String>()
        var overBudget = 0
        let date = ISO8601DateFormatter().string(from: now)
        for region in preferences.regions {
            try Task.checkCancellation()
            let common = ["--profile", profile, "--region", region, "--output", "json",
                          "--no-cli-pager", "--no-cli-auto-prompt", "--cli-connect-timeout", "10", "--cli-read-timeout", "20"]
            let types: InstanceTypesResponse = try await query(
                ["ec2", "describe-instance-types", "--filters", "Name=instance-type,Values=" + preferences.instanceTypes.joined(separator: ",")] + common)
            try requireComplete(types.NextToken)
            var metadata: [String: InstanceType] = [:]
            for type in types.InstanceTypes where preferences.instanceTypes.contains(type.InstanceType) {
                guard type.ProcessorInfo.SupportedArchitectures.contains(requirements.architecture),
                      type.SupportedUsageClasses.contains("spot"),
                      type.VCpuInfo.DefaultVCpus >= requirements.minCPUs,
                      type.MemoryInfo.SizeInMiB >= requirements.minMemoryMiB else { continue }
                metadata[type.InstanceType] = type
                compatible.insert(type.InstanceType)
            }
            guard !metadata.isEmpty else { continue }
            let prices: PricesResponse = try await query(
                ["ec2", "describe-spot-price-history", "--instance-types"] + metadata.keys.sorted()
                + ["--product-descriptions", "Linux/UNIX", "--start-time", date, "--end-time", date] + common)
            try requireComplete(prices.NextToken)
            var latest: [String: AWSSpotOffer] = [:]
            for price in prices.SpotPriceHistory {
                guard let type = metadata[price.InstanceType], price.ProductDescription == "Linux/UNIX",
                      preferences.availabilityZones.isEmpty || preferences.availabilityZones.contains(price.AvailabilityZone) else { continue }
                guard price.AvailabilityZone.hasPrefix(region), let effective = Self.parseDate(price.Timestamp) else {
                    throw ProviderError("AWS returned an invalid Spot price location or timestamp in \(region).")
                }
                guard effective <= now else { continue }
                let amount = try AWSProviderPreferences.positiveAmount(price.SpotPrice)
                let offer = AWSSpotOffer(region: region, availabilityZone: price.AvailabilityZone,
                    instanceType: price.InstanceType, architecture: requirements.architecture,
                    cpus: type.VCpuInfo.DefaultVCpus, memoryMiB: type.MemoryInfo.SizeInMiB,
                    hourlyUSD: amount, priceEffectiveAt: effective, observedAt: now,
                    burstable: type.BurstablePerformanceSupported,
                    preferred: price.InstanceType == preferences.preferredInstanceType)
                let key = price.InstanceType + "/" + price.AvailabilityZone
                if latest[key].map({ $0.priceEffectiveAt < effective }) ?? true { latest[key] = offer }
            }
            for offer in latest.values {
                priced.insert(offer.instanceType)
                if let limit = preferences.maxHourlyUSD, offer.hourlyUSD > limit { overBudget += 1 }
                else { offers.append(offer) }
            }
        }
        offers.sort {
            if $0.hourlyUSD != $1.hourlyUSD { return $0.hourlyUSD < $1.hourlyUSD }
            if $0.preferred != $1.preferred { return $0.preferred }
            return ($0.region, $0.instanceType, $0.availabilityZone) < ($1.region, $1.instanceType, $1.availabilityZone)
        }
        return AWSOfferReport(preferences: preferences, requirements: requirements, offers: offers,
            excludedInstanceTypes: Set(preferences.instanceTypes).subtracting(compatible).sorted(),
            unpricedInstanceTypes: compatible.subtracting(priced).sorted(), overBudgetOfferCount: overBudget,
            observationsStartedAt: now)
    }

    private func query<T: Decodable>(_ args: [String]) async throws -> T {
        try Task.checkCancellation()
        let output: CLIOutput
        do {
            output = try await executor.run(command: "aws", args: args, at: NSHomeDirectory(), timeout: .seconds(45))
        } catch CLIError.notFound {
            throw ProviderError("Install the AWS CLI v2 and configure your profile before querying offers.")
        } catch CLIError.nonZeroExit(_, _, let stderr) {
            throw ProviderError("AWS discovery failed: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        try Task.checkCancellation()
        do { return try JSONDecoder().decode(T.self, from: Data(output.stdout.utf8)) }
        catch { throw ProviderError("AWS returned an unsupported or incomplete JSON response: \(error)") }
    }

    private func requireComplete(_ nextToken: String?) throws {
        guard nextToken?.isEmpty != false else {
            throw ProviderError("AWS returned incomplete paginated results; no offer ranking was produced.")
        }
    }

    private static func parseDate(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }
}

private struct InstanceTypesResponse: Decodable { let InstanceTypes: [InstanceType]; let NextToken: String? }
private struct InstanceType: Decodable {
    let InstanceType: String
    let VCpuInfo: CPUs
    let MemoryInfo: Memory
    let ProcessorInfo: Processor
    let SupportedUsageClasses: [String]
    let BurstablePerformanceSupported: Bool
    struct CPUs: Decodable { let DefaultVCpus: Int }
    struct Memory: Decodable { let SizeInMiB: Int }
    struct Processor: Decodable { let SupportedArchitectures: [String] }
}
private struct PricesResponse: Decodable { let SpotPriceHistory: [Price]; let NextToken: String? }
private struct Price: Decodable {
    let InstanceType: String
    let AvailabilityZone: String
    let SpotPrice: String
    let Timestamp: String
    let ProductDescription: String
}
