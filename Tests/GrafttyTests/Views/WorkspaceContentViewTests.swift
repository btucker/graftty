import AppKit
import SwiftUI
import Testing
import GrafttyKit
import GrafttyProtocol
@testable import Graftty

@MainActor
struct WorkspaceContentViewTests {
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
        second.paneSlotID = b; second.observeWaiting(true)
        var entry = WorktreeEntry(path: "/repo/agent-workspace", branch: "agent-workspace", state: .running,
            splitTree: SplitTree(root: .leaf(a)).inserting(b, at: a, direction: .horizontal)
                .inserting(shell, at: a, direction: .vertical))
        var layout = WorkspaceLayout<PaneSlotID>()
        layout.addAgent(a); layout.addAgent(b); layout.addTerminal(shell); layout.select(a)
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
                .write(to: output.appendingPathComponent("workspace-loading-fixture-\(name).png"))
        }
    }
}
