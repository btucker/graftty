import Foundation
import Testing
import GrafttyProtocol
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import GrafttyCommandUI

@MainActor
struct SidebarAttentionBannerTests {
    private let project = SidebarProject(id: "p", repositoryID: "r", name: "Project")

    private func item(_ id: String, time: Double, worktree: String? = nil) -> SidebarActivityItem {
        .init(id: id, projectID: "p", worktreeID: worktree ?? id, paneID: nil,
              projectName: "Project", worktreeName: id, title: "Question",
              occurrence: .init(timestamp: Date(timeIntervalSince1970: time), text: "Question", source: .agentStop),
              isBusy: false)
    }

    @Test("@spec LAYOUT-2.90: When a new pending Attention request arrives while the worktree view is open, the application shall temporarily slide a banner over the top of the worktree list, show each worktree once in arrival order, and suppress existing requests, repeated snapshots.")
    func onlyNewRequestsShowBanners() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let existing = item("existing", time: 10)
        navigation.updateAttentionItems([existing])
        #expect(navigation.attentionBanner == nil)
        let first = item("first", time: 20)
        let second = item("second", time: 30)
        navigation.updateAttentionItems([existing, first])
        navigation.updateAttentionItems([existing, first, second])
        #expect(navigation.attentionBanner?.id == first.id)
        navigation.dismissAttentionBanner(first)
        #expect(navigation.attentionBanner?.id == second.id)
        navigation.dismissAttentionBanner(second)
        navigation.updateAttentionItems([existing, first, second])
        #expect(navigation.attentionBanner == nil)
        navigation.showProject(project.id)
        let hidden = item("while-project-open", time: 40)
        navigation.updateAttentionItems([hidden])
        navigation.resetSelection()
        navigation.updateAttentionItems([hidden])
        #expect(navigation.attentionBanner?.id == hidden.id)
    }

    @Test("A newer request replaces its worktree's queued banner and an old expiry cannot hide it")
    func oneBannerPerWorktree() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        navigation.updateAttentionItems([])
        let old = item("pane", time: 10, worktree: "/wt")
        let recap = item("stop", time: 20, worktree: "/wt")
        navigation.updateAttentionItems([old])
        navigation.updateAttentionItems([old, recap])
        #expect(navigation.attentionBanner?.id == recap.id)
        navigation.dismissAttentionBanner(old)
        #expect(navigation.attentionBanner?.id == recap.id)
        var delayed = recap
        delayed.occurrence = item("stop", time: 15, worktree: "/wt").occurrence
        navigation.updateAttentionItems([delayed])
        #expect(navigation.attentionBanner?.occurrence == recap.occurrence)
        navigation.dismissAttentionBanner(recap)
        #expect(navigation.attentionBanner == nil)
        navigation.updateAttentionItems([old])
        #expect(navigation.attentionBanner == nil)
    }

    @Test func openingAnOlderRequestPreservesANewerBanner() {
        let navigation = SidebarNavigationState(prefix: UUID().uuidString)
        navigation.updateAttentionItems([])
        let first = item("stop", time: 10, worktree: "/wt")
        navigation.updateAttentionItems([first])
        let opening = navigation.beginOpening(first)
        let next = item("stop", time: 20, worktree: "/wt")
        navigation.updateAttentionItems([next])
        navigation.finishOpening(opening, succeeded: true)
        #expect(navigation.attentionBanner?.occurrence == next.occurrence)
        #expect(!navigation.hasViewed(next))
    }

    @Test("@spec LAYOUT-2.91: When an Attention banner is clicked, the application shall open its worktree directly in the project worktree list and acknowledge only a successful visit.")
    func bannerOpensWorktreeDirectly() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let existing = item("existing", time: 10)
        let incoming = item("incoming", time: 20)
        navigation.updateAttentionItems([existing])
        navigation.updateAttentionItems([existing, incoming])
        navigation.filter = .running
        let opening = navigation.beginOpeningAttentionBanner(incoming, projects: [project], items: [existing, incoming])
        navigation.finishOpening(opening, succeeded: true)
        #expect(navigation.selectedProjectID == project.id)
        #expect(navigation.selectedAttentionID == incoming.id)
        #expect(navigation.rememberedWorktrees[project.id] == incoming.worktreeID)
        #expect(navigation.hasViewed(incoming))
        #expect(!navigation.hasViewed(existing))
        #expect(navigation.attentionBanner == nil)
    }

    @Test("@spec LAYOUT-2.93: When a queued Attention request resumes, is viewed, or is dismissed, the application shall remove its banner while preserving requests absent from incomplete or offline snapshots.")
    func resolvedRequestsLeaveBannerQueue() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        navigation.updateAttentionItems([])
        let pending = item("stable:stop", time: 10, worktree: "/wt")
        navigation.updateAttentionItems([pending])
        navigation.reconcile(worktrees: [], projects: [project], authoritativeProjectIDs: [])
        #expect(navigation.attentionBanner?.id == pending.id)
        let resumed = WorktreePanes(path: "/wt", displayName: "Task", repoDisplayName: "Project",
            displayBranch: "task", state: .running, isMainCheckout: false, prBadge: nil,
            stats: nil, attentionText: nil, layout: nil, sidebar: .init(id: "stable", projectID: "p"))
        navigation.reconcile(worktrees: [resumed], projects: [project])
        #expect(navigation.attentionBanner == nil)

        let viewed = item("viewed", time: 20)
        navigation.updateAttentionItems([viewed])
        #expect(navigation.attentionBanner?.id == viewed.id)
        navigation.opened(viewed)
        #expect(navigation.attentionBanner == nil)

        let dismissed = item("dismissed", time: 30)
        navigation.updateAttentionItems([dismissed])
        navigation.forget(dismissed.id)
        #expect(navigation.attentionBanner == nil)
    }

    #if os(macOS)
    @Test func bannerFitsSearchArea() async throws {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
            recap: .init(title: "Attention queue refinements", completed: "Sidebar updated.", next: "Review the changes.",
                         need: "Which of the connected Macs should receive the updated sidebar first?"))
        var incoming = item("needs-attention-refinements", time: 100)
        incoming.agentStop = stop
        incoming.worktreeEmoji = "📥"
        for width in [220.0, 300, 420] {
            let hosting = NSHostingView(rootView: SidebarAttentionBanner(item: incoming, onOpen: {}, onDismiss: {})
                .frame(width: width).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 62),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.height <= 58)
            if let directory = ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("attention-banner-\(Int(width)).png"))
            }
        }
    }
    #endif
}
