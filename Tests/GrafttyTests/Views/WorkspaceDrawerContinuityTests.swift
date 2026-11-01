import AppKit
import SwiftUI
import Testing
import GrafttyCommandUI
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct WorkspaceDrawerContinuityTests {
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
        init(_ entry: WorktreeEntry) { self.entry = entry }
    }
    private struct Fixture: View {
        @ObservedObject var model: Model
        let manager: TerminalManager
        var body: some View {
            WorkspaceContentView(terminalManager: manager, worktree: $model.entry,
                onFocusTerminal: { model.entry.focusedPaneSlotID = $0 }, onNewTerminal: {}, onCloseTerminal: { _ in })
        }
    }
}
