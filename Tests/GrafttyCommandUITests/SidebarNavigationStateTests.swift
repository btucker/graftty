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
    @Test("@spec LAYOUT-2.75: When Attention mode opens, the application shall include every project, order projects by pending attention with direct requests ranked first, and keep that order fixed until Attention closes.")
    func attentionProjectOrderIsFrozen() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let projects = ["a", "b", "c"].map { SidebarProject(id: $0, repositoryID: $0, name: $0) }
        func item(_ id: String, _ project: String, need: String? = nil) -> SidebarActivityItem {
            let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
                recap: .init(title: "Task", completed: "Done", next: "Next", need: need))
            return .init(id: id, projectID: project, worktreeID: id, paneID: nil,
                projectName: project, worktreeName: id, title: stop.title,
                occurrence: stop.occurrence, isBusy: false, agentStop: stop)
        }
        navigation.enterAttention(projects: projects, items: [item("a1", "a"), item("a2", "a"), item("b1", "b", need: "Choose")])
        #expect(navigation.orderedProjects(projects).map(\.id) == ["b", "a", "c"])
        #expect(navigation.attentionItems(live: [item("a1", "a"), item("b1", "b")], projects: projects).count == 2)
        #expect(navigation.orderedProjects(projects).map(\.id) == ["b", "a", "c"])
        navigation.leaveAttention()
        #expect(navigation.orderedProjects(projects).map(\.id) == ["a", "b", "c"])
        navigation.enterAttention(projects: projects, items: [item("c1", "c")])
        #expect(navigation.orderedProjects(projects).first?.id == "c")
    }
    @Test("@spec LAYOUT-2.80: When a project is chosen or the current Attention card opens successfully, the application shall leave Attention, select the target project, and remember the card's worktree.")
    func attentionNavigationOpensWorktreeList() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "attention-navigation", defaults: defaults)
        let projects = [SidebarProject(id: "a", repositoryID: "a", name: "A"),
                        SidebarProject(id: "b", repositoryID: "b", name: "B")]
        let item = SidebarActivityItem(id: "stop", projectID: "b", worktreeID: "worktree-b", paneID: nil,
            projectName: "B", worktreeName: "worktree-b", title: "Stopped",
            occurrence: .init(timestamp: .now, text: "Stopped", source: .agentStop), isBusy: false)
        navigation.enterAttention(projects: projects, items: [item])
        navigation.showProject("a")
        #expect(!navigation.showsAttention)
        #expect(navigation.selectedProjectID == "a")

        navigation.enterAttention(projects: projects, items: [item])
        let stale = navigation.beginOpening(item)
        navigation.showProject("a")
        navigation.finishOpening(stale, succeeded: true)
        #expect(navigation.selectedProjectID == "a")
        #expect(navigation.rememberedWorktrees["b"] == nil)

        navigation.enterAttention(projects: projects, items: [item])
        let opening = navigation.beginOpening(item)
        navigation.finishOpening(opening, succeeded: false)
        #expect(navigation.showsAttention)
        let retry = navigation.beginOpening(item)
        navigation.finishOpening(retry, succeeded: true)
        #expect(!navigation.showsAttention)
        #expect(navigation.selectedProjectID == "b")
        #expect(navigation.rememberedWorktrees["b"] == "worktree-b")
        navigation.enterAttention(projects: projects, items: [])
        #expect(navigation.attentionItems(live: [], projects: projects).map(\.id) == ["stop"])
    }
    @Test("@spec LAYOUT-2.57: When an Attention item is opened, the application shall retain it at its occurrence-time position, highlight the selection, and place newer incoming items above it without moving it into a separate viewed section.")
    func openingAttentionPreservesPosition() throws {
        let suite = "AttentionOrder." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let project = SidebarProject(id: "p", repositoryID: "r", name: "Project")
        func item(_ id: String, _ time: Double) -> SidebarActivityItem {
            .init(id: id, projectID: "p", worktreeID: id, paneID: nil, projectName: "Project", worktreeName: id,
                title: "Stopped", occurrence: .init(timestamp: Date(timeIntervalSince1970: time), text: "Stopped", source: .agentStop), isBusy: false)
        }
        let older = item("older", 1), selected = item("selected", 2), latest = item("latest", 3)
        #expect(navigation.attentionItems(live: [older, selected, latest], projects: [project]).map(\.id) == ["latest", "selected", "older"])
        let opening = navigation.beginOpening(selected)
        #expect(navigation.selectedAttentionID == selected.id)
        // Host acknowledgement can arrive before the open request completes.
        #expect(navigation.attentionItems(live: [older, latest], projects: [project]).map(\.id) == ["latest", "selected", "older"])
        navigation.finishOpening(opening, succeeded: true)
        #expect(navigation.attentionItems(live: [older, latest], projects: [project]).map(\.id) == ["latest", "selected", "older"])
        #expect(navigation.hasViewed(selected))
        var busy = selected
        busy.occurrence = nil
        busy.isBusy = true
        busy.prBadge = .init(number: 342, state: .merged, checks: .success,
                             url: URL(string: "https://github.com/btucker/graftty/pull/342")!)
        let retained = navigation.attentionItems(live: [older, busy, latest], projects: [project])
        #expect(retained.map(\.id) == ["latest", "selected", "older"])
        #expect(retained[1].occurrence == selected.occurrence)
        #expect(retained[1].prBadge == busy.prBadge)
        #expect(navigation.attentionItems(live: [older, latest, item("new", 4)], projects: [project]).map(\.id) == ["new", "latest", "selected", "older"])
        let reopen = navigation.beginOpening(selected)
        navigation.finishOpening(reopen, succeeded: true)
        #expect(navigation.attentionItems(live: [older, latest], projects: [project]).map(\.id) == ["latest", "selected", "older"])
        let failed = navigation.beginOpening(older)
        navigation.finishOpening(failed, succeeded: false)
        #expect(!navigation.hasViewed(older))
        #expect(navigation.selectedAttentionID == selected.id)
        let fresh = item("selected", 5)
        #expect(navigation.attentionItems(live: [older, latest, fresh], projects: [project]).first == fresh)
        #expect(!navigation.hasViewed(fresh))
        navigation.filter = .running
        #expect(navigation.attentionItems(live: [], projects: [project]).isEmpty)
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

    #if os(macOS)
    @Test("""
@spec LAYOUT-2.49: While Attention is displayed in a narrow sidebar column, the application shall fit its filter and request cards within that column, omit the visible filter label, and stack compact Needs You labels above their questions.
""")
    func attentionFitsNarrowColumns() async throws {
        let suite = "AttentionLayout." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let project = SidebarProject(id: "p", repositoryID: "r", name: "graftty-server", accentHex: "54A86C")
        var item = SidebarActivityItem(id: "w", projectID: "p", worktreeID: "w", paneID: nil,
            projectName: project.name, worktreeName: "deploy-to-cloudflare", title: "Claude stopped",
            occurrence: .init(timestamp: Date(), text: "Claude stopped", source: .agentStop), isBusy: false,
            agentStop: SidebarAgentStop(agentName: "Claude", stoppedAt: Date().addingTimeInterval(-120)),
            prBadge: .init(number: 5000, state: .open, checks: .failure,
                           url: URL(string: "https://gitlab.example/team/project/-/merge_requests/5000")!))
        item.worktreeEmoji = "🌿"
        let visit = navigation.beginOpening(item)
        navigation.finishOpening(visit, succeeded: true)
        var incoming = item
        incoming.id = "new"
        incoming.worktreeID = "new"
        incoming.worktreeName = "newer-request"
        incoming.title = "Codex needs input"
        incoming.worktreeEmoji = "🧪"
        incoming.agentStop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
            recap: .init(title: "Device notification relay", context: "Pairing devices for release push notifications.",
                completed: "Client integration and tests are committed.", next: "Verify APNs on a locked phone.",
                need: "Should done mean merged code or a real device notification?"))
        incoming.occurrence = .init(timestamp: Date().addingTimeInterval(1), text: incoming.title, source: .agentStop)
        var secondQuestion = incoming
        secondQuestion.id = "second-question"
        secondQuestion.worktreeID = "second-question"
        secondQuestion.worktreeName = "bottom-scroll-button"
        secondQuestion.worktreeEmoji = nil
        secondQuestion.prBadge = nil
        secondQuestion.agentStop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date().addingTimeInterval(-3600),
            recap: .init(title: "Terminal bottom row clipping", context: "The terminal bottom row is clipped.",
                completed: "Reproduced the clipping.", next: "Inspect the affected pane layout.",
                need: "Is this a local Mac pane, a pane following another display, or the mobile client?"))
        secondQuestion.occurrence = .init(timestamp: Date().addingTimeInterval(-3600), text: secondQuestion.title, source: .agentStop)
        for width in [220.0, 300, 420] {
            let content = SidebarAttentionList(navigation: navigation, items: [incoming, secondQuestion], projects: [project],
                selectionColor: Color.white.opacity(0.16), onOpen: { _ in true })
                .frame(width: width, height: 850)
                .background(Color(red: 0.21, green: 0.23, blue: 0.25)).environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 850), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            #expect(abs(hosting.bounds.width - width) < 1)
            func checkControls(_ view: NSView) {
                if let control = view as? NSControl, !control.isHiddenOrHasHiddenAncestor {
                    let frame = hosting.convert(control.bounds, from: control)
                    #expect(frame.minX >= -1 && frame.maxX <= width + 1)
                    if let label = control as? NSTextField { #expect(label.stringValue != "Activity") }
                }
                view.subviews.forEach(checkControls)
            }
            checkControls(hosting)
            if let directory = ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("attention-\(Int(width)).png"))
            }
        }
    }
    #endif

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
                                             workingCounts: ["project-1": 2, "project-3": 1, "project-4": 101], icons: [:], selectedID: "project-3", showsAttention: false,
                                             collapsed: .constant(collapsed), expandedWidth: .constant(expandedWidth), onSelect: { _ in }, onAttention: {}, onMove: { _, _, _ in },
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
