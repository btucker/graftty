import AppKit
import SwiftUI
import Testing
import XCTest
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

@MainActor
private final class SidebarScrollHarness: ObservableObject {
    @Published var state: AppState
    var selections: [String] = []
    let manager = TerminalManager(socketPath: "/tmp/sidebar-test-unused.sock")
    let remotes = RemoteMacsModel(store: RemoteMacStore(storeURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    let voice = VoiceDictationController()
    let stats = WorktreeStatsStore()
    let prs = PRStatusStore()
    let registry = ClaudeSessionRegistry()
    let branches = RemoteBranchStore()
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
                remoteMacsModel: harness.remotes, selectedRemoteIdentity: nil, selectedRemoteWorktreePath: nil,
                selectedRemotePaneSessionName: nil, onSelect: { harness.selections.append($0) },
                onSelectPane: { _, _ in }, onSelectRemoteMac: { _ in }, onSelectRemoteWorktree: { _, _ in },
                onSelectRemotePane: { _, _, _ in }, onAddRemoteWorktree: { _, _ in }, onDeleteRemoteWorktree: { _, _ in },
                onAddRemoteMac: {}, onAddRepo: {}, onAddPath: { _ in }, onRemoveRepo: { _ in }, onInitializeGit: { _ in },
                onStopWorktree: { _ in }, onDeleteWorktree: { _ in }, onMovePane: { _, _ in },
                onAddWorktree: { _, _, _ in nil }, pendingAddWorktree: .constant(nil))
                .environmentObject(harness.web)
                .environmentObject(PortBindingsModel())
                .navigationSplitViewColumnWidth(min: 300, ideal: 440, max: 540)
        } detail: { Color.clear }
    }
}

@Suite("Sidebar scroll layout", .serialized)
@MainActor
struct SidebarScrollLayoutTests {
    @Test("@spec LAYOUT-2.89: While the ordinary worktree list scrolls, the application shall keep Pinned Agents and the Sort order and Add Worktree line fixed above its viewport in both macOS sidebar modes.", arguments: [false, true])
    func ordinaryScrollKeepsPinnedRowsFixed(rail: Bool) async throws {
        let hosted = try await Hosted.make(pinnedCount: 1, rail: rail)
        defer { hosted.tearDown() }
        let pinned = try hosted.dragView(named: "pinned-0")
        let task = try hosted.dragView(named: "task-0")
        let ordinary = try #require(hosted.enclosingScroll(task))
        let originalPinned = pinned.convert(pinned.bounds, to: hosted.hosting)
        let originalTask = task.convert(task.bounds, to: hosted.hosting)
        let sort = try #require(Self.find(NSPopUpButton.self, in: hosted.hosting).first)
        let originalSort = sort.convert(sort.bounds, to: hosted.hosting)
        ordinary.contentView.scroll(to: CGPoint(x: 0, y: 120))
        ordinary.reflectScrolledClipView(ordinary.contentView)
        try await hosted.settle()
        #expect(ordinary.contentView.bounds.origin.y == 120)
        #expect(pinned.convert(pinned.bounds, to: hosted.hosting) == originalPinned)
        #expect(task.convert(task.bounds, to: hosted.hosting).minY != originalTask.minY)
        #expect(hosted.enclosingScroll(pinned) !== ordinary)
        #expect(sort.convert(sort.bounds, to: hosted.hosting) == originalSort)
    }

    @Test("@spec LAYOUT-2.119: If pinned agents exceed the available sidebar height, then the application shall scroll them independently within at most half the usable sidebar height, keep the sort line fixed, reserve 96 points for ordinary worktrees when space permits, and fit short pinned sections to their content.", arguments: [false, true], [1, 30])
    func pinnedOverflowIsBounded(rail: Bool, pinnedCount: Int) async throws {
        let hosted = try await Hosted.make(pinnedCount: pinnedCount, rail: rail)
        defer { hosted.tearDown() }
        let pinned = try #require(hosted.enclosingScroll(try hosted.dragView(named: "pinned-0")))
        let ordinary = try #require(hosted.enclosingScroll(try hosted.dragView(named: "task-0")))
        #expect(pinned !== ordinary)
        #expect(pinned.contentView.bounds.height - pinned.contentInsets.top <= hosted.hosting.bounds.height / 2)
        #expect(ordinary.contentView.bounds.height >= 120)
        try hosted.captureIfRequested(name: "sidebar-\(rail ? "rail" : "single")-pins-\(pinnedCount)")
        if pinnedCount == 1 {
            #expect(try #require(pinned.documentView).bounds.height <= pinned.contentView.bounds.height + 1)
        } else {
            #expect(try #require(pinned.documentView).bounds.height > pinned.contentView.bounds.height)
            let oldOrdinaryOrigin = ordinary.contentView.bounds.origin
            let sort = try #require(Self.find(NSPopUpButton.self, in: hosted.hosting).first)
            let sortFrame = sort.convert(sort.bounds, to: hosted.hosting)
            pinned.contentView.scroll(to: CGPoint(x: 0, y: 100))
            pinned.reflectScrolledClipView(pinned.contentView)
            try await hosted.settle()
            #expect(pinned.contentView.bounds.origin.y == 100)
            #expect(ordinary.contentView.bounds.origin == oldOrdinaryOrigin)
            #expect(sort.convert(sort.bounds, to: hosted.hosting) == sortFrame)
            hosted.window.setContentSize(NSSize(width: 900, height: 340))
            try await hosted.settle()
            #expect(pinned.contentView.bounds.height - pinned.contentInsets.top <= hosted.hosting.bounds.height / 2)
            #expect(ordinary.contentView.bounds.height >= 96)
        }
    }

    @Test func returningToProjectRevealsRememberedPinnedAgent() async throws {
        let hosted = try await Hosted.make(pinnedCount: 30, rail: true)
        defer { hosted.tearDown() }
        let target = try #require(hosted.harness.state.repos[0].worktrees.first { $0.branch == "pinned-29" })
        hosted.harness.state.repos.append(RepoEntry(path: "/other-sidebar-test", displayName: "Other",
            worktrees: [WorktreeEntry(path: "/other-sidebar-test", branch: "main")]))
        hosted.harness.state.selectedWorktreePath = target.path
        try await hosted.settle()
        hosted.harness.state.selectedWorktreePath = "/other-sidebar-test"
        try await hosted.settle()
        hosted.harness.state.selectedWorktreePath = target.path
        try await hosted.settle()
        let row = try hosted.dragView(named: "pinned-29")
        let scroll = try #require(hosted.enclosingScroll(row))
        #expect(scroll.contentView.bounds.origin.y > 0)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: hosted.hosting)
        #expect(viewport.contains(row.convert(row.bounds, to: hosted.hosting)))
    }

    @Test(arguments: [false, true])
    func overflowPinnedMenusDoNotShadowOrdinaryRows(rail: Bool) async throws {
        let hosted = try await Hosted.make(pinnedCount: 30, rail: rail)
        defer { hosted.tearDown() }
        let row = try hosted.dragView(named: "task-0")
        let scroll = try #require(hosted.enclosingScroll(row))
        let location = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let expected = try #require(Self.find(RightClickMenuHostView.self, in: hosted.hosting).first {
            hosted.enclosingScroll($0) === scroll && $0.convert($0.bounds, to: nil).contains(location)
        })
        #expect(RightClickMenuHostView.innermostHost(at: location, in: hosted.hosting) === expected)
    }

    @Test(arguments: [false, true])
    func splitRegionsKeepWorktreeHeadingClicks(rail: Bool) async throws {
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
            let root = try #require(hosted.window.contentView)
            let hit = try #require(root.hitTest(root.superview?.convert(location, from: nil) ?? location))
            #expect(hit === row)
            hit.mouseDown(with: down)
            hit.mouseUp(with: up)
            #expect(hosted.harness.selections.last == "/sidebar-test/.worktrees/" + name)
        }
    }

    /// AppKit menu cancellation can stop the caller's CFRunLoop. Swift's
    /// async main exits the test process if that is its outer run loop, so
    /// keep native tracking inside a nested loop owned by this probe.
    @MainActor
    private final class NativeMenuDispatch {
        let window: NSWindow
        let event: NSEvent
        let popup: NSPopUpButton
        var didRun = false
        init(window: NSWindow, event: NSEvent, popup: NSPopUpButton) {
            self.window = window; self.event = event; self.popup = popup
        }
        func perform() {
            let timer = Timer(timeInterval: 0.01, repeats: false) { _ in
                MainActor.assumeIsolated { self.run() }
            }
            RunLoop.main.add(timer, forMode: .default)
            defer { timer.invalidate() }
            CFRunLoopRunInMode(.defaultMode, 2, false)
        }
        private func run() {
            let fallback = Timer(timeInterval: 0.5, repeats: false) { _ in
                MainActor.assumeIsolated { self.popup.menu?.cancelTrackingWithoutAnimation() }
            }
            RunLoop.main.add(fallback, forMode: .eventTracking)
            defer { fallback.invalidate() }
            NSApp.finishLaunching()
            window.sendEvent(event)
            didRun = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    @MainActor
    private final class MenuTracking { var menu: NSMenu? }

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
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentView = hosting
            window.orderFront(nil)
        }
        func expectSortOpensAndSelects(_ mode: WorktreeOrderMode) async throws {
            for probe in 0..<3 {
                // SwiftUI may replace the native control when AppState
                // updates. Probe the view currently attached to the window.
                let popup = try XCTUnwrap(SidebarScrollLayoutTests.find(NSPopUpButton.self, in: hosting).first {
                    $0.accessibilityLabel() == "Worktree order"
                })
                let sources = SidebarScrollLayoutTests.find(WorktreeDragSourceView.self, in: hosting)
                let frame = popup.convert(popup.bounds, to: hosting)
                XCTAssertGreaterThanOrEqual(frame.height, 28)
                let point = [CGPoint(x: frame.midX, y: frame.midY),
                             CGPoint(x: frame.minX + 2, y: frame.minY + 2),
                             CGPoint(x: frame.maxX - 2, y: frame.maxY - 2)][probe]
                let location = hosting.convert(point, to: nil)
                let down = try NSEvent.syntheticClick(.leftMouseDown, at: location, in: window)
                let up = try NSEvent.syntheticClick(.leftMouseUp, at: location, in: window)
                for source in sources { source.currentEvent = { down } }
                defer { for source in sources { source.currentEvent = { NSApp.currentEvent } } }
                let root = try XCTUnwrap(window.contentView)
                let hit = root.hitTest(root.superview?.convert(location, from: nil) ?? location)
                XCTAssertTrue(hit === popup || hit?.isDescendant(of: popup) == true,
                    "sort click at \(point) routed to \(String(describing: hit))")
                let tracking = MenuTracking()
                let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                    object: popup.menu, queue: .main) { note in
                    MainActor.assumeIsolated { tracking.menu = note.object as? NSMenu }
                }
                defer { NotificationCenter.default.removeObserver(observer) }
                // Open by pointer, then select with local keyboard events.
                // No global pointer movement or live app events.
                func key(_ characters: String, code: UInt16) throws -> NSEvent {
                    try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: location,
                        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                }
                let index = try XCTUnwrap(SidebarWorktreeOrderControl.choices.firstIndex { $0.mode == mode })
                NSApp.postEvent(up, atStart: false)
                if popup.indexOfSelectedItem != index {
                    NSApp.postEvent(try key(index == 0 ? "\u{f700}" : "\u{f701}", code: index == 0 ? 126 : 125), atStart: false)
                }
                NSApp.postEvent(try key("\r", code: 36), atStart: false)
                let dispatch = NativeMenuDispatch(window: window, event: down, popup: popup)
                dispatch.perform()
                XCTAssertTrue(dispatch.didRun)
                let menu = try XCTUnwrap(tracking.menu)
                XCTAssertTrue(menu.items.map(\.title).contains("Manual Order"))
                XCTAssertTrue(menu.items.map(\.title).contains("Recent Activity"))
                try await settle()
                XCTAssertEqual(harness.state.repos[0].worktreeOrderMode, mode)
                XCTAssertTrue(harness.selections.isEmpty)
            }
        }
        func dragView(named name: String) throws -> WorktreeDragSourceView {
            let row = try #require(harness.state.repos[0].worktrees.first { $0.branch == name })
            return try #require(SidebarScrollLayoutTests.find(WorktreeDragSourceView.self, in: hosting).first {
                $0.payload?.worktreeID == row.id
            })
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
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            window.displayIfNeeded()
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
            let scroll = try #require(enclosingScroll(try dragView(named: "pinned-0")))
            let document = try #require(scroll.documentView)
            let rect = CGRect(x: document.bounds.minX, y: document.bounds.minY,
                width: document.bounds.width, height: min(document.bounds.height, 220))
            let pinnedBitmap = try #require(document.bitmapImageRepForCachingDisplay(in: rect))
            document.needsDisplay = true
            document.displayIfNeeded()
            document.cacheDisplay(in: rect, to: pinnedBitmap)
            try pinnedBitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + "-document.png"))

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
    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
    }
}

/// Native menu tracking stops the Swift Testing async-main run loop on
/// affected Swift runtimes. XCTest provides a separate AppKit test process.
@MainActor
final class SidebarSortNativeTests: XCTestCase {
    /// @spec LAYOUT-2.118: When the user clicks the visible sidebar sort dropdown, the application shall open its order choices and apply the selected order without selecting a worktree, including after scrolling and resizing, with a target at least 28 points tall.
    func testSortTargetsInBothSidebarModes() async throws {
        for rail in [false, true] {
            let hosted = try await SidebarScrollLayoutTests.Hosted.make(pinnedCount: 1, rail: rail)
            defer { hosted.tearDown() }
            try await hosted.expectSortOpensAndSelects(.recentActivity)
            let ordinary = try XCTUnwrap(hosted.enclosingScroll(try hosted.dragView(named: "task-0")))
            ordinary.contentView.scroll(to: CGPoint(x: 0, y: 120))
            ordinary.reflectScrolledClipView(ordinary.contentView)
            try await hosted.settle()
            XCTAssertEqual(ordinary.contentView.bounds.origin.y, 120)
            try await hosted.expectSortOpensAndSelects(.manual)
            hosted.window.setContentSize(NSSize(width: 740, height: 420))
            try await hosted.settle()
            try await hosted.expectSortOpensAndSelects(.recentActivity)
        }
    }
}
