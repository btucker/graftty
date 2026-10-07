#if os(macOS)
import AppKit
import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct SidebarWorktreeReportTests {
    @Test("@spec LAYOUT-2.131: While a worktree report is previewed, the application shall wrap its full question and recap within the available width and keep Open and Close controls accessible without acknowledging the request.")
    func reportFitsNarrowWidth() async throws {
        let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: Date().addingTimeInterval(-420),
            recap: .init(title: "Reconnect after a sleeping Mac", context: "A paired Mac appears online while its control connection is stale.",
                         completed: "Confirmed the stale connection and added a retry prototype.",
                         next: "Verify both Macs recover after sleep.", need: "Retry silently, or ask before reconnecting? Keep the current terminal session available while reconnecting."),
            paneTitle: "Codex · reconnect handling")
        let row = WorktreePanes(path: "/task", displayName: "remote-reconnect", repoDisplayName: "graftty", displayBranch: "remote-reconnect",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "task", projectID: "p", unseenAgentStop: stop, lastAgentStop: stop))
        let navigation = SidebarNavigationState(prefix: UUID().uuidString)
        for width in [260.0, 380.0] {
            let content = SidebarWorktreeReport(context: navigation.worktreeContext(row), onOpen: { false }, onDismiss: {}, onClose: {})
                .frame(width: width, height: 540).background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: 540),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            #expect(abs(host.bounds.width - width) < 1)
            func check(_ view: NSView) {
                if let control = view as? NSControl, !control.isHiddenOrHasHiddenAncestor {
                    let rect = host.convert(control.bounds, from: control)
                    #expect(rect.minX >= -1 && rect.maxX <= width + 1)
                }
                view.subviews.forEach(check)
            }
            check(host)
            #expect(navigation.worktreeContext(row).pending.count == 1)
            if let directory = ProcessInfo.processInfo.environment["GRAFTTY_SIDEBAR_RENDER_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("report-\(Int(width)).png"))
            }
        }
    }
}
#endif
