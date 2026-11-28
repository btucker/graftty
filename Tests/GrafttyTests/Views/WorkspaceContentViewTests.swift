import AppKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

@MainActor
struct WorkspaceContentViewTests {
    @Test("@spec LAYOUT-2.198: When the user expands the terminal drawer, the application shall give its selected terminal keyboard focus, including a first terminal created by that action.", arguments: [false, true])
    func expandingDrawerActivatesItsTerminal(startsEmpty: Bool) {
        let agent = PaneSlotID(), terminal = PaneSlotID()
        var entry = WorktreeEntry(path: "/repo/drawer-focus", branch: "drawer-focus", state: .running,
            splitTree: SplitTree(root: .leaf(agent)))
        var layout = WorkspaceLayout<PaneSlotID>()
        layout.addAgent(agent)
        if !startsEmpty {
            entry.splitTree = entry.splitTree.inserting(terminal, at: agent, direction: .vertical)
            layout.addTerminal(terminal)
        }
        layout.hideDrawer()
        entry.workspaceLayout = layout
        entry.focusedPaneSlotID = agent
        var activated: [PaneSlotID] = []
        var creations = 0
        let view = WorkspaceContentView(terminalManager: TerminalManager(socketPath: "/tmp/graftty-drawer-focus-test.sock"),
            worktree: Binding(get: { entry }, set: { entry = $0 }),
            onFocusTerminal: { entry.focusedPaneSlotID = $0 },
            onNewTerminal: {
                creations += 1
                entry.splitTree = entry.splitTree.inserting(terminal, at: agent, direction: .vertical)
                entry.workspaceLayout?.addTerminal(terminal)
            }, onCloseTerminal: { _ in },
            onActivateTerminal: { activated.append($0) })

        view.toggleDrawer()
        #expect(entry.workspaceLayout?.drawerVisible == true)
        #expect(entry.workspaceLayout?.selectedTerminal == terminal)
        #expect(entry.focusedPaneSlotID == terminal)
        #expect(activated == [terminal])
        #expect(creations == (startsEmpty ? 1 : 0))
        view.toggleDrawer()
        view.toggleDrawer()
        #expect(activated == [terminal, terminal])
        #expect(creations == (startsEmpty ? 1 : 0))
    }

    @Test func absentLivenessEntryMatchesRemoteIdleProjection() {
        let slot = PaneSlotID(), session = PaneSessionID()
        var entry = WorktreeEntry(path: "/repo", branch: "main", state: .running)
        entry.paneSessions = [slot: session]
        let registry = ClaudeSessionRegistry()
        let view = WorkspaceContentView(terminalManager: TerminalManager(socketPath: "/tmp/graftty-tab-busy-test.sock"),
            worktree: .constant(entry), onFocusTerminal: { _ in }, onNewTerminal: {}, onCloseTerminal: { _ in },
            agentLiveness: registry)
        #expect(view.isBusy(slot) == false)
    }

    @Test("@spec AGENT-6.134: When cleanup captures a transcript for the selected finished tab, the application shall refresh its result pane without requiring the user to switch tabs.")
    func cleanupReloadsMountedTranscript() async throws {
        _ = NSApplication.shared
        let model = CompletedModel()
        var loads: [String?] = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: CompletedFixture(model: model, load: { agent in
            loads.append(agent.transcriptArchive?.id)
            return agent.transcriptArchive == nil ? nil : "Saved transcript"
        }))
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<50 where loads.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(loads.count == 1)
        model.agent.transcriptArchive = AgentTranscriptArchive(id: String(repeating: "a", count: 64), byteCount: 16)
        for _ in 0..<50 where loads.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(loads.count == 2)
        #expect(loads.last! == model.agent.transcriptArchive?.id)
    }

    @Test("@spec LAYOUT-2.190: When the user puts a live agent on stage or selects a terminal-drawer tab, the application shall give that terminal keyboard focus, including when it is already shown.", arguments: [false, true])
    func selectingTabActivatesItsTerminal(inDrawer: Bool) async throws {
        _ = NSApplication.shared
        let first = PaneSlotID(), second = PaneSlotID()
        var entry = WorktreeEntry(path: "/repo/tabs", branch: "tabs", state: .running,
            splitTree: SplitTree(root: .split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(first), right: .leaf(second)))))
        entry.agents = [("Codex A", first), ("Codex B", second)].map { name, slot in
            var agent = ManagedAgent(name: name, provider: .codex, parent: nil, launchOrigin: .cliAgentAdd, isPrimary: false)
            agent.paneSlotID = slot
            return agent
        }
        let group = WorkspaceLayout<PaneSlotID>.Group(sessions: [first, second], selected: first)
        entry.workspaceLayout = WorkspaceLayout(root: .group(group.id), groups: [group])
        if inDrawer {
            entry.agents = []
            var layout = WorkspaceLayout<PaneSlotID>()
            layout.addTerminal(first)
            layout.addTerminal(second)
            layout.select(first)
            entry.workspaceLayout = layout
        }
        entry.focusedPaneSlotID = first
        var activated: [PaneSlotID] = []
        let worktree = Binding(get: { entry }, set: { entry = $0 })
        let view = WorkspaceContentView(terminalManager: TerminalManager(socketPath: "/tmp/graftty-agent-tab-focus-test.sock"),
            worktree: worktree, onFocusTerminal: { entry.focusedPaneSlotID = $0 }, onNewTerminal: {}, onCloseTerminal: { _ in },
            onActivateTerminal: { activated.append($0) })
        for _ in 0..<2 {
            if inDrawer { view.selectTerminalTab(second) }
            else { view.stageAgent(second) }
            #expect(entry.focusedPaneSlotID == second)
            if inDrawer { #expect(entry.workspaceLayout?.selectedTerminal == second) }
            else { #expect(entry.workspaceLayout?.group(containing: second)?.selected == second) }
        }
        #expect(activated == [second, second])
    }

    private func twoAgentEntry(split: Bool = false) -> (WorktreeEntry, PaneSlotID, PaneSlotID) {
        let first = PaneSlotID(), second = PaneSlotID()
        var entry = WorktreeEntry(path: "/repo/gallery", branch: "gallery", state: .running,
            splitTree: SplitTree(root: .split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(first), right: .leaf(second)))))
        entry.agents = [("Codex A", first), ("Codex B", second)].map { name, slot in
            var agent = ManagedAgent(name: name, provider: .codex, parent: nil, launchOrigin: .cliAgentAdd, isPrimary: false)
            agent.paneSlotID = slot
            return agent
        }
        var layout = WorkspaceLayout<PaneSlotID>()
        layout.addAgent(first); layout.addAgent(second)
        if split, let group = layout.groups.first?.id { layout.split(second, beside: group, edge: .right) }
        layout.select(first)
        entry.workspaceLayout = layout
        entry.focusedPaneSlotID = first
        return (entry, first, second)
    }

    private func view(_ entry: Binding<WorktreeEntry>) -> WorkspaceContentView {
        WorkspaceContentView(terminalManager: TerminalManager(socketPath: "/tmp/graftty-gallery-test.sock"),
            worktree: entry, onFocusTerminal: { entry.wrappedValue.focusedPaneSlotID = $0 }, onNewTerminal: {}, onCloseTerminal: { _ in })
    }

    @Test("@spec LAYOUT-2.266: When the user clicks the sidebar button in the Mac worktree header, the application shall show or hide one right-hand column that holds the worktree's agents above its Context, however many agents the worktree has, and shall offer no separate control that opens or hides either part.")
    func oneButtonOwnsTheWholeColumn() {
        var (entry, _, second) = twoAgentEntry()
        let binding = Binding(get: { entry }, set: { entry = $0 })
        entry.workspaceLayout?.galleryVisible = false
        #expect(view(binding).showsGallery)
        entry.agents.removeAll { $0.paneSlotID == second }
        entry.workspaceLayout?.remove(second)
        #expect(view(binding).showsGallery)
        var hidden = view(binding)
        hidden.showsSidebar = false
        #expect(!hidden.showsGallery)
    }

    @Test("@spec LAYOUT-2.253: While the gallery and Context are both open on desktop, the application shall show them in one right-hand column, the gallery above Context, so the terminal gives up one column's width.")
    func galleryAndContextShareOneColumn() {
        #expect(WorkspaceGalleryColumn.width(showsGallery: false, showsContext: false) == nil)
        #expect(WorkspaceGalleryColumn.width(showsGallery: true, showsContext: false) == WorkspaceGalleryColumn.galleryWidth)
        #expect(WorkspaceGalleryColumn.width(showsGallery: false, showsContext: true) == WorkspaceGalleryColumn.contextWidth)
        #expect(WorkspaceGalleryColumn.width(showsGallery: true, showsContext: true) == WorkspaceGalleryColumn.contextWidth)
    }

    @Test("@spec LAYOUT-2.257: While the stage shows one pane on Mac, the application shall show no pane header, and shall float that pane's Chat / Terminal switch at the pane's top trailing corner, after any input request, so the terminal keeps the row.")
    func aLoneStagePaneHasNoHeader() {
        #expect(!StagePaneChrome.showsHeader(paneCount: 1))
        #expect(StagePaneChrome.showsHeader(paneCount: 2))
        #expect(StagePaneTopControls(banner: nil, chatSwitch: nil).isEmpty)
        #expect(!StagePaneTopControls(banner: nil, chatSwitch: AnyView(EmptyView())).isEmpty)
        #expect(!StagePaneTopControls(banner: AnyView(EmptyView()), chatSwitch: nil).isEmpty)
    }

    @Test("@spec LAYOUT-2.267: While Context shares the right-hand column with the agents on Mac, the application shall give Context the column's width, and when the user minimizes Context, the application shall reduce it to a bar at the foot of the column that opens it again and give the agents the rest of the column.")
    func contextMinimizesToTheFootOfTheColumn() {
        #expect(WorkspaceGalleryColumn.galleryMaxHeight(showsContext: true, contextMinimized: false) == 320)
        #expect(WorkspaceGalleryColumn.galleryMaxHeight(showsContext: true, contextMinimized: true) == .infinity)
        #expect(WorkspaceGalleryColumn.galleryMaxHeight(showsContext: false, contextMinimized: false) == .infinity)
    }

    @Test func theColumnWashMirrorsTheHeaderBandDownward() {
        #expect(WorktreeColumnWash.stretch(bandHeight: 42) == -10)
        #expect(WorktreeColumnWash.stretch(bandHeight: 0) == 0)
    }

    @Test("@spec LAYOUT-2.263: While an agent is shown as a gallery tile or as a row under Finished, the application shall show its provider's logo, over the corner of a tile's miniature and before the name of a Finished row.")
    func aTileCarriesItsAgentsProvider() {
        var (entry, first, _) = twoAgentEntry()
        let binding = Binding(get: { entry }, set: { entry = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-gallery-test.sock")
        let tile = WorkspaceContentView(terminalManager: manager, worktree: binding, onFocusTerminal: { _ in },
                                        onNewTerminal: {}, onCloseTerminal: { _ in }).tileModel(first)
        #expect(tile.provider == "codex")
    }

    @Test("@spec LAYOUT-2.258: When a gallery tile is shown before its agent's terminal surface exists, such as while the application restores terminals at launch, the application shall show the terminal's miniature and scroll rail once the surface exists.")
    func aTileFindsASurfaceCreatedAfterItWasBuilt() throws {
        var (entry, first, _) = twoAgentEntry()
        let binding = Binding(get: { entry }, set: { entry = $0 })
        let manager = TerminalManager(socketPath: "/tmp/graftty-gallery-test.sock")
        let tile = WorkspaceContentView(terminalManager: manager, worktree: binding, onFocusTerminal: { _ in },
                                        onNewTerminal: {}, onCloseTerminal: { _ in }).tileModel(first)
        #expect(tile.handle() == nil)

        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(terminalID: first, app: fakeApp(), worktreePath: entry.path,
            socketPath: "/tmp/graftty-gallery-test.sock", zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory, zmxBackendFactory: { _, _, _, _ in FakeSurfaceHandleZmxBackend() }))
        manager.insertSurfaceForTesting(handle, for: first)
        #expect(tile.handle() === handle)
    }

    @Test("@spec LAYOUT-2.260: When the user drags the leading edge of the right-hand column on Mac, the application shall resize the column between 180 and 600 points, size gallery tiles in proportion to its width, and keep the width for later sessions, separately for the gallery alone or above minimized Context and for the column with Context open.")
    func theRightColumnResizesAndScalesItsTiles() {
        #expect(WorkspaceGalleryColumn.width(showsGallery: true, showsContext: false, galleryWidth: 300, contextWidth: 400) == 300)
        #expect(WorkspaceGalleryColumn.width(showsGallery: true, showsContext: true, galleryWidth: 300, contextWidth: 400) == 400)
        #expect(WorkspaceGalleryColumn.width(showsGallery: false, showsContext: false, galleryWidth: 300, contextWidth: 400) == nil)
        // Dragging the leading edge left widens the column.
        #expect(WorkspaceGalleryColumn.resized(220, by: -80) == 300)
        #expect(WorkspaceGalleryColumn.resized(220, by: 500) == WorkspaceGalleryColumn.widthRange.lowerBound)
        #expect(WorkspaceGalleryColumn.resized(220, by: -900) == WorkspaceGalleryColumn.widthRange.upperBound)
        #expect(WorkspaceGalleryColumn.widthRange == 180...600)
        #expect(WorkspaceGalleryColumn.tileHeight(columnWidth: 220, showsContext: false) == 128)
        #expect(WorkspaceGalleryColumn.tileHeight(columnWidth: 440, showsContext: false) == 256)
        #expect(WorkspaceGalleryColumn.tileHeight(columnWidth: 360, showsContext: true) == 128)
        // Minimized under the gallery, Context is a bar and the column is the gallery's.
        #expect(WorkspaceGalleryColumn.showsContext(hasPanel: true, showsGallery: true, contextMinimized: false))
        #expect(!WorkspaceGalleryColumn.showsContext(hasPanel: true, showsGallery: true, contextMinimized: true))
        #expect(WorkspaceGalleryColumn.showsContext(hasPanel: true, showsGallery: false, contextMinimized: true))
        #expect(!WorkspaceGalleryColumn.showsContext(hasPanel: false, showsGallery: true, contextMinimized: false))
    }

    @Test("@spec LAYOUT-2.261: While the user drags an agent tile over a stage pane on Mac or iPad, the application shall highlight the half of the pane the agent would take, left or right over the pane's side thirds and upper or lower over the top or bottom of its middle, and the whole pane over its center, where the drop replaces what the pane shows.")
    func aDragHighlightsWhereTheAgentWouldLand() {
        typealias Layout = WorkspaceLayout<String>
        #expect(Layout.dropEdge(x: 100, y: 300, width: 1000, height: 600) == .left)
        #expect(Layout.dropEdge(x: 900, y: 300, width: 1000, height: 600) == .right)
        #expect(Layout.dropEdge(x: 500, y: 100, width: 1000, height: 600) == .top)
        #expect(Layout.dropEdge(x: 500, y: 500, width: 1000, height: 600) == .bottom)
        #expect(Layout.dropEdge(x: 500, y: 300, width: 1000, height: 600) == nil)
        let size = CGSize(width: 1000, height: 600)
        #expect(WorkspaceStageDropTarget.highlight(.right, in: size) == CGRect(x: 500, y: 0, width: 500, height: 600))
        #expect(WorkspaceStageDropTarget.highlight(.left, in: size) == CGRect(x: 0, y: 0, width: 500, height: 600))
        #expect(WorkspaceStageDropTarget.highlight(.top, in: size) == CGRect(x: 0, y: 0, width: 1000, height: 300))
        #expect(WorkspaceStageDropTarget.highlight(.bottom, in: size) == CGRect(x: 0, y: 300, width: 1000, height: 300))
        #expect(WorkspaceStageDropTarget.highlight(nil, in: size) == CGRect(origin: .zero, size: size))
    }

    @Test func theEmptyTileNamesItsWorktree() {
        #expect(AgentGalleryEmptyTile.title(worktreePath: "/repo/.worktrees/graft-bug") == "Add agent to graft-bug")
        #expect(AgentGalleryEmptyTile.title(worktreePath: "") == "Add agent")
    }

    @Test func offStageQuestionsShowOnTheFocusedStagePane() {
        var (entry, first, _) = twoAgentEntry(split: true)
        let binding = Binding(get: { entry }, set: { entry = $0 })
        #expect(view(binding).stageBannerGroupID == entry.workspaceLayout?.group(containing: first)?.id)
    }

    @Test func stagingAnOffStageAgentReplacesTheFocusedPane() {
        var (entry, first, second) = twoAgentEntry()
        let binding = Binding(get: { entry }, set: { entry = $0 })
        view(binding).stageAgent(second)
        #expect(entry.workspaceLayout?.isOnStage(second) == true)
        #expect(entry.workspaceLayout?.isOnStage(first) == false)
        #expect(entry.focusedPaneSlotID == second)
        #expect(entry.workspaceLayout?.gallerySessions == [first, second])
    }

    private final class CompletedModel: ObservableObject {
        @Published var agent: ManagedAgent
        init() {
            var agent = ManagedAgent(name: "Finished", provider: .codex, parent: nil, launchOrigin: .cliAgentAdd, isPrimary: false)
            _ = try! agent.finish(assignment: agent.assignmentID, result: "Done")
            self.agent = agent
        }
    }
    private struct CompletedFixture: View {
        @ObservedObject var model: CompletedModel
        let load: @MainActor (ManagedAgent) async throws -> String?
        var body: some View { CompletedAgentContent(agent: model.agent, launching: false, onResume: {}, loadTranscript: load) }
    }

    @Test("@spec AGENT-6.130: When a selected agent has retained result content, the application shall render that content inside its pane while keeping the tab header mounted.")
    func retainedContentKeepsTabHeader() async throws {
        _ = NSApplication.shared
        let manager = TerminalManager(socketPath: "/tmp/graftty-completed-agent-test.sock")
        let slot = PaneSlotID()
        var headerMounted = false, resultMounted = false
        let view = TerminalContentView(terminalManager: manager,
            splitTree: .constant(SplitTree(root: .leaf(slot))), focusedPaneSlotID: nil,
            theme: .fallback, onFocusTerminal: { _ in },
            paneHeader: { _ in AnyView(Text("Agent tabs").onAppear { headerMounted = true }) },
            paneContent: { _ in AnyView(Text("Completed result").onAppear { resultMounted = true }) })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<50 where !headerMounted || !resultMounted { try await Task.sleep(for: .milliseconds(20)) }
        #expect(headerMounted && resultMounted)
    }

    @Test("@spec LAYOUT-2.177: While a terminal attachment is loading or unavailable, the application shall keep its tab header mounted so users can select another session.")
    func loadingTerminalKeepsTabControls() async throws {
        _ = NSApplication.shared
        let manager = TerminalManager(socketPath: "/tmp/graftty-workspace-view-test.sock")
        let slot = PaneSlotID()
        var headerMounted = false
        let view = TerminalContentView(terminalManager: manager,
            splitTree: .constant(SplitTree(root: .leaf(slot))), focusedPaneSlotID: slot,
            theme: .fallback, onFocusTerminal: { _ in },
            paneHeader: { _ in AnyView(Text("Agent tabs").onAppear { headerMounted = true }) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        for _ in 0..<50 where !headerMounted { try await Task.sleep(for: .milliseconds(20)) }
        #expect(headerMounted)
        try captureWorkspaceIfRequested(manager: manager)
    }

    private func captureWorkspaceIfRequested(manager: TerminalManager) throws {
        guard let directory = ProcessInfo.processInfo.environment["GRAFTTY_TEST_SCREENSHOT_DIR"] else { return }
        let a = PaneSlotID(), b = PaneSlotID(), shell = PaneSlotID()
        var first = ManagedAgent(name: "Implement workspace", provider: .codex, parent: nil, launchOrigin: .cliAgentAdd, isPrimary: false)
        first.paneSlotID = a
        var second = ManagedAgent(name: "Review lifecycle", provider: .claude, parent: nil, launchOrigin: .cliAgentAdd, isPrimary: false)
        second.paneSlotID = b
        second.providerSessionID = "saved-conversation"
        let completion = try second.finish(assignment: second.assignmentID, result: "Reviewed the workspace changes. Completed tabs retain their position and the parent has cleaned up this session.")
        try second.beginClose(completion: completion.id)
        second.didClose()
        var entry = WorktreeEntry(path: "/repo/agent-workspace", branch: "agent-workspace", state: .running,
            splitTree: SplitTree(root: .leaf(a)).inserting(b, at: a, direction: .horizontal)
                .inserting(shell, at: a, direction: .vertical).removing(b))
        var layout = WorkspaceLayout<PaneSlotID>()
        layout.addAgent(a); layout.addAgent(b); layout.addTerminal(shell); _ = layout.hideDrawer(); layout.select(b)
        entry.agents = [first, second]; entry.workspaceLayout = layout; entry.focusedPaneSlotID = a
        let binding = Binding(get: { entry }, set: { entry = $0 })
        let root = WorkspaceContentView(terminalManager: manager, worktree: binding,
            onFocusTerminal: { _ in }, onNewTerminal: {}, onCloseTerminal: { _ in })
        let output = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, width, height) in [("wide", 1000.0, 700.0), ("compact", 520.0, 500.0)] {
            let host = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("workspace-completed-fixture-\(name).png"))
        }
    }
}
