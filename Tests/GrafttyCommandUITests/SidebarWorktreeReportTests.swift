#if os(macOS)
import AppKit
import SwiftUI
import Testing
import GrafttyProtocol
@testable import GrafttyCommandUI

@MainActor
struct SidebarWorktreeReportTests {
    @Test("@spec LAYOUT-2.133: While an inline worktree question is displayed, the application shall align its accent and text to the leading edge regardless of question length.")
    func questionUsesLeadingEdge() throws {
        for question in ["Set auto-merge?", "Refresh the token so the analytics agent can read the pages and continue its work."] {
            let stop = SidebarAgentStop(agentName: "Codex", stoppedAt: .now,
                recap: .init(title: "Report", context: "Context", completed: "Done", next: "Next", need: question))
            let row = WorktreePanes(path: "/task", displayName: "Task", repoDisplayName: "Project", displayBranch: "task",
                state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
                sidebar: .init(id: "task", projectID: "p", unseenAgentStop: stop, lastAgentStop: stop))
            let host = NSHostingView(rootView: VStack {
                SidebarWorktreeQuestion(context: SidebarWorktreeContext(worktree: row))
            }.frame(width: 380).fixedSize(horizontal: false, vertical: true))
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            var firstAccentX: Int?
            for x in 0..<bitmap.pixelsWide {
                if (0..<bitmap.pixelsHigh).contains(where: { y in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.redComponent > 0.5 && color.redComponent > color.greenComponent * 1.3 && color.greenComponent > color.blueComponent * 1.3
                }) { firstAccentX = x; break }
            }
            #expect(firstAccentX == 0)
        }
    }

    @Test("@spec LAYOUT-2.131: While a mobile worktree report is previewed, the application shall wrap its full question and recap within the available width and keep Open and Close controls accessible without acknowledging the request.")
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
