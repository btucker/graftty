import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

struct HostPlacementPlannerTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private var demand: HostPlacementDemand { .init(architecture: "arm64", cpus: 2, memoryBytes: 4 * 1024 * 1024 * 1024, diskBytes: 8 * 1024 * 1024 * 1024) }

    @Test("@spec REMOTE-31.15: When an agent requests a read-only placement plan, the CLI shall rank connected compatible hosts using fresh measured CPU, memory, and disk headroom, explain rejections and unknown reservation state, and require admission before starting work.")
    func packsCompatibleHostsButDoesNotGrantAdmission() throws {
        let small = try host("small", memoryGiB: 8)
        let large = try host("large", memoryGiB: 16)
        let plan = try HostPlacementPlanner.plan(hosts: [large, small], demand: demand, at: now)
        #expect(plan.selectedHost?.deviceID.value == "small")
        #expect(plan.candidates.map { $0.host.deviceID.value } == ["small", "large"])
        #expect(plan.admissionRequired)
        #expect(plan.nextAction == "requestAdmission")
        #expect(plan.candidates.allSatisfy { $0.reservationState == "unknown" })
        #expect(plan.candidates.first?.filesystemPath == "/work")
    }

    @Test func rejectsDisconnectedStaleIncompatibleAndBusyHosts() throws {
        var stale = sample(); stale.sampledAt = 900
        var wrongArch = sample(); wrongArch.architecture = "x86_64"
        var wrongOS = sample(); wrongOS.operatingSystem = "macos"
        var busy = sample(); busy.cpuUtilization = 0.9
        var preparing = sample(); preparing.pendingWorktreeOperations = 1
        var pending = sample(); pending.pendingPlacements = 1
        var draining = sample(); draining.acceptingPlacements = false
        let plan = try HostPlacementPlanner.plan(hosts: [
            host("offline", state: .offline), host("stale", sample: stale), host("arch", sample: wrongArch),
            host("os", sample: wrongOS), host("busy", sample: busy), host("preparing", sample: preparing), host("pending", sample: pending), host("draining", sample: draining)
        ], demand: demand, at: now)
        #expect(plan.candidates.isEmpty)
        #expect(plan.selectedHost == nil)
        #expect(plan.nextAction == "refreshTelemetry")
        let reasons = Dictionary(uniqueKeysWithValues: plan.rejected.map { ($0.host.deviceID.value, $0.reasons) })
        #expect(reasons["offline"] == ["notConnected"])
        #expect(reasons["stale"] == ["staleTelemetry"])
        #expect(reasons["arch"]?.contains("architectureMismatch") == true)
        #expect(reasons["os"]?.contains("operatingSystemMismatch") == true)
        #expect(reasons["busy"]?.contains("insufficientCPUHeadroom") == true)
        #expect(reasons["preparing"]?.contains("worktreeOperationInProgress") == true)
        #expect(reasons["pending"]?.contains("placementsPending") == true)
        #expect(reasons["draining"]?.contains("hostDraining") == true)
    }

    @Test func missingMetricsDoNotBecomeZeroAndPreventPrematureExpansion() throws {
        var missing = sample(); missing.memoryAvailableBytes = nil; missing.cpuUtilization = nil; missing.pendingWorktreeOperations = nil
        let plan = try HostPlacementPlanner.plan(hosts: [host("unknown", sample: missing)], demand: demand, at: now)
        #expect(plan.candidates.isEmpty)
        #expect(plan.rejected.first?.reasons.contains("unknownCPU") == true)
        #expect(plan.rejected.first?.reasons.contains("unknownMemory") == true)
        #expect(plan.nextAction == "refreshTelemetry")
        #expect(plan.rejected.first?.reasons.contains("unknownWorktreeOperations") == true)
    }

    @Test func memoryDiskAndSafetyMarginsAreEnforced() throws {
        var memory = sample(); memory.memoryAvailableBytes = demand.memoryBytes
        var disk = sample(); disk.diskAvailableBytes = demand.diskBytes
        let plan = try HostPlacementPlanner.plan(hosts: [host("memory", sample: memory), host("disk", sample: disk)], demand: demand, at: now)
        #expect(plan.candidates.isEmpty)
        #expect(plan.nextAction == "inspectProviderOffers")
        #expect(plan.rejected.contains { $0.reasons.contains("insufficientMemoryHeadroom") })
        #expect(plan.rejected.contains { $0.reasons.contains("insufficientDiskHeadroom") })
    }

    @Test func invalidDemandCannotOverflowHeadroomArithmetic() throws {
        for value in [HostPlacementDemand(architecture: "arm64", cpus: .nan, memoryBytes: 1, diskBytes: 1),
                      HostPlacementDemand(architecture: "arm64", cpus: 1, memoryBytes: Int64.max, diskBytes: 1),
                      HostPlacementDemand(architecture: "other", cpus: 1, memoryBytes: 1, diskBytes: 1)] {
            #expect(throws: (any Error).self) { _ = try HostPlacementPlanner.plan(hosts: [], demand: value, at: now) }
        }
    }

    private func sample(memoryGiB: Int64 = 16) -> HostResourceSnapshot {
        .init(sampledAt: 999, architecture: "arm64", operatingSystem: "linux", cpuCount: 4, cpuUtilization: 0.1,
            memoryTotalBytes: memoryGiB * 1024 * 1024 * 1024, memoryAvailableBytes: memoryGiB * 1024 * 1024 * 1024,
            diskPath: "/work", diskAvailableBytes: 100 * 1024 * 1024 * 1024, activeWorktrees: 1, pendingWorktreeOperations: 0)
    }
    private func host(_ name: String, memoryGiB: Int64 = 16, state: RemoteMacConnectionSummary.State = .connected,
                      sample: HostResourceSnapshot? = nil) throws -> RemoteMacConnectionSummary {
        .init(deviceID: .init(value: name), fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: 1, count: 32)),
              label: name, lastKnownHost: nil, state: state,
              resourceObservation: .init(sample: sample ?? self.sample(memoryGiB: memoryGiB), receivedAt: 1000))
    }
}
