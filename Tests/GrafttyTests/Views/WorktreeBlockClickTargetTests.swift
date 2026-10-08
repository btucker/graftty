import AppKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

/// Selection and geometry recorded by the hosted sidebar column. Frames are
/// SwiftUI `.global` frames, which in an `NSHostingView` are the hosting
/// view's own (top-left) coordinates — measured independently of the AppKit
/// overlays whose hit testing the tests exercise.
@MainActor
final class WorktreeBlockClickHarness: ObservableObject {
    @Published var reorderingEnabled = true
    @Published var state: AppState
    @Published var headingFrames: [String: CGRect] = [:]
    @Published var blockFrames: [String: CGRect] = [:]
    @Published var questionFrames: [String: CGRect] = [:]
    @Published var paneFrames: [PaneSlotID: CGRect] = [:]
    var selections: [String] = []
    var paneSelections: [PaneSlotID] = []

    init(state: AppState) { self.state = state }

    var repo: RepoEntry { state.repos[0] }
}

/// The production worktree column: `ProjectWorktreeColumn` hosting one
/// `WorktreeBlock` per worktree, each with a `WorktreeRow` heading and
/// `PaneTitleRow` children, as `SidebarView.worktreeBlock` composes them.
/// The production worktree column only. The legacy `List` sidebar
/// (`showsProjectRail == false`) hosts rows in an AppKit outline view that
/// resolves presses through its own event loop, which synthesized events
/// delivered outside the application run loop cannot drive, so that
/// container is not covered here.
private struct WorktreeBlockClickColumn: View {
    @ObservedObject var harness: WorktreeBlockClickHarness

    var body: some View {
        ProjectWorktreeColumn(header: { Text("Project").frame(height: 30) }) {
            ForEach(harness.repo.worktrees) { worktree in
                block(worktree)
            }
        }
    }

    private func block(_ worktree: WorktreeEntry) -> some View {
        let repo = harness.repo
        let isActive = harness.state.selectedWorktreePath == worktree.path
        let paneLeaves = worktree.state == .running ? worktree.splitTree.allLeaves : []
        let groupsPanes = !paneLeaves.isEmpty
        return WorktreeBlock(
            worktree: worktree, repoID: repo.id, isActive: isActive, isDropTarget: false,
            groupsPanes: groupsPanes, theme: .fallback,
            appState: Binding(get: { harness.state }, set: { harness.state = $0 }),
            reorderingEnabled: harness.reorderingEnabled,
            onSelect: { harness.selections.append(worktree.path) },
            onMovePane: { _, _ in }, onPaneTargeted: { _ in },
            menu: { _ in NSMenu() }
        ) {
            WorktreeRow(entry: worktree, isActive: isActive, displayName: worktree.branch,
                        isMainCheckout: worktree.path == repo.path, theme: .fallback,
                        stats: nil, baseRef: nil, prBadge: nil, attentionStyle: nil)
                .frame(minHeight: groupsPanes ? 28 : 44)
                .contentShape(Rectangle())
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    harness.headingFrames[worktree.path] = $0
                }
                // LazyVStack releases blocks that scroll out of view; drop
                // their last frame so the harness never clicks a ghost.
                .onDisappear { harness.headingFrames[worktree.path] = nil }
        } panes: {
            ForEach(paneLeaves, id: \.self) { terminalID in
                Button {
                    harness.paneSelections.append(terminalID)
                } label: {
                    PaneTitleRow(title: "shell", isActiveWorktree: isActive, isFocusedPane: false,
                                 isBusy: false, theme: .fallback, attentionStyle: nil, portBindings: [])
                }
                .buttonStyle(.plain)
                .transformAnchorPreference(key: WorktreeHeadingAnchor.self, value: .bounds) { $0[.pane(terminalID)] = $1 }
                .draggable(TransferablePaneSlotID(id: terminalID.id))
                .rightClickMenu { NSMenu() }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    harness.paneFrames[terminalID] = $0
                }
                .onDisappear { harness.paneFrames[terminalID] = nil }
            }
            if let stop = worktree.unseenAgentStop {
                let row = sidebarLocalWorktree(worktree, repo: repo,
                    owner: .init(deviceID: .init(value: "test"), deviceLabel: "Test", relayDepth: 0),
                    displayName: worktree.branch, titles: [:], liveness: [:], prBadge: nil)
                SidebarWorktreeQuestion(context: .init(worktree: row))
                    .padding(.leading, 33).padding(.trailing, 8)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        harness.questionFrames[worktree.path] = $0
                    }
                    .accessibilityLabel(stop.title)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            harness.blockFrames[worktree.path] = $0
        }
        .onDisappear { harness.blockFrames[worktree.path] = nil }
    }
}

/// The sidebar as `MainWindow` hosts it: a `NavigationSplitView` sidebar whose
/// root ignores the top safe area so the search row sits in the title bar.
private struct WorktreeBlockClickSidebar: View {
    @ObservedObject var harness: WorktreeBlockClickHarness
    @State private var visibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    TextField("Find any project or worktree", text: .constant(""))
                        .textFieldStyle(.roundedBorder).controlSize(.small)
                        .padding(.leading, 112).padding(.trailing, 10)
                        .frame(height: max(geometry.safeAreaInsets.top, 38))
                    HStack(spacing: 0) {
                        Color.gray.frame(width: 40)
                        Divider()
                        WorktreeBlockClickColumn(harness: harness)
                            .frame(minWidth: 220, maxWidth: .infinity)
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 400)
        } detail: {
            Color.clear.ignoresSafeArea(.container, edges: .top)
        }
    }
}

@Suite("Worktree block click targets", .serialized)
@MainActor
struct WorktreeBlockClickTargetTests {
    private static let rowCount = 20
    private static let grownPath = "/repo/.worktrees/wt-01"

    @Test("@spec LAYOUT-2.116: When the user clicks a visible worktree heading in the project column outside its embedded controls such as the PR/MR badge, the application shall select that worktree, including after another block changes height, after the column scrolls, and after the window resizes.")
    func visibleHeadingClicksSelectTheirWorktree() async throws {
        let hosted = try await Hosted.make(rowCount: Self.rowCount)
        defer { hosted.tearDown() }

        try await hosted.expectVisibleHeadingsSelect(scenario: "initial")

        // A block above the rest gains two pane rows, pushing later rows down.
        hosted.setPanes(path: Self.grownPath, count: 2)
        try await hosted.settle()
        try await hosted.expectVisibleHeadingsSelect(scenario: "after a block grew")
        for pane in hosted.harness.paneFrames.keys {
            try await hosted.expectPaneClickSelects(pane)
        }

        // Real scrolling: the clip view origin must move.
        let scrollView = try #require(hosted.scrollView)
        let before = scrollView.contentView.bounds.origin.y
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 150))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await hosted.settle()
        #expect(scrollView.contentView.bounds.origin.y != before)
        #expect(scrollView.contentView.bounds.origin.y == 150)
        try await hosted.expectVisibleHeadingsSelect(scenario: "after scrolling")

        hosted.window.setContentSize(NSSize(width: 700, height: 300))
        try await hosted.settle()
        try await hosted.expectVisibleHeadingsSelect(scenario: "after resizing")

        hosted.setPanes(path: Self.grownPath, count: 0)
        try await hosted.settle()
        try await hosted.expectVisibleHeadingsSelect(scenario: "after the block collapsed")
    }

    @Test("@spec LAYOUT-2.117: When the user clicks the vertical padding inside a grouped worktree block's highlight, the application shall select that worktree.")
    func groupedBlockPaddingSelectsTheWorktree() async throws {
        let hosted = try await Hosted.make(rowCount: 4)
        defer { hosted.tearDown() }
        hosted.setPanes(path: Self.grownPath, count: 2)
        try await hosted.settle()

        let block = try #require(hosted.harness.blockFrames[Self.grownPath])
        let heading = try #require(hosted.harness.headingFrames[Self.grownPath])
        #expect(abs(heading.minY - block.minY - 8) < 0.5, "the grouped block carries 8pt of padding above its heading")
        let lastPaneMaxY = try #require(hosted.harness.paneFrames.values.map(\.maxY).max())
        #expect(abs(block.maxY - lastPaneMaxY - 8) < 0.5, "the grouped block carries 8pt of padding below its last pane")

        for point in [CGPoint(x: block.midX, y: block.minY + 4), CGPoint(x: block.midX, y: block.maxY - 4)] {
            let outcome = try await hosted.click(at: point)
            #expect(outcome.selections == [Self.grownPath], "padding click at \(point) selected \(outcome.selections)")
            #expect(outcome.paneSelections.isEmpty)
        }
    }

    @Test("@spec LAYOUT-2.145: When the user clicks anywhere in a macOS worktree block, including its Needs your input question and surrounding space, the application shall select that worktree while preserving embedded controls and pane selection.", arguments: [false, true])
    func questionAndSurroundingSpaceSelectWorktree(reorderingEnabled: Bool) async throws {
        let hosted = try await Hosted.make(rowCount: Self.rowCount)
        defer { hosted.tearDown() }
        hosted.harness.reorderingEnabled = reorderingEnabled
        for index in 0...1 {
            hosted.harness.state.repos[0].worktrees[index].recordAgentStop(.init(
                agentName: "Codex", stoppedAt: Date(),
                recap: .init(title: "Sidebar", completed: "Updated clicks", next: "Review", need: "Try this question?")))
        }
        try await hosted.settle()
        for path in [hosted.harness.repo.path, Self.grownPath] {
            let frame = try #require(hosted.harness.questionFrames[path])
            for point in [CGPoint(x: frame.midX, y: frame.midY),
                          CGPoint(x: frame.minX + 2, y: frame.midY),
                          CGPoint(x: frame.maxX - 2, y: frame.midY)] {
                let outcome = try await hosted.click(at: point)
                #expect(outcome.selections == [path])
                #expect(outcome.paneSelections.isEmpty)
            }
        }
        let path = Self.grownPath
        hosted.setPanes(path: path, count: 2)
        try await hosted.settle()
        for pane in hosted.harness.paneFrames.keys { try await hosted.expectPaneClickSelects(pane) }
    }

    // MARK: - Hosting

    @MainActor
    private final class Hosted {
        let harness: WorktreeBlockClickHarness
        let hosting: NSHostingView<WorktreeBlockClickSidebar>
        let window: NSWindow

        struct ClickOutcome {
            let hitView: String
            let selections: [String]
            let paneSelections: [PaneSlotID]
        }

        static func make(rowCount: Int) async throws -> Hosted {
            var worktrees = [WorktreeEntry(path: "/repo", branch: "main")]
            worktrees += (1..<rowCount).map {
                WorktreeEntry(path: "/repo/.worktrees/wt-\(String(format: "%02d", $0))", branch: "wt-\($0)")
            }
            let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: worktrees)
            let hosted = Hosted(harness: WorktreeBlockClickHarness(state: AppState(repos: [repo])))
            try await hosted.settle()
            return hosted
        }

        private init(harness: WorktreeBlockClickHarness) {
            self.harness = harness
            hosting = NSHostingView(rootView: WorktreeBlockClickSidebar(harness: harness))
            // `MainWindow` hides the title bar and extends content under it.
            window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 400),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = hosting
            window.orderFront(nil)
        }

        func tearDown() { window.orderOut(nil) }

        func settle() async throws {
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(80))
                hosting.layoutSubtreeIfNeeded()
            }
        }

        func setPanes(path: String, count: Int) {
            guard let index = harness.state.repos[0].worktrees.firstIndex(where: { $0.path == path }) else { return }
            harness.paneFrames = [:]
            if count == 0 {
                harness.state.repos[0].worktrees[index].state = .closed
                harness.state.repos[0].worktrees[index].splitTree = SplitTree(root: nil)
                return
            }
            var node: SplitTree.Node = .leaf(PaneSlotID(id: UUID()))
            for _ in 1..<count {
                node = .split(.init(direction: .horizontal, ratio: 0.5, left: node, right: .leaf(PaneSlotID(id: UUID()))))
            }
            harness.state.repos[0].worktrees[index].state = .running
            harness.state.repos[0].worktrees[index].splitTree = SplitTree(root: node)
        }

        /// The scroll view that hosts the worktree rows (the one containing a drag source).
        var scrollView: NSScrollView? {
            Self.find(NSScrollView.self, in: hosting).first { !Self.find(WorktreeDragSourceView.self, in: $0).isEmpty }
        }

        /// The column's visible area in hosting coordinates.
        var visibleRect: CGRect {
            guard let clip = scrollView?.contentView else { return hosting.bounds }
            return clip.convert(clip.bounds, to: hosting)
        }

        /// Headings whose frames lie fully inside the visible column.
        var visibleHeadings: [(path: String, frame: CGRect)] {
            let visible = visibleRect
            return harness.headingFrames
                .filter { visible.insetBy(dx: 0, dy: 1).contains($0.value) }
                .map { (path: $0.key, frame: $0.value) }
                .sorted { $0.frame.minY < $1.frame.minY }
        }

        func expectVisibleHeadingsSelect(scenario: String) async throws {
            let headings = visibleHeadings
            #expect(headings.count >= 3, "\(scenario): expected several visible headings, found \(headings.count)")
            for (path, frame) in headings {
                let probes = [
                    CGPoint(x: frame.midX, y: frame.midY),
                    CGPoint(x: frame.minX + 9, y: frame.minY + 2),
                    CGPoint(x: frame.maxX - 10, y: frame.maxY - 2),
                ]
                for point in probes {
                    let outcome = try await click(at: point)
                    #expect(outcome.selections == [path],
                            "\(scenario): click at \(point) on \(path) selected \(outcome.selections) via \(outcome.hitView)")
                    #expect(outcome.paneSelections.isEmpty, "\(scenario): heading click reached a pane row")
                    if path != harness.repo.path {
                        // Linked worktrees are draggable, so the AppKit drag
                        // source owns the press and must be what the window's
                        // root hit test resolves to.
                        #expect(outcome.hitView == "WorktreeDragSourceView",
                                "\(scenario): root hit test at \(point) on \(path) found \(outcome.hitView)")
                    }
                }
            }
        }

        func expectPaneClickSelects(_ pane: PaneSlotID) async throws {
            let frame = try #require(harness.paneFrames[pane])
            let outcome = try await click(at: CGPoint(x: frame.midX, y: frame.midY))
            #expect(outcome.paneSelections == [pane])
            #expect(outcome.selections.isEmpty)
        }

        /// Clicks like AppKit does: resolve the hit view from the window's
        /// root with the press as the current event, then deliver the press
        /// and release to it. SwiftUI-owned regions take the events through
        /// the window so the hosting view runs its own gesture handling.
        func click(at hostingPoint: CGPoint) async throws -> ClickOutcome {
            harness.selections = []
            harness.paneSelections = []
            let windowPoint = hosting.convert(hostingPoint, to: nil)
            let down = try NSEvent.syntheticClick(.leftMouseDown, at: windowPoint, in: window)
            let up = try NSEvent.syntheticClick(.leftMouseUp, at: windowPoint, in: window)
            let root = try #require(window.contentView)
            let hit = withDragSources(seeing: down) {
                root.hitTest(root.superview?.convert(windowPoint, from: nil) ?? windowPoint)
            }
            let hitName = hit.map { String(describing: type(of: $0)) } ?? "nil"
            if let drag = hit as? WorktreeDragSourceView {
                drag.mouseDown(with: down)
                drag.mouseUp(with: up)
            } else {
                // No live event: the drag sources stay transparent so the
                // hosting view's own gesture handling receives the press.
                withDragSources(seeing: nil) {
                    window.sendEvent(down)
                    window.sendEvent(up)
                }
            }
            try await Task.sleep(for: .milliseconds(40))
            return ClickOutcome(hitView: hitName, selections: harness.selections, paneSelections: harness.paneSelections)
        }

        /// Points every drag source under the window root at `event` for the
        /// synchronous `body`, then restores the live-event lookup. Instances
        /// are SwiftUI's, so they are reached by walking the AppKit hierarchy.
        private func withDragSources<T>(seeing event: NSEvent?, _ body: () -> T) -> T {
            let sources = Self.find(WorktreeDragSourceView.self, in: hosting)
            for source in sources { source.currentEvent = { event } }
            defer { for source in sources { source.currentEvent = { NSApp.currentEvent } } }
            return body()
        }

        private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            var found: [T] = []
            if let match = view as? T { found.append(match) }
            for subview in view.subviews { found += find(type, in: subview) }
            return found
        }
    }
}
