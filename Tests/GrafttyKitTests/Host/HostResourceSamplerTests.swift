import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyKit

struct HostResourceSamplerTests {
    @Test("@spec REMOTE-24.13: While a Linux host runs, the host shall periodically measure CPU utilization from successive kernel counters, available memory from MemAvailable, and unprivileged filesystem headroom, reporting unreadable or invalid measurements as unknown rather than zero.")
    func samplesLinuxCountersWithoutDoubleCountingGuestTime() throws {
        var sampler = LinuxHostResourceMeasurements()
        let first = sampler.sample(stat: "cpu 100 0 100 800 0 0 0 0 50 0\ncpu0 1\ncpu1 1\n", meminfo: "MemTotal: 1000 kB\nMemAvailable: 400 kB\n")
        #expect(first.cpuUtilization == nil)
        #expect(first.cpuCount == 2)
        #expect(first.memoryTotalBytes == 1024000)
        #expect(first.memoryAvailableBytes == 409600)
        let second = sampler.sample(stat: "cpu 150 0 150 900 0 0 0 0 75 0\ncpu0 1\ncpu1 1\n", meminfo: nil)
        #expect(second.cpuUtilization == 0.5)
        #expect(second.memoryAvailableBytes == nil)
        let reset = sampler.sample(stat: "cpu 1 0 0 1 0 0 0 0\n", meminfo: "MemFree: 200 kB\n")
        #expect(reset.cpuUtilization == nil)
        #expect(reset.memoryAvailableBytes == nil)
        #expect(sampler.sample(stat: nil, meminfo: nil).cpuUtilization == nil)
        #expect(sampler.sample(stat: "cpu 2 0 0 2 0 0 0 0\n", meminfo: nil).cpuUtilization == nil)
    }

    @Test func hostListSocketMessagesRoundTrip() throws {
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(NotificationMessage.listRemoteHosts)) == .listRemoteHosts)
        #expect(try JSONDecoder().decode(ResponseMessage.self, from: JSONEncoder().encode(ResponseMessage.remoteHosts([]))) == .remoteHosts([]))
    }

    @MainActor @Test func headlessSnapshotIncludesItsResourceSample() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try HeadlessHostRuntime(configuration: HostConfiguration(stateDirectory: root,
            runtimeDirectory: root.appendingPathComponent("run"), zmxExecutable: URL(fileURLWithPath: "/bin/true")), initialState: AppState())
        let sample = HostResourceSnapshot(sampledAt: 100, cpuCount: 4, diskPath: root.path)
        runtime.hostResources = sample
        guard case .snapshot(_, let sidebar) = runtime.panesMessage() else { return }
        #expect(sidebar?.hostResources == sample)
    }

    @Test func invalidMemoryAndCountersStayUnknown() {
        var sampler = LinuxHostResourceMeasurements()
        let result = sampler.sample(stat: "cpu -1 0 0 1\n", meminfo: "MemTotal: 1 kB\nMemAvailable: 2 kB\n")
        #expect(result.cpuUtilization == nil)
        #expect(result.memoryAvailableBytes == nil)
        #expect(sampler.sample(stat: nil, meminfo: "MemTotal: 9223372036854775807 kB\n").memoryTotalBytes == nil)
    }

    @Test func diskProbeDistinguishesUnknownFromFull() async throws {
        let sampler = HostResourceSampler()
        let missing = await sampler.sample(diskPath: "/nonexistent-graftty-\(UUID().uuidString)", activeWorktrees: 2, pendingOperations: 1)
        #expect(missing.diskAvailableBytes == nil)
        #expect(missing.activeWorktrees == 2)
        #expect(missing.pendingWorktreeOperations == 1)
        #expect(missing.pendingPlacements == nil)
        let existing = await sampler.sample(diskPath: FileManager.default.temporaryDirectory.path, activeWorktrees: 0, pendingOperations: 0)
        #expect(try #require(existing.diskAvailableBytes) >= 0)
        #expect(existing.isValid)
    }
}
