import AppKit
import GrafttyKit
import GrafttyProtocol
import Testing
import SwiftUI
@testable import Graftty

@MainActor
struct PreviewChromeTests {
    @Test("@spec PREVIEW-1.12: While a Mac preview window is open, the application shall use one path bar for worktree, files and history, and disallow automatic system tabs.")
    func windowHasOneBarAndNoTabs() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory()
        let windows = FilePreviewWindows(history: history, inline: ImagePreviewStore())
        defer { windows.closeAll() }
        let file = try FilePreviewFile(.init(filename: "plan.html", bytes: Data()))
        let entry = history.record(files: [file], pane: PaneSlotID(), worktreePath: "/a")
        windows.show(entry, activate: false)
        let window = try #require(windows.window(for: "/a"))
        #expect(window.tabbingMode == .disallowed)
        #expect(window.titleVisibility == .hidden)
        #expect(window.styleMask.contains(.fullSizeContentView))
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let tray = try #require(descendants(content).compactMap { $0 as? NativeFilePreviewTray }.first)
        #expect(abs(tray.bounds.height - content.bounds.height) < 1)
        #expect(tray.header.frame.height == 40)
    }

    @Test("@spec PREVIEW-1.13: While preview chrome follows the Ghostty theme, the application shall update its window and tray colors without changing Quick Look's system document appearance.")
    func themeUpdatesKeepDocumentAppearanceIndependent() async throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory()
        let windows = FilePreviewWindows(history: history, inline: ImagePreviewStore())
        defer { windows.closeAll() }
        let file = try FilePreviewFile(.init(filename: "theme.html", bytes: Data()))
        let entry = history.record(files: [file], pane: PaneSlotID(), worktreePath: "/a")
        windows.show(entry, activate: false)
        let window = try #require(windows.window(for: "/a"))
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let tray = try #require(descendants(content).compactMap { $0 as? NativeFilePreviewTray }.first)
        for theme in [GhosttyTheme.fallback, GhosttyTheme(backgroundRGB: .init(r: 0.95, g: 0.95, b: 0.95),
                                                        foregroundRGB: .init(r: 0.1, g: 0.1, b: 0.2))] {
            windows.updateTheme(theme)
            try await Task.sleep(for: .milliseconds(20))
            content.layoutSubtreeIfNeeded()
            #expect(window.backgroundColor == theme.backgroundNSColor)
            #expect(window.appearance == theme.nsAppearance)
            #expect(tray.header.backgroundColor == NSColor(theme.core.contextBackground))
            #expect(tray.quickLook.appearance === NSApp.effectiveAppearance)
        }
    }

    @Test("@spec PREVIEW-1.14: While a preview has earlier requests or multiple files, the application shall combine file selection and deduplicated worktree history in one menu, show collection navigation only for multiple files, and raise an existing worktree window without replacing its selection.")
    func historyAndWorktreeNavigationPreserveSelection() throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory()
        let windows = FilePreviewWindows(history: history, inline: ImagePreviewStore())
        defer { windows.closeAll() }
        let first = try FilePreviewFile(.init(filename: "first.html", bytes: Data()))
        let second = try FilePreviewFile(.init(filename: "second.html", bytes: Data()))
        let older = history.record(files: [first], pane: PaneSlotID(), worktreePath: "/a")
        let newer = history.record(files: [first, second], pane: older.pane, worktreePath: "/a")
        let other = history.record(files: [second], pane: PaneSlotID(), worktreePath: "/b")
        windows.show(older, activate: false)
        windows.show(other, activate: false)
        let window = try #require(windows.window(for: "/a"))
        windows.raise(worktreePath: "/a")
        #expect(windows.window(for: "/a") === window)
        #expect(windows.selectedEntry(for: "/a")?.id == older.id)
        #expect(windows.worktreePaths == ["/a", "/b"])
        var selected: UUID?
        var raised: String?
        let duplicate = RemoteOpenOffer(id: UUID(), filename: "first.html", byteCount: 0, previewKind: "file",
            previewGroupID: older.id, createdAt: older.createdAt)
        let navigation = FilePreviewNavigation(worktreePath: "/a", worktreePaths: windows.worktreePaths,
            entries: history.entries(for: "/a"), catalog: RemoteOpenOffer.previewCollections(in: [duplicate]),
            onSelectEntry: { selected = $0.id },
            onSelectWorktree: { path in raised = path; windows.raise(worktreePath: path) })
        #expect(navigation.choices.map(\.id) == [newer.id, older.id])
        let tray = NativeFilePreviewTray(preview: older.preview, onDismiss: {}, onInteraction: { _ in },
                                        isWindowed: true, navigation: navigation)
        defer { tray.tearDown() }
        tray.frame = .init(x: 0, y: 0, width: 900, height: 400)
        tray.layoutSubtreeIfNeeded()
        #expect(!tray.picker.isHidden)
        #expect(tray.previous.isHidden && tray.next.isHidden)
        #expect(!tray.worktreePicker.isHidden)
        tray.worktreePicker.selectItem(at: 1)
        _ = NSApp.sendAction(try #require(tray.worktreePicker.action), to: tray.worktreePicker.target, from: tray.worktreePicker)
        #expect(raised == "/b")
        #expect(tray.worktreePicker.selectedItem?.representedObject as? String == "/a")
        #expect(tray.picker.titleOfSelectedItem?.contains(try #require(older.createdAt).formatted(date: .omitted, time: .shortened)) == true)
        let menu = try #require(tray.picker.menu)
        let index = try #require(menu.items.firstIndex { $0.title == newer.menuTitle })
        menu.performActionForItem(at: index)
        #expect(selected == newer.id)
        selected = nil
        tray.picker.selectItem(at: index)
        _ = NSApp.sendAction(try #require(tray.picker.action), to: tray.picker.target, from: tray.picker)
        #expect(selected == newer.id)
        tray.update(newer.preview)
        #expect(!tray.previous.isHidden && tray.next.isEnabled)
        tray.nextFile()
        #expect(tray.selectedIndex == 1)
    }

    @Test("@spec PREVIEW-1.23: While a macOS preview file menu is visible, the application shall fit its width to its menu items up to 360 points and the available header space, leaving unused header space available for dragging.", arguments: [false, true])
    func fileMenuLeavesUnusedHeaderDraggable(isWindowed: Bool) throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory()
        let pane = PaneSlotID()
        let files = try ["plan.html", "implementation-notes.html"].map {
            try FilePreviewFile(.init(filename: $0, bytes: Data()))
        }
        let longFile = try FilePreviewFile(.init(filename: String(repeating: "long-name-", count: 20) + ".html", bytes: Data()))
        let older = history.record(files: [longFile], pane: pane, worktreePath: "/synthetic")
        let current = history.record(files: files, pane: pane, worktreePath: "/synthetic")
        var navigation = FilePreviewNavigation(worktreePath: "/synthetic", entries: [current])
        let tray = NativeFilePreviewTray(preview: current.preview, onDismiss: {}, onInteraction: { _ in },
                                        isWindowed: isWindowed, navigation: navigation)
        defer { tray.tearDown() }
        func layout(width: CGFloat) {
            tray.frame = .init(x: 0, y: 0, width: width, height: 400)
            tray.layoutSubtreeIfNeeded()
        }
        func expectDragSpace() {
            let controls: [NSView] = [tray.previous, tray.next, tray.countLabel, tray.open, tray.showInTerminal, tray.close, tray.popOut]
            let controlsLeft = controls.filter { !$0.isHidden }.map(\.frame.minX).min() ?? tray.bounds.maxX
            #expect(controlsLeft - tray.picker.frame.maxX >= 80)
            let point = NSPoint(x: (tray.picker.frame.maxX + controlsLeft) / 2, y: tray.picker.frame.midY)
            let hit = tray.header.hitTest(tray.header.convert(point, to: tray))
            #expect(hit === tray.header, "Unused menu width must reach the drag handle")
            #expect(tray.header.movesWindow == isWindowed)
        }
        layout(width: 900)
        let compactWidth = tray.picker.frame.width
        let longestTitle = (files[1].url.lastPathComponent as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        #expect(compactWidth >= longestTitle)
        #expect(compactWidth < 300, "Short filenames must not consume the entire header")
        expectDragSpace()
        layout(width: 1400)
        #expect(abs(tray.picker.frame.width - compactWidth) < 1)
        expectDragSpace()

        // A long, unselected history item must affect the menu's preferred width.
        navigation.entries = [current, older]
        tray.configure(theme: .fallback, navigation: navigation)
        layout(width: 1400)
        #expect(tray.picker.frame.width > compactWidth)
        #expect(tray.picker.frame.width <= 360)
        expectDragSpace()
        for width: CGFloat in isWindowed ? [480] : [180, 480] {
            layout(width: width)
            #expect(tray.picker.frame.maxX <= tray.open.frame.minX)
            #expect(tray.picker.frame.width <= 360)
        }
        navigation.entries = [current]
        tray.configure(theme: .fallback, navigation: navigation)
        layout(width: 1400)
        #expect(abs(tray.picker.frame.width - compactWidth) < 1)
    }

    @Test("A library download cannot replace a newer user selection or append discarded history.")
    func staleLibraryDownloadDoesNotOverrideSelection() async throws {
        let history = FilePreviewHistory()
        let file = try FilePreviewFile(.init(filename: "current.txt", bytes: Data()))
        let entry = history.record(files: [file], pane: PaneSlotID(), worktreePath: "/a")
        let replacement = history.record(files: [file], pane: entry.pane, worktreePath: "/a")
        let model = FilePreviewWindowModel(entry: entry)
        let offer = RemoteOpenOffer(id: UUID(), filename: "download.txt", byteCount: 1, previewKind: "file")
        let collection = try #require(RemoteOpenOffer.previewCollections(in: [offer]).first)
        try await model.open(collection, history: history) { _ in
            model.entry = replacement
            return .chunk(Data([1]))
        }
        #expect(model.entry.id == replacement.id)
        #expect(history.entries.count == 2)
    }

    @Test("@spec PREVIEW-1.15: When a remote preview window is hidden or closed and reopened, the application shall retain its remote catalog transport for browsing and downloading history.")
    func reopeningRemotePreviewRetainsCatalogTransport() async throws {
        _ = NSApplication.shared
        let history = FilePreviewHistory()
        let windows = FilePreviewWindows(history: history, inline: ImagePreviewStore())
        defer { windows.closeAll() }
        let path = "remote-preview:host:/repo"
        let file = try FilePreviewFile(.init(filename: "current.html", bytes: Data()))
        let entry = history.record(files: [file], pane: PaneSlotID(), worktreePath: path)
        let offer = RemoteOpenOffer(id: UUID(), filename: "remote.html", byteCount: 1, previewKind: "file")
        windows.show(entry, activate: false, catalogRequest: { _ in .offers([offer]) })
        windows.hide(entry, inlinePane: nil)
        #expect(windows.restoreHidden(for: path, inlinePane: nil, resolveWorktree: nil))
        let restored = try #require(windows.model(for: path)?.catalogRequest)
        #expect(try await restored(.list) == .offers([offer]))
        windows.window(for: path)?.performClose(nil)
        windows.raise(worktreePath: path)
        let reopened = try #require(windows.model(for: path)?.catalogRequest)
        #expect(try await reopened(.list) == .offers([offer]))
    }

    @Test("Downloading a legacy collection keeps its unknown creation time out of history labels and chronological ordering.")
    func legacyDownloadDoesNotInventCreationTime() async throws {
        let history = FilePreviewHistory()
        let file = try FilePreviewFile(.init(filename: "known.html", bytes: Data()))
        let known = history.record(files: [file], pane: PaneSlotID(), worktreePath: "/a")
        let model = FilePreviewWindowModel(entry: known)
        let offer = RemoteOpenOffer(id: UUID(), filename: "legacy.html", byteCount: 0, previewKind: "file")
        let collection = try #require(RemoteOpenOffer.previewCollections(in: [offer]).first)
        try await model.open(collection, history: history) { _ in .chunk(Data()) }
        #expect(model.entry.menuTitle == "legacy.html")
        let choices = FilePreviewNavigation(worktreePath: "/a", entries: history.entries(for: "/a")).choices
        #expect(choices.first?.id == known.id)
        #expect(choices.last?.createdAt == nil)
    }

    @Test("Selecting inline history transfers the snapshot from its window and other inline owners.")
    func inlineHistoryUsesPresentationTransfer() throws {
        _ = NSApplication.shared
        let path = "/preview-inline-" + UUID().uuidString
        let pane = PaneSlotID(), sibling = PaneSlotID()
        let file = try FilePreviewFile(.init(filename: "report.html", bytes: Data()))
        let history = FilePreviewHistory.shared
        let windows = FilePreviewWindows.shared
        let inline = ImagePreviewStore.shared
        defer {
            windows.window(for: path)?.performClose(nil)
            inline.dismiss(pane)
            inline.dismiss(sibling)
        }
        let first = history.record(files: [file], pane: pane, worktreePath: path)
        let second = history.record(files: [file], pane: pane, worktreePath: path)
        windows.show(first, activate: false)
        inline.present(second.preview, for: pane, worktreePath: path)
        inline.present(first.preview, for: sibling, worktreePath: path)
        let manager = TerminalManager(socketPath: "/tmp/unused-inline-preview-test.sock")
        let view = TerminalContentView(terminalManager: manager, splitTree: .constant(SplitTree(root: .leaf(pane))),
            focusedPaneSlotID: pane, theme: .fallback, onFocusTerminal: { _ in }, previewWorktreePath: path)
        let navigation = try #require(view.previewNavigation)
        navigation.onSelectEntry(first)
        #expect(windows.window(for: path) == nil)
        #expect(inline.previews[pane]?.id == first.id)
        #expect(inline.previews[sibling] == nil)
        #expect(history.entries(for: path).count == 2)
    }

    @Test("@spec PREVIEW-1.16: When a library download is superseded before task cancellation is observed, the application shall discard its result without changing the selected preview or appending discarded history.")
    func newDownloadSelectionWinsBeforeCancellation() async throws {
        let history = FilePreviewHistory()
        let file = try FilePreviewFile(.init(filename: "current.txt", bytes: Data()))
        let entry = history.record(files: [file], pane: PaneSlotID(), worktreePath: "/a")
        let model = FilePreviewWindowModel(entry: entry)
        let offer = RemoteOpenOffer(id: UUID(), filename: "download.txt", byteCount: 1, previewKind: "file")
        let collection = try #require(RemoteOpenOffer.previewCollections(in: [offer]).first)
        let requestID = UUID()
        var currentRequestID = requestID
        try await model.open(collection, history: history, isCurrent: { currentRequestID == requestID }) { _ in
            currentRequestID = UUID()
            return .chunk(Data([1]))
        }
        #expect(!Task.isCancelled)
        #expect(model.entry.id == entry.id)
        #expect(history.entries.count == 1)
    }

    @Test("Capture native preview chrome for manual review when requested.")
    func captureChromeIfRequested() async throws {
        guard let directory = ProcessInfo.processInfo.environment["GRAFTTY_TEST_SCREENSHOT_DIR"] else { return }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let history = FilePreviewHistory()
        let windows = FilePreviewWindows(history: history, inline: ImagePreviewStore())
        defer { windows.closeAll() }
        let html = Data("<html><body style='font:18px system-ui;padding:32px;background:white;color:#222'><h1>Preview UI</h1><p>The document keeps its own appearance.</p></body></html>".utf8)
        let files = try ["header-review.html", "another.html"].map { try FilePreviewFile(.init(filename: $0, bytes: html)) }
        let entry = history.record(files: files, pane: PaneSlotID(), worktreePath: "/phone-header")
        _ = history.record(files: files, pane: PaneSlotID(), worktreePath: "/stuck-restoring")
        NSApp.setActivationPolicy(.regular)
        NSApp.finishLaunching()
        windows.show(entry, activate: false)
        let window = try #require(windows.window(for: entry.worktreePath))
        let content = try #require(window.contentView)
        for (name, theme) in [
            ("dark", GhosttyTheme(backgroundRGB: .init(r: 0.118, g: 0.118, b: 0.18), foregroundRGB: .init(r: 0.804, g: 0.839, b: 0.957))),
            ("light", GhosttyTheme(backgroundRGB: .init(r: 0.937, g: 0.945, b: 0.961), foregroundRGB: .init(r: 0.298, g: 0.310, b: 0.412)))
        ] {
            windows.updateTheme(theme)
            for width in [900.0, 480] {
                window.setContentSize(.init(width: width, height: 500))
                try await Task.sleep(for: .milliseconds(300))
                content.layoutSubtreeIfNeeded()
                let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("preview-\(name)-\(Int(width)).png"))
            }
        }
        let simpleHistory = FilePreviewHistory()
        let simpleWindows = FilePreviewWindows(history: simpleHistory, inline: ImagePreviewStore())
        defer { simpleWindows.closeAll() }
        let simple = simpleHistory.record(files: [files[0]], pane: entry.pane, worktreePath: "/phone-header")
        simpleWindows.show(simple, activate: false)
        let simpleWindow = try #require(simpleWindows.window(for: simple.worktreePath))
        simpleWindow.setContentSize(.init(width: 900, height: 500))
        try await Task.sleep(for: .milliseconds(300))
        let simpleContent = try #require(simpleWindow.contentView)
        simpleContent.layoutSubtreeIfNeeded()
        let bitmap = try #require(simpleContent.bitmapImageRepForCachingDisplay(in: simpleContent.bounds))
        simpleContent.cacheDisplay(in: simpleContent.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("preview-single-file.png"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
