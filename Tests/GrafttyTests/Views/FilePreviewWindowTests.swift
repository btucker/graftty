import AppKit
import GrafttyKit
import Testing
@testable import Graftty

@MainActor
struct FilePreviewWindowTests {
    private func files(_ name: String) throws -> [FilePreviewFile] {
        [try FilePreviewFile(.init(filename: name, bytes: Data(name.utf8)))]
    }

    @Test("@spec LAYOUT-1.14: While a worktree preview is open, the header shall name that preview and allow its primary control to hide it without deleting its history.")
    func toolbarNamesAndTogglesCurrentPreview() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory(), inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        defer { windows.closeAll() }
        let pane = PaneSlotID()
        let entry = history.record(files: try files("plan.md"), pane: pane, worktreePath: "/a")
        let button = FilePreviewToolbarButton(worktreePath: "/a", inlinePane: pane,
            history: history, windows: windows, inline: inline)
        #expect(button.displayTitle == "plan.md")
        windows.showInline(entry)
        #expect(button.isPreviewOpen)
        button.togglePreview()
        #expect(!button.isPreviewOpen)
        #expect(button.entries.first?.id == entry.id)
        _ = history.record(files: try files("newer.md"), pane: pane, worktreePath: "/a")
        #expect(button.displayTitle == "plan.md")
        button.togglePreview()
        #expect(inline.previews[pane]?.id == entry.preview.id)
        #expect(windows.window(for: "/a") == nil)
    }

    @Test("The preview toggle targets the focused pane and honors reassigned worktree ownership.")
    func toolbarTargetsFocusedPreview() throws {
        let history = FilePreviewHistory(), inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        let first = PaneSlotID(), second = PaneSlotID()
        let a = history.record(files: try files("a.md"), pane: first, worktreePath: "/a")
        let b = history.record(files: try files("b.md"), pane: second, worktreePath: "/a")
        windows.showInline(a)
        windows.showInline(b)
        let button = FilePreviewToolbarButton(worktreePath: "/a", inlinePane: second,
            history: history, windows: windows, inline: inline)
        #expect(button.displayTitle == "b.md")
        button.togglePreview()
        #expect(inline.previews[first]?.id == a.preview.id)
        #expect(inline.previews[second] == nil)
        #expect(!button.isPreviewOpen)
        let moved = FilePreviewToolbarButton(worktreePath: "/a", inlinePane: first, resolveInlineWorktree: { _ in "/b" },
            history: history, windows: windows, inline: inline)
        #expect(!moved.isPreviewOpen)
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
            history: history, windows: windows, inline: inline)
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

    @Test("Opening a history entry removes its actual inline owner and preserves unrelated previews.")
    func popOutRemovesMatchingSnapshotAfterFocusChanges() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory(), inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        defer { windows.closeAll() }
        let origin = PaneSlotID(), docked = PaneSlotID(), focused = PaneSlotID()
        let entry = history.record(files: try files("report.txt"), pane: origin, worktreePath: "/a")
        let unrelated = history.record(files: try files("other.txt"), pane: focused, worktreePath: "/a")
        windows.showInline(entry, pane: docked)
        inline.present(unrelated.preview, for: focused)
        windows.show(entry, activate: false, inlinePane: focused)
        #expect(inline.previews[docked] == nil)
        #expect(inline.previews[focused]?.id == unrelated.id)
        #expect(windows.selectedEntry(for: "/a")?.id == entry.id)
    }

    @Test("An inline preview remains in its worktree toolbar after history eviction and a sibling-pane focus change.")
    func titlebarIncludesSiblingInlinePreviewAfterEviction() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory(), inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        let pane = PaneSlotID(), sibling = PaneSlotID()
        let entry = history.record(files: try files("report.txt"), pane: pane, worktreePath: "/a")
        windows.showInline(entry)
        for _ in 0..<FilePreviewHistory.maximumEntries {
            _ = history.record(files: try files("other.txt"), pane: sibling, worktreePath: "/b")
        }
        let button = FilePreviewToolbarButton(worktreePath: "/a", inlinePane: sibling,
            history: history, windows: windows, inline: inline)
        #expect(button.entries.map(\.id) == [entry.id])
        #expect(button.entries.first?.createdAt == entry.createdAt)
    }

    @Test("An evicted open selection stays behind newer retained requests in the toolbar.")
    func titlebarKeepsLatestRequestFirst() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory(), inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        defer { windows.closeAll() }
        let pane = PaneSlotID()
        let older = history.record(files: try files("older.txt"), pane: pane, worktreePath: "/a")
        let newer = history.record(files: try files("newer.txt"), pane: pane, worktreePath: "/a")
        windows.show(older, activate: false)
        for _ in 0..<(FilePreviewHistory.maximumEntries - 1) {
            _ = history.record(files: try files("other.txt"), pane: pane, worktreePath: "/b")
        }
        let button = FilePreviewToolbarButton(worktreePath: "/a", inlinePane: pane,
            history: history, windows: windows, inline: inline)
        #expect(button.entries.map(\.id) == [newer.id, older.id])
    }

    @Test("Selecting window history updates the default destination pane and its availability.")
    func historySelectionUsesSelectedOriginPane() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory(), inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        defer { windows.closeAll() }
        let a = PaneSlotID(), b = PaneSlotID()
        let first = history.record(files: try files("a.txt"), pane: a, worktreePath: "/a")
        let second = history.record(files: try files("b.txt"), pane: b, worktreePath: "/a")
        windows.show(first, activate: false)
        windows.show(second, activate: false, resolveInlineWorktree: { $0 == a ? "/a" : nil })
        let model = try #require(windows.model(for: "/a"))
        #expect(!model.canShowInline)
        model.entry = first
        #expect(model.canShowInline)
        model.showInline()
        #expect(windows.inlineTarget?.pane == a)
        #expect(inline.previews[a]?.id == first.id)
        #expect(inline.previews[b] == nil)
    }

    @Test("@spec PREVIEW-1.10: When returning a preview to a registered pane whose renderer has been evicted, the application shall allow terminal navigation to wake that pane rather than require an existing renderer.")
    func returningToTerminalAllowsRegisteredPaneWithoutRenderer() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory(), inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        defer { windows.closeAll() }
        let pane = PaneSlotID()
        let manager = TerminalManager(socketPath: "/tmp/unused-preview-window-test.sock")
        manager.recordPaneSession(PaneSessionID(), for: pane, worktreePath: "/a")
        #expect(manager.handle(for: pane) == nil)
        let entry = history.record(files: try files("report.txt"), pane: pane, worktreePath: "/a")
        windows.show(entry, activate: false, resolveInlineWorktree: { manager.worktreePath(for: $0) })
        let model = try #require(windows.model(for: "/a"))
        #expect(model.canShowInline)
        model.showInline()
        #expect(windows.inlineTarget?.pane == pane)
        #expect(inline.previews[pane]?.id == entry.id)
    }

    @Test("@spec PREVIEW-1.11: When a pane with a preview moves to another worktree, the application shall resolve active preview controls and return navigation against its current worktree while retaining the original request's history grouping.")
    func activePreviewFollowsPaneToAnotherWorktree() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory(), inline = ImagePreviewStore()
        let windows = FilePreviewWindows(history: history, inline: inline)
        defer { windows.closeAll() }
        let pane = PaneSlotID(), session = PaneSessionID()
        let manager = TerminalManager(socketPath: "/tmp/unused-preview-pane-move-test.sock")
        manager.recordPaneSession(session, for: pane, worktreePath: "/a")
        let previous = history.record(files: try files("previous.txt"), pane: PaneSlotID(), worktreePath: "/b")
        let entry = history.record(files: try files("report.txt"), pane: pane, worktreePath: "/a")
        windows.showInline(entry)
        manager.recordPaneSession(session, for: pane, worktreePath: "/b")
        let resolve = { manager.worktreePath(for: $0) }
        let destination = FilePreviewToolbarButton(worktreePath: "/b", inlinePane: pane,
            resolveInlineWorktree: resolve, history: history, windows: windows, inline: inline)
        #expect(destination.entries.map(\.id) == [entry.id, previous.id])
        #expect(history.entries(for: "/a").first?.id == entry.id)
        for _ in 0..<FilePreviewHistory.maximumEntries {
            _ = history.record(files: try files("other.txt"), pane: pane, worktreePath: "/other")
        }
        let source = FilePreviewToolbarButton(worktreePath: "/a", inlinePane: nil,
            resolveInlineWorktree: resolve, history: history, windows: windows, inline: inline)
        #expect(source.entries.isEmpty)
        #expect(destination.entries.map(\.id) == [entry.id])
        windows.show(entry, activate: false, resolveInlineWorktree: resolve)
        let model = try #require(windows.model(for: "/a"))
        model.showInline()
        #expect(windows.inlineTarget?.worktreePath == "/b")
        #expect(windows.inlineTarget?.pane == pane)
        #expect(inline.previews(forWorktreePath: "/b")[pane]?.id == entry.id)
    }
}
