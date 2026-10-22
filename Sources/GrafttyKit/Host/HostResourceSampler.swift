import Foundation
import GrafttyProtocol
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Sampling runs off the main actor and does not launch subprocesses.
public actor HostResourceSampler {
    private var linux = LinuxHostResourceMeasurements()
    public init() {}
    public func sample(diskPath: String, activeWorktrees: Int, pendingOperations: Int) -> HostResourceSnapshot {
        #if os(Linux)
        let measurements = linux.sample(stat: try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
            meminfo: try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8))
        #else
        let measurements = LinuxHostResourceMeasurements.Measurements(cpuCount: ProcessInfo.processInfo.activeProcessorCount,
            cpuUtilization: nil, memoryTotalBytes: Int64(exactly: ProcessInfo.processInfo.physicalMemory), memoryAvailableBytes: nil)
        #endif
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture: String? = nil
        #endif
        return HostResourceSnapshot(sampledAt: Date().timeIntervalSince1970, architecture: architecture,
            cpuCount: measurements.cpuCount, cpuUtilization: measurements.cpuUtilization,
            memoryTotalBytes: measurements.memoryTotalBytes, memoryAvailableBytes: measurements.memoryAvailableBytes,
            diskPath: diskPath, diskAvailableBytes: Self.availableDiskBytes(at: diskPath), activeWorktrees: activeWorktrees,
            pendingWorktreeOperations: pendingOperations)
    }

    private static func availableDiskBytes(at path: String) -> Int64? {
        var info = statvfs()
        guard statvfs(path, &info) == 0 else { return nil }
        let (bytes, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_frsize))
        return overflow ? nil : Int64(exactly: bytes)
    }
}

struct LinuxHostResourceMeasurements {
    struct Measurements {
        var cpuCount: Int?
        var cpuUtilization: Double?
        var memoryTotalBytes: Int64?
        var memoryAvailableBytes: Int64?
    }
    private var previous: [UInt64]?

    mutating func sample(stat: String?, meminfo: String?) -> Measurements {
        let rows = stat?.split(separator: "\n") ?? []
        let fields = rows.first(where: { $0.hasPrefix("cpu ") })?.split(whereSeparator: \.isWhitespace).dropFirst()
        // guest and guest_nice are already included in user and nice; only sum the first eight counters.
        let counters = fields.map { Array($0.prefix(8)).compactMap { UInt64($0) } }
        let current = counters.flatMap { $0.count == 8 ? $0 : nil }
        defer { previous = current }
        var utilization: Double?
        if let previous, let current, zip(previous, current).allSatisfy({ $0 <= $1 }) {
            let deltas = zip(previous, current).map { Double($1 - $0) }
            let total = deltas.reduce(0, +)
            if total > 0 { utilization = (total - deltas[3] - deltas[4]) / total }
        }
        let count = rows.filter { row in
            let key = row.split(whereSeparator: \.isWhitespace).first ?? ""
            return key.hasPrefix("cpu") && !key.dropFirst(3).isEmpty && key.dropFirst(3).allSatisfy(\.isNumber)
        }.count
        let memory = meminfo?.split(separator: "\n").reduce(into: [String: Int64]()) { values, row in
            let parts = row.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3, parts[2] == "kB", let amount = Int64(parts[1]), amount >= 0 else { return }
            let (bytes, overflow) = amount.multipliedReportingOverflow(by: 1024)
            if !overflow { values[String(parts[0])] = bytes }
        } ?? [:]
        let total = memory["MemTotal:"]
        let available = memory["MemAvailable:"].flatMap { value in total.map { value <= $0 ? value : nil } ?? nil }
        return Measurements(cpuCount: count > 0 ? count : nil, cpuUtilization: utilization,
            memoryTotalBytes: total, memoryAvailableBytes: available)
    }
}
