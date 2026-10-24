import Foundation

/// Host-wide measurements. Disk space applies only to the filesystem containing diskPath.
/// Sender identity comes from the authenticated connection, never from this payload.
public struct HostResourceSnapshot: Codable, Sendable, Hashable {
    public var sampledAt: Double
    public var architecture: String?
    public var operatingSystem: String?
    public var cpuCount: Int?
    /// Busy CPU time divided by total CPU time across all CPUs, in 0...1.
    public var cpuUtilization: Double?
    public var memoryTotalBytes: Int64?
    public var memoryAvailableBytes: Int64?
    public var diskPath: String
    public var diskAvailableBytes: Int64?
    public var activeWorktrees: Int
    public var pendingWorktreeOperations: Int?
    public var pendingPlacements: Int?
    public var acceptingPlacements: Bool?

    public init(sampledAt: Double, architecture: String? = nil, operatingSystem: String? = nil, cpuCount: Int? = nil, cpuUtilization: Double? = nil,
                memoryTotalBytes: Int64? = nil, memoryAvailableBytes: Int64? = nil,
                diskPath: String, diskAvailableBytes: Int64? = nil, activeWorktrees: Int = 0,
                pendingWorktreeOperations: Int? = nil, pendingPlacements: Int? = nil, acceptingPlacements: Bool? = nil) {
        self.sampledAt = sampledAt; self.architecture = architecture; self.operatingSystem = operatingSystem; self.cpuCount = cpuCount; self.cpuUtilization = cpuUtilization
        self.memoryTotalBytes = memoryTotalBytes; self.memoryAvailableBytes = memoryAvailableBytes
        self.diskPath = diskPath; self.diskAvailableBytes = diskAvailableBytes; self.activeWorktrees = activeWorktrees
        self.pendingWorktreeOperations = pendingWorktreeOperations; self.pendingPlacements = pendingPlacements
        self.acceptingPlacements = acceptingPlacements
    }

    public var isValid: Bool {
        guard sampledAt.isFinite, sampledAt > 0, diskPath.hasPrefix("/"), diskPath.utf8.count <= 4096,
              !diskPath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              activeWorktrees >= 0 else { return false }
        if let cpuCount, cpuCount <= 0 { return false }
        if let cpuUtilization, !cpuUtilization.isFinite || !(0...1).contains(cpuUtilization) { return false }
        if [memoryTotalBytes, memoryAvailableBytes, diskAvailableBytes].contains(where: { $0.map { $0 < 0 } ?? false }) { return false }
        if let memoryTotalBytes, let memoryAvailableBytes, memoryAvailableBytes > memoryTotalBytes { return false }
        if [pendingWorktreeOperations, pendingPlacements].contains(where: { $0.map { $0 < 0 } ?? false }) { return false }
        return true
    }
}

/// Receipt time is assigned by the consumer of the authenticated channel.
public struct HostResourceObservation: Codable, Sendable, Hashable {
    public let sample: HostResourceSnapshot
    public let receivedAt: Double
    public init(sample: HostResourceSnapshot, receivedAt: Double) { self.sample = sample; self.receivedAt = receivedAt }

    public func isFresh(at now: Date = Date(), maximumAge: TimeInterval = 30) -> Bool {
        let now = now.timeIntervalSince1970
        return sample.isValid && maximumAge.isFinite && maximumAge > 0 && receivedAt.isFinite
            && now >= receivedAt && now - receivedAt <= maximumAge
            && now - sample.sampledAt <= maximumAge && sample.sampledAt <= receivedAt + 5
    }
}
