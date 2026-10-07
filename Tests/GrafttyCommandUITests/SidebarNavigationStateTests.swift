import Foundation
#if os(macOS)
import AppKit
#endif
import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct SidebarNavigationStateTests {
    @Test("@spec LAYOUT-2.84: When an agent resumes, the application shall retain its latest report as previous context and replace it when a newer stopped report arrives.")
    func resumedStopStaysInNeedsYou() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let project = SidebarProject(id: "project", repositoryID: "repo", name: "Project")
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 100),
                                    providerSessionKey: "codex:session:one")
        let stopped = WorktreePanes(path: "/wt", displayName: "wt", repoDisplayName: "Project",
            displayBranch: "wt", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "stable", projectID: "project", unseenAgentStop: stop))
        let item = try #require(SidebarProjection.activity([stopped]).first)
        navigation.updateAttentionItems([item])
        let opening = navigation.beginOpening(item)
        navigation.finishOpening(opening, succeeded: true)
        #expect(navigation.attentionItems(live: [], projects: [project]).count == 1)

        let running = WorktreePanes(path: "/wt", displayName: "wt", repoDisplayName: "Project",
            displayBranch: "wt", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil,
            layout: .leaf(sessionName: "pane", title: "Working", attentionText: nil, isBusy: true,
                          attentionSource: nil),
            sidebar: .init(id: "stable", projectID: "project", unseenAgentStop: nil,
                agentProgressTimes: ["codex:session:one": Date(timeIntervalSince1970: 200).timeIntervalSinceReferenceDate]))
        let live = SidebarProjection.activity([running])
        navigation.reconcile(worktrees: [running], projects: [project])
        let retained = navigation.attentionItems(live: live, projects: [project])
        #expect(retained.map(\.id) == [item.id])
        #expect(retained.first?.isBusy == true)
        navigation.filter = .running
        #expect(navigation.attentionItems(live: live, projects: [project]).count == 1)
        navigation.filter = .needsYou
        // A late UI render of the old report must not expand a resumed card.
        #expect(navigation.attentionItems(live: [item], projects: [project]).first?.isBusy == true)
        var fresh = item
        fresh.agentStop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 300),
            recap: .init(title: "Ready to review", completed: "Finished the change.", next: "Review it."),
            providerSessionKey: "codex:session:one")
        fresh.occurrence = fresh.agentStop?.occurrence
        navigation.updateAttentionItems([fresh])
        let expanded = navigation.attentionItems(live: [], projects: [project])
        #expect(expanded.map(\.id) == [item.id])
        #expect(expanded.first?.isBusy == false)
        #expect(expanded.first?.agentStop?.recap?.title == "Ready to review")
        #expect(!navigation.hasViewed(fresh))
    }

    @Test("Unrelated agent progress and missing snapshots preserve the pending card")
    func unrelatedProgressDoesNotCollapse() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let project = SidebarProject(id: "p", repositoryID: "r", name: "Project")
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date(timeIntervalSince1970: 100),
                                    providerSessionKey: "codex:one")
        let worktree = WorktreePanes(path: "/wt", displayName: "wt", repoDisplayName: "Project",
            displayBranch: "wt", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "stable", projectID: "p", unseenAgentStop: stop,
                agentProgressTimes: ["codex:other": Date(timeIntervalSince1970: 200).timeIntervalSinceReferenceDate]))
        navigation.reconcile(worktrees: [worktree], projects: [project])
        #expect(navigation.attentionItems(live: [], projects: [project]).first?.isBusy == false)
        navigation.reconcile(worktrees: [], projects: [])
        #expect(navigation.attentionItems(live: [], projects: []).isEmpty)
        #expect(navigation.attentionItems(live: [], projects: [project]).map(\.id) == ["stable:stop"])
        navigation.query = "wt"
        #expect(navigation.attentionItems(live: [], projects: [project]).count == 1)
    }

    @Test("@spec LAYOUT-2.85: While agent request context is retained, the application shall preserve it across acknowledgement, navigation, and relaunch without the recent-history limit; explicit dismissal shall hide the current request until a later request arrives.")
    func cardsPersistUntilDismissed() throws {
        let suite = "attention-workspace-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let project = SidebarProject(id: "p", repositoryID: "r", name: "Project")
        let items = (0..<30).map { index in
            SidebarActivityItem(id: "item-\(index)", projectID: "p", worktreeID: "wt-\(index)", paneID: nil,
                projectName: "Project", worktreeName: "Task \(index)", title: "Review",
                occurrence: .init(timestamp: Date(timeIntervalSince1970: Double(index)), text: "Review", source: .agentStop), isBusy: false)
        }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        navigation.updateAttentionItems(items)
        for item in items { navigation.opened(item) }
        navigation.resetSelection()
        let restored = SidebarNavigationState(prefix: "test", defaults: defaults)
        restored.updateAttentionItems([])
        #expect(restored.attentionItems(live: [], projects: [project]).count == 30)
        let dismissed = items[10]
        restored.forget(dismissed.id)
        #expect(!restored.attentionItems(live: items, projects: [project]).contains { $0.id == dismissed.id })
        var fresh = dismissed
        fresh.occurrence = .init(timestamp: Date(timeIntervalSince1970: 100), text: "Another question", source: .agentStop)
        #expect(restored.attentionItems(live: [fresh], projects: [project]).first == fresh)
        let reopened = SidebarNavigationState(prefix: "test", defaults: defaults)
        #expect(!reopened.attentionItems(live: [dismissed], projects: [project]).contains { $0.id == dismissed.id })
    }

    @Test("@spec LAYOUT-2.80: When a project or report target is opened, the application shall select the target project and worktree only after a successful visit and preserve newer navigation intentions.")
    func attentionNavigationOpensWorktreeList() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "attention-navigation", defaults: defaults)
        let projects = [SidebarProject(id: "a", repositoryID: "a", name: "A"),
                        SidebarProject(id: "b", repositoryID: "b", name: "B")]
        let item = SidebarActivityItem(id: "stop", projectID: "b", worktreeID: "worktree-b", paneID: nil,
            projectName: "B", worktreeName: "worktree-b", title: "Stopped",
            occurrence: .init(timestamp: .now, text: "Stopped", source: .agentStop), isBusy: false)
        navigation.updateAttentionItems([item])
        navigation.showProject("a")
        #expect(navigation.selectedProjectID == "a")

        navigation.updateAttentionItems([item])
        let stale = navigation.beginOpening(item)
        navigation.showProject("a")
        navigation.finishOpening(stale, succeeded: true, navigateToProject: true)
        #expect(navigation.selectedProjectID == "a")
        #expect(navigation.rememberedWorktrees["b"] == nil)

        navigation.updateAttentionItems([item])
        let opening = navigation.beginOpening(item)
        navigation.finishOpening(opening, succeeded: false, navigateToProject: true)
        let retry = navigation.beginOpening(item)
        navigation.finishOpening(retry, succeeded: true, navigateToProject: true)
        #expect(navigation.selectedProjectID == "b")
        #expect(navigation.rememberedWorktrees["b"] == "worktree-b")
        navigation.updateAttentionItems([])
        #expect(navigation.attentionItems(live: [], projects: projects).map(\.id) == ["stop"])
    }
    @Test("""
@spec LAYOUT-2.48: When the user drags the project rail edge, the application shall resize the rail, collapse it to icons below the collapse threshold, and retain the last expanded width across relaunches.
""")
    func dragRailAndRestoreWidth() throws {
        let suite = "RailResize." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        #expect(navigation.railExpandedWidth == 196)
        let narrow = SidebarLayoutPolicy.resizedRail(proposedWidth: 150, expandedWidth: 196)
        #expect(!narrow.collapsed)
        #expect(narrow.expandedWidth == 150)
        navigation.railExpandedWidth = narrow.expandedWidth
        let compact = SidebarLayoutPolicy.resizedRail(proposedWidth: 100, expandedWidth: 150)
        #expect(compact.collapsed)
        #expect(compact.expandedWidth == 150)
        navigation.railCollapsed = compact.collapsed
        let restored = SidebarNavigationState(prefix: "test", defaults: defaults)
        #expect(restored.railCollapsed)
        #expect(restored.railExpandedWidth == 150)
        #expect(SidebarLayoutPolicy.resizedRail(proposedWidth: 170, expandedWidth: 150).expandedWidth == 170)
        #expect(!SidebarLayoutPolicy.resizedRail(proposedWidth: 170, expandedWidth: 150).collapsed)
        #expect(SidebarLayoutPolicy.resizedRail(proposedWidth: 900, expandedWidth: 150).expandedWidth == 280)
        #expect(SidebarLayoutPolicy.resizedRail(proposedWidth: -500, expandedWidth: 150).collapsed)
        defaults.set(-10, forKey: "test.railWidth")
        #expect(SidebarNavigationState(prefix: "test", defaults: defaults).railExpandedWidth == 128)
    }


    @Test("@spec LAYOUT-2.2: When the project rail is collapsed, the application shall retain project icons and attention badges in a 64-point rail and persist the collapse preference independently of recent history.")
    func collapseAndRenderManyProjects() async throws {
        let suite = "SidebarTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let projects = (0..<50).map { index in
            SidebarProject(id: "project-\(index)", repositoryID: "route-\(index)", name: "Project \(index)",
                owner: index.isMultiple(of: 2) ? nil : .init(deviceID: .init(value: "studio"), deviceLabel: "Studio Mac", relayDepth: 0))
        }
        navigation.railCollapsed = true
        let restored = SidebarNavigationState(prefix: "test", defaults: defaults)
        #expect(restored.railCollapsed)
        #expect(restored.history.entries.isEmpty)
        #if os(macOS)
        for (collapsed, expandedWidth) in [(true, 196.0), (false, 196.0), (false, 128.0)] {
            let rail = ProjectNavigationRail(projects: projects, counts: ["project-1": 3, "project-4": 102],
                                             workingCounts: ["project-1": 2, "project-3": 1, "project-4": 101], icons: [:], selectedID: "project-3",
                                             collapsed: .constant(collapsed), expandedWidth: .constant(expandedWidth), onSelect: { _ in },  onMove: { _, _, _ in },
                                             management: { AnyView(HStack(spacing: 0) {
                                                 ForEach(["folder.badge.plus", "desktopcomputer"], id: \.self) { icon in
                                                     Button {} label: {
                                                         Image(systemName: icon).frame(minWidth: 28, minHeight: 32)
                                                     }.buttonStyle(.plain)
                                                 }
                                             }) })
                .frame(height: 760).background(Color(red: 0.13, green: 0.14, blue: 0.16)).environment(\.colorScheme, .dark)
            let width = collapsed ? 64 : expandedWidth
            let hosting = NSHostingView(rootView: rail)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 760), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            #expect(Int(hosting.bounds.width) == Int(width))
            #expect(Int(hosting.bounds.height) == 760)
            if let directory = ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(collapsed ? "rail-compact.png" : expandedWidth == 196 ? "rail-expanded.png" : "rail-narrow.png"))
            }
        }
        #endif
    }
}
