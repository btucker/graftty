import AppKit
import SwiftUI
import XCTest
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

@MainActor
private final class SidebarScrollHarness: ObservableObject {
    @Published var state: AppState
    var selections: [String] = []
    @Published var pendingAddWorktree: AddWorktreeRequest?
    var deleteRequests: [(path: String, window: NSWindow)] = []
    let manager = TerminalManager(socketPath: "/tmp/sidebar-test-unused.sock")
    let remotes = RemoteMacsModel(store: RemoteMacStore(storeURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    let voice = VoiceDictationController()
    let stats = WorktreeStatsStore()
    let prs = PRStatusStore()
    let registry = ClaudeSessionRegistry()
    let branches = RemoteBranchStore()
    /// Published on every `state` change, as GrafttyApp does for AppState.
    let changes = AppStateChanges()
    let web: WebServerController

    init(pinnedCount: Int) throws {
        let settings = WebAccessSettings()
        web = WebServerController(settings: settings, zmxExecutable: URL(fileURLWithPath: "/unused"), zmxDir: .temporaryDirectory)
        var rows = [WorktreeEntry(path: "/sidebar-test", branch: "main")]
        for index in 0..<pinnedCount {
            var row = WorktreeEntry(path: "/sidebar-test/.worktrees/pinned-\(index)", branch: "pinned-\(index)")
            row.isPinned = true
            rows.append(row)
        }
        rows += (0..<30).map { WorktreeEntry(path: "/sidebar-test/.worktrees/task-\($0)", branch: "task-\($0)") }
        state = AppState(repos: [RepoEntry(path: "/sidebar-test", displayName: "Sidebar test", worktrees: rows)])
    }
}

private struct HostedSidebarScrollView: View {
    @ObservedObject var harness: SidebarScrollHarness
    var body: some View {
        NavigationSplitView {
            SidebarView(appState: $harness.state, terminalManager: harness.manager,
                paneTitleInvalidations: PaneTitleInvalidationSource(), voiceDictation: harness.voice,
                selectedVoicePaneID: nil, theme: .fallback, statsStore: harness.stats, prStatusStore: harness.prs,
                claudeSessionRegistry: harness.registry, remoteBranchStore: harness.branches,
                remoteMacsModel: harness.remotes, appStateChanges: harness.changes, selectedRemoteIdentity: nil, selectedRemoteWorktreePath: nil,
                selectedRemotePaneSessionName: nil, onSelect: {
                    harness.selections.append($0)
                    harness.state.selectedWorktreePath = $0
                },
                onSelectRemoteMac: { _ in }, onSelectRemoteWorktree: { _, _ in }, onWakeRemoteWorktree: { _, _ in },
                onAddRemoteWorktree: { _, _ in }, onAddRemoteWorktreeWithHost: { _, _, _, _, _ in }, onDeleteRemoteWorktree: { _, _ in },
                onAddRemoteMac: {}, onAddRepo: {}, onAddPath: { _ in }, onRemoveRepo: { _ in }, onInitializeGit: { _ in },
                onStopWorktree: { _ in }, onDeleteWorktree: { harness.deleteRequests.append(($0, $1)) },
                onAddWorktree: { _, _, _, _ in nil }, pendingAddWorktree: $harness.pendingAddWorktree)
                .environmentObject(harness.web)
                .environmentObject(PortBindingsModel())
                .onChange(of: harness.state) { _, _ in harness.changes.publish() }
                .navigationSplitViewColumnWidth(min: 300, ideal: 440, max: 540)
        } detail: { Color.clear }
    }
}

/// Mounted sidebar controls can stop Swift Testing's async-main run loop.
/// XCTest keeps the AppKit run loop alive until every native assertion finishes.
@MainActor
final class SidebarScrollLayoutTests: XCTestCase {
    /// @spec TECH-6.7: When the native sidebar test fixture creates a window, the fixture shall disable native window animations before displaying the window.
    func testHostedWindowDisablesAnimations() async throws {
        _ = NSApplication.shared
        let hosted = try await Hosted.make(pinnedCount: 1, rail: false)
        defer { hosted.tearDown() }
        XCTAssertEqual(hosted.window.animationBehavior, .none)
    }

    /// @spec LAYOUT-2.122: While the macOS sidebar is displayed below native window controls, the application shall place pinned content below the native toolbar's full hit region, including after resizing.
    func testPinnedContentClearsNativeToolbar() async throws {
        for rail in [false, true] {
            for compactToolbar in [false, true] {
                try await pinnedContentClearsNativeToolbar(rail: rail, compactToolbar: compactToolbar)
            }
        }
    }

    private func pinnedContentClearsNativeToolbar(rail: Bool, compactToolbar: Bool) async throws {
        let hosted = try await Hosted.make(pinnedCount: 1, rail: rail)
        defer { hosted.tearDown() }
        hosted.window.toolbarStyle = compactToolbar ? .unifiedCompact : .unified
        try await hosted.settle()
        for width in [900.0, 720.0] {
            hosted.window.setContentSize(NSSize(width: width, height: 540))
            try await hosted.settle()
            let toggle = try hosted.sidebarToggle()
            let toolbarItem = try XCTUnwrap(toggle.superview)
            let toolbarFrame = toolbarItem.convert(toolbarItem.bounds, to: hosted.hosting)
            let tile = try hosted.dragView(named: "pinned-0")
            XCTAssertTrue(tile.convert(tile.bounds, to: hosted.hosting).minY >= toolbarFrame.maxY)
        }
    }

    /// @spec LAYOUT-2.120: While the macOS sidebar displays pinned agents, the application shall start their tiles below the dedicated search row without an extra title-bar inset.
    func testPinnedContentStartsBelowSearchStrip() async throws {
        for rail in [false, true] {
            let hosted = try await Hosted.make(pinnedCount: 1, rail: rail)
            defer { hosted.tearDown() }
            let tile = try hosted.dragView(named: "main")
            let content = tile.convert(tile.bounds, to: hosted.hosting)
            let search = try XCTUnwrap(Self.find(NSTextField.self, in: hosted.hosting).first {
                $0.placeholderString == "Search projects and worktrees"
            })
            let searchFrame = search.convert(search.bounds, to: hosted.hosting)
            XCTAssertTrue(content.minY >= searchFrame.maxY)
            // Without the rail, the project's disclosure row sits between them.
            XCTAssertTrue(content.minY - searchFrame.maxY <= (rail ? 16 : 48))
            try hosted.captureIfRequested(name: "sidebar-tiles-\(rail ? "rail" : "single")")
        }
    }

    /// @spec LAYOUT-2.121: When the user first clicks a pinned tile in an inactive macOS window, the application shall select that agent on the same click without requiring a second click.
    func testFirstPinnedHeadingClickSelects() async throws {
        for rail in [false, true] {
            for name in ["main", "pinned-0"] {
                try await firstPinnedHeadingClickSelects(rail: rail, name: name)
            }
        }
    }

    private func firstPinnedHeadingClickSelects(rail: Bool, name: String) async throws {
        let hosted = try await Hosted.make(pinnedCount: 1, rail: rail)
        defer { hosted.tearDown() }
        let row = try hosted.dragView(named: name)
        let originalFrame = row.convert(row.bounds, to: hosted.hosting)
        XCTAssertTrue(!hosted.window.isKeyWindow)
        let location = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let down = try NSEvent.syntheticClick(.leftMouseDown, at: location, in: hosted.window)
        let up = try NSEvent.syntheticClick(.leftMouseUp, at: location, in: hosted.window)
        let sources = Self.find(WorktreeDragSourceView.self, in: hosted.hosting)
        for source in sources { source.currentEvent = { down } }
        defer { for source in sources { source.currentEvent = { NSApp.currentEvent } } }
        let root = try XCTUnwrap(hosted.window.contentView)
        let hit = try XCTUnwrap(root.hitTest(root.superview?.convert(location, from: nil) ?? location))
        XCTAssertTrue(hit.acceptsFirstMouse(for: down))
        hosted.window.sendEvent(down)
        hosted.window.sendEvent(up)
        try await hosted.settle()
        let expectedPath = name == "main" ? "/sidebar-test" : "/sidebar-test/.worktrees/" + name
        XCTAssertTrue(hosted.harness.selections == [expectedPath])
        XCTAssertTrue(hosted.harness.state.selectedWorktreePath == expectedPath)
        let selected = try hosted.dragView(named: name)
        XCTAssertTrue(selected.convert(selected.bounds, to: hosted.hosting) == originalFrame)
    }

    /// @spec LAYOUT-2.89: While the ordinary worktree list scrolls with the project rail shown, the application shall keep the pinned tiles and the New worktree line fixed above its viewport; without the rail, each project's tiles shall scroll with its list.
    func testOrdinaryScrollKeepsPinnedRowsFixed() async throws {
        for rail in [false, true] {
            try await ordinaryScrollKeepsPinnedRowsFixed(rail: rail)
        }
    }

    private func ordinaryScrollKeepsPinnedRowsFixed(rail: Bool) async throws {
        let hosted = try await Hosted.make(pinnedCount: 1, rail: rail)
        defer { hosted.tearDown() }
        let pinned = try hosted.dragView(named: "pinned-0")
        let task = try hosted.dragView(named: "task-0")
        let ordinary = try XCTUnwrap(hosted.enclosingScroll(task))
        let originalPinned = pinned.convert(pinned.bounds, to: hosted.hosting)
        let originalTask = task.convert(task.bounds, to: hosted.hosting)
        // Without the rail the tiles are part of the list, so they scroll with it.
        XCTAssertTrue((hosted.enclosingScroll(pinned) === ordinary) == !rail)
        ordinary.contentView.scroll(to: CGPoint(x: 0, y: 120))
        ordinary.reflectScrolledClipView(ordinary.contentView)
        try await hosted.settle()
        XCTAssertTrue(ordinary.contentView.bounds.origin.y == 120)
        XCTAssertTrue(task.convert(task.bounds, to: hosted.hosting).minY != originalTask.minY)
        if rail {
            XCTAssertTrue(pinned.convert(pinned.bounds, to: hosted.hosting) == originalPinned)
        }
    }

    /// @spec LAYOUT-2.119: While a project has more pinned agents than fit in one row, the application shall wrap its tiles onto further rows without scrolling them separately, so every tile stays visible and the list below takes the remaining height.
    func testPinnedTilesWrapWithoutScrolling() async throws {
        let hosted = try await Hosted.make(pinnedCount: 11, rail: true)
        defer { hosted.tearDown() }
        let first = try hosted.dragView(named: "pinned-0")
        let last = try hosted.dragView(named: "pinned-10")
        XCTAssertNil(hosted.enclosingScroll(last))
        let lastFrame = last.convert(last.bounds, to: hosted.hosting)
        XCTAssertGreaterThan(lastFrame.minY, first.convert(first.bounds, to: hosted.hosting).maxY)
        XCTAssertTrue(hosted.hosting.bounds.contains(lastFrame))
        let ordinary = try XCTUnwrap(hosted.enclosingScroll(try hosted.dragView(named: "task-0")))
        XCTAssertGreaterThanOrEqual(ordinary.convert(ordinary.bounds, to: hosted.hosting).minY, lastFrame.maxY)
        try hosted.captureIfRequested(name: "sidebar-rail-tiles-11")
    }

    /// @spec LAYOUT-2.227: While the sidebar shows a project that can add worktrees, the application shall offer New worktree as a line directly below the pinned tiles and above Needs you, Working, and Recent, in both macOS sidebar modes.
    func testNewWorktreeLineSitsBetweenTilesAndList() async throws {
        for rail in [false, true] {
            let hosted = try await Hosted.make(pinnedCount: 1, rail: rail)
            defer { hosted.tearDown() }
            let tile = try hosted.dragView(named: "pinned-0")
            let task = try hosted.dragView(named: "task-0")
            let tileFrame = tile.convert(tile.bounds, to: nil)
            // Window coordinates grow upward: the line is just below the tiles.
            let location = CGPoint(x: tileFrame.minX + 30, y: tileFrame.minY - 18)
            XCTAssertGreaterThan(location.y, task.convert(task.bounds, to: nil).maxY)
            let down = try NSEvent.syntheticClick(.leftMouseDown, at: location, in: hosted.window)
            let up = try NSEvent.syntheticClick(.leftMouseUp, at: location, in: hosted.window)
            hosted.window.sendEvent(down)
            hosted.window.sendEvent(up)
            try await hosted.settle()
            XCTAssertEqual(hosted.harness.pendingAddWorktree?.repo.path, "/sidebar-test")
            XCTAssertTrue(hosted.harness.selections.isEmpty)
        }
    }

    func testPinnedMenusDoNotShadowOrdinaryRows() async throws {
        for rail in [false, true] {
            try await pinnedMenusDoNotShadowOrdinaryRows(rail: rail)
        }
    }

    private func pinnedMenusDoNotShadowOrdinaryRows(rail: Bool) async throws {
        let hosted = try await Hosted.make(pinnedCount: 8, rail: rail)
        defer { hosted.tearDown() }
        let row = try hosted.dragView(named: "task-0")
        let scroll = try XCTUnwrap(hosted.enclosingScroll(row))
        let location = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let expected = try XCTUnwrap(Self.find(RightClickMenuHostView.self, in: hosted.hosting).first {
            hosted.enclosingScroll($0) === scroll && $0.convert($0.bounds, to: nil).contains(location)
        })
        XCTAssertTrue(RightClickMenuHostView.innermostHost(at: location, in: hosted.hosting) === expected)
    }

    func testSplitRegionsKeepWorktreeHeadingClicks() async throws {
        for rail in [false, true] {
            try await splitRegionsKeepWorktreeHeadingClicks(rail: rail)
        }
    }

    private func splitRegionsKeepWorktreeHeadingClicks(rail: Bool) async throws {
        let hosted = try await Hosted.make(pinnedCount: 1, rail: rail)
        defer { hosted.tearDown() }
        for name in ["pinned-0", "task-0"] {
            let row = try hosted.dragView(named: name)
            let location = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            let down = try NSEvent.syntheticClick(.leftMouseDown, at: location, in: hosted.window)
            let up = try NSEvent.syntheticClick(.leftMouseUp, at: location, in: hosted.window)
            let sources = Self.find(WorktreeDragSourceView.self, in: hosted.hosting)
            for source in sources { source.currentEvent = { down } }
            defer { for source in sources { source.currentEvent = { NSApp.currentEvent } } }
            let root = try XCTUnwrap(hosted.window.contentView)
            let hit = try XCTUnwrap(root.hitTest(root.superview?.convert(location, from: nil) ?? location))
            XCTAssertTrue(hit === row)
            hit.mouseDown(with: down)
            hit.mouseUp(with: up)
            XCTAssertTrue(hosted.harness.selections.last == "/sidebar-test/.worktrees/" + name)
        }
    }


    @MainActor
    fileprivate final class Hosted {
        let harness: SidebarScrollHarness
        let hosting: NSHostingView<HostedSidebarScrollView>
        let window: NSWindow
        let oldRail: Any?

        static func make(pinnedCount: Int, rail: Bool) async throws -> Hosted {
            let hosted = try Hosted(pinnedCount: pinnedCount, rail: rail)
            try await hosted.settle()
            return hosted
        }
        init(pinnedCount: Int, rail: Bool) throws {
            oldRail = UserDefaults.standard.object(forKey: SidebarLayoutPolicy.projectRailSettingKey)
            UserDefaults.standard.set(rail, forKey: SidebarLayoutPolicy.projectRailSettingKey)
            harness = try SidebarScrollHarness(pinnedCount: pinnedCount)
            hosting = NSHostingView(rootView: HostedSidebarScrollView(harness: harness))
            window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 540),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            window.orderFront(nil)
        }
        func dragView(named name: String) throws -> WorktreeDragSourceView {
            let row = try XCTUnwrap(harness.state.repos[0].worktrees.first { $0.branch == name })
            // The default checkout can't be dragged, so its tile is the one without a payload.
            return try XCTUnwrap(SidebarScrollLayoutTests.find(WorktreeDragSourceView.self, in: hosting).first {
                name == "main" ? $0.payload == nil : $0.payload?.worktreeID == row.id
            })
        }
        func sidebarToggle() throws -> NSView {
            try XCTUnwrap(window.toolbar?.items.first {
                $0.itemIdentifier == .toggleSidebar || $0.itemIdentifier.rawValue.hasSuffix("toggleSidebar")
            }?.view)
        }
        func enclosingScroll(_ view: NSView) -> NSScrollView? {
            var ancestor = view.superview
            while let current = ancestor {
                if let scroll = current as? NSScrollView { return scroll }
                ancestor = current.superview
            }
            return nil
        }
        func captureIfRequested(name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["GRAFTTY_TEST_SCREENSHOT_DIR"] else { return }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            window.displayIfNeeded()
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        }
        func tearDown() {
            window.orderOut(nil)
            window.contentView = nil
            harness.web.stop()
            UserDefaults.standard.set(oldRail, forKey: SidebarLayoutPolicy.projectRailSettingKey)
        }
        func settle() async throws {
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
            }
        }
    }
    fileprivate static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
    }
}

/// Native text selection tracking uses XCTest because it can stop the
/// Swift Testing async-main run loop, just like native menu tracking.
@MainActor
final class SidebarSearchNativeTests: XCTestCase {
    /// @spec LAYOUT-2.151: When the user clicks the macOS sidebar search field, the application shall focus an editable search control below the native toolbar and filter worktrees as the user types, including after resizing.
    func testSearchReceivesClicksBelowToolbar() async throws {
        for rail in [false, true] {
            for compactToolbar in [false, true] {
                let hosted = try await SidebarScrollLayoutTests.Hosted.make(pinnedCount: 1, rail: rail)
                defer { hosted.tearDown() }
                hosted.window.toolbarStyle = compactToolbar ? .unifiedCompact : .unified
                for width in [900.0, 720.0] {
                    hosted.window.setContentSize(NSSize(width: width, height: 540))
                    try await hosted.settle()
                    let search = try XCTUnwrap(SidebarScrollLayoutTests.find(NSTextField.self, in: hosted.hosting).first {
                        $0.placeholderString == "Search projects and worktrees"
                    })
                    let toggle = try hosted.sidebarToggle()
                    let toolbar = try XCTUnwrap(toggle.superview)
                    let searchFrame = search.convert(search.bounds, to: hosted.hosting)
                    XCTAssertGreaterThanOrEqual(searchFrame.minY, toolbar.convert(toolbar.bounds, to: hosted.hosting).maxY)
                    XCTAssertGreaterThanOrEqual(searchFrame.height, 28)
                    let chrome = try XCTUnwrap(hosted.window.contentView?.superview)
                    let location = search.convert(CGPoint(x: search.bounds.midX, y: search.bounds.midY), to: nil)
                    let hit = try XCTUnwrap(chrome.hitTest(chrome.superview?.convert(location, from: nil) ?? location))
                    XCTAssertTrue(hit === search || hit.isDescendant(of: search))
                    let down = try NSEvent.syntheticClick(.leftMouseDown, at: location, in: hosted.window)
                    let up = try NSEvent.syntheticClick(.leftMouseUp, at: location, in: hosted.window)
                    // NSTextView may synchronously track selection until mouse-up.
                    // Queue the release before entering that native tracking loop.
                    NSApp.postEvent(up, atStart: true)
                    hosted.window.sendEvent(down)
                    let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
                    XCTAssertTrue(hosted.window.firstResponder === editor)
                    editor.selectAll(nil)
                    editor.insertText("task-29", replacementRange: editor.selectedRange())
                    try await hosted.settle()
                    // The project column keeps recycled rows hidden until it reuses them.
                    let visible = SidebarScrollLayoutTests.find(WorktreeDragSourceView.self, in: hosted.hosting)
                        .filter { !$0.isHiddenOrHasHiddenAncestor }
                    let target = try XCTUnwrap(hosted.harness.state.repos[0].worktrees.first { $0.branch == "task-29" })
                    XCTAssertEqual(search.stringValue, "task-29")
                    XCTAssertEqual(visible.count, 1)
                    XCTAssertTrue(hosted.harness.selections.isEmpty)
                    // Search disables reordering, so these rows have no drag payload.
                    // Resolve the remaining row through its selection action instead.
                    try XCTUnwrap(visible.first).onClick?()
                    XCTAssertEqual(hosted.harness.selections, [target.path])
                    hosted.harness.selections.removeAll()
                    editor.selectAll(nil)
                    editor.insertText("", replacementRange: editor.selectedRange())
                    try await hosted.settle()
                    _ = try hosted.dragView(named: "pinned-0")
                    XCTAssertTrue(hosted.harness.selections.isEmpty)
                }
            }
        }
    }
}

/// Native menu tracking stops the Swift Testing async-main run loop on some
/// Swift runtimes, so native menu construction uses the XCTest AppKit process.
@MainActor
final class SidebarDeleteMenuNativeTests: XCTestCase {
    func testUnselectedDeleteTargetsOwningWindow() async throws {
        for rail in [false, true] {
            let hosted = try await SidebarScrollLayoutTests.Hosted.make(pinnedCount: 1, rail: rail)
            defer { hosted.tearDown() }
            hosted.harness.state.selectedWorktreePath = "/sidebar-test"
            try await hosted.settle()
            let row = try hosted.dragView(named: "task-0")
            let point = row.convert(CGPoint(x: row.bounds.maxX - 12, y: row.bounds.midY), to: nil)
            let host = try XCTUnwrap(RightClickMenuHostView.innermostHost(at: point, in: hosted.hosting))
            let event = try NSEvent.syntheticClick(.rightMouseDown, at: point, in: hosted.window)
            let menu = try XCTUnwrap(host.menu(for: event))
            let item = try XCTUnwrap(menu.items.first { $0.title == "Delete Worktree" })
            _ = item.target?.perform(item.action, with: item)
            let request = try XCTUnwrap(hosted.harness.deleteRequests.first)
            XCTAssertEqual(hosted.harness.deleteRequests.count, 1)
            XCTAssertEqual(request.path, "/sidebar-test/.worktrees/task-0")
            XCTAssertTrue(request.window === hosted.window)
            XCTAssertEqual(hosted.harness.state.selectedWorktreePath, "/sidebar-test")
            XCTAssertTrue(hosted.harness.selections.isEmpty)
        }
    }
}
