import Testing
@testable import GrafttyProtocol

@Suite("@spec REMOTE-13.35: When a project is on several hosts, Add Worktree shall offer the hosts that have it, defaulting to the last one used unless that host is asleep and another is awake, so opening the sheet wakes nothing while any host is awake.")
struct AddWorktreeHostChoiceTests {
    private func choice(_ id: String, _ availability: HostAvailability = .reachable, host: String? = nil, path: String? = nil) -> AddWorktreeHostChoice {
        AddWorktreeHostChoice(id: id, host: host ?? id, path: path, availability: availability)
    }
    @Test func defaultsToLastUsed() {
        let result = AddWorktreeHostChoice.defaultChoice([choice("a"), choice("b")], lastUsedID: "b")
        #expect(result?.choice.id == "b")
        #expect(result?.wakesOnOpen == false)
    }
    @Test func unknownLastUsedFallsBackToFirst() {
        #expect(AddWorktreeHostChoice.defaultChoice([choice("a"), choice("b")], lastUsedID: "gone")?.choice.id == "a")
    }
    @Test func sleepingLastUsedDefersToAwakeHost() {
        let result = AddWorktreeHostChoice.defaultChoice([choice("a"), choice("b", .asleep)], lastUsedID: "b")
        #expect(result?.choice.id == "a")
        #expect(result?.wakesOnOpen == false)
    }
    @Test func allAsleepWakesLastUsed() {
        let result = AddWorktreeHostChoice.defaultChoice([choice("a", .asleep), choice("b", .asleep)], lastUsedID: "b")
        #expect(result?.choice.id == "b")
        #expect(result?.wakesOnOpen == true)
    }
    @Test func offlineDisabled() {
        #expect(!choice("a", .offline).isSelectable)
        #expect(choice("a", .asleep).isSelectable)
        #expect(AddWorktreeHostChoice.defaultChoice([choice("a", .offline), choice("b", .asleep)], lastUsedID: "a")?.choice.id == "b")
        #expect(AddWorktreeHostChoice.defaultChoice([choice("a", .offline)], lastUsedID: nil) == nil)
    }
    @Test func hiddenForOneHost() {
        #expect(!AddWorktreeHostChoice.showsRow([choice("a")]))
        #expect(AddWorktreeHostChoice.showsRow([choice("a"), choice("b")]))
    }
    @Test func twoCheckoutsOnOneHostShowPath() {
        let labels = AddWorktreeHostChoice.labeled([choice("a", host: "box", path: "/srv/one"), choice("b", host: "box", path: "/srv/two"), choice("c", host: "mini", path: "/srv/one")])
        #expect(labels.map(\.label) == ["box · /srv/one", "box · /srv/two", "mini"])
    }
}
