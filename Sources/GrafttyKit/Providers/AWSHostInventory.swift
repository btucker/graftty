import Foundation

/// EC2 observations describe machines, not authenticated Graftty connections.
public struct AWSHostInventoryEntry: Encodable, Equatable, Sendable {
    public var identity: String { "aws/\(accountID)/\(region)/\(instanceID)" }
    public let accountID: String
    public let region: String
    public let instanceID: String
    public let name: String?
    public let instanceType: String?
    public let architecture: String?
    public let availabilityZone: String?
    public let state: String
    public let market: String
    public let grafttyTagged: Bool
    public let privateIPAddress: String?
    public let publicIPAddress: String?
    public let cpus: Int?
    public let memoryMiB: Int?
    public let observedAt: Date

    // Only authenticated host telemetry can populate these in a later phase.
    // Encode explicit nulls so consumers cannot mistake missing samples for zero.
    public let readiness = "unknown"
    public let cpuUtilization: Double? = nil
    public let availableMemoryMiB: Int? = nil
    public let freeDiskBytes: Int64? = nil
    public let pendingPlacements: Int? = nil
    public let telemetryObservedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case identity, accountID, region, instanceID, name, instanceType, architecture, availabilityZone
        case state, market, grafttyTagged, privateIPAddress, publicIPAddress, cpus, memoryMiB, observedAt
        case readiness, cpuUtilization, availableMemoryMiB, freeDiskBytes, pendingPlacements, telemetryObservedAt
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity)
        try c.encode(accountID, forKey: .accountID)
        try c.encode(region, forKey: .region)
        try c.encode(instanceID, forKey: .instanceID)
        try c.encode(name, forKey: .name)
        try c.encode(instanceType, forKey: .instanceType)
        try c.encode(architecture, forKey: .architecture)
        try c.encode(availabilityZone, forKey: .availabilityZone)
        try c.encode(state, forKey: .state)
        try c.encode(market, forKey: .market)
        try c.encode(grafttyTagged, forKey: .grafttyTagged)
        try c.encode(privateIPAddress, forKey: .privateIPAddress)
        try c.encode(publicIPAddress, forKey: .publicIPAddress)
        try c.encode(cpus, forKey: .cpus)
        try c.encode(memoryMiB, forKey: .memoryMiB)
        try c.encode(observedAt, forKey: .observedAt)
        try c.encode(readiness, forKey: .readiness)
        try c.encode(cpuUtilization, forKey: .cpuUtilization)
        try c.encode(availableMemoryMiB, forKey: .availableMemoryMiB)
        try c.encode(freeDiskBytes, forKey: .freeDiskBytes)
        try c.encode(pendingPlacements, forKey: .pendingPlacements)
        try c.encode(telemetryObservedAt, forKey: .telemetryObservedAt)
    }
}

public struct AWSHostInventoryReport: Encodable, Sendable {
    public let provider = "aws"
    public let preferences: AWSProviderPreferences
    public let includesUntagged: Bool
    public let hosts: [AWSHostInventoryEntry]
    public let observationsStartedAt: Date
    public let limitations = [
        "EC2 state and tags do not verify Graftty identity, connectivity, or project readiness.",
        "Host utilization, available memory, free disk, and pending placements are unknown until authenticated telemetry is available.",
        "Inventory covers configured regions, including stopped and recently terminated instances; instance pools and placement zones do not filter existing hosts.",
        "AWS inventory is eventually consistent. An empty result is not proof of available capacity or permission to launch."
    ]
}

public struct AWSHostInventory: Sendable {
    private let client: AWSReadOnlyClient
    public init(executor: any CLIExecutor = CLIRunner()) { self.client = AWSReadOnlyClient(executor: executor) }

    public func hosts(preferences: AWSProviderPreferences, includeUntagged: Bool = false,
                      at now: Date = Date()) async throws -> AWSHostInventoryReport {
        try preferences.validateForInventory()
        let profile = preferences.profile!
        var hosts: [String: AWSHostInventoryEntry] = [:]
        for region in preferences.regions {
            let response: InstancesResponse = try await client.query(.instances,
                arguments: includeUntagged ? [] : ["--filters", "Name=tag:graftty:managed,Values=true"], profile: profile, region: region)
            let instances = response.Reservations.flatMap { reservation in
                reservation.Instances.filter { includeUntagged || $0.grafttyTagged }.map { (reservation.OwnerId, $0) }
            }
            // Inventory must include types that were removed from the user's placement pool.
            let types = Set(instances.compactMap { $0.1.InstanceType }).sorted()
            var metadata: [String: AWSInstanceType] = [:]
            for offset in stride(from: 0, to: types.count, by: 100) {
                let batch = types[offset..<min(offset + 100, types.count)]
                let response: AWSInstanceTypesResponse = try await client.query(.instanceTypes,
                    arguments: ["--filters", "Name=instance-type,Values=" + batch.joined(separator: ",")], profile: profile, region: region)
                for type in response.InstanceTypes where batch.contains(type.InstanceType) { metadata[type.InstanceType] = type }
            }
            for (account, instance) in instances {
                guard !account.isEmpty, !instance.InstanceId.isEmpty, !instance.State.Name.isEmpty else {
                    throw ProviderError("AWS returned an instance without an account, identity, or lifecycle state.")
                }
                let hardware = instance.InstanceType.flatMap { metadata[$0] }
                let memory = hardware?.MemoryInfo.SizeInMiB
                let host = AWSHostInventoryEntry(accountID: account, region: region, instanceID: instance.InstanceId,
                    name: instance.Tags?.first(where: { $0.Key == "Name" })?.Value,
                    instanceType: instance.InstanceType, architecture: instance.Architecture,
                    availabilityZone: instance.Placement?.AvailabilityZone, state: instance.State.Name,
                    market: instance.InstanceLifecycle ?? "on-demand", grafttyTagged: instance.grafttyTagged,
                    privateIPAddress: instance.PrivateIpAddress, publicIPAddress: instance.PublicIpAddress,
                    cpus: instance.cpuCount(defaultCount: hardware?.VCpuInfo.DefaultVCpus),
                    memoryMiB: memory.flatMap { $0 > 0 ? $0 : nil }, observedAt: now)
                if let existing = hosts[host.identity], existing != host {
                    throw ProviderError("AWS returned conflicting observations for \(host.identity); retry discovery.")
                }
                hosts[host.identity] = host
            }
        }
        return AWSHostInventoryReport(preferences: preferences, includesUntagged: includeUntagged,
            hosts: hosts.values.sorted { ($0.region, $0.accountID, $0.instanceID) < ($1.region, $1.accountID, $1.instanceID) },
            observationsStartedAt: now)
    }
}

private struct InstancesResponse: AWSPaginatedResponse {
    let Reservations: [Reservation]
    let NextToken: String?
    struct Reservation: Decodable {
        let OwnerId: String
        let Instances: [Instance]
    }
}

private struct Instance: Decodable {
    let InstanceId: String
    let InstanceType: String?
    let State: StateInfo
    let Architecture: String?
    let Placement: PlacementInfo?
    let InstanceLifecycle: String?
    let PrivateIpAddress: String?
    let PublicIpAddress: String?
    let CpuOptions: CPUOptions?
    let Tags: [Tag]?
    var grafttyTagged: Bool { Tags?.contains { $0.Key == "graftty:managed" && $0.Value == "true" } == true }
    struct StateInfo: Decodable { let Name: String }
    struct PlacementInfo: Decodable { let AvailabilityZone: String? }
    struct CPUOptions: Decodable { let CoreCount: Int?; let ThreadsPerCore: Int? }
    struct Tag: Decodable { let Key: String?; let Value: String? }

    func cpuCount(defaultCount: Int?) -> Int? {
        guard let options = CpuOptions else { return defaultCount.flatMap { $0 > 0 ? $0 : nil } }
        guard let cores = options.CoreCount, let threads = options.ThreadsPerCore, cores > 0, threads > 0 else { return nil }
        let (count, overflow) = cores.multipliedReportingOverflow(by: threads)
        return overflow ? nil : count
    }
}
