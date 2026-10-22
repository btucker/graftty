import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct RemotePlacementPlan: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "plan", abstract: "Compare paired Linux hosts for a new workload without reserving capacity",
        discussion: "Uses authenticated resource observations from the running Graftty app. Candidates still require admission and environment preparation. This command does not create worktrees or launch instances.")
    @Option(help: "Required architecture: arm64 or x86_64") var architecture: String
    @Option(help: "Required CPU capacity in vCPUs") var cpus: Double = 1
    @Option(help: "Required memory in MiB") var memoryMib: Int64 = 1024
    @Option(help: "Required disk space in MiB on the reported filesystem") var diskMib: Int64 = 1024
    @Option(help: "Maximum projected CPU utilization as a fraction in 0...1") var maxCpuUtilization = 0.8
    @Option(help: "Memory headroom to retain in MiB") var reserveMemoryMib: Int64 = 512
    @Option(help: "Disk headroom to retain in MiB") var reserveDiskMib: Int64 = 1024
    @Option(help: "Maximum source and receipt age in seconds") var maxSampleAgeSeconds: Double = 30
    @Flag(help: "Print constraints, ranked candidates, and rejection reasons as JSON") var json = false

    func validate() throws { try HostPlacementPlanner.validate(demand: demand(), policy: policy()) }
    private func demand() throws -> HostPlacementDemand {
        .init(architecture: architecture, cpus: cpus, memoryBytes: try bytes(memoryMib), diskBytes: try bytes(diskMib))
    }
    private func policy() throws -> HostPlacementPolicy {
        var value = HostPlacementPolicy()
        value.maximumCPUUtilization = maxCpuUtilization
        value.memoryHeadroomBytes = try bytes(reserveMemoryMib)
        value.diskHeadroomBytes = try bytes(reserveDiskMib)
        value.maximumTelemetryAge = maxSampleAgeSeconds
        return value
    }
    private func bytes(_ mib: Int64) throws -> Int64 {
        let (bytes, overflow) = mib.multipliedReportingOverflow(by: 1024 * 1024)
        guard !overflow, mib >= 0 else { throw ValidationError("Memory and disk amounts must be non-negative MiB values within range.") }
        return bytes
    }
    func run() throws {
        let plan = try HostPlacementPlanner.plan(hosts: RemoteHosts.fetch(), demand: demand(), policy: policy())
        if json {
            let encoder = JSONEncoder.iso8601(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(plan), as: UTF8.self))
            return
        }
        if let selected = plan.selectedHost { print("Candidate: \(String(reflecting: selected.deviceID.value))") }
        else { print("No candidate currently meets the measured requirements.") }
        print("Next action: \(plan.nextAction)")
        for rejection in plan.rejected {
            print("\(String(reflecting: rejection.host.deviceID.value)): \(rejection.reasons.joined(separator: ", "))")
        }
        for limitation in plan.limitations { print(limitation) }
    }
}
