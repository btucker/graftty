import Testing
@testable import GrafttyProtocol

struct SidebarPinnedSectionsTests {
    @Test("@spec LAYOUT-2.109: When viewing sidebar membership from a host, the application shall group Pinned Agents before temporary worktrees, place the default-branch checkout first among pinned rows, preserve other supplied order, and retain the existing layout for hosts without membership metadata.")
    func partitionsMembershipWithoutReorderingOrDroppingRows() {
        func row(_ id: String, isMember: Bool? = nil, isMain: Bool = false) -> WorktreePanes {
            WorktreePanes(path: id, displayName: id, repoDisplayName: "Project", displayBranch: id,
                state: .closed, isMainCheckout: isMain, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                sidebar: .init(id: id, projectID: "p", isPinned: isMember))
        }
        let pinnedA = row("architect", isMember: true)
        let pinnedB = row("qa", isMember: true)
        let task = row("fix", isMember: false)
        let main = row("trunk", isMember: false, isMain: true)
        let sections = SidebarWorktreeSections([pinnedA, task, main, pinnedB])
        #expect(sections.hasPinMetadata)
        #expect(sections.tasks.map(\.path) == ["fix"])
        #expect(sections.pinned.map(\.path) == ["trunk", "architect", "qa"])
        let legacy = SidebarWorktreeSections([row("trunk", isMain: true), row("a"), row("b")])
        #expect(!legacy.hasPinMetadata)
        #expect(legacy.tasks.map(\.path) == ["trunk", "a", "b"])
        #expect(legacy.pinned.isEmpty)
    }
}
