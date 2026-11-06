import Testing
@testable import GrafttyProtocol

@Suite("@spec PROJECT-4.1: When hosts publish projects with equal origin keys, the application shall show them as one project, keeping projects without a key separate and every project's rows visible.")
struct MergedProjectsTests {
    private let mac = WorktreeOrigin(deviceID: RemoteDeviceID(value: "mac"), deviceLabel: "MacBook", relayDepth: 0)
    private let box = WorktreeOrigin(deviceID: RemoteDeviceID(value: "box"), deviceLabel: "build-box", relayDepth: 1)

    private func project(_ id: String, owner: WorktreeOrigin?, key: String? = nil, name: String = "app",
                         rank: String? = nil, at: Double? = nil, icon: String? = nil) -> SidebarProject {
        SidebarProject(id: id, repositoryID: "repo-\(id)", name: name, owner: owner, iconRevision: icon,
                       originKey: key, rank: rank, rankChangedAt: at)
    }
    private func merge(_ projects: [SidebarProject], _ availability: @escaping (SidebarProject) -> HostAvailability = { _ in .reachable }) -> [MergedProject] {
        ProjectMerge.merge(projects, availability: availability, localDeviceID: mac.deviceID)
    }

    @Test func sameKeyMergesAcrossHosts() {
        let merged = merge([project("a", owner: mac, key: "github.com/acme/app"), project("b", owner: box, key: "github.com/acme/app")])
        #expect(merged.count == 1)
        #expect(merged[0].id == "origin:github.com/acme/app")
        #expect(merged[0].members.map(\.id).sorted() == ["a", "b"])
        #expect(merged[0].representative.id == merged[0].id)
    }
    @Test func twoCheckoutsOnOneHostMerge() {
        #expect(merge([project("a", owner: mac, key: "k/app"), project("c", owner: mac, key: "k/app")]).count == 1)
    }
    @Test func noKeyStaysSeparate() {
        let merged = merge([project("a", owner: mac), project("b", owner: box)])
        #expect(merged.map(\.id) == ["a", "b"])
    }
    @Test func differentKeysSameNameShowOwner() {
        let merged = merge([project("a", owner: mac, key: "github.com/acme/app"), project("b", owner: box, key: "github.com/me/app"), project("c", owner: box, key: "github.com/me/tool", name: "tool")])
        #expect(Set(merged.map(\.name)) == ["acme/app", "me/app", "tool"])
    }
    @Test func newestRankWins() {
        let merged = merge([project("a", owner: mac, key: "k/app", rank: "b", at: 10), project("b", owner: box, key: "k/app", rank: "c", at: 20)])
        #expect(merged[0].rank == "c")
        #expect(merged[0].rankChangedAt == 20)
    }
    @Test func timedBeatsUntimed() {
        #expect(merge([project("a", owner: mac, key: "k/app", rank: "a"), project("b", owner: box, key: "k/app", rank: "c", at: 1)])[0].rank == "c")
    }
    @Test func lowestUntimedWins() {
        #expect(merge([project("a", owner: mac, key: "k/app", rank: "c"), project("b", owner: box, key: "k/app", rank: "b")])[0].rank == "b")
    }
    @Test func sortsByRankThenID() {
        let merged = merge([project("z", owner: mac, rank: "b"), project("y", owner: box, rank: "b"), project("x", owner: mac, rank: "a")])
        #expect(merged.map(\.id) == ["x", "y", "z"])
    }
    @Test func olderHostProjectsSortLastAndAreNotDropped() {
        let merged = merge([project("old2", owner: box), project("new", owner: mac, rank: "b"), project("old1", owner: box)])
        #expect(merged.map(\.id) == ["new", "old2", "old1"])
    }
    @Test func malformedRankIsIgnored() {
        #expect(merge([project("a", owner: mac, rank: "not valid!")])[0].rank == nil)
    }
    @Test func availabilityPrefersReachableThenAsleep() {
        let pair = [project("a", owner: mac, key: "k/app"), project("b", owner: box, key: "k/app")]
        #expect(merge(pair) { $0.id == "a" ? .offline : .reachable }[0].availability == .reachable)
        let asleep = merge(pair) { $0.id == "a" ? .offline : .asleep }[0]
        #expect(asleep.availability == .asleep)
        #expect(asleep.representative.isAvailable)
        #expect(asleep.representative.statusLabel == "Asleep")
        let offline = merge(pair) { _ in .offline }[0]
        #expect(!offline.representative.isAvailable)
        #expect(offline.representative.ownerSubtitle(localDeviceID: nil) == "Offline")
    }
    @Test func idStableWhenAHostDisappears() {
        let both = merge([project("a", owner: mac, key: "k/app"), project("b", owner: box, key: "k/app")])
        let one = merge([project("b", owner: box, key: "k/app")])
        #expect(both[0].id == one[0].id)
    }
    @Test func relayedProjectCollapsesToDirect() {
        let direct = WorktreeOrigin(deviceID: box.deviceID, deviceLabel: "build-box", relayDepth: 0)
        let merged = merge([project("b", owner: box, key: "k/app"), project("b", owner: direct, key: "k/app")])
        #expect(merged[0].members.map(\.owner?.relayDepth) == [0])
    }
    @Test func repairsTargetOnlyReachableStaleHosts() {
        let a = project("a", owner: mac, key: "k/app", rank: "b", at: 20)
        let stale = project("b", owner: box, key: "k/app", rank: "c", at: 10)
        let away = project("c", owner: box, key: "k/app", rank: "c")
        let older = project("d", owner: box, key: "k/app")
        let repairs = ProjectMerge.repairs(merge([a, stale, away, older])) { $0.id != "c" }
        #expect(repairs.map(\.member.id) == ["b"])
        #expect(repairs[0].rank == "b")
        #expect(repairs[0].changedAt == 20)
    }
    @Test func noRepairForUntimedRanks() {
        #expect(ProjectMerge.repairs(merge([project("a", owner: mac, key: "k/app", rank: "b"), project("b", owner: box, key: "k/app", rank: "c")])) { _ in true }.isEmpty)
    }
    @Test func iconPrefersLocalMember() {
        let merged = merge([project("b", owner: box, key: "k/app", icon: "remote"), project("a", owner: mac, key: "k/app", icon: "local")])
        #expect(merged[0].representative.iconRevision == "local")
        #expect(merged[0].iconMember?.id == "a")
    }
    @Test func memberMapCoversEveryMember() {
        let map = ProjectMerge.memberToMergedID(merge([project("a", owner: mac, key: "k/app"), project("b", owner: box, key: "k/app"), project("c", owner: box)]))
        #expect(map == ["a": "origin:k/app", "b": "origin:k/app", "c": "c"])
    }
}
