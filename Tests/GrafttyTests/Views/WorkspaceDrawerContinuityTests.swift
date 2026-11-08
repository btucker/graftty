import AppKit
import SwiftUI
import Testing
import GrafttyCommandUI
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct WorkspaceDrawerContinuityTests {
    @Test("Showing, updating, and clearing a question keeps the mounted Mac terminal and its native size unchanged")
    func questionKeepsMountedAgentAndSize() async throws {
        _ = NSApplication.shared
        let slot = PaneSlotID()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        harness.sizeStub = .testSize132x43
        let backend = FakeSurfaceHandleZmxBackend()
        let handle = try #require(SurfaceHandle(terminalID: slot, app: fakeApp(), worktreePath: "/tmp/workspace",
            socketPath: "/tmp/workspace-test.sock", zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory, zmxBackendFactory: { _, _, _, _ in backend }))
        let terminal = try #require(handle.view as? SurfaceNSView)
        terminal.surfaceOperations = .init(setSize: harness.factory.setSize,
            size: harness.factory.size, refresh: harness.factory.refresh, setFocus: { _, _ in })
        let manager = TerminalManager(socketPath: "/tmp/workspace-test.sock")
        manager.insertSurfaceForTesting(handle, for: slot)
        manager.recordAttachmentFailure("Fixture disconnection", for: handle)
        var entry = WorktreeEntry(path: "/tmp/workspace", branch: "workspace", state: .running,
            splitTree: SplitTree(root: .leaf(slot)))
        let session = PaneSessionID()
        entry.paneSessions = [slot: session]
        var layout = WorkspaceLayout<PaneSlotID>()
        layout.addAgent(slot)
        entry.workspaceLayout = layout
        entry.focusedPaneSlotID = slot
        let model = Model(entry)
        let host = NSHostingView(rootView: Fixture(model: model, manager: manager))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 600, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        let original = terminal.frame
        let wrapper = try #require(handle.followerPresentation)
        for question in ["Pick an approach?", "A different question with more text that wraps across the pane before the agent can continue.", nil] {
            harness.setSizeCalls.removeAll()
            model.context = SidebarWorktreeContext(worktree: .init(path: entry.path, displayName: "workspace", repoDisplayName: "repo",
                displayBranch: "workspace", state: .running, isMainCheckout: false, prBadge: nil, stats: nil,
                attentionText: nil, layout: .leaf(sessionName: ZmxLauncher.sessionName(for: session), title: "Claude",
                    attentionText: question, isBusy: false, attentionSource: .agentStop)))
            try #require(model.context?.question == question)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            #expect(handle.followerPresentation === wrapper)
            #expect(terminal.window === window)
            #expect(terminal.frame == original)
            let pixels = terminal.convertToBacking(original.size)
            #expect(harness.setSizeCalls.allSatisfy {
                $0.width == UInt32(pixels.width) && $0.height == UInt32(pixels.height)
            }, "An input request must not change the native terminal dimensions")
            if let question {
                let requestFrame = try #require(accessibilityFrame(label: question, in: host))
                let retryFrame = try #require(accessibilityFrame(label: "Retry", in: host))
                #expect(retryFrame.maxY <= requestFrame.minY - 8, "The floating request must leave Retry visible below it")
            }
        }
    }

    @Test("@spec LAYOUT-2.181: When the terminal drawer opens or closes, the application shall retain the mounted agent surface and resize it directly to the final canvas viewport without intermediate terminal sizes.")
    func drawerKeepsMountedAgentAndSettledSize() async throws {
        _ = NSApplication.shared
        let slot = PaneSlotID(), shell = PaneSlotID()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        harness.sizeStub = .testSize132x43
        let backend = FakeSurfaceHandleZmxBackend()
        let handle = try #require(SurfaceHandle(terminalID: slot, app: fakeApp(), worktreePath: "/tmp/workspace",
            socketPath: "/tmp/workspace-test.sock", zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            surfaceFactory: harness.factory, zmxBackendFactory: { _, _, _, _ in backend }))
        let terminal = try #require(handle.view as? SurfaceNSView)
        terminal.surfaceOperations = .init(setSize: harness.factory.setSize,
            size: harness.factory.size, refresh: harness.factory.refresh, setFocus: { _, _ in })
        let manager = TerminalManager(socketPath: "/tmp/workspace-test.sock")
        manager.insertSurfaceForTesting(handle, for: slot)
        var entry = WorktreeEntry(path: "/tmp/workspace", branch: "workspace", state: .running,
            splitTree: SplitTree(root: .leaf(slot)).inserting(shell, at: slot, direction: .vertical))
        var agent = ManagedAgent(name: "Agent", provider: .codex, parent: nil)
        agent.paneSlotID = slot
        entry.agents = [agent]
        var layout = WorkspaceLayout<PaneSlotID>()
        layout.addAgent(slot); layout.addTerminal(shell); _ = layout.hideDrawer()
        entry.workspaceLayout = layout
        entry.focusedPaneSlotID = slot
        let model = Model(entry)
        let hosting = NSHostingView(rootView: Fixture(model: model, manager: manager))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        let wrapper = try #require(handle.followerPresentation)
        let initial = terminal.frame.size
        for visible in [true, false, true, false] {
            harness.setSizeCalls.removeAll()
            harness.setOcclusionCalls.removeAll()
            model.entry.workspaceLayout?.drawerVisible = visible
            try await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
            #expect(handle.followerPresentation === wrapper)
            #expect(terminal.window === window)
            #expect(!harness.setOcclusionCalls.contains(false))
            let finalPixels = terminal.convertToBacking(terminal.frame.size)
            #expect(harness.setSizeCalls.count == 1, "Redundant terminal resize calls: \(harness.setSizeCalls)")
            #expect(harness.setSizeCalls.allSatisfy {
                $0.width == UInt32(finalPixels.width) && $0.height == UInt32(finalPixels.height)
            }, "Intermediate resize sequence: \(harness.setSizeCalls)")
            #expect(terminal.frame.height == initial.height - (visible ? 240 + HorizontalResizeDivider.thickness : 0))
        }
    }

    private final class Model: ObservableObject {
        @Published var entry: WorktreeEntry
        @Published var context: SidebarWorktreeContext?
        init(_ entry: WorktreeEntry) { self.entry = entry }
    }
    private func accessibilityFrame(label: String, in element: NSObject) -> CGRect? {
        let labelSelector = NSSelectorFromString("accessibilityLabel")
        if element.responds(to: labelSelector),
           element.perform(labelSelector)?.takeUnretainedValue() as? String == label,
           let accessible = element as? NSAccessibilityElementProtocol {
            return accessible.accessibilityFrame()
        }
        let childrenSelector = NSSelectorFromString("accessibilityChildren")
        guard element.responds(to: childrenSelector),
              let children = element.perform(childrenSelector)?.takeUnretainedValue() as? [NSObject] else { return nil }
        return children.lazy.compactMap { accessibilityFrame(label: label, in: $0) }.first
    }
    private struct Fixture: View {
        @ObservedObject var model: Model
        let manager: TerminalManager
        var body: some View {
            WorkspaceContentView(terminalManager: manager, worktree: $model.entry,
                onFocusTerminal: { model.entry.focusedPaneSlotID = $0 }, onNewTerminal: {}, onCloseTerminal: { _ in },
                attentionContext: model.context)
                .environment(\.accessibilityEnabled, true)
        }
    }
}
