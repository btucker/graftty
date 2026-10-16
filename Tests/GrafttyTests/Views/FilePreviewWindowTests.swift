import AppKit
import GrafttyKit
import Testing
@testable import Graftty

@MainActor
struct FilePreviewWindowTests {
    private func files(_ name: String) throws -> [FilePreviewFile] {
        [try FilePreviewFile(.init(filename: name, bytes: Data(name.utf8)))]
    }

    @Test("@spec PREVIEW-1.6: When a Mac preview arrives, the application shall retain the latest 32 requests as immutable session history grouped by worktree, including replaced and closed previews.")
    func retainsBoundedWorktreeHistory() throws {
        let history = FilePreviewHistory()
        let pane = PaneSlotID(id: UUID())
        let first = history.record(files: try files("first.txt"), pane: pane, worktreePath: "/a")
        let firstURL = first.preview.files[0].url
        _ = history.record(files: try files("other.txt"), pane: pane, worktreePath: "/b")
        _ = history.record(files: try files("second.txt"), pane: pane, worktreePath: "/a")
        #expect(history.entries(for: "/a").map(\.preview.filename) == ["second.txt", "first.txt"])
        #expect(history.entries(for: "/b").count == 1)
        #expect(try Data(contentsOf: firstURL) == Data("first.txt".utf8))
        for index in 0..<40 {
            _ = history.record(files: try files("\(index).txt"), pane: pane, worktreePath: "/a")
        }
        #expect(history.entries.count == FilePreviewHistory.maximumEntries)
        #expect(history.entries.first?.preview.filename == "39.txt")
        #expect(history.entries(for: "/b").isEmpty)
    }

    @Test("History eviction releases snapshots that have no open presentation.")
    func evictionRemovesUnownedSnapshots() throws {
        let history = FilePreviewHistory()
        let pane = PaneSlotID(id: UUID())
        let url = history.record(files: try files("old.txt"), pane: pane, worktreePath: "/a").preview.files[0].url
        for _ in 0..<FilePreviewHistory.maximumEntries {
            _ = history.record(files: try files("new.txt"), pane: pane, worktreePath: "/a")
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("The titlebar retains access to an open preview after its request ages out of history.")
    func titlebarKeepsOpenPreviewReachableAfterEviction() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory()
        let inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        defer { windows.closeAll() }
        let pane = PaneSlotID(id: UUID())
        let entry = history.record(files: try files("open.txt"), pane: pane, worktreePath: "/a")
        windows.show(entry, activate: false)
        for _ in 0..<FilePreviewHistory.maximumEntries {
            _ = history.record(files: try files("other.txt"), pane: pane, worktreePath: "/b")
        }
        let button = FilePreviewToolbarButton(worktreePath: "/a", inlinePane: pane,
            canShowInline: { _ in true }, history: history, windows: windows, inline: inline)
        #expect(button.entries.map(\.id) == [entry.id])
        windows.showInline(entry)
        #expect(button.entries.map(\.id) == [entry.id])
        inline.dismiss(pane)
        #expect(button.entries.isEmpty)
    }

    @Test("@spec PREVIEW-1.7: When a Mac preview arrives, the application shall reuse one resizable standard window per worktree without taking terminal focus, and closing that window shall retain its history for reopening.")
    func reusesWindowsAndRetainsHistoryAfterClose() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory()
        let inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        let pane = PaneSlotID(id: UUID())
        let terminalWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        terminalWindow.makeKeyAndOrderFront(nil)
        defer { terminalWindow.orderOut(nil); windows.closeAll() }
        let keyWindow = NSApp.keyWindow
        let first = history.record(files: try files("first.txt"), pane: pane, worktreePath: "/a")
        windows.show(first, activate: false)
        let window = try #require(windows.window(for: "/a"))
        #expect(window.styleMask.contains(.resizable))
        #expect(NSApp.keyWindow === keyWindow)
        let second = history.record(files: try files("second.txt"), pane: pane, worktreePath: "/a")
        windows.show(second, activate: false)
        #expect(windows.window(for: "/a") === window)
        #expect(windows.selectedEntry(for: "/a")?.id == second.id)
        let other = history.record(files: try files("other.txt"), pane: pane, worktreePath: "/b")
        windows.show(other, activate: false)
        #expect(windows.window(for: "/b") !== window)
        window.performClose(nil)
        #expect(windows.window(for: "/a") == nil)
        #expect(history.entries(for: "/a").count == 2)
        windows.show(first, activate: false)
        #expect(windows.selectedEntry(for: "/a")?.id == first.id)
    }

    @Test("@spec PREVIEW-1.8: While the selected local worktree has a preview or preview history, the application shall expose a top-right Preview control that reopens its latest request and lists earlier requests from that worktree only.")
    func titlebarAvailabilityTracksSelectedWorktree() throws {
        let history = FilePreviewHistory()
        let pane = PaneSlotID(id: UUID())
        #expect(history.entries(for: "/a").isEmpty)
        _ = history.record(files: try files("a.txt"), pane: pane, worktreePath: "/a")
        #expect(history.entries(for: "/a").first?.preview.filename == "a.txt")
        #expect(history.entries(for: "/b").isEmpty)
    }

    @Test("@spec PREVIEW-1.9: When a user shows a preview inside its terminal or pops it into a window, the application shall transfer the same snapshot collection without adding history entries and select its worktree and pane when returning to the terminal.")
    func movesBetweenInlineAndWindowWithoutDuplicatingHistory() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory()
        let inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        defer { windows.closeAll() }
        let pane = PaneSlotID(id: UUID())
        let entry = history.record(files: try files("report.txt"), pane: pane, worktreePath: "/a")
        windows.show(entry, activate: false)
        windows.showInline(entry)
        #expect(windows.window(for: "/a") == nil)
        #expect(inline.previews[pane]?.id == entry.id)
        #expect(windows.inlineTarget?.worktreePath == "/a")
        #expect(windows.inlineTarget?.pane == pane)
        windows.show(entry, activate: false)
        #expect(inline.previews[pane] == nil)
        #expect(windows.selectedEntry(for: "/a")?.preview.files[0].url == entry.preview.files[0].url)
        #expect(history.entries.count == 1)
    }

    @Test("Popping out history docked in a different live pane removes that inline presentation.")
    func popsOutFromReplacementPane() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory()
        let inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        defer { windows.closeAll() }
        let original = PaneSlotID(id: UUID()), replacement = PaneSlotID(id: UUID())
        let entry = history.record(files: try files("report.txt"), pane: original, worktreePath: "/a")
        windows.showInline(entry, pane: replacement)
        #expect(inline.previews[replacement]?.id == entry.id)
        windows.show(entry, activate: false, inlinePane: replacement)
        #expect(inline.previews[replacement] == nil)
        #expect(windows.inlineTarget?.pane == replacement)
    }

    @Test("When a tray is hosted in a preview window, it uses native window resizing and exposes no inline resize grips.")
    func windowTrayUsesWindowChrome() throws {
        _ = NSApplication.shared
        let tray = NativeFilePreviewTray(preview: .init(files: try files("report.txt")),
                                         onDismiss: {}, onInteraction: { _ in }, isWindowed: true)
        defer { tray.tearDown() }
        tray.frame = .init(x: 0, y: 0, width: 600, height: 400)
        tray.layoutSubtreeIfNeeded()
        #expect(tray.grip.isHidden)
        #expect(tray.bottom.isHidden)
        #expect(tray.close.isHidden)
        #expect(tray.quickLook.frame.minY == 0)
    }

    @Test("The inline pop-out control remains reachable at narrow widths and opens the window without starting a drag.")
    func inlinePopOutControlFitsAndPerformsAction() throws {
        _ = NSApplication.shared
        var poppedOut = 0
        var interacted = false
        let tray = NativeFilePreviewTray(preview: .init(files: try files("report.txt")),
            onDismiss: {}, onInteraction: { _ in interacted = true }, onPopOut: { poppedOut += 1 })
        defer { tray.tearDown() }
        for width in [180.0, 240, 320, 800] {
            tray.frame = .init(x: 0, y: 0, width: width, height: 300)
            tray.layoutSubtreeIfNeeded()
            #expect(!tray.popOut.isHidden)
            #expect(tray.header.bounds.contains(tray.popOut.frame))
            for control in [tray.picker, tray.open, tray.close] {
                #expect(!tray.popOut.frame.intersects(control.frame))
            }
        }
        tray.popOut.performClick(nil)
        #expect(poppedOut == 1)
        #expect(!interacted)
    }
}
