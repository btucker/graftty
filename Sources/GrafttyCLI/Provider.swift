import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct Provider: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save compute preferences, inspect hosts, and compare AWS Spot offers",
        discussion: "Preferences are local to this user. Discovery and preference commands work without Graftty running. Enrollment uses the running parent app. These commands do not launch or terminate instances.",
        subcommands: [ProviderConfigure.self, ProviderShow.self, ProviderList.self, ProviderRemove.self, ProviderOffers.self, ProviderHosts.self, ProviderEnroll.self])
}

struct ProviderConfigure: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "configure", abstract: "Update saved AWS preferences",
        discussion: """
        Examples:
          graftty provider configure aws --profile development --region us-east-1
          graftty provider configure aws --instance-types t4g.large,t4g.xlarge --preferred-instance-type t4g.xlarge
          graftty provider configure aws --clear preferred-instance-type

        Unspecified settings are preserved. Lists replace their saved values.
        --clear accepts comma-separated setting names. Profile names reference
        existing AWS configuration; Graftty never reads or copies credentials.
        No preferred instance type or instance pool is supplied by default.
        """)
    @Argument(help: "Compute provider: aws") var provider: String
    @Option(help: "Existing AWS CLI profile name") var profile: String?
    @Option(name: [.customLong("region"), .customLong("regions")], help: "Comma-separated AWS regions") var regions: String?
    @Option(help: "Comma-separated allowed instance types") var instanceTypes: String?
    @Option(help: "Preferred type within the pool; breaks equal-price ties") var preferredInstanceType: String?
    @Option(help: "Comma-separated allowed Availability Zones; unset means all in selected regions") var availabilityZones: String?
    @Option(help: "Purchase market: spot") var market: String?
    @Option(help: "Saved maximum instance count for future provisioning") var maxInstances: Int?
    @Option(help: "Saved hourly compute budget in USD; offers above it are excluded") var maxHourlyUsd: String?
    @Option(help: "Burstable CPU credit mode: standard or unlimited") var creditMode: String?
    @Option(help: "Comma-separated setting names to clear") var clear: String?
    @Flag(help: "Print saved preferences as JSON") var json = false

    private var changedNames: Set<String> {
        var names = Set<String>()
        if profile != nil { names.insert("profile") }
        if regions != nil { names.insert("region") }
        if instanceTypes != nil { names.insert("instance-types") }
        if preferredInstanceType != nil { names.insert("preferred-instance-type") }
        if availabilityZones != nil { names.insert("availability-zones") }
        if market != nil { names.insert("market") }
        if maxInstances != nil { names.insert("max-instances") }
        if maxHourlyUsd != nil { names.insert("max-hourly-usd") }
        if creditMode != nil { names.insert("credit-mode") }
        return names
    }

    func validate() throws {
        try ProviderOutput.validate(provider)
        let cleared = try clear.map(Self.list) ?? []
        let supported: Set<String> = ["profile", "region", "instance-types", "preferred-instance-type", "availability-zones", "market", "max-instances", "max-hourly-usd", "credit-mode"]
        guard Set(cleared).isSubset(of: supported) else { throw ValidationError("Unknown setting in --clear. Use: " + supported.sorted().joined(separator: ", ")) }
        guard changedNames.isDisjoint(with: cleared) else { throw ValidationError("Cannot set and clear the same setting.") }
        guard !changedNames.isEmpty || !cleared.isEmpty else { throw ValidationError("Supply a setting to update or --clear. Use provider show aws to inspect preferences.") }
        // Validate independent values before any file IO. Membership of a
        // preferred type is checked against the merged configuration at save.
        var values = AWSProviderPreferences()
        try applyValues(to: &values)
        values.preferredInstanceType = nil
        try values.validate()
        if let preferredInstanceType {
            let preference = AWSProviderPreferences(instanceTypes: [preferredInstanceType], preferredInstanceType: preferredInstanceType)
            try preference.validate()
        }
    }

    func apply(to store: AWSProviderStore) throws -> AWSProviderPreferences {
        try validate()
        return try store.update { value in
            for name in try clear.map(Self.list) ?? [] {
                switch name {
                case "profile": value.profile = nil
                case "region": value.regions = []
                case "instance-types": value.instanceTypes = []
                case "preferred-instance-type": value.preferredInstanceType = nil
                case "availability-zones": value.availabilityZones = []
                case "market": value.market = "spot"
                case "max-instances": value.maxInstances = nil
                case "max-hourly-usd": value.maxHourlyUSD = nil
                case "credit-mode": value.creditMode = nil
                default: break // validate() rejected unknown names.
                }
            }
            try applyValues(to: &value)
        }
    }

    private func applyValues(to value: inout AWSProviderPreferences) throws {
        if let profile { value.profile = profile }
        if let regions { value.regions = try Self.list(regions) }
        if let instanceTypes { value.instanceTypes = try Self.list(instanceTypes) }
        if let preferredInstanceType { value.preferredInstanceType = preferredInstanceType }
        if let availabilityZones { value.availabilityZones = try Self.list(availabilityZones) }
        if let market { value.market = market }
        if let maxInstances { value.maxInstances = maxInstances }
        if let maxHourlyUsd { value.maxHourlyUSD = try AWSProviderPreferences.positiveAmount(maxHourlyUsd) }
        if let creditMode { value.creditMode = creditMode }
    }

    private static func list(_ text: String) throws -> [String] {
        let values = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !values.contains(""), Set(values).count == values.count else {
            throw ValidationError("Lists must contain distinct non-empty values; use --clear to remove a setting.")
        }
        return values
    }

    func run() throws { try ProviderOutput.preferences(apply(to: AWSProviderStore()), json: json) }
}

struct ProviderShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show saved provider preferences")
    @Argument(help: "Compute provider: aws") var provider: String
    @Flag(help: "Print JSON") var json = false
    func validate() throws { try ProviderOutput.validate(provider) }
    func preferences(in store: AWSProviderStore) throws -> AWSProviderPreferences {
        try validate()
        guard let value = try store.load() else { throw ValidationError("aws is not configured. Run graftty provider configure aws.") }
        return value
    }
    func run() throws { try ProviderOutput.preferences(preferences(in: AWSProviderStore()), json: json) }
}

struct ProviderList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List configured compute providers")
    @Flag(help: "Print JSON") var json = false
    func run() throws {
        let names = try AWSProviderStore().load() == nil ? [] : ["aws"]
        if json { try ProviderOutput.json(names) }
        else { print(names.isEmpty ? "No compute providers configured." : names.joined(separator: "\n")) }
    }
}

struct ProviderRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove saved preferences; does not terminate instances")
    @Argument(help: "Compute provider: aws") var provider: String
    func validate() throws { try ProviderOutput.validate(provider) }
    func remove(from store: AWSProviderStore) throws { try validate(); try store.remove() }
    func run() throws { try remove(from: AWSProviderStore()); print("Removed aws preferences. Instances were not changed.") }
}

struct ProviderOffers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "offers", abstract: "Compare current AWS Spot rates without allocating instances",
        discussion: "Queries the configured profile, regions, and instance pool through AWS CLI v2. Rates do not guarantee capacity or include storage, network, or surplus CPU credit charges. Preferred types break equal-price ties.")
    @Argument(help: "Compute provider: aws") var provider: String
    @Option(help: "Required workload architecture: arm64 or x86_64") var architecture: String
    @Option(help: "Minimum vCPU count") var minCpus = 1
    @Option(help: "Minimum memory in MiB") var minMemoryMib = 1
    @Flag(help: "Print observations, filters, and limitations as JSON") var json = false
    func validate() throws {
        try ProviderOutput.validate(provider)
        try requirements.validate()
    }
    private var requirements: AWSOfferRequirements {
        .init(architecture: architecture, minCPUs: minCpus, minMemoryMiB: minMemoryMib)
    }
    func run() async throws {
        guard let preferences = try AWSProviderStore().load() else { throw ValidationError("Configure aws before querying offers.") }
        let report = try await AWSProviderDiscovery().offers(preferences: preferences, requirements: requirements)
        if json { try ProviderOutput.json(report); return }
        print("TYPE\tREGION\tZONE\tVCPU\tMEMORY_MIB\tUSD/H\tPREFERRED\tBURSTABLE")
        for offer in report.offers {
            print("\(offer.instanceType)\t\(offer.region)\t\(offer.availabilityZone)\t\(offer.cpus)\t\(offer.memoryMiB)\t\(offer.hourlyUSD)\t\(offer.preferred)\t\(offer.burstable)")
        }
        if report.offers.isEmpty { print("No matching priced offers.") }
        if !report.excludedInstanceTypes.isEmpty { print("Unavailable or incompatible types: " + report.excludedInstanceTypes.joined(separator: ", ")) }
        if !report.unpricedInstanceTypes.isEmpty { print("No price observed in selected zones: " + report.unpricedInstanceTypes.joined(separator: ", ")) }
        if report.overBudgetOfferCount > 0 { print("Offers above hourly limit: \(report.overBudgetOfferCount)") }
        for limitation in report.limitations { print(limitation) }
    }
}

struct ProviderHosts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hosts", abstract: "List EC2 instances in configured regions",
        discussion: "Defaults to instances tagged graftty:managed=true. --all includes untagged instances. Inventory includes machines outside your current instance pool and placement zones. EC2 running state and tags do not establish authenticated Graftty readiness or available capacity.")
    @Argument(help: "Compute provider: aws") var provider: String
    @Flag(help: "Include instances without the Graftty discovery tag") var all = false
    @Flag(help: "Print inventory with explicit nulls for unknown load") var json = false
    func validate() throws { try ProviderOutput.validate(provider) }
    func run() async throws {
        guard let preferences = try AWSProviderStore().load() else { throw ValidationError("Configure aws before listing hosts.") }
        let report = try await AWSHostInventory().hosts(preferences: preferences, includeUntagged: all)
        if json { try ProviderOutput.json(report); return }
        print(Self.table(report))
    }

    static func table(_ report: AWSHostInventoryReport) -> String {
        var lines = ["IDENTITY\tSTATE\tTYPE\tARCH\tZONE\tVCPU\tMEMORY_MIB\tGRAFTTY_TAGGED\tREADY\tLOAD"]
        for host in report.hosts {
            let cells = [host.identity, host.state, host.instanceType ?? "unknown", host.architecture ?? "unknown",
                host.availabilityZone ?? "unknown", host.cpus.map(String.init) ?? "unknown", host.memoryMiB.map(String.init) ?? "unknown",
                String(host.grafttyTagged), host.readiness, "unknown"]
            // AWS fields are data. Do not let control characters become terminal commands or table delimiters.
            lines.append(cells.map { cell in
                cell.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? "?" : String($0) }.joined()
            }.joined(separator: "\t"))
        }
        if report.hosts.isEmpty { lines.append("No matching instances in configured regions.") }
        lines.append(contentsOf: report.limitations)
        return lines.joined(separator: "\n")
    }
}

struct ProviderEnroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enroll", abstract: "Enroll an explicit AWS instance through Systems Manager",
        discussion: """
        Requires SSM Agent, an instance role permitting Systems Manager, and a
        prepared graftty-host installation owned by the development user.
        Uses the running Mac app's public identities. Saves the target and SSM
        command for retries; reuse the same operation UUID and options.
        Grants the worker replication access only. This does not start its
        phone-home service, launch an instance, or authorize repository refs.
        """)
    @Argument(help: "Compute provider: aws") var provider: String
    @Option(help: "Existing AWS CLI profile") var profile: String
    @Option(help: "AWS region containing the instance") var region: String
    @Option(help: "Expected 12-digit AWS account ID") var accountId: String
    @Option(help: "Exact EC2 instance ID") var instanceId: String
    @Option(help: "Stable provisioning/enrollment operation UUID; reuse on retry") var operationId: String
    @Option(help: "Non-root development user that runs graftty-host") var user: String
    @Option(help: "Absolute graftty-host executable path on the instance") var hostExecutable: String
    @Option(help: "Absolute graftty-host state directory on the instance") var hostStateDirectory: String
    @Flag(help: "Print the enrolled public identity as JSON") var json = false

    private var target: AWSHostEnrollmentTarget {
        .init(profile: profile, accountID: accountId, region: region, instanceID: instanceId, user: user,
              executable: hostExecutable, stateDirectory: hostStateDirectory)
    }
    func validate() throws {
        try ProviderOutput.validate(provider)
        guard UUID(uuidString: operationId) != nil else { throw ValidationError("--operation-id must be a UUID") }
        try target.validate()
    }
    func run() async throws {
        #if os(macOS)
        guard let operation = UUID(uuidString: operationId) else { throw ValidationError("--operation-id must be a UUID") }
        let parent: LinuxHostTrustRequest
        switch try CLIEnv.sendRequest(.linuxSetupIdentity) {
        case .linuxSetupIdentity(let identity): parent = identity
        case .error(let error): throw ValidationError(error)
        default: throw ValidationError("Update and relaunch Graftty to enroll an AWS host.")
        }
        guard parent.serverPublicKey != nil else { throw ValidationError("Update and relaunch Graftty to provide the parent's server public key.") }
        let identity = try await AWSHostEnrollment(peers: TrustedPeerStore(directory: TrustedPeerStore.defaultDirectory))
            .enroll(operationID: operation, target: target, parent: parent)
        if json { try ProviderOutput.json(identity) }
        else { print("Enrolled \(instanceId) as \(identity.deviceID) with replication access. Operation: \(operation.uuidString)") }
        #else
        throw ValidationError("Run provider enroll on the parent Mac with Graftty running.")
        #endif
    }
}

private enum ProviderOutput {
    static func validate(_ provider: String) throws {
        guard provider == "aws" else { throw ValidationError("Unknown compute provider '\(provider)'. Supported provider: aws.") }
    }
    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder.iso8601()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    static func preferences(_ value: AWSProviderPreferences, json asJSON: Bool) throws {
        if asJSON { try json(value); return }
        print("Provider: aws")
        print("Profile: \(value.profile ?? "unset")")
        print("Regions: \(value.regions.joined(separator: ", "))")
        print("Instance types: \(value.instanceTypes.joined(separator: ", "))")
        print("Preferred instance type: \(value.preferredInstanceType ?? "unset")")
        print("Availability Zones: \(value.availabilityZones.isEmpty ? "all in selected regions" : value.availabilityZones.joined(separator: ", "))")
        print("Market: \(value.market)")
        print("Maximum instances: \(value.maxInstances.map(String.init) ?? "unset")")
        print("Maximum hourly compute USD: \(value.maxHourlyUSD.map { "\($0)" } ?? "unset")")
        print("CPU credit mode: \(value.creditMode ?? "unset")")
    }
}
