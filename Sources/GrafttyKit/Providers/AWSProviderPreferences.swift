import Foundation
import GrafttyProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ProviderError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// References an existing AWS profile. Credential contents never enter this model.
public struct AWSProviderPreferences: Codable, Equatable, Sendable {
    public var version: Int
    public var profile: String?
    public var regions: [String]
    public var instanceTypes: [String]
    public var preferredInstanceType: String?
    public var availabilityZones: [String]
    public var market: String
    public var maxInstances: Int?
    public var maxHourlyUSD: Decimal?
    public var creditMode: String?

    public init(version: Int = 1, profile: String? = nil, regions: [String] = [],
                instanceTypes: [String] = [], preferredInstanceType: String? = nil,
                availabilityZones: [String] = [], market: String = "spot",
                maxInstances: Int? = nil, maxHourlyUSD: Decimal? = nil, creditMode: String? = nil) {
        self.version = version
        self.profile = profile
        self.regions = regions
        self.instanceTypes = instanceTypes
        self.preferredInstanceType = preferredInstanceType
        self.availabilityZones = availabilityZones
        self.market = market
        self.maxInstances = maxInstances
        self.maxHourlyUSD = maxHourlyUSD
        self.creditMode = creditMode
    }

    public func validate() throws {
        guard version == 1 else { throw ProviderError("Unsupported AWS preferences version \(version); update Graftty before changing this file.") }
        if let profile {
            guard !profile.isEmpty, profile == profile.trimmingCharacters(in: .whitespacesAndNewlines),
                  !profile.hasPrefix("-"), !profile.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ProviderError("Provide a non-empty AWS profile name without leading options or control characters.")
            }
        }
        try Self.validateList(regions, pattern: "^[a-z][a-z0-9-]*-[0-9]+$", name: "regions", maximum: 16)
        try Self.validateList(instanceTypes, pattern: "^[a-z][a-z0-9-]*\\.[a-z0-9]+$", name: "instance types", maximum: 100)
        try Self.validateList(availabilityZones, pattern: "^[a-z][a-z0-9-]*[a-z0-9]$", name: "Availability Zones", maximum: 100)
        if let preferredInstanceType, !instanceTypes.contains(preferredInstanceType) {
            throw ProviderError("The preferred instance type must be in the configured pool. Update the pool and preference together, or clear the preference.")
        }
        guard market == "spot" else { throw ProviderError("Only Spot offer discovery is supported; use --market spot.") }
        if let maxInstances, maxInstances <= 0 { throw ProviderError("Maximum instance count must be positive.") }
        if let maxHourlyUSD, maxHourlyUSD.isNaN || maxHourlyUSD <= 0 { throw ProviderError("Maximum hourly USD must be a positive decimal.") }
        if let creditMode, !["standard", "unlimited"].contains(creditMode) {
            throw ProviderError("CPU credit mode must be standard or unlimited.")
        }
    }

    public func validateForInventory() throws {
        try validate()
        guard profile != nil, !regions.isEmpty else {
            throw ProviderError("Configure aws with --profile and --region before listing hosts.")
        }
    }

    public func validateForDiscovery() throws {
        try validate()
        guard profile != nil, !regions.isEmpty, !instanceTypes.isEmpty else {
            throw ProviderError("Configure aws with --profile, --region, and --instance-types before querying offers.")
        }
    }

    public static func positiveAmount(_ text: String) throws -> Decimal {
        guard text.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value > 0 else {
            throw ProviderError("Expected a positive decimal amount, such as 0.50.")
        }
        return value
    }

    private static func validateList(_ values: [String], pattern: String, name: String, maximum: Int) throws {
        guard values.count <= maximum, Set(values).count == values.count,
              values.allSatisfy({ $0.utf8.count <= 128 && $0.range(of: pattern, options: .regularExpression) != nil }) else {
            throw ProviderError("Provide at most \(maximum) distinct valid \(name), without empty entries.")
        }
    }
}

/// Serializes read/modify/write across CLI processes as well as in-process callers.
public struct AWSProviderStore: Sendable {
    private static let processLock = NSLock()
    public let directory: URL
    private var file: JSONFileStore<AWSProviderPreferences> {
        JSONFileStore(fileURL: directory.appendingPathComponent("aws.json"),
                      outputFormatting: [.prettyPrinted, .sortedKeys], posixPermissions: 0o600)
    }

    public init(directory: URL = AppState.defaultDirectory.appendingPathComponent("Providers", isDirectory: true)) {
        self.directory = directory
    }

    public func load() throws -> AWSProviderPreferences? {
        let value = try file.load()
        try value?.validate()
        return value
    }

    @discardableResult
    public func update(_ change: (inout AWSProviderPreferences) throws -> Void) throws -> AWSProviderPreferences {
        try withLock {
            var value = try load() ?? AWSProviderPreferences()
            try change(&value)
            try value.validate()
            try file.save(value)
            return value
        }
    }

    public func remove() throws { try withLock { try file.remove() } }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent("aws.lock").path
        #if canImport(Darwin)
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        #else
        let descriptor = Glibc.open(path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        #endif
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }
}
