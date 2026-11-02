import AppKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct WorkspaceContentViewTests {
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

    @Test("@spec LAYOUT-2.190: When the user selects a live agent or terminal-drawer tab, the application shall give that terminal keyboard focus, including when the tab is already selected.", arguments: [false, true])
    func selectingTabActivatesItsTerminal(inDrawer: Bool) async throws {
        _ = NSApplication.shared
        let first = PaneSlotID(), second = PaneSlotID()
        var entry = WorktreeEntry(path: "/repo/tabs", branch: "tabs", state: .running,
            splitTree: SplitTree(root: .split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(first), right: .leaf(second)))))
        entry.agents = [("Codex A", first), ("Codex B", second)].map { name, slot in
            var agent = ManagedAgent(name: name, provider: .codex, parent: nil)
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
            else { view.selectTab(second) }
            #expect(entry.focusedPaneSlotID == second)
            if inDrawer { #expect(entry.workspaceLayout?.selectedTerminal == second) }
            else { #expect(entry.workspaceLayout?.group(containing: second)?.selected == second) }
        }
        #expect(activated == [second, second])
    }

    private final class CompletedModel: ObservableObject {
        @Published var agent: ManagedAgent
        init() {
            var agent = ManagedAgent(name: "Finished", provider: .codex, parent: nil)
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
        var first = ManagedAgent(name: "Implement workspace", provider: .codex, parent: nil)
        first.paneSlotID = a
        var second = ManagedAgent(name: "Review lifecycle", provider: .claude, parent: nil)
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
