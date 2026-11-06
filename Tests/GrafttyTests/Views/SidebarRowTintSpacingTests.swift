import AppKit
import GrafttyCommandUI
import GrafttyKit
import GrafttyProtocol
import SwiftUI
import Testing
@testable import Graftty

@MainActor
struct SidebarRowTintSpacingTests {
    @Test("@spec LAYOUT-2.213: While a selected sidebar row shows its question on a tint, the application shall leave the same space between the tint and the selection's bottom edge as between the tint and its trailing edge.")
    func selectionInsetsTheTintEvenly() async throws {
        let theme = GhosttyTheme.fallback
        let worktree = WorktreeEntry(path: "/repo/feature", branch: "feature", state: .running)
        let status = SidebarRowStatus.question("Merge main into the project branch and fix the conflicts?", paneID: "a")
        let view = WorktreeBlock(worktree: worktree, repoID: UUID(), isActive: true, theme: theme, appState: .constant(AppState()),
            reorderingEnabled: false, onSelect: {}, menu: { _ in NSMenu() }) {
            WorktreeRow(entry: worktree, isActive: true, displayName: "feature", isMainCheckout: false,
                theme: theme, stats: nil, baseRef: nil, prBadge: nil).frame(minHeight: 24)
        } status: {
            SidebarWorktreeStatusTarget(status: status, secondary: theme.sidebarSecondaryText, onOpen: {})
        }
        .padding(10).frame(width: 300).background(Color.black).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / host.bounds.width
        func color(_ x: Int, _ y: Int) -> NSColor { bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .clear }
        func differs(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.03
        }
        /// Points between the selection's edge and the tint, walking in from the outside.
        func gap(along positions: [Int], at sample: (Int) -> NSColor) throws -> Double {
            let outside = sample(positions[0])
            let edge = try #require(positions.firstIndex { differs(sample($0), outside) })
            let selection = sample(positions[edge + Int(2 * scale)])
            let tint = try #require(positions[(edge + Int(2 * scale))...].firstIndex { differs(sample($0), selection) })
            return Double(tint - edge) / scale
        }
        let middleX = bitmap.pixelsWide / 2
        let bottom = try gap(along: Array((0..<bitmap.pixelsHigh).reversed())) { color(middleX, $0) }
        // Above the tint's rounded corner, so its edge is straight. Walking in from
        // the side reaches the tint before any of its text.
        let tintY = bitmap.pixelsHigh - 1 - Int((10 + bottom + 10) * scale)
        let trailing = try gap(along: Array((0..<bitmap.pixelsWide).reversed())) { color($0, tintY) }
        #expect(abs(bottom - trailing) <= 1, "bottom \(bottom), trailing \(trailing)")
    }

    @Test("@spec LAYOUT-2.214: While the sidebar lists worktrees with status lines, the application shall leave at least twice as much space between a status line and the next worktree's name as between a name and its own status line, so each row reads as one group.")
    func rowsReadAsSeparateGroups() async throws {
        let theme = GhosttyTheme.fallback
        func row(_ name: String) -> some View {
            let worktree = WorktreeEntry(path: "/repo/\(name)", branch: name, state: .running)
            return WorktreeBlock(worktree: worktree, repoID: UUID(), isActive: false, theme: theme, appState: .constant(AppState()),
                reorderingEnabled: false, onSelect: {}, menu: { _ in NSMenu() }) {
                WorktreeRow(entry: worktree, isActive: false, displayName: name, isMainCheckout: false,
                    theme: theme, stats: nil, baseRef: nil, prBadge: nil).frame(minHeight: 24)
            } status: {
                SidebarWorktreeStatusTarget(status: .whereWeAre("Typography checks passed", isUnread: true),
                    secondary: theme.sidebarSecondaryText, onOpen: {})
            }
        }
        // The spacing `ProjectWorktreeColumn` and the pinned pane put between rows.
        let view = VStack(alignment: .leading, spacing: 3) { row("first"); row("second") }
            .padding(10).frame(width: 300).background(Color.black).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / host.bounds.width
        // Right of the identity column, so only text counts.
        let textColumns = Int(60 * scale)..<bitmap.pixelsWide
        func hasInk(_ y: Int) -> Bool {
            textColumns.contains { x in
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                return c.redComponent + c.greenComponent + c.blueComponent > 0.3
            }
        }
        var gaps: [Double] = []
        var blank = 0
        var seenInk = false
        for y in 0..<bitmap.pixelsHigh {
            if hasInk(y) {
                if seenInk, blank > 0 { gaps.append(Double(blank) / scale) }
                seenInk = true
                blank = 0
            } else {
                blank += 1
            }
        }
        // First name, its status, second name, its status.
        try #require(gaps.count == 3, "gaps \(gaps)")
        #expect(gaps[1] >= 2 * gaps[0], "name to status \(gaps[0]), status to next name \(gaps[1])")
    }

    @Test("@spec LAYOUT-2.215: While the sidebar shows a worktree row, the application shall draw its name at no less than 80 percent of the theme foreground, and at full foreground when the row is selected, brighter than the status line beneath it.", arguments: [false, true])
    func namesStandOutFromTheirStatus(selected: Bool) async throws {
        let theme = GhosttyTheme.fallback
        let worktree = WorktreeEntry(path: "/repo/voice-mode", branch: "voice-mode", state: .running)
        let view = WorktreeBlock(worktree: worktree, repoID: UUID(), isActive: selected, theme: theme, appState: .constant(AppState()),
            reorderingEnabled: false, onSelect: {}, menu: { _ in NSMenu() }) {
            WorktreeRow(entry: worktree, isActive: selected, displayName: "voice-mode", isMainCheckout: false,
                theme: theme, stats: nil, baseRef: nil, prBadge: nil).frame(minHeight: 24)
        } status: {
            SidebarWorktreeStatusTarget(status: .whereWeAre("Rendered a demo", isUnread: true),
                secondary: theme.sidebarSecondaryText, onOpen: {})
        }
        .padding(10).frame(width: 300).background(Color.black).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / host.bounds.width
        let fg = try #require(NSColor(theme.foreground).usingColorSpace(.deviceRGB))
        let full = fg.redComponent + fg.greenComponent + fg.blueComponent
        func brightest(_ rows: Range<Int>) -> Double {
            var best = 0.0
            for y in rows { for x in Int(60 * scale)..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                best = max(best, (c.redComponent + c.greenComponent + c.blueComponent) / full)
            } }
            return best
        }
        let middle = bitmap.pixelsHigh / 2
        let name = brightest(0..<middle)
        let status = brightest(middle..<bitmap.pixelsHigh)
        #expect(name >= (selected ? 0.97 : 0.78), "name \(name)")
        #expect(name > status + 0.15, "name \(name), status \(status)")
    }
}
