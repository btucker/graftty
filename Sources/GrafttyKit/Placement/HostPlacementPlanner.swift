import Foundation
import GrafttyProtocol

public struct HostPlacementDemand: Codable, Sendable, Equatable {
    public let architecture: String
    public let cpus: Double
    public let memoryBytes: Int64
    public let diskBytes: Int64
    public init(architecture: String, cpus: Double, memoryBytes: Int64, diskBytes: Int64) {
        self.architecture = architecture; self.cpus = cpus; self.memoryBytes = memoryBytes; self.diskBytes = diskBytes
    }
}

public struct HostPlacementPolicy: Codable, Sendable {
    public var maximumCPUUtilization = 0.8
    public var memoryHeadroomBytes: Int64 = 512 * 1024 * 1024
    public var diskHeadroomBytes: Int64 = 1024 * 1024 * 1024
    public var maximumTelemetryAge: TimeInterval = 30
    public init() {}
}

public struct HostPlacementEvaluation: Encodable, Sendable {
    public let host: RemoteMacConnectionSummary.ID
    public let label: String
    public let reasons: [String]
    public let reservationState: String
    public let filesystemPath: String?
    public let cpuHeadroomAfterRequest: Double?
    public let memoryHeadroomAfterRequest: Int64?
    public let diskHeadroomAfterRequest: Int64?
    public let observation: HostResourceObservation?
}

public struct HostPlacementPlan: Encodable, Sendable {
    public let demand: HostPlacementDemand
    public let policy: HostPlacementPolicy
    public let evaluatedAt: Date
    public let selectedHost: RemoteMacConnectionSummary.ID?
    public let candidates: [HostPlacementEvaluation]
    public let rejected: [HostPlacementEvaluation]
    public let nextAction: String
    public let admissionRequired = true
    public let limitations = [
        "This plan is read-only. Candidates require a fresh admission check and reservation before starting work.",
        "Measured load does not predict future peaks; active worktrees may become busy after this sample.",
        "Disk headroom applies only to the reported filesystem path. Project and Dev Container readiness must be checked separately.",
        "Provider prices and fleet spending limits are separate from this existing-host comparison."
    ]
}

public enum HostPlacementPlanner {
    public static func validate(demand: HostPlacementDemand, policy: HostPlacementPolicy) throws {
        guard ["arm64", "x86_64"].contains(demand.architecture), demand.cpus.isFinite, demand.cpus > 0,
              demand.memoryBytes > 0, demand.diskBytes > 0,
              policy.maximumCPUUtilization.isFinite, policy.maximumCPUUtilization > 0, policy.maximumCPUUtilization <= 1,
              policy.memoryHeadroomBytes >= 0, policy.diskHeadroomBytes >= 0,
              policy.maximumTelemetryAge.isFinite, policy.maximumTelemetryAge > 0,
              !demand.memoryBytes.addingReportingOverflow(policy.memoryHeadroomBytes).overflow,
              !demand.diskBytes.addingReportingOverflow(policy.diskHeadroomBytes).overflow else {
            throw ProviderError("Provide a supported architecture, positive finite resource requirements and telemetry age, and valid headroom limits.")
        }
    }

    public static func plan(hosts: [RemoteMacConnectionSummary], demand: HostPlacementDemand,
                            policy: HostPlacementPolicy = .init(), at now: Date = Date()) throws -> HostPlacementPlan {
        try validate(demand: demand, policy: policy)
        let evaluations = hosts.map { evaluate($0, demand: demand, policy: policy, at: now) }
        let candidates = evaluations.filter { $0.reasons.isEmpty }.sorted {
            // Fit smaller remaining memory first to leave larger machines available for larger requests.
            if $0.memoryHeadroomAfterRequest != $1.memoryHeadroomAfterRequest {
                return $0.memoryHeadroomAfterRequest! < $1.memoryHeadroomAfterRequest!
            }
            if $0.cpuHeadroomAfterRequest != $1.cpuHeadroomAfterRequest {
                return $0.cpuHeadroomAfterRequest! < $1.cpuHeadroomAfterRequest!
            }
            return identityPrecedes($0.host, $1.host)
        }
        let rejected = evaluations.filter { !$0.reasons.isEmpty }.sorted { identityPrecedes($0.host, $1.host) }
        let transient: Set<String> = ["missingTelemetry", "staleTelemetry", "invalidTelemetry", "unknownPlatform", "unknownCPU", "unknownMemory", "unknownDisk", "unknownWorktreeOperations", "worktreeOperationInProgress", "placementsPending"]
        let next = candidates.isEmpty
            ? (rejected.contains { $0.reasons.contains(where: transient.contains) } ? "refreshTelemetry" : "inspectProviderOffers")
            : "requestAdmission"
        return HostPlacementPlan(demand: demand, policy: policy, evaluatedAt: now,
            selectedHost: candidates.first?.host, candidates: candidates, rejected: rejected, nextAction: next)
    }

    private static func identityPrecedes(_ lhs: RemoteMacConnectionSummary.ID, _ rhs: RemoteMacConnectionSummary.ID) -> Bool {
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID.value < rhs.deviceID.value }
        return lhs.fingerprint.rawBytes.lexicographicallyPrecedes(rhs.fingerprint.rawBytes)
    }

    private static func evaluate(_ host: RemoteMacConnectionSummary, demand: HostPlacementDemand,
                                 policy: HostPlacementPolicy, at now: Date) -> HostPlacementEvaluation {
        var reasons: [String] = []
        var cpu: Double?
        var memory: Int64?
        var disk: Int64?
        let sample = host.resourceObservation?.sample
        if host.state != .connected { reasons.append("notConnected") }
        else if host.resourceObservation == nil { reasons.append("missingTelemetry") }
        else if sample?.isValid != true { reasons.append("invalidTelemetry") }
        else if host.resourceObservation?.isFresh(at: now, maximumAge: policy.maximumTelemetryAge) != true { reasons.append("staleTelemetry") }
        else if let sample {
            if sample.operatingSystem == nil || sample.architecture == nil { reasons.append("unknownPlatform") }
            else {
                if sample.operatingSystem != "linux" { reasons.append("operatingSystemMismatch") }
                if sample.architecture != demand.architecture { reasons.append("architectureMismatch") }
            }
            if let count = sample.cpuCount, let utilization = sample.cpuUtilization {
                cpu = Double(count) * (policy.maximumCPUUtilization - utilization) - demand.cpus
                if cpu! < 0 { reasons.append("insufficientCPUHeadroom") }
            } else { reasons.append("unknownCPU") }
            if let available = sample.memoryAvailableBytes {
                memory = available - (demand.memoryBytes + policy.memoryHeadroomBytes)
                if memory! < 0 { reasons.append("insufficientMemoryHeadroom") }
            } else { reasons.append("unknownMemory") }
            if let available = sample.diskAvailableBytes {
                disk = available - (demand.diskBytes + policy.diskHeadroomBytes)
                if disk! < 0 { reasons.append("insufficientDiskHeadroom") }
            } else { reasons.append("unknownDisk") }
            if let operations = sample.pendingWorktreeOperations {
                if operations > 0 { reasons.append("worktreeOperationInProgress") }
            } else { reasons.append("unknownWorktreeOperations") }
            if let pending = sample.pendingPlacements, pending > 0 { reasons.append("placementsPending") }
        }
        return HostPlacementEvaluation(host: host.id, label: host.label, reasons: reasons,
            reservationState: sample?.pendingPlacements == nil ? "unknown" : "observed",
            filesystemPath: sample?.diskPath, cpuHeadroomAfterRequest: cpu,
            memoryHeadroomAfterRequest: memory, diskHeadroomAfterRequest: disk, observation: host.resourceObservation)
    }
}
