import Testing
@testable import GrafttyProtocol

struct SidebarTeamSectionsTests {
    @Test("@spec LAYOUT-2.109: When viewing sidebar membership from a host, the application shall group Tasks before Team, preserve each section's supplied order and main-checkout placement, and retain the existing layout for hosts without membership metadata.")
    func partitionsMembershipWithoutReorderingOrDroppingRows() {
        func row(_ id: String, isMember: Bool? = nil, isMain: Bool = false) -> WorktreePanes {
            WorktreePanes(path: id, displayName: id, repoDisplayName: "Project", displayBranch: id,
                state: .closed, isMainCheckout: isMain, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                sidebar: .init(id: id, projectID: "p", isTeamMember: isMember))
        }
        let teamA = row("architect", isMember: true)
        let teamB = row("qa", isMember: true)
        let task = row("fix", isMember: false)
        let main = row("main", isMember: true, isMain: true)
        let sections = SidebarWorktreeSections([main, teamA, task, teamB])
        #expect(sections.hasMembershipMetadata)
        #expect(sections.tasks.map(\.path) == ["main", "fix"])
        #expect(sections.team.map(\.path) == ["architect", "qa"])
        let legacy = SidebarWorktreeSections([row("a"), row("b")])
        #expect(!legacy.hasMembershipMetadata)
        #expect(legacy.tasks.map(\.path) == ["a", "b"])
        #expect(legacy.team.isEmpty)
    }
}
