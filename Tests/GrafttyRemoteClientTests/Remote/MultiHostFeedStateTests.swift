import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyRemoteClient

@Suite("@spec IPAD-1.33: While the app shows worktrees from several paired hosts, the application shall merge their rows and projects, show cached rows for sleeping hosts, and keep each row tied to the host that delivered it.")
struct MultiHostFeedStateTests {
    private let hostA = UUID(), hostB = UUID()
    private let deviceA = RemoteDeviceID(value: "a"), deviceB = RemoteDeviceID(value: "b")

    private func row(_ name: String, device: RemoteDeviceID, depth: Int = 0, path: String? = nil) -> WorktreePanes {
        WorktreePanes(path: path ?? "/\(device.value)/\(name)", displayName: name, repoDisplayName: "app", displayBranch: name, state: .running,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            origin: WorktreeOrigin(deviceID: device, deviceLabel: device.value, relayDepth: depth),
            sidebar: .init(id: "\(device.value):repo:\(name)", projectID: "\(device.value):repo"))
    }
    private func project(_ device: RemoteDeviceID, depth: Int = 0) -> SidebarProject {
        SidebarProject(id: "\(device.value):repo", repositoryID: "/r", name: "app",
                       owner: WorktreeOrigin(deviceID: device, deviceLabel: device.value, relayDepth: depth), originKey: "k/app")
    }
    private func state(wakeableB: Bool = false) -> MultiHostFeedState {
        var state = MultiHostFeedState()
        state.setHosts([.init(id: hostA, label: "a", deviceID: deviceA, isWakeable: false),
                        .init(id: hostB, label: "b", deviceID: deviceB, isWakeable: wakeableB)])
        return state
    }

    @Test func mergesRowsAndKnowsWhichHostDelivered() {
        var state = state()
        state.apply(rows: [row("one", device: deviceA)], projects: [project(deviceA)], from: hostA)
        state.apply(rows: [row("two", device: deviceB)], projects: [project(deviceB)], from: hostB)
        #expect(Set(state.rows.map(\.displayName)) == ["one", "two"])
        #expect(state.hostID(for: row("two", device: deviceB)) == hostB)
        #expect(state.merged(localDeviceID: nil).projects.count == 1)
    }
    @Test func samePathOnTwoHostsDistinct() {
        var state = state()
        state.apply(rows: [row("w", device: deviceA, path: "/same")], projects: [], from: hostA)
        state.apply(rows: [row("w", device: deviceB, path: "/same")], projects: [], from: hostB)
        #expect(state.rows.count == 2)
        #expect(state.hostID(for: row("w", device: deviceB, path: "/same")) == hostB)
    }
    @Test func relayedRowPrefersDirectHost() {
        var state = state()
        state.apply(rows: [row("two", device: deviceB, depth: 1, path: "relay-1")], projects: [project(deviceB, depth: 1)], from: hostA)
        #expect(state.hostID(for: row("two", device: deviceB, depth: 1, path: "relay-1")) == hostA)
        state.apply(rows: [row("two", device: deviceB)], projects: [project(deviceB)], from: hostB)
        #expect(state.rows.map(\.path) == ["/b/two"])
        #expect(state.hostID(for: state.rows[0]) == hostB)
    }
    @Test func showsCachedRowsBeforeConnecting() {
        var state = state(wakeableB: true)
        state.setCache(.init(projects: [project(deviceB)], rows: [row("sat", device: deviceB)]), for: hostB)
        #expect(state.rows.map(\.displayName) == ["sat"])
        let merged = state.merged(localDeviceID: nil)
        #expect(merged.projects[0].availability == .asleep)
        #expect(merged.sections(for: merged.projects[0].id).temporary[0].availability == .asleep)
    }
    @Test func cacheIsIgnoredWithoutWakeAddresses() {
        var state = state(wakeableB: false)
        state.setCache(.init(projects: [project(deviceB)], rows: [row("sat", device: deviceB)]), for: hostB)
        #expect(state.rows.isEmpty)
    }
    @Test func liveFrameReplacesCache() {
        var state = state(wakeableB: true)
        state.setCache(.init(projects: [project(deviceB)], rows: [row("old", device: deviceB)]), for: hostB)
        state.apply(rows: [row("new", device: deviceB)], projects: [project(deviceB)], from: hostB)
        #expect(state.rows.map(\.displayName) == ["new"])
        #expect(state.merged(localDeviceID: nil).projects[0].availability == .reachable)
    }
    @Test func goingUnavailableFallsBackToLastFrameAsAsleep() {
        var state = state(wakeableB: true)
        state.apply(rows: [row("new", device: deviceB)], projects: [project(deviceB)], from: hostB)
        state.markUnavailable(hostB)
        #expect(state.rows.map(\.displayName) == ["new"])
        #expect(state.merged(localDeviceID: nil).projects[0].availability == .asleep)
    }
    @Test func otherUnavailableHostHidesRowsAndIsOffline() {
        var state = state(wakeableB: false)
        state.apply(rows: [row("new", device: deviceB)], projects: [project(deviceB)], from: hostB)
        state.markUnavailable(hostB)
        #expect(state.rows.isEmpty)
        let merged = state.merged(localDeviceID: nil)
        #expect(merged.projects[0].availability == .offline)
        #expect(merged.offlineHosts(for: merged.projects[0].id) == ["b"])
    }
    @Test func removedHostLeaves() {
        var state = state()
        state.apply(rows: [row("two", device: deviceB)], projects: [project(deviceB)], from: hostB)
        state.setHosts([.init(id: hostA, label: "a", deviceID: deviceA, isWakeable: false)])
        #expect(state.rows.isEmpty)
    }
    @Test func rawRowsStayPerHost() {
        var state = state()
        state.apply(rows: [row("one", device: deviceA)], projects: [], from: hostA)
        #expect(state.rawRows(of: hostA).map(\.displayName) == ["one"])
        #expect(state.rawRows(of: hostB).isEmpty)
    }
    @Test func olderHostWithoutMetadataStillListed() {
        var state = state()
        let legacy = WorktreePanes(path: "/w", displayName: "w", repoDisplayName: "app", displayBranch: "w", state: .running,
            isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil)
        state.apply(rows: [legacy], projects: [], from: hostA)
        #expect(state.rows.count == 1)
        #expect(state.hostID(for: legacy) == hostA)
        #expect(state.merged(localDeviceID: nil).projects.count == 1)
    }
}
