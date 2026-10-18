import Foundation
import Testing
import GrafttyProtocol
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import GrafttyCommandUI

@MainActor
struct SidebarWorktreeRequestNavigationTests {
    private let project = SidebarProject(id: "p", repositoryID: "r", name: "Project")

    private func item(_ id: String, time: Double, worktree: String? = nil) -> SidebarActivityItem {
        .init(id: id, projectID: "p", worktreeID: worktree ?? id, paneID: nil,
              projectName: "Project", worktreeName: id, title: "Question",
              occurrence: .init(timestamp: Date(timeIntervalSince1970: time), text: "Question", source: .agentStop),
              isBusy: false)
    }

    @Test("@spec LAYOUT-2.91: When a worktree request is opened, the application shall open its worktree directly in the project worktree list and acknowledge only a successful visit.")
    func requestOpensWorktreeDirectly() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let existing = item("existing", time: 10)
        let incoming = item("incoming", time: 20)
        navigation.updateAttentionItems([existing])
        navigation.updateAttentionItems([existing, incoming])
        navigation.filter = .running
        let opening = navigation.beginOpeningWorktreeRequest(incoming, projects: [project], items: [existing, incoming])
        navigation.finishOpening(opening, succeeded: true)
        #expect(navigation.selectedProjectID == project.id)
        #expect(navigation.selectedAttentionID == incoming.id)
        #expect(navigation.rememberedWorktrees[project.id] == incoming.worktreeID)
        #expect(navigation.hasViewed(incoming))
        #expect(!navigation.hasViewed(existing))
    }

}
