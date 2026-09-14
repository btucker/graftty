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
@spec LAYOUT-2.49: While Attention is displayed in a narrow sidebar column, the application shall fit its filter and request cards within that column and omit the visible filter label.
""")
    func attentionFitsNarrowColumns() async throws {
        let suite = "AttentionLayout." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let project = SidebarProject(id: "p", repositoryID: "r", name: "graftty-server")
        let item = SidebarActivityItem(id: "w", projectID: "p", worktreeID: "w", paneID: nil,
            projectName: project.name, worktreeName: "deploy-to-cloudflare", title: "Claude stopped",
            occurrence: .init(timestamp: Date(), text: "Claude stopped", source: .agentStop), isBusy: false,
            agentStop: SidebarAgentStop(agentName: "Claude", stoppedAt: Date().addingTimeInterval(-120)))
        for width in [220.0, 300, 420] {
            let content = SidebarAttentionList(navigation: navigation, items: [item], projects: [project], icons: [:], onOpen: { _ in })
                .frame(width: width, height: 520)
                .background(Color(red: 0.21, green: 0.23, blue: 0.25)).environment(\.colorScheme, .dark)
            let hosting = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
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
            let rail = ProjectNavigationRail(projects: projects, counts: ["project-1": 3, "project-4": 102], icons: [:], selectedID: "project-3", showsAttention: false,
                                             collapsed: .constant(collapsed), expandedWidth: .constant(expandedWidth), onSelect: { _ in }, onAttention: {}, onMove: { _, _, _ in })
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
