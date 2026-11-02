import AppKit
import SwiftUI
import Testing
import CoreTransferable
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
@testable import Graftty

@MainActor
struct WorkspaceTabDragInteractionTests {
    @Test("@spec LAYOUT-2.197: When the user drags an agent tab on Mac, the application shall start a native in-app tab drag after the drag threshold, preserve contextual menus, and select a tab on click without selecting it on drag.")
    func agentTabsUseNativeClickAndDragSources() async throws {
        _ = NSApplication.shared
        let a = PaneSlotID(), b = PaneSlotID()
        var entry = WorktreeEntry(path: "/repo/tabs", branch: "tabs", state: .running,
            splitTree: SplitTree(root: .leaf(a)).inserting(b, at: a, direction: .horizontal))
        entry.agents = [a, b].map { slot in
            var agent = ManagedAgent(name: "Agent", provider: .codex, parent: nil)
            agent.paneSlotID = slot
            return agent
        }
        entry.paneSessions = [a: PaneSessionID(), b: PaneSessionID()]
        let group = WorkspaceLayout<PaneSlotID>.Group(sessions: [a, b], selected: a)
        entry.workspaceLayout = WorkspaceLayout(root: .group(group.id), groups: [group])
        var activated: [PaneSlotID] = []
        let manager = TerminalManager(socketPath: "/tmp/graftty-native-tab-drag.sock")
        let hosted = NSHostingView(rootView: WorkspaceContentView(terminalManager: manager,
            worktree: Binding(get: { entry }, set: { entry = $0 }),
            onFocusTerminal: { entry.focusedPaneSlotID = $0 }, onNewTerminal: {}, onCloseTerminal: { _ in },
            onActivateTerminal: { activated.append($0) }))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 900, height: 500),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = hosted
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func sources(in view: NSView) -> [SidebarRowDragSourceView] {
            if let source = view as? SidebarRowDragSourceView { return [source] }
            return view.subviews.flatMap(sources)
        }
        for _ in 0..<50 where sources(in: hosted).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(sources(in: hosted).count == 2)
        let type = NSPasteboard.PasteboardType(WorkspaceTabDrag.contentType.identifier)
        let source = try #require(sources(in: hosted).first { view in
            guard let data = view.pasteboardWriter?.pasteboardPropertyList(forType: type) as? Data else { return false }
            return (try? JSONDecoder().decode(WorkspaceTabDrag.self, from: data).session) == b.id.uuidString
        })
        let payload = try #require(source.pasteboardWriter?.pasteboardPropertyList(forType: type) as? Data)
        let provider = NSItemProvider(item: payload as NSData, typeIdentifier: type.rawValue)
        let decoded: WorkspaceTabDrag = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: WorkspaceTabDrag.self) { continuation.resume(with: $0) }
        }
        #expect(decoded.session == b.id.uuidString)
        source.onClick?()
        #expect(activated == [b])
        let recording = RecordingTabDragView(frame: .init(x: 0, y: 0, width: 100, height: 40))
        recording.pasteboardWriter = source.pasteboardWriter
        recording.onClick = { activated.append(a) }
        func event(_ kind: NSEvent.EventType, x: CGFloat, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: kind, location: .init(x: x, y: 10), modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let down = try event(.leftMouseDown, x: 10)
        #expect(recording.hitTest(.init(x: 10, y: 10), event: down) === recording)
        #expect(recording.hitTest(.init(x: 10, y: 10), event: try event(.rightMouseDown, x: 10)) == nil)
        #expect(recording.hitTest(.init(x: 10, y: 10), event: try event(.leftMouseDown, x: 10, modifiers: .control)) == nil)
        recording.mouseDown(with: down)
        recording.mouseDragged(with: try event(.leftMouseDragged, x: 12))
        #expect(recording.items.isEmpty)
        recording.mouseDragged(with: try event(.leftMouseDragged, x: 20))
        recording.mouseUp(with: try event(.leftMouseUp, x: 20))
        #expect(recording.items.count == 1)
        #expect(activated == [b])
    }

}

@MainActor
private final class RecordingTabDragView: SidebarRowDragSourceView {
    var items: [NSDraggingItem] = []
    override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: any NSDraggingSource) -> NSDraggingSession {
        self.items = items
        return NSDraggingSession()
    }
}

