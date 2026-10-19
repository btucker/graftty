#if os(macOS)
import AppKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import GrafttyCommandUI

@MainActor
struct WorktreeHistoryContentTests {
    @Test("@spec CONTEXT-15: When Context is opened on Mac or mobile, the application shall show its history section without a disclosure, label human input separately from agent progress, and show a local date and time for each visible event while fitting the available width.")
    func historyRendersImmediatelyAtSidebarAndPhoneWidths() throws {
        let start = Date(timeIntervalSince1970: 1_792_411_200)
        var history = WorktreeHistory(origin: .init(date: start, source: .user))
        history.record(.init(text: "Keep my decisions visible, and let me expand all the steps.", at: start.addingTimeInterval(150)))
        var brief = WorktreeBrief(recap: .init(title: "How we got here", completed: "Reviewed the shared context view.", next: "Compare the timeline.", checkpoint: "Current timeline reviewed"), at: start.addingTimeInterval(60))
        brief.update(.init(title: "How we got here", completed: "Kept creation and user input visible.", next: "Verify Mac and mobile.", checkpoint: "Timeline implemented"), at: start.addingTimeInterval(300))
        for width in [260.0, 360.0, 390.0] {
            let short = NSHostingView(rootView: WorktreeHistoryContent(timeline: .init(history: history, brief: nil), secondary: .secondary)
                .padding(24).frame(width: width).fixedSize(horizontal: false, vertical: true))
            let host = NSHostingView(rootView: WorktreeHistoryContent(timeline: .init(history: history, brief: brief), secondary: .secondary)
                .padding(24).frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            let size = host.fittingSize
            #expect(abs(size.width - width) < 1)
            #expect(size.height > short.fittingSize.height + 90)
            if let path = ProcessInfo.processInfo.environment["GRAFTTY_HISTORY_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: path, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderFront(nil)
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("history-\(Int(width)).png"))
            }
        }
    }
}
#endif
