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
    @Test("@spec LAYOUT-2.2: When the project rail is collapsed, the application shall retain project icons and attention badges in a 64-point rail and persist the collapse preference independently of recent history.")
    func collapseAndRenderManyProjects() async throws {
        let suite = "SidebarTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let navigation = SidebarNavigationState(prefix: "test", defaults: defaults)
        let projects = (0..<50).map { SidebarProject(id: "project-\($0)", repositoryID: "route-\($0)", name: "Project \($0)") }
        navigation.railCollapsed = true
        let restored = SidebarNavigationState(prefix: "test", defaults: defaults)
        #expect(restored.railCollapsed)
        #expect(restored.history.entries.isEmpty)
        #if os(macOS)
        for collapsed in [true, false] {
            let rail = ProjectNavigationRail(projects: projects, counts: ["project-1": 3, "project-4": 102], icons: [:], selectedID: "project-3", showsAttention: false,
                                             collapsed: .constant(collapsed), onSelect: { _ in }, onAttention: {}, onMove: { _, _, _ in })
                .frame(height: 760).background(Color(red: 0.13, green: 0.14, blue: 0.16)).environment(\.colorScheme, .dark)
            let width = collapsed ? 64 : 196
            let hosting = NSHostingView(rootView: rail)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 760), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            #expect(Int(hosting.bounds.width) == width)
            #expect(Int(hosting.bounds.height) == 760)
            if let directory = ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(collapsed ? "rail-compact.png" : "rail-expanded.png"))
            }
        }
        #endif
    }
}
