import Foundation
import Testing
@testable import GrafttyProtocol

struct HostResourceSnapshotTests {
    @Test("@spec REMOTE-31.12: When a host publishes resource observations on its authenticated panes-state channel, the protocol shall preserve optional CPU, memory, disk, and workload measurements with a sample timestamp while accepting legacy snapshots without telemetry.")
    func preservesOptionalResourceObservations() throws {
        let data = Data(#"{"projects":[],"supportsNavigationEditing":true,"hostResources":{"sampledAt":1750000000,"cpuCount":4,"cpuUtilization":0.25,"memoryTotalBytes":17179869184,"memoryAvailableBytes":8589934592,"diskPath":"/work","diskAvailableBytes":1000000000,"activeWorktrees":2}}"#.utf8)
        let snapshot = try JSONDecoder().decode(SidebarSnapshot.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(object["hostResources"] != nil)
    }
    @Test func legacyAndInvalidTelemetryDoNotBreakNavigation() throws {
        for payload in ["null", "{\"sampledAt\":-1}", "\"invalid\""] {
            let data = Data("{\"projects\":[],\"supportsNavigationEditing\":true,\"hostResources\":\(payload)}".utf8)
            #expect(try JSONDecoder().decode(SidebarSnapshot.self, from: data).hostResources == nil)
        }
        let legacy = Data(#"{"projects":[],"supportsNavigationEditing":true}"#.utf8)
        #expect(try JSONDecoder().decode(SidebarSnapshot.self, from: legacy).hostResources == nil)
    }

    @Test func freshnessRejectsOldFutureAndInvalidSamples() {
        let sample = HostResourceSnapshot(sampledAt: 100, cpuCount: 4, cpuUtilization: 0.2, diskPath: "/work")
        let observation = HostResourceObservation(sample: sample, receivedAt: 102)
        #expect(observation.isFresh(at: Date(timeIntervalSince1970: 120)))
        #expect(!observation.isFresh(at: Date(timeIntervalSince1970: 131)))
        #expect(!observation.isFresh(at: Date(timeIntervalSince1970: 101)))
        var future = sample; future.sampledAt = 200
        #expect(!HostResourceObservation(sample: future, receivedAt: 102).isFresh(at: Date(timeIntervalSince1970: 103)))
        var invalid = sample; invalid.cpuUtilization = 1.1
        #expect(!invalid.isValid)
    }

}
